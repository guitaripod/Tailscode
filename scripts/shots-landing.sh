#!/usr/bin/env bash
# Reshoots the landing page's Studio phone shots, in both appearances of the Suomi theme, and
# writes them as the page names them: suomi-{dark,light}-13 .. 16.
#
#   TAILSCODE_STUDIO_ART=<folder of real pictures + manifest.json> \
#   scripts/shots-landing.sh <output folder, e.g. ~/Dev/web/midgarcorp/public/screenshots/tailscode>
#
# With --chat it reshoots the conversation screens instead, so the page shows the compact
# transcript and its link rail: 01 live, 02 the dial, 03 approval, 05 subagents, 06 work. The
# others of the twelve do not change with the transcript's look, and are left as they are.
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
CHAT=""
[ "${1:-}" = "--chat" ] && { CHAT=1; shift; }
DEST="${1:?output folder}"
WORK="$(mktemp -d)"
if [ -n "$CHAT" ]; then
  NAMES=(01-live 02-dial 03-approval 05-subagents 02-work)
  NUMBERS=(01 02 03 05 06)
else
  : "${TAILSCODE_STUDIO_ART:?TAILSCODE_STUDIO_ART is not set}"
  NAMES=(studio-paint studio-done video-run video-done)
  NUMBERS=(13 14 15 16)
fi

island_in() {
  python3 -W ignore - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
box = im.crop((380, 40, 940, 140))
dark = sum(1 for p in box.getdata() if max(p) < 6)
sys.exit(0 if dark > box.width * box.height * 0.5 else 1)
PY
}

for appearance in dark light; do
  export TAILSCODE_SHOT_THEME=suomi TAILSCODE_SHOT_APPEARANCE=$appearance
  out="$WORK/$appearance"
  TAILSCODE_SHOT_OUT="$out" "$ROOT/scripts/shots.sh" "${NAMES[@]}"
  for name in "${NAMES[@]}"; do
    for attempt in 1 2 3 4; do
      island_in "$out/$name.png" || break
      echo "  $name: the simulator drew the Dynamic Island, shooting again"
      TAILSCODE_SHOT_OUT="$out" "$ROOT/scripts/shots.sh" "$name"
    done
  done
  for i in "${!NAMES[@]}"; do
    python3 - "$out/${NAMES[$i]}.png" "$DEST/suomi-$appearance-${NUMBERS[$i]}.webp" <<'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], "WEBP", quality=85, method=6)
PY
  done
done
echo "-> $DEST (masters in $WORK)"
