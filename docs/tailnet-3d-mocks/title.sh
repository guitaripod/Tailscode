#!/usr/bin/env bash
set -euo pipefail
in="$1"; out="$2"; layout="$3"
cd "$(dirname "$0")"
width=$(magick identify -format %w "$in")
bold=/usr/share/fonts/noto/NotoSans-Bold.ttf
regular=/usr/share/fonts/noto/NotoSans-Regular.ttf
if [ "$layout" = portrait ]; then
  u=$(( width / 33 )); x=$(( u * 2 )); y=$(( u * 7 )); lx=$x; ly=$(( y + u * 4 ))
else
  u=$(( width / 96 )); x=$(( u * 3 )); y=$(( u * 5 )); lx=$(( width - u * 37 )); ly=$(( u * 4 ))
fi
args=( "$in" -fill '#e6ebf2' -font "$bold" -pointsize $(( u * 3 )) -annotate "+${x}+${y}" 'Tailnet'
  -fill '#8f9bb0' -font "$regular" -pointsize $(( u * 3 / 2 )) -annotate "+${x}+$(( y + u * 2 + u / 3 ))" '7 of 13 online  ·  2 working  ·  1 needs you' )
cx=$lx
if [ "$layout" = portrait ]; then ps=$u; else ps=$(( u * 5 / 4 )); fi
r=$(( ps * 32 / 100 ))
for item in '#f0a08a:Claude Code' '#a9cdfb:opencode' '#a8e6ae:Your model' '#cbb9f6:omp'; do
  color=${item%%:*}; label=${item#*:}
  args+=( -fill "$color" -draw "circle $(( cx + r )),$(( ly - r )) $(( cx + r * 2 )),$(( ly - r ))"
    -fill '#c3ccd9' -font "$regular" -pointsize "$ps" -annotate "+$(( cx + r * 3 ))+${ly}" "$label" )
  cx=$(( cx + r * 3 + ${#label} * ps * 56 / 100 + ps * 13 / 10 ))
done
magick "${args[@]}" -depth 8 "$out"
