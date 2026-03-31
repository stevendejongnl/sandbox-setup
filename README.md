# sandbox-setup

A persistent, browser-accessible root shell on any Linux machine. Connect from any browser (desktop or mobile) and get a full terminal. The session survives disconnects. Exiting resets the environment back to a clean state.

- **Terminal**: ttyd + tmux — WebSocket-based, xterm.js frontend, works on iOS Safari
- **Session**: tmux `main` — reconnecting resumes where you left off
- **Reset on exit**: apt packages purged, bootstrap re-runs, fresh session on next connect
- **Manual reset**: run `restore-session` from inside the terminal

## Quick install

On any Debian/Ubuntu machine, as root:

```bash
git clone https://github.com/stevendejongnl/sandbox-setup.git
cd sandbox-setup
bash scripts/install.sh
```

ttyd starts on port **7681**. Put a reverse proxy in front of it (see [Reverse proxy](#reverse-proxy)).

## Customising

### Bootstrap (`bootstrap.sh`)

Runs automatically after every session exit and on `restore-session`. Edit it to install tools, set config, or do anything you want in a fresh environment.

### Repos (`repos.txt`)

Add HTTPS git URLs, one per line. They're cloned (or pulled if present) on every bootstrap run.

```
https://github.com/you/your-project.git
https://github.com/you/dotfiles.git
```

### Dotfiles (`dotfiles/`)

Files in `dotfiles/` are symlinked to `$HOME/` on each bootstrap run. Includes `.bashrc` (aliases, PATH, welcome banner) and `.bash_profile` (login shell bridge to `.bashrc`).

## Reset behaviour

| Trigger | What happens |
|---------|-------------|
| Type `exit` | apt packages reset to baseline, bootstrap re-runs, fresh session on reconnect |
| `restore-session` | same — kills the session, triggering the same cleanup |
| Browser disconnect / C-a d | nothing — session stays alive |

The baseline is snapshotted at install time (`/etc/sandbox-baseline-packages`). Anything installed since then is removed on reset.

---

## Reverse proxy

ttyd has no built-in auth. **Always put a reverse proxy with authentication in front of it** — Basic Auth, OAuth, SSO, or similar.

WebSocket must be forwarded (`Upgrade` / `Connection` headers).

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name sandbox.example.com;

    location / {
        proxy_pass http://localhost:7681;
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
    reverse_proxy localhost:7681
}
```

**Traefik / others:** point to `localhost:7681`, enable WebSocket passthrough.

---

## Running in an isolated Proxmox LXC

If you want the terminal to be network-isolated from your LAN (cannot reach local devices even as root), run it inside a Proxmox LXC container on a NAT-only bridge.

### 1. Create a NAT bridge on the Proxmox host

One-time setup. Choose a private subnet that doesn't overlap with your LAN.

Add to `/etc/network/interfaces` on the Proxmox host:

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

Then bring it up: `ifup vmbr1`

> Adjust the subnet, bridge name (`vmbr1`), and uplink bridge (`vmbr0`) to match your setup.

### 2. Create the LXC container

```bash
CTID=200
STORAGE=local-lvm
BRIDGE=vmbr1
CONTAINER_IP=10.0.100.2
GATEWAY=10.0.100.1

pct create $CTID local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname sandbox \
  --memory 2048 --swap 512 --cores 2 \
  --rootfs ${STORAGE}:20 \
  --net0 name=eth0,bridge=${BRIDGE},ip=${CONTAINER_IP}/24,gw=${GATEWAY},type=veth \
  --nameserver 8.8.8.8 \
  --features nesting=1 \
  --onboot 1 --unprivileged 1
pct start $CTID
```

### 3. Run the provisioning script

From your workstation (requires SSH access to the Proxmox host):

```bash
CTID=200 PVE_HOST=myhost ./scripts/provision.sh
```

This copies `install.sh` into the container and runs it.

### 4. Reverse proxy

The Proxmox host DNATs port 7681 to the container, so point your reverse proxy at the host IP on port 7681 — the container itself is not directly reachable from the LAN.

---

## Dev hooks

After cloning, run once to activate git hooks:

```bash
./scripts/install-hooks.sh
```

Hooks run bash syntax checks, shellcheck, and gitleaks before every commit and push. The same checks run in CI via GitHub Actions on every push and pull request.
