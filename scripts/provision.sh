#!/bin/bash
# provision.sh — Proxmox helper: runs install.sh inside an LXC container.
# For non-Proxmox installs, run install.sh directly on the target machine.
#
# Usage: CTID=200 PVE_HOST=myhost ./scripts/provision.sh
# shellcheck disable=SC2029  # $CTID and $SCRIPT intentionally expand client-side
set -euo pipefail

CTID="${CTID:?Usage: CTID=200 PVE_HOST=myhost ./scripts/provision.sh}"
PVE_HOST="${PVE_HOST:?Set PVE_HOST to your Proxmox hostname or IP}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Copying install.sh into container $CTID on $PVE_HOST"
scp "$SCRIPT_DIR/install.sh" "$PVE_HOST:/tmp/sandbox-install.sh"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct push $CTID /tmp/sandbox-install.sh /tmp/sandbox-install.sh --perms 755
rm /tmp/sandbox-install.sh
EOF"

echo "==> Running install.sh in container $CTID"
ssh "$PVE_HOST" "sudo su << 'EOF'
pct exec $CTID -- bash /tmp/sandbox-install.sh
pct exec $CTID -- rm /tmp/sandbox-install.sh
EOF"

echo ""
echo "Done! Container $CTID is ready."
echo "  Point your reverse proxy at <proxmox-host-ip>:7681"
echo "  Open your sandbox URL in the browser"
echo "  Inside tmux: git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup && ~/setup/bootstrap.sh"
