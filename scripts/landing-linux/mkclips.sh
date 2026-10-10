#!/bin/bash
set -e
T=${TSLP:-$HOME/tslp}
mkdir -p "$T/mockout/video"
cd "$T/mockout/video"
M=$T/mockout/studio
i=0
for f in 02-aurora-cabin 04-cat-roof 03-sauna 01-lighthouse 06-fox 05-station; do
    src=$M/$f.png
    [ -f "$src" ] || src=$T/mockout/${f#*-}.src
    ffmpeg -loglevel error -y -loop 1 -framerate 24 -i "$src" \
        -vf "scale=2560:1408:force_original_aspect_ratio=increase,crop=2560:1408,zoompan=z=1+0.0008*on:x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=120:s=1280x704:fps=24" \
        -t 5 -pix_fmt yuv420p -c:v libx264 -crf 23 -movflags +faststart forge_0000$i.mp4
    i=$((i + 1))
done
