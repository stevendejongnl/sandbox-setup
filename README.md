# sandbox-setup

Reproducible setup for the `sandbox` LXC container — a persistent, browser-accessible tmux terminal exposed at `sandbox.madebysteven.nl`.

## What this is

A web terminal (ttyd + tmux) running in an isolated LXC container on Proxmox. You get a persistent shell in your browser with internet access but no local network access.

- **URL**: https://sandbox.madebysteven.nl
- **Auth**: HTTP basic auth (username: `steven`)
- **Terminal**: xterm.js via ttyd, works on mobile (iOS Safari)
- **Session**: tmux session named `main` — survives browser disconnects
- **Restore**: `sudo restore-session` to wipe and re-bootstrap the environment

## Two-layer persistence

| Layer | What | Survives restore? |
|-------|------|------------------|
| Files | Everything in `/home/terminal/` | ✅ Always |
| Tools | uv, pip packages, venvs | ❌ Reinstalled by bootstrap |

## Recreating the container

### 1. Provision the LXC on Proxmox (pve2)

```bash
ssh pve2 'sudo su << EOF
pct create 133 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname aiaiai \
  --memory 2048 \
  --swap 512 \
  --cores 2 \
  --rootfs VM-drives:20 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.55/24,gw=192.168.1.254,type=veth \
  --nameserver 8.8.8.8 \
  --features nesting=1 \
  --onboot 1 \
  --unprivileged 1
pct start 133
EOF'
```

Adjust CTID, IP, storage, and Proxmox host as needed.

### 2. Run the provisioning script

```bash
# From your workstation (requires ssh access to pve2):
./scripts/provision.sh
```

This installs all system packages, creates the `terminal` user, sets up iptables isolation, installs ttyd, and configures systemd.

You will be prompted for the ttyd credentials (username + password). Store them in 1Password.

### 3. Add a reverse proxy rule

ttyd listens on port **7681** (HTTP). Point any reverse proxy at `<container-ip>:7681`.

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name sandbox.example.com;
    # ... your SSL config ...

    location / {
        proxy_pass http://192.168.1.55:7681;
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
    reverse_proxy 192.168.1.55:7681
}
```

**Traefik / Zoraxy / others:** add a rule with domain `sandbox.example.com` pointing to `192.168.1.55:7681`. WebSocket passthrough must be enabled (most proxies do this automatically).

> **WebSocket is required** — ttyd uses WebSockets for the terminal stream. Ensure your proxy passes `Upgrade` and `Connection` headers.

### 4. Bootstrap the session environment (inside the container)

Once the container is running, open the terminal and:

```bash
git clone https://github.com/stevendejong/sandbox-setup.git ~/setup
~/setup/bootstrap.sh
```

## bootstrap.sh

`bootstrap.sh` is the idempotent user-level setup script. Edit it to define what gets installed and which repos get cloned. It is re-run by `restore-session` to rebuild the environment.

Edit `repos.txt` to list HTTPS git URLs to clone into `~/`:

```
# repos.txt — one repo per line, HTTPS URLs only (LAN is blocked)
# https://github.com/you/your-project.git
```

## Network isolation

The container can reach the internet but **not** the local 192.168.1.0/24 network:

```
iptables OUTPUT DROP → 192.168.1.0/24
iptables OUTPUT DROP → 10.0.0.0/8
iptables OUTPUT DROP → 172.16.0.0/12
DNS: 8.8.8.8 (not local resolver)
```

## Restoring the environment

From within the tmux session:

```bash
sudo restore-session
```

This kills the current tmux session, re-runs `bootstrap.sh` (pulls repos, reinstalls uv/tools), then ttyd auto-restarts a fresh session.
