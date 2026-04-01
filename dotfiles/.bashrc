# shellcheck shell=bash
# .bashrc — sandbox terminal user
# Sourced by interactive bash shells

# Random hacker alias per session (also masks root from tools like Claude Code)
_SANDBOX_NAMES=(
  "null-ptr" "segfault" "buffer-overflow" "heap-wizard" "kernel-panic"
  "fork-bomb" "sudo-nym" "bit-flipper" "stack-smasher" "rm-rf"
  "git-pusher" "xss-enjoyer" "tcp-ghost" "endian-error" "race-condition"
  "zero-day" "nan-boxer" "off-by-one" "dirty-pipe" "chaos-daemon"
)
SANDBOX_USER="${_SANDBOX_NAMES[$RANDOM % ${#_SANDBOX_NAMES[@]}]}"
export USER="$SANDBOX_USER"
alias whoami='echo "$USER"'

# Wrap claude with fakeid.so so process.getuid() returns 1000, not 0.
# Without this, Claude Code warns about running as root on every launch.
claude() { LD_PRELOAD=/usr/local/lib/fakeid.so command claude "$@"; }

export PATH="$HOME/.local/bin:$PATH"

# Handy aliases
alias ll='ls -lah --color=auto'
alias ..='cd ..'
alias gs='git status'
alias gl='git log --oneline -10'

PS1='\[\033[01;31m\]${SANDBOX_USER}\[\033[00m\]@\[\033[01;34m\]\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# uv / python
export UV_LINK_MODE=copy

# Route HTTPS through mitmproxy so claude-dashboard captures API calls.
# The mitmproxy CA cert is trusted system-wide (installed by install.sh).
export HTTPS_PROXY=http://localhost:8082
export HTTP_PROXY=http://localhost:8082
export NO_PROXY=localhost,127.0.0.1,::1

# Help text shown once per tmux session (not on every new pane)
if [ -n "$TMUX" ] && [ ! -f /tmp/.sandbox_welcomed ]; then
  touch /tmp/.sandbox_welcomed
  echo ""
  echo "  ┌─ sandbox ──────────────────────────────────────────┐"
  echo "  │  hey, ${SANDBOX_USER}   $(date '+%a %d %b %H:%M')                  │"
  echo "  ├────────────────────────────────────────────────────┤"
  echo "  │  Network    internet only  (no LAN access)         │"
  echo "  │  Files      ~/   persistent across restores        │"
  echo "  │  Tools      uv, python, git  (reinstalled on restore) │"
  echo "  ├────────────────────────────────────────────────────┤"
  echo "  │  First time?                                       │"
  echo "  │    git clone <your-setup-repo> ~/setup             │"
  echo "  │    ~/setup/bootstrap.sh                            │"
  echo "  │                                                    │"
  echo "  │  Rebuild environment (keeps files):                │"
  echo "  │    restore-session                                 │"
  echo "  ├────────────────────────────────────────────────────┤"
  echo "  │  tmux: C-a |  split right   C-a -  split down     │"
  echo "  │        C-a d  detach         C-a [  scroll mode    │"
  echo "  └────────────────────────────────────────────────────┘"
  echo ""
fi
