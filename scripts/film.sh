#!/usr/bin/env bash
# Build the launch film end to end: capture the app, render the phone, cut the film.
#
#   scripts/film.sh              # capture + render + post
#   scripts/film.sh --no-capture # reuse the existing screen take
#
# Stages, each of which can be run on its own:
#   1. film-capture.sh  drives the app's scripted --tour on a dedicated simulator
#   2. ffmpeg           flattens the variable-rate screen recording to 60fps stills
#   3. film-scene.py    procedurally builds the iPhone Air and renders the sequence
#   4. film-post.py     titles, grades and encodes
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
TAKE=${TAKE:-/tmp/tailscode-screen.mov}
SCREEN=${SCREEN:-/tmp/screen-frames}
MASTER=${MASTER:-/tmp/film-master}
OUT=${OUT:-$ROOT/build/tailscode-launch.mp4}
WIDTH=${WIDTH:-1920}
HEIGHT=${HEIGHT:-1080}
SAMPLES=${SAMPLES:-64}
# The recorder starts before the app does; OFFSET drops the springboard and the
# launch fade so film frame 1 is the tour's first frame. Re-measure it whenever
# the take is re-shot — the tour drifts a second or two between runs, and the
# camera keyframes in film-scene.py are timed against a specific take.
OFFSET=${OFFSET:-168}
SECONDS_=${SECONDS_:-68}

if [ "${1:-}" != "--no-capture" ]; then
  echo "== 1/4 capturing the app"
  "$ROOT/scripts/film-capture.sh" 78 "$TAKE"
fi

echo "== 2/4 flattening the take to 60fps stills"
rm -rf "$SCREEN" && mkdir -p "$SCREEN"
ffmpeg -v error -i "$TAKE" -vsync cfr -r 60 -q:v 3 "$SCREEN/screen_%05d.jpg"
echo "   $(ls "$SCREEN" | wc -l | tr -d ' ') frames"

echo "== 3/4 rendering the phone (this is the long one)"
rm -rf "$MASTER" && mkdir -p "$MASTER"
"$BLENDER" --background -P "$ROOT/scripts/film-scene.py" -- \
  --frames "$SCREEN" --out "$MASTER/" --screen-offset "$OFFSET" --seconds "$SECONDS_" \
  --width "$WIDTH" --height "$HEIGHT" --samples "$SAMPLES" \
  > /tmp/film-render.log 2>&1
echo "   $(ls "$MASTER" | wc -l | tr -d ' ') frames rendered"

echo "== 4/4 titling and encoding"
mkdir -p "$(dirname "$OUT")"
python3 "$ROOT/scripts/film-post.py" --frames "$MASTER" --out "$OUT"
ffprobe -v error -show_entries format=duration -show_entries stream=width,height \
  -of default=nw=1 "$OUT"
echo "film -> $OUT"
