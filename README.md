# sandbox-setup

Reproducible setup for the `sandbox` LXC container — a persistent, browser-accessible tmux terminal exposed at `sandbox.madebysteven.nl`.

## What this is

A web terminal (ttyd + tmux) running in an isolated LXC container on Proxmox. You get a persistent root shell in your browser with internet access but no local network access.

- **URL**: https://sandbox.madebysteven.nl
- **Auth**: HTTP Basic Auth at the Zoraxy reverse proxy level (not in ttyd)
- **Terminal**: xterm.js via ttyd, works on mobile (iOS Safari)
- **Session**: tmux session named `main` — survives browser disconnects
- **Session user**: root (full access inside the container — LXC + NAT bridge is the isolation boundary)
- **Reset**: type `exit` or run `restore-session` — apt packages removed, bootstrap re-runs, fresh session on reconnect

## Two-layer persistence

| Layer | What | Survives restore? |
|-------|------|------------------|
| Files | Everything in `/root/` | ✅ Always |
| Tools | uv, pip packages, venvs | ❌ Reinstalled by bootstrap |
| apt packages | anything installed since provision | ❌ Removed on reset |

## Recreating the container

### 1. Configure the NAT bridge on pve2 (once, if not already done)

Add `vmbr1` to `/etc/network/interfaces` on pve2:

```
auto vmbr1
iface vmbr1 inet static
	address 10.0.133.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
	post-up   iptables -t nat -A POSTROUTING -s 10.0.133.0/24 -o vmbr0 -j MASQUERADE
	post-up   iptables -t nat -A PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to-destination 10.0.133.2:7681
	post-up   iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
	post-up   iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
	post-down iptables -t nat -D POSTROUTING -s 10.0.133.0/24 -o vmbr0 -j MASQUERADE
	post-down iptables -t nat -D PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to-destination 10.0.133.2:7681
	post-down iptables -D FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
	post-down iptables -D FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Then bring it up:

```bash
ssh pve2 'sudo ifup vmbr1'
```

### 2. Create the LXC on Proxmox (pve2)

```bash
ssh pve2 'sudo su << EOF
pct create 133 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname sandbox \
  --memory 2048 \
  --swap 512 \
  --cores 2 \
  --rootfs VM-drives:20 \
  --net0 name=eth0,bridge=vmbr1,ip=10.0.133.2/24,gw=10.0.133.1,type=veth \
  --nameserver 8.8.8.8 \
  --features nesting=1 \
  --onboot 1 \
  --unprivileged 1
pct start 133
EOF'
```

Adjust CTID, storage, and Proxmox host as needed.

### 3. Run the provisioning script

```bash
# From your workstation (requires ssh access to pve2):
./scripts/provision.sh
```

This installs system packages, installs ttyd, configures `sandbox-session` (cleanup-on-exit wrapper), saves the baseline package list, and starts the ttyd systemd service.

### 4. Add a reverse proxy rule

ttyd listens on port **7681** inside the container. pve2 DNATs `<pve2-ip>:7681` → `10.0.133.2:7681`, so point your reverse proxy at pve2.

**Zoraxy:** add a rule `sandbox.example.com` → `<pve2-ip>:7681`. WebSocket passthrough must be enabled.

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name sandbox.example.com;

    location / {
        proxy_pass http://<pve2-ip>:7681;
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
    reverse_proxy <pve2-ip>:7681
}
```

> **WebSocket is required** — ttyd uses WebSockets for the terminal stream. Ensure your proxy passes `Upgrade` and `Connection` headers.

### 5. Bootstrap the session environment (inside the container)

Once the container is running, open the terminal and:

```bash
git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup
~/setup/bootstrap.sh
```

## bootstrap.sh

`bootstrap.sh` is the idempotent user-level setup script. Edit it to define what gets installed and which repos get cloned. It runs automatically after every session exit.

Edit `repos.txt` to list HTTPS git URLs to clone into `~/`:

```
# repos.txt — one repo per line, HTTPS URLs only (LAN is blocked)
# https://github.com/you/your-project.git
```

## Network isolation

The container runs on an isolated NAT bridge (`vmbr1`, 10.0.133.0/24) on pve2. Isolation is enforced at the host — there is no route to the LAN from inside the container, even as root.

```
Container IP:  10.0.133.2  (not on the LAN subnet)
Gateway:       10.0.133.1  (pve2 vmbr1)
Internet:      via NAT masquerade on pve2
LAN access:    none (no route)
DNS:           8.8.8.8 (public, via NAT)
ttyd inbound:  pve2:7681 DNAT → 10.0.133.2:7681
```

## Reset behaviour

**On exit** (type `exit` or shell closes):
1. apt packages installed since provisioning are purged
2. `bootstrap.sh` re-runs (pulls repos, reinstalls tools)
3. ttyd restarts → fresh session on next browser connect

**`restore-session`** does the same — kills the session, triggering the same cleanup.

**Detach** (C-a d) or browser disconnect: session stays alive, no cleanup.
