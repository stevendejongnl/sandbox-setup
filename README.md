# sandbox-setup

A persistent, browser-accessible root shell running in an isolated LXC container on Proxmox. Connect from any browser (desktop or mobile) and get a full terminal. The session survives disconnects. Exiting resets the environment back to a clean state.

- **Terminal**: ttyd + tmux — WebSocket-based, xterm.js frontend, works on iOS Safari
- **Session**: tmux `main` — reconnecting resumes the same session
- **User**: root inside the container (the LXC + NAT bridge is the isolation boundary)
- **Reset on exit**: apt packages purged, bootstrap re-runs, fresh session on next connect
- **Manual reset**: run `restore-session` from inside the terminal

## How it works

```
Browser → reverse proxy → Proxmox host DNAT → LXC container:7681 (ttyd)
                                                     ↓
                                               tmux session main
```

The container sits on a private NAT bridge on the Proxmox host. It has full internet access via NAT masquerade but no route to your LAN — enforced at the host, not inside the container.

```
Container IP:  10.0.X.2/24       (private, not on your LAN)
Internet:      ✅ via NAT on host
LAN:           ❌ no route
ttyd inbound:  <host-ip>:7681  DNAT → container:7681
```

## Prerequisites

- A Proxmox host (tested on PVE 8)
- A Debian 12 LXC template available (`debian-12-standard_*.tar.zst`)
- SSH access to the Proxmox host
- A reverse proxy in front (nginx, Caddy, Traefik, Zoraxy, etc.)

---

## Setup

### Step 1 — Create a NAT bridge on the Proxmox host

This is a one-time setup per host. Choose a private subnet that doesn't conflict with your LAN (e.g. `10.0.100.0/24`).

Append to `/etc/network/interfaces` on your Proxmox host:

```
auto vmbr1
iface vmbr1 inet static
    address 10.0.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.0.100.0/24 -o vmbr0 -j MASQUERADE
    post-up   iptables -t nat -A PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to-destination 10.0.100.2:7681
    post-up   iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
    post-up   iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    post-down iptables -t nat -D POSTROUTING -s 10.0.100.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to-destination 10.0.100.2:7681
    post-down iptables -D FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

> Adjust the subnet (`10.0.100.0/24`), bridge name (`vmbr1`), and LAN bridge (`vmbr0`) to match your setup. If you want multiple containers or a different port, adjust the DNAT rule accordingly.

Bring it up without rebooting:

```bash
ifup vmbr1
```

### Step 2 — Create the LXC container

```bash
CTID=200                   # pick a free container ID
STORAGE=local-lvm          # your Proxmox storage name
BRIDGE=vmbr1               # the NAT bridge from step 1
CONTAINER_IP=10.0.100.2    # must match the DNAT target above
GATEWAY=10.0.100.1         # the bridge IP from step 1

pct create $CTID local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname sandbox \
  --memory 2048 \
  --swap 512 \
  --cores 2 \
  --rootfs ${STORAGE}:20 \
  --net0 name=eth0,bridge=${BRIDGE},ip=${CONTAINER_IP}/24,gw=${GATEWAY},type=veth \
  --nameserver 8.8.8.8 \
  --features nesting=1 \
  --onboot 1 \
  --unprivileged 1
pct start $CTID
```

### Step 3 — Run the provisioning script

```bash
git clone https://github.com/stevendejongnl/sandbox-setup.git
cd sandbox-setup

CTID=200 PVE_HOST=your-proxmox-host ./scripts/provision.sh
```

`PVE_HOST` is whatever you use to SSH into the Proxmox host. `CTID` must match the container you created.

This installs system packages, ttyd, the `sandbox-session` cleanup wrapper, saves the baseline package snapshot, and starts the ttyd systemd service.

### Step 4 — Add a reverse proxy rule

ttyd listens on port **7681** inside the container. The Proxmox host DNATs `<host-ip>:7681` to the container, so point your reverse proxy at the host.

> **WebSocket is required.** ttyd uses WebSockets for the terminal stream — ensure your proxy forwards `Upgrade` and `Connection` headers.

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name sandbox.example.com;

    location / {
        proxy_pass http://<proxmox-host-ip>:7681;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600;
    }
}
```

**Caddy:**
```
sandbox.example.com {
    reverse_proxy <proxmox-host-ip>:7681
}
```

**Traefik / other:** point to `<proxmox-host-ip>:7681` with WebSocket passthrough enabled.

> **Auth**: ttyd itself has no authentication. Protect the URL with your reverse proxy (Basic Auth, SSO, etc.).

### Step 5 — Bootstrap the session environment

Open the terminal in your browser and run:

```bash
git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup
~/setup/bootstrap.sh
```

---

## Customising

### Adding tools on every reset (`bootstrap.sh`)

Edit `bootstrap.sh` to install anything you want available after every reset — pip packages, npm globals, config files, etc. It runs automatically when the session exits and on `restore-session`.

### Cloning repos on every reset (`repos.txt`)

Add HTTPS git URLs to `repos.txt`, one per line:

```
# repos.txt
https://github.com/you/your-project.git
https://github.com/you/dotfiles.git
```

These are cloned (or pulled if already present) on every bootstrap run.

### Dotfiles

Files in `dotfiles/` are symlinked to `$HOME/` on each bootstrap run. Edit `.bashrc` to customise aliases, the welcome banner, environment variables, etc.

---

## Reset behaviour

| Trigger | What happens |
|---------|-------------|
| Type `exit` in the shell | apt packages reset, bootstrap re-runs, fresh session on reconnect |
| `restore-session` | same — kills the session, triggering the same cleanup |
| Browser disconnect / C-a d | nothing — session stays alive |

The apt baseline is snapshotted at provision time (`/etc/sandbox-baseline-packages`). Anything installed since then is removed on reset.

---

## Installing the dev hooks

After cloning this repo, run once:

```bash
./scripts/install-hooks.sh
```

This symlinks `hooks/pre-commit` and `hooks/pre-push` into `.git/hooks/`. They run bash syntax checks, shellcheck, and gitleaks before every commit and push.
