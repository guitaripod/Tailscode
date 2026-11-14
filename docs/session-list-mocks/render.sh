#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
HS=$( (ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
  ~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-*/chrome-headless-shell 2>/dev/null || true) | tail -1)
for page in "$@"; do
  file="${page%%#*}"
  name="${file%.html}"
  [ "$page" != "$file" ] && name="$name-${page##*#}"
  "$HS" --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor="${SCALE:-3}" --window-size="${WIDTH:-660},${HEIGHT:-900}" --screenshot="$name.png" "file://$PWD/$page" >/dev/null 2>&1
  echo "$name.png"
done
