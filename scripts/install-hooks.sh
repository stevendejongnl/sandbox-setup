#!/bin/bash
# install-hooks.sh — symlink repo hooks into .git/hooks/
# Run once after cloning: ./scripts/install-hooks.sh
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_SRC="$REPO_ROOT/hooks"
HOOKS_DEST="$REPO_ROOT/.git/hooks"

for hook in pre-commit pre-push; do
  ln -sf "$HOOKS_SRC/$hook" "$HOOKS_DEST/$hook"
  echo "Installed $hook"
done

echo "Done. Hooks active for this clone."
