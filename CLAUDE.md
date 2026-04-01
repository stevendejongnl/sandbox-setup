# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**sandbox-setup** provisions a browser-accessible root shell on Debian/Ubuntu. It runs ttyd (WebSocket terminal) + tmux for session persistence, and resets the environment on every disconnect — removing any installed packages and re-running `bootstrap.sh`.

Default service port: **7681**. Requires a reverse proxy with authentication — no built-in auth.

## Common Commands

```bash
# Setup git hooks (once after clone)
./scripts/install-hooks.sh

# Validate all shell files (same as CI)
find . -not -path './.git/*' \( -name "*.sh" -o -name ".bashrc" -o -name ".bash_profile" \) \
  | xargs shellcheck

# Bash syntax check only
find . -not -path './.git/*' \( -name "*.sh" -o -name ".bashrc" -o -name ".bash_profile" \) \
  | while IFS= read -r f; do bash -n "$f" || exit 1; done

# Secret scan (full history)
gitleaks detect --redact

# Install on target machine (run as root)
bash scripts/install.sh
SANDBOX_PORT=8080 bash scripts/install.sh  # custom port
```

## Architecture

**Session lifecycle:**
1. Browser connects → ttyd WebSocket → `sandbox-session` wrapper called
2. `sandbox-session` creates/attaches tmux `main` session
3. On `exit` or `restore-session` → cleanup: compare installed packages against `/etc/sandbox-baseline-packages`, purge new packages, re-run `bootstrap.sh`
4. Next connect starts fresh

**Key scripts and what they do:**

| Script | Runs as | Purpose |
|--------|---------|---------|
| `scripts/install.sh` | root, once | Installs system packages, ttyd, writes service scripts to `/usr/local/bin/`, generates mobile UI, snapshots baseline packages |
| `bootstrap.sh` | user, every reset | Installs uv, syncs `repos.txt`, symlinks dotfiles |
| `/usr/local/bin/sandbox-session` | user (from ttyd) | tmux wrapper + post-exit cleanup orchestrator |
| `scripts/provision.sh` | operator | Proxmox LXC helper — SSHs into PVE host and runs install.sh inside the container |

**Mobile UI:** `install.sh` fetches ttyd's built-in HTML, injects a viewport meta tag, WebSocket interceptor, and CSS toolbar, saving to `/usr/local/share/sandbox/index.html`.

## Customization Points

- **`repos.txt`** — HTTPS git URLs cloned/synced on every session reset
- **`bootstrap.sh`** — User-level setup commands (uv tools, npm globals, etc.)
- **`dotfiles/`** — `.bashrc`, `.bash_profile`, `.tmux.conf` symlinked to `$HOME`

## CI / Hooks

GitHub Actions (`.github/workflows/validate.yml`) runs on every push/PR: bash syntax check → shellcheck → gitleaks.

Pre-commit hook validates staged files; pre-push validates full history. Both use the same three checks.

`.gitleaks.toml` extends default rules and allowlists base64 patterns in `provision.sh`.
