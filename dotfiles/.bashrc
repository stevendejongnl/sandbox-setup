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

# Reminder shown on new sessions
if [ -n "$TMUX" ]; then
  echo "  sandbox — $(hostname) — $(date '+%a %d %b %H:%M')"
  echo "  restore: sudo restore-session | setup: ~/setup/bootstrap.sh"
  echo ""
fi
