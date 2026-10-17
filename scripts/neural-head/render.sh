#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"${TMPDIR:-/tmp}/neural-head"}
width=${2:-1536}
samples=${3:-64}
device=${NEURAL_DEVICE:-gpu}

mkdir -p "$out"

render() {
  local mode=$1 spp=$2
  blender -b --factory-startup --python "$here/build_layers.py" -- mode="$mode" out="$out/$mode.png" samples="$spp" width="$width" device="$device" > "$out/$mode.log" 2>&1
  echo "rendered $mode"
}

for mode in chassis interior glass; do render "$mode" "$samples"; done
for mode in mask_i1 mask_i2 mask_i3 mask_c; do render "$mode" 12; done

python3 "$here/bake_bloom.py" "$out"
python3 "$here/composite.py" "$out" "$out/preview.png" matrix 0.7
echo "layers, masks, bloom and preview are in $out"
