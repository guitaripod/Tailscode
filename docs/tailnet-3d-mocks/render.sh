#!/usr/bin/env bash
# Renders one mock with Cycles, adds the glow, then the title and legend.
#
#   render.sh desk landscape 3840 2160 512
#   render.sh phone portrait 1320 2868 512
set -euo pipefail
name="$1"; layout="$2"; width="$3"; height="$4"; samples="$5"
cd "$(dirname "$0")"
blender -b --python scene.py -- "$layout" "$width" "$height" "$samples" "$PWD/$name-raw.png" 2>&1 | grep -iE "Traceback|Error:|line [0-9]+, in|Saved" | grep -v HIPEW || true
radius=$(( width / 110 ))
magick "$name-raw.png" \( +clone -blur "0x$radius" -evaluate multiply 0.5 \) -compose screen -composite \( +clone -blur "0x$(( radius * 4 ))" -evaluate multiply 0.22 \) -compose screen -composite -depth 8 "$name.png"
bash title.sh "$name.png" "$name.png" "$layout"
rm -f "$name-raw.png"
