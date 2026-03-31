#!/bin/bash
# install.sh — Installs the sandbox web terminal on the local machine.
# Requires: Debian/Ubuntu, root.
# Usage: bash install.sh
#   SANDBOX_PORT=7681  (optional, default 7681)
set -euo pipefail

PORT="${SANDBOX_PORT:-7681}"

echo "==> [1/5] Installing system packages"
apt-get update -qq
apt-get install -y tmux curl wget git build-essential python3 ca-certificates 2>&1 | tail -3

echo "==> [2/5] Installing ttyd"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  TTYD_BIN="ttyd.x86_64" ;;
  aarch64) TTYD_BIN="ttyd.aarch64" ;;
  *)       echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
if [ ! -x /usr/local/bin/ttyd ]; then
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/$TTYD_BIN" \
    -o /usr/local/bin/ttyd
  chmod +x /usr/local/bin/ttyd
  echo "  installed ttyd"
else
  echo "  ttyd already installed"
fi

echo "==> [3/5] Writing service scripts"

# ttyd-start — launches ttyd pointing at sandbox-session
cat > /usr/local/bin/ttyd-start << SCRIPT_EOF
#!/bin/bash
exec /usr/local/bin/ttyd \\
  --writable \\
  --port $PORT \\
  --client-option fontFamily=monospace \\
  --client-option fontSize=15 \\
  /usr/local/bin/sandbox-session
SCRIPT_EOF
chmod 755 /usr/local/bin/ttyd-start

# sandbox-session — wraps tmux; resets environment when session actually ends
cat > /usr/local/bin/sandbox-session << 'SCRIPT_EOF'
#!/bin/bash
tmux new-session -A -s main

# If session still exists, this was a detach or browser disconnect — do nothing.
tmux has-session -t main 2>/dev/null && exit 0

# Session ended — reset environment for next user.
BASELINE=/etc/sandbox-baseline-packages
if [ -f "$BASELINE" ]; then
  TO_REMOVE=$(comm -23 \
    <(dpkg --get-selections | grep -v deinstall | awk '{print $1}' | sort) \
    <(sort "$BASELINE"))
  if [ -n "$TO_REMOVE" ]; then
    # shellcheck disable=SC2086
    apt-get purge -y $TO_REMOVE 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi
fi

if [ -f /root/setup/bootstrap.sh ]; then
  bash /root/setup/bootstrap.sh
fi

rm -f /tmp/.sandbox_welcomed
SCRIPT_EOF
chmod 755 /usr/local/bin/sandbox-session

# restore-session — kills the session; sandbox-session handles cleanup
cat > /usr/local/bin/restore-session << 'SCRIPT_EOF'
#!/bin/bash
echo "==> Ending session..."
tmux kill-session -t main 2>/dev/null && echo "Session killed." || echo "No active session."
echo "==> Environment will reset and reconnect in a moment."
SCRIPT_EOF
chmod 755 /usr/local/bin/restore-session

echo "==> [4/5] Configuring systemd service"
cat > /etc/systemd/system/ttyd.service << 'SVC_EOF'
[Unit]
Description=ttyd web terminal
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd-start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now ttyd

echo "==> [5/5] Saving baseline package list"
dpkg --get-selections | grep -v deinstall | awk '{print $1}' \
  > /etc/sandbox-baseline-packages
echo "  $(wc -l < /etc/sandbox-baseline-packages) packages in baseline"

echo ""
echo "Done! ttyd is running on port $PORT."
echo "  Point a reverse proxy at this machine:$PORT"
echo "  Inside tmux: git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup && ~/setup/bootstrap.sh"
