#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
HS=$(ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell | tail -1)
for page in "$@"; do
  name="${page%.html}"
  "$HS" --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size="${WIDTH:-1572},${HEIGHT:-1500}" --screenshot="$name.png" "file://$PWD/$page" >/dev/null 2>&1
  echo "$name.png"
done
