#!/usr/bin/env bash
# sandbox.sh — Create a Proxmox LXC and install the sandbox web terminal.
# Run this on your Proxmox host:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevendejongnl/sandbox-setup/main/ct/sandbox.sh)"
# shellcheck source=/dev/null
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Sandbox"
var_tags="${var_tags:-sandbox}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-0}"  # privileged: root shell needs full container access

header_info "$APP"
variables
color
catch_errors

start
build_container

msg_info "Installing Sandbox"
pct exec "$CTID" -- bash -c \
  "$(curl -fsSL https://raw.githubusercontent.com/stevendejongnl/sandbox-setup/main/install/sandbox-install.sh)"
msg_ok "Installed Sandbox"

description
msg_ok "Completed Successfully!\n"
echo -e "${APP} is running at: ${BL}http://${IP}:7681${CL}"
echo -e "Point a reverse proxy at that address — ttyd has no built-in auth."
