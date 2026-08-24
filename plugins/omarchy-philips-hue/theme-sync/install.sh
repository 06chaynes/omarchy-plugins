#!/usr/bin/env bash
# Installs the omarchy theme-set hook that syncs Hue lights to the active
# theme, plus a default hue-theme.json config.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$HERE/45-hue.sh"
CONFIG_SRC="$HERE/hue-theme.json"
HOOK_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
CONFIG_DIR="$HOME/.config/omarchy/settings"
HOOK_DEST="$HOOK_DIR/45-hue.sh"
CONFIG_DEST="$CONFIG_DIR/hue-theme.json"

[[ -f "$HOOK_SRC" ]] || { echo "error: missing $HOOK_SRC" >&2; exit 1; }

mkdir -p "$HOOK_DIR" "$CONFIG_DIR"

if [[ -f "$HOOK_DEST" ]] && [[ ! -L "$HOOK_DEST" ]]; then
  backup="$HOOK_DEST.bak.$(date +%s)"
  [[ ! -L "$backup" ]] || rm "$backup"
  cp -f "$HOOK_DEST" "$backup"
  echo "Backed up existing hook to $backup"
fi

python3 -c "
import os
data = open('''$HOOK_SRC''', 'rb').read()
fd = os.open('''$HOOK_DEST''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755)
os.write(fd, data)
os.close(fd)
" 2>/dev/null || {
  rm -f "$HOOK_DEST" 2>/dev/null
  python3 -c "
import os
data = open('''$HOOK_SRC''', 'rb').read()
fd = os.open('''$HOOK_DEST''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755)
os.write(fd, data)
os.close(fd)
"
}
echo "Installed $HOOK_DEST"

if [[ -L "$CONFIG_DEST" ]]; then
  rm "$CONFIG_DEST"
fi
python3 -c "
import os
data = open('''$CONFIG_SRC''', 'rb').read()
fd = os.open('''$CONFIG_DEST''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, data)
os.close(fd)
" 2>/dev/null || {
  rm -f "$CONFIG_DEST" 2>/dev/null
  python3 -c "
import os
data = open('''$CONFIG_SRC''', 'rb').read()
fd = os.open('''$CONFIG_DEST''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, data)
os.close(fd)
"
}
echo "Installed $CONFIG_DEST"

echo
echo "Done. The hook runs automatically on every 'omarchy theme set'."
echo "Test it now with:  bash $HOOK_DEST <theme-slug>"
