#!/bin/bash
# bootstrap.sh — Idempotent user-level environment setup.
# Run after a restore, or on first boot inside the sandbox container.
# Safe to re-run: checks before installing.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── uv (Python package manager) ──────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
else
  echo "==> uv already installed ($(uv --version))"
fi
export PATH="$HOME/.local/bin:$PATH"

# ── Git repos ─────────────────────────────────────────────────────────────────
if [ -f "$SETUP_DIR/repos.txt" ]; then
  echo "==> Syncing repos from repos.txt"
  while IFS= read -r repo; do
    # Skip blank lines and comments
    [[ -z "$repo" || "$repo" == \#* ]] && continue
    name=$(basename "$repo" .git)
    if [ -d "$HOME/$name/.git" ]; then
      echo "   pull  $name"
      git -C "$HOME/$name" pull --ff-only 2>/dev/null || echo "   (pull skipped — dirty or diverged)"
    else
      echo "   clone $name"
      git clone "$repo" "$HOME/$name"
    fi
  done < "$SETUP_DIR/repos.txt"
else
  echo "==> No repos.txt found — skipping repo sync"
  echo "   Create $SETUP_DIR/repos.txt with one HTTPS git URL per line"
fi

# ── Dotfiles ──────────────────────────────────────────────────────────────────
echo "==> Linking dotfiles"
for f in "$SETUP_DIR/dotfiles"/.*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  ln -sf "$f" "$HOME/$name" && echo "   linked $name"
done

echo ""
echo "Bootstrap complete."
echo "  tmux is already running as session 'main' — you're in it."
echo "  Run 'sudo restore-session' to wipe tools and re-run this script."
