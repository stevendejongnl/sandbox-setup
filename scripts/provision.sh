#!/bin/bash
# provision.sh — Run from workstation to fully set up the sandbox LXC container.
#
# Prerequisites:
#   1. LXC container created and running (see README.md step 1)
#   2. vmbr1 NAT bridge configured on pve2 (see README.md step 2)
#   3. SSH access to pve2
#
# The container runs as root, on an isolated NAT bridge (vmbr1, 10.0.133.0/24).
# Network isolation is enforced at the host — no iptables rules needed inside.
# shellcheck disable=SC2029  # $CTID intentionally expands client-side in ssh commands
set -euo pipefail

CTID="${CTID:?Set CTID env var (e.g. CTID=200 PVE_HOST=myhost ./scripts/provision.sh)}"
PVE_HOST="${PVE_HOST:?Set PVE_HOST env var}"

echo "==> [1/4] Installing system packages"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"apt-get update -qq && apt-get install -y tmux curl wget git sudo iptables iptables-persistent build-essential python3 ca-certificates 2>&1 | tail -3\"
EOF"

echo "==> [2/4] Installing ttyd"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"[ -x /usr/local/bin/ttyd ] && echo ttyd already installed || (curl -fsSL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd && echo ttyd installed)\"
EOF"

echo "==> [3/4] Configuring ttyd service"
# ttyd runs without --credential. Auth is handled by Zoraxy (HTTP Basic Auth on the proxy rule).
# Add Basic Auth in Zoraxy admin UI -> HTTP Proxy -> sandbox rule -> Access Rules.

WRAPPER_B64=$(base64 -w0 << 'SCRIPT'
#!/bin/bash
exec /usr/local/bin/ttyd \
  --writable \
  --port 7681 \
  --client-option fontFamily=monospace \
  --client-option fontSize=15 \
  /usr/local/bin/sandbox-session
SCRIPT
)

SESSION_B64=$(base64 -w0 << 'SCRIPT'
#!/bin/bash
# sandbox-session: runs tmux and cleans up when the session actually ends.
tmux new-session -A -s main

# If session still exists, this was a detach or browser disconnect — do nothing.
# ttyd will reconnect to the same session.
tmux has-session -t main 2>/dev/null && exit 0

# Session is gone (user typed exit / killed the shell).
# Reset the environment so the next connection starts clean.

BASELINE=/etc/sandbox-baseline-packages
if [ -f "$BASELINE" ]; then
  TO_REMOVE=$(comm -23 \
    <(dpkg --get-selections | grep -v deinstall | awk '{print $1}' | sort) \
    <(sort "$BASELINE"))
  if [ -n "$TO_REMOVE" ]; then
    apt-get purge -y $TO_REMOVE 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi
fi

if [ -f /root/setup/bootstrap.sh ]; then
  bash /root/setup/bootstrap.sh
fi

rm -f /tmp/.sandbox_welcomed
SCRIPT
)

SVC_B64=$(base64 -w0 << 'SVC'
[Unit]
Description=ttyd web terminal (sandbox)
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd-start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC
)

RESTORE_B64=$(base64 -w0 << 'RESTORE'
#!/bin/bash
# restore-session: kills the tmux session.
# sandbox-session detects the session is gone and handles cleanup + bootstrap automatically.
echo "==> Ending session..."
tmux kill-session -t main 2>/dev/null && echo "Session killed." || echo "No active session."
echo "==> Environment will reset and reconnect in a moment."
RESTORE
)

ssh "$PVE_HOST" "sudo su << EOF
pct exec $CTID -- bash << 'INNER'
echo $WRAPPER_B64 | base64 -d > /usr/local/bin/ttyd-start
chmod 755 /usr/local/bin/ttyd-start
echo $SESSION_B64 | base64 -d > /usr/local/bin/sandbox-session
chmod 755 /usr/local/bin/sandbox-session
echo $SVC_B64 | base64 -d > /etc/systemd/system/ttyd.service
echo $RESTORE_B64 | base64 -d > /usr/local/bin/restore-session
chmod 755 /usr/local/bin/restore-session
rm -f /etc/sudoers.d/terminal /etc/sudoers.d/restore
dpkg --get-selections | grep -v deinstall | awk '{print $1}' > /etc/sandbox-baseline-packages
echo baseline packages saved
systemctl daemon-reload
systemctl enable --now ttyd
INNER
EOF"

echo "==> [4/4] Verifying"
sleep 2
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"curl -s -o /dev/null -w 'ttyd HTTP status: %{http_code}\n' http://localhost:7681\"
EOF"

echo ""
echo "Done! Container $CTID is ready."
echo "  Point your reverse proxy at <proxmox-host-ip>:7681 (DNAT forwards to the container)"
echo "  Open https://sandbox.example.com (or whatever domain you configured)"
echo "  Inside tmux: git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup && ~/setup/bootstrap.sh"
