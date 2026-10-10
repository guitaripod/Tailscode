#!/usr/bin/env bash
# Reshoots the landing page's Studio phone shots, in both appearances of the Suomi theme, and
# writes them as the page names them: suomi-{dark,light}-13 .. 16.
#
#   TAILSCODE_STUDIO_ART=<folder of real pictures + manifest.json> \
#   scripts/shots-landing.sh <output folder, e.g. ~/Dev/web/midgarcorp/public/screenshots/tailscode>
#
# 13 studio-paint  the image studio mid-render, the machine's sketch on the stage
# 14 studio-done   the finished picture, its real facts, the verbs and the shelf
# 15 video-run     the video forge mid-render, second pass
# 16 video-done    a finished clip on the stage
#
# The renders come from scripts/mock-comfyui.py started on TAILSCODE_STUDIO_MOCK_HOST (see
# scripts/shots.sh); the pictures are the art, so what is on screen is a real render's result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?output folder}"
: "${TAILSCODE_STUDIO_ART:?TAILSCODE_STUDIO_ART is not set}"
WORK="$(mktemp -d)"
NAMES=(studio-paint studio-done video-run video-done)

for appearance in dark light; do
  TAILSCODE_SHOT_THEME=suomi TAILSCODE_SHOT_APPEARANCE=$appearance \
    TAILSCODE_SHOT_OUT="$WORK/$appearance" "$ROOT/scripts/shots.sh" "${NAMES[@]}"
  for i in 0 1 2 3; do
    python3 - "$WORK/$appearance/${NAMES[$i]}.png" "$DEST/suomi-$appearance-$((13 + i)).webp" <<'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], "WEBP", quality=85, method=6)
PY
  done
done
echo "-> $DEST (masters in $WORK)"
