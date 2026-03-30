#!/bin/bash
# provision.sh — Run from workstation to fully set up the sandbox LXC container.
# Requires: ssh access to pve2, container already created and running.
set -euo pipefail

CTID="${CTID:-133}"
PVE_HOST="${PVE_HOST:-pve2}"

echo "==> [1/6] Installing system packages"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"apt-get update -qq && apt-get install -y tmux curl wget git sudo iptables iptables-persistent build-essential python3 ca-certificates 2>&1 | tail -3\"
EOF"

echo "==> [2/6] Creating terminal user"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"id terminal &>/dev/null || useradd -m -s /bin/bash terminal && echo terminal user ready\"
EOF"

echo "==> [3/6] Configuring network isolation (iptables)"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash << 'INNER'
iptables -C OUTPUT -d 192.168.1.0/24 -j DROP 2>/dev/null || iptables -A OUTPUT -d 192.168.1.0/24 -j DROP
iptables -C OUTPUT -d 10.0.0.0/8    -j DROP 2>/dev/null || iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
iptables -C OUTPUT -d 172.16.0.0/12 -j DROP 2>/dev/null || iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent 2>/dev/null || true
echo iptables rules saved
INNER
EOF"

echo "==> [4/6] Installing ttyd"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"[ -x /usr/local/bin/ttyd ] && echo ttyd already installed || (curl -fsSL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd && echo ttyd installed)\"
EOF"

echo "==> [5/6] Configuring ttyd credentials and service"
read -rp "ttyd username [steven]: " TTYD_USER
TTYD_USER="${TTYD_USER:-steven}"
read -rsp "ttyd password: " TTYD_PASS
echo

CRED_B64=$(printf 'TTYD_CREDENTIAL=%s:%s' "$TTYD_USER" "$TTYD_PASS" | base64 -w0)

WRAPPER_B64=$(base64 -w0 << 'SCRIPT'
#!/bin/bash
CRED=$(grep TTYD_CREDENTIAL /etc/ttyd/credentials | cut -d= -f2-)
/usr/local/bin/ttyd \
  --writable \
  --port 7681 \
  --credential "$CRED" \
  --client-option fontFamily=monospace \
  --client-option fontSize=15 \
  tmux new-session -A -s main
SCRIPT
)

SVC_B64=$(base64 -w0 << 'SVC'
[Unit]
Description=ttyd web terminal (sandbox)
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd-start
User=terminal
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC
)

RESTORE_B64=$(base64 -w0 << 'RESTORE'
#!/bin/bash
# restore-session: kills tmux session and re-runs bootstrap.
set -e
echo "==> Stopping tmux session..."
tmux kill-session -t main 2>/dev/null && echo "Session killed." || echo "No active session."
echo "==> Running bootstrap..."
if [ -f /home/terminal/setup/bootstrap.sh ]; then
  sudo -u terminal bash /home/terminal/setup/bootstrap.sh
else
  echo "No bootstrap.sh found at ~/setup/bootstrap.sh"
  echo "Run: git clone <your-setup-repo> /home/terminal/setup"
fi
echo "==> Done. Reconnect in your browser."
RESTORE
)

ssh "$PVE_HOST" "sudo su << EOF
pct exec $CTID -- bash << 'INNER'
mkdir -p /etc/ttyd
echo $CRED_B64 | base64 -d > /etc/ttyd/credentials
chown root:terminal /etc/ttyd/credentials
chmod 640 /etc/ttyd/credentials
echo $WRAPPER_B64 | base64 -d > /usr/local/bin/ttyd-start
chmod 755 /usr/local/bin/ttyd-start
echo $SVC_B64 | base64 -d > /etc/systemd/system/ttyd.service
echo $RESTORE_B64 | base64 -d > /usr/local/bin/restore-session
chmod 755 /usr/local/bin/restore-session
echo 'terminal ALL=(root) NOPASSWD: /usr/local/bin/restore-session' > /etc/sudoers.d/restore
chmod 440 /etc/sudoers.d/restore
systemctl daemon-reload
systemctl enable --now ttyd
INNER
EOF"

echo "==> [6/6] Verifying"
sleep 2
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash -c \"curl -s -o /dev/null -w 'ttyd HTTP status: %{http_code}\n' http://localhost:7681\"
EOF"

echo ""
echo "Done! Container $CTID is ready."
echo "  Add Zoraxy rule: sandbox.madebysteven.nl -> 192.168.1.55:7681"
echo "  Open https://sandbox.madebysteven.nl"
echo "  Inside tmux: git clone <your-setup-repo> ~/setup && ~/setup/bootstrap.sh"
