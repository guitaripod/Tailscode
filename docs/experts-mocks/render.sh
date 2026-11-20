#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
HS=$(ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell ~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell 2>/dev/null | tail -1 || true)
for page in "$@"; do
  name="${page%.html}"
  for theme in dark light; do
    out="$name.png"; [[ $theme == light ]] && out="$name-light.png"
    size="${WIDTH:-1572},${HEIGHT:-860}"
    [[ $name == *ipad* ]] && size="${WIDTH:-1300},${HEIGHT:-950}"
    "$HS" --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor="${SCALE:-2}" --window-size="$size" --screenshot="$out" "file://$PWD/$page#$theme" >/dev/null 2>&1
    echo "$out"
  done
done
