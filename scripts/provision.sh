#!/bin/bash
# provision.sh — Re-run the install script on an existing LXC container.
# For new containers use ct/sandbox.sh instead.
# For non-Proxmox installs run install/sandbox-install.sh directly.
#
# Usage: CTID=200 PVE_HOST=myhost ./scripts/provision.sh
# shellcheck disable=SC2029  # $CTID intentionally expands client-side
set -euo pipefail

CTID="${CTID:?Usage: CTID=200 PVE_HOST=myhost ./scripts/provision.sh}"
PVE_HOST="${PVE_HOST:?Set PVE_HOST to your Proxmox hostname or IP}"

INSTALL_URL="https://raw.githubusercontent.com/stevendejongnl/sandbox-setup/main/install/sandbox-install.sh"

echo "==> Running sandbox-install.sh in container $CTID on $PVE_HOST"
ssh "$PVE_HOST" "sudo pct exec $CTID -- bash -c \"\$(curl -fsSL $INSTALL_URL)\""

echo ""
echo "Done! Container $CTID is updated."
echo "  Sandbox running at <proxmox-host-ip>:7681"
