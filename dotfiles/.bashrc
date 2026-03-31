# shellcheck shell=bash
# .bashrc — sandbox terminal user
# Sourced by interactive bash shells

export PATH="$HOME/.local/bin:$PATH"

# Handy aliases
alias ll='ls -lah --color=auto'
alias ..='cd ..'
alias gs='git status'
alias gl='git log --oneline -10'

# uv / python
export UV_LINK_MODE=copy

# Help text shown once per tmux session (not on every new pane)
if [ -n "$TMUX" ] && [ ! -f /tmp/.sandbox_welcomed ]; then
  touch /tmp/.sandbox_welcomed
  echo ""
  echo "  ┌─ sandbox ──────────────────────────────────────────┐"
  echo "  │  $(hostname)   $(date '+%a %d %b %H:%M')                          │"
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
