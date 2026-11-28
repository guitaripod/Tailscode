#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
HS=$(ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell | tail -1)
shoot() {
  "$HS" --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size="$2" --screenshot="$1.png" "file://$PWD/$1.html" >/dev/null 2>&1
  magick "$1.png" -quality 84 "$1.webp" && rm "$1.png"
  echo "$1.webp"
}
shoot desktop 2684,1500
shoot phone 2010,910
