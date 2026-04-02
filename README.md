# sandbox-setup

A browser-accessible root shell on any Debian/Ubuntu machine. Connect from any browser — desktop or mobile — and get a full terminal. Sessions survive disconnects. Exiting resets the environment to a clean slate.

Also bundles [claude-dashboard](https://github.com/stevendejongnl/claude-dashboard) — a real-time proxy that intercepts Claude Code API traffic and shows it in a web dashboard at `/dashboard`.

---

## What it does

- **Terminal** — ttyd + tmux, WebSocket-based, xterm.js frontend. Works on iOS Safari.
- **Session persistence** — tmux `main` survives browser disconnects; reconnecting resumes exactly where you left off.
- **Reset on exit** — typing `exit` or running `restore-session` purges any packages installed since baseline, re-runs `bootstrap.sh`, and starts a fresh session on the next connect.
- **Claude Code proxy** — all Claude Code API calls are intercepted by mitmproxy. The `claude` shell function routes traffic through it automatically.
- **Dashboard** — live view of API flows, telemetry events, credential leak detection, cost stats, and session history at `/dashboard`.

---

## Architecture

```
Browser → reverse proxy → nginx:7681 (sandbox nginx)
                               ├── /           → ttyd:7682 (WebSocket terminal)
                               └── /dashboard/ → claude-dashboard:5000
                                                    ├── FastAPI (dashboard + REST API)
                                                    └── mitmproxy:8082 (traffic interceptor)
```

**Ports (all internal — only `7681` needs to be reachable from outside):**

| Port | Service |
|------|---------|
| 7681 | sandbox nginx — the only public-facing port |
| 7682 | ttyd (internal) |
| 5000 | claude-dashboard nginx → FastAPI |
| 8082 | mitmproxy HTTPS proxy |
| 8888 | FastAPI dashboard (internal) |

---

## Quick install

On any Debian/Ubuntu machine, as root:

```bash
git clone https://github.com/stevendejongnl/sandbox-setup.git
cd sandbox-setup
bash scripts/install.sh
```

Optional — change the public port (default `7681`):

```bash
SANDBOX_PORT=8080 bash scripts/install.sh
```

After install, put a reverse proxy in front of port `7681` (see [Reverse proxy](#reverse-proxy)).

### What the installer does

1. Installs system packages: `tmux`, `curl`, `wget`, `git`, `nginx`, `ca-certificates`, build tools
2. Downloads and installs [ttyd](https://github.com/tsl0922/ttyd) (latest release binary, x86_64 or aarch64)
3. Writes `/usr/local/bin/ttyd-start`, `sandbox-session`, `restore-session`
4. Patches ttyd's built-in HTML to inject a mobile-friendly toolbar (keyboard toggle, arrow keys, Ctrl combos)
5. Creates and enables `ttyd.service` systemd unit (internal port `7682`)
6. Configures nginx on port `7681` routing `/` → ttyd and `/dashboard/` → claude-dashboard
7. Installs Docker, clones claude-dashboard to `/opt/claude-dashboard`, generates the mitmproxy CA cert, creates and enables `claude-dashboard.service`
8. Snapshots installed packages to `/etc/sandbox-baseline-packages`

---

## Customisation

### Bootstrap (`bootstrap.sh`)

Runs automatically after every session reset and on first boot. Edit it to install tools, clone repos, configure your environment, etc.

```bash
# Example additions to bootstrap.sh
apt-get install -y nodejs npm
npm install -g typescript
```

### Repos (`repos.txt`)

One HTTPS git URL per line. Cloned on first bootstrap, pulled on subsequent runs.

```
https://github.com/you/your-project.git
https://github.com/you/dotfiles.git
```

### Dotfiles (`dotfiles/`)

Files in `dotfiles/` are symlinked to `$HOME/` on every bootstrap run. Ships with:

- `.bashrc` — aliases, PATH, welcome banner, `claude()` proxy wrapper
- `.bash_profile` — login shell bridge to `.bashrc`
- `.tmux.conf` — prefix key `C-a`, mouse mode, minimal status bar

### Port

Override at install time with the `SANDBOX_PORT` environment variable (default `7681`):

```bash
SANDBOX_PORT=9000 bash scripts/install.sh
```

---

## Session lifecycle

| Trigger | What happens |
|---------|--------------|
| Type `exit` | Packages reset to baseline, `bootstrap.sh` re-runs, fresh session on next connect |
| `restore-session` | Same — kills the session, triggering the same cleanup |
| Browser disconnect or `C-a d` | Nothing — session stays alive, reconnect resumes it |

The baseline is snapshotted at install time (`/etc/sandbox-baseline-packages`). Any packages installed since then are removed on reset.

---

## Claude Code proxy

The `claude` shell function in `.bashrc` wraps the Claude Code CLI with:

```bash
claude() {
  LD_PRELOAD=/usr/local/lib/fakeid.so \
  HTTPS_PROXY=http://localhost:8082 \
  HTTP_PROXY=http://localhost:8082 \
  NO_PROXY=localhost,127.0.0.1,::1 \
  NODE_EXTRA_CA_CERTS=/root/.mitmproxy/mitmproxy-ca-cert.pem \
  command claude "$@"
}
```

- **`fakeid.so`** — preloaded library that makes `getuid()` return `1000` so Claude Code doesn't refuse to run as root
- **Proxy env vars** — scoped to the `claude` command only; other tools (curl, git, uv) are unaffected
- **`NODE_EXTRA_CA_CERTS`** — required because Node.js has its own CA bundle and ignores the system trust store

The mitmproxy CA cert is installed system-wide (`/usr/local/share/ca-certificates/mitmproxy.crt`) for tools that respect it. You can also download it from the dashboard at `/dashboard/api/cert`.

---

## Reverse proxy

ttyd has no built-in authentication. **Always put a reverse proxy with auth in front of port `7681`** — Basic Auth, OAuth2 proxy, SSO, or similar.

WebSocket headers (`Upgrade`, `Connection`) must be forwarded.

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name sandbox.example.com;

    location / {
        proxy_pass         http://localhost:7681;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_read_timeout 7d;
        proxy_buffering    off;
    }
}
```

**Caddy:**
```
sandbox.example.com {
    reverse_proxy localhost:7681
}
```

> When served over HTTPS, the frontend automatically upgrades the WebSocket to `wss://`.

---

## Running in a Proxmox LXC

For a network-isolated sandbox (internet access only, no LAN access), run inside an LXC on a NAT-only bridge.

### 1. Create a NAT bridge on the Proxmox host

Add to `/etc/network/interfaces` (adjust subnet and bridge names for your setup):

```
auto vmbr1
iface vmbr1 inet static
    address 10.0.133.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.0.133.0/24 -o vmbr0 -j MASQUERADE
    post-up   iptables -t nat -A PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to 10.0.133.2:7681
    post-up   iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
    post-up   iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    post-down iptables -t nat -D POSTROUTING -s 10.0.133.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D PREROUTING  -i vmbr0 -p tcp --dport 7681 -j DNAT --to 10.0.133.2:7681
    post-down iptables -D FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Then: `ifup vmbr1`

### 2. Create the LXC container

```bash
CTID=133
STORAGE=local-lvm
BRIDGE=vmbr1
CONTAINER_IP=10.0.133.2
GATEWAY=10.0.133.1

pct create $CTID local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname sandbox \
  --memory 2048 --swap 1024 --cores 2 \
  --rootfs ${STORAGE}:20 \
  --net0 name=eth0,bridge=${BRIDGE},ip=${CONTAINER_IP}/24,gw=${GATEWAY},type=veth \
  --nameserver 8.8.8.8 \
  --features nesting=1 \
  --onboot 1 --unprivileged 1
pct start $CTID
```

`nesting=1` is required for Docker to run inside the container.

### 3. Provision

From your workstation (requires SSH access to the Proxmox host):

```bash
CTID=133 PVE_HOST=pve2 ./scripts/provision.sh
```

Or run `scripts/install.sh` directly inside the container.

### 4. Reverse proxy

The Proxmox host DNATs port `7681` to the container. Point your reverse proxy at the host IP on port `7681` — no changes needed to any upstream router or firewall.

---

## Community-scripts provisioner

`install/sandbox-install.sh` is compatible with the [community-scripts](https://github.com/community-scripts/ProxmoxVE) helper framework (`$STD`, `msg_info`, etc.). Use it if you manage LXC containers via that tooling.

---

## Resource requirements

| Component | Approx. RAM |
|-----------|------------|
| ttyd + tmux | ~20 MB |
| mitmproxy | ~380 MB |
| FastAPI dashboard | ~20 MB |
| nginx (both) | ~10 MB |

**Recommended: 2 GB RAM, 1 GB swap.** 1 GB is too tight when mitmproxy runs alongside a Claude Code session.

---

## Dev hooks

After cloning, activate git hooks once:

```bash
./scripts/install-hooks.sh
```

Runs bash syntax check, shellcheck, and gitleaks before every commit and push. The same checks run in CI via GitHub Actions.
