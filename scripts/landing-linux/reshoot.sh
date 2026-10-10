#!/bin/bash
# The Linux landing-page shots of the Studio and the compact chat, reproducible on the Arch box.
#
#   TSLP=~/tslp scripts/landing-linux/reshoot.sh <stage...>
#   (DISP=90 MOCK_PORT=8233 TSLP=~/tslp2 for a second, independent run beside the first)
#
#   mock       start the stand-in ComfyUI on :8203 over $TSLP/mockout (a copy of the art's mock-output)
#   assets     poster crops and the blurred sketch the forge demo is told about (needs $TSLP/art)
#   chat       desk-dark-chat, desk-dark-rail, desk-light-chat
#   split      desk-dark-split, desk-light-split
#   studio     desk-dark-studio, desk-light-studio: the whole window with the Studio sheet up (lighthouse picked off the shelf)
#   paint      the studio mid-render, for the composite
#   forge      the video forge running and with a clip landed, for the composite
#   states     desk-dark-studio-states, composed from the four
#   all        every stage in that order, then stop
#   stop       stop the harness and the mock
#
# Everything runs on display $DISP (default 87; DISP, MOCK_PORT and GEOM override) of this machine, over the scripts/dev-linuxapp.sh harness: a 3840x2300
# screen at GDK_SCALE=2 so a window 1920x1080 in layout is drawn at 3840x2160 and cropped from the top left.
set -euo pipefail

T=${TSLP:-$HOME/tslp}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$T/out
PYX=$HOME/.cache/tailscode-dev/xvenv/bin/python
MOCK_PORT=${MOCK_PORT:-8203}
DISP=${DISP:-87}
GEOM=${GEOM:-3840x2300x24}
LIGHTHOUSE_PROMPT="a lighthouse on a cliff at dusk, waves breaking below, last light on the lamp room"
export MOCK_PORT DISP TSLP=$T
mkdir -p "$OUT" "$T/assets"

h() {
    TAILSCODE_DEV_DISPLAY_NUM=$DISP TAILSCODE_DEV_GEOM=$GEOM GDK_SCALE=2 \
        TAILSCODE_IMAGE_ENDPOINT=http://arch:$MOCK_PORT TAILSCODE_DEMO_FORGE_PORT=$MOCK_PORT \
        PATH=$HOME/.local/bin:$PATH "$T/scripts/dev-linuxapp.sh" "$@"
}

prefs() { python3 "$HERE/prefs.py" "$@" >/dev/null; }

shoot() {
    local name=$1 drive=$2 wait=$3
    shift 3
    h stop >/dev/null 2>&1 || true
    prefs "$@"
    h start --release --no-build --fresh --drive "$drive" -- --demo | tail -1
    sleep "$wait"
    h shot "$OUT/$name.raw.png" >/dev/null
    magick "$OUT/$name.raw.png" -crop 3840x2160+0+0 +repage "$OUT/$name.png"
    rm -f "$OUT/$name.raw.png"
}

# The Studio is a sheet inside the main window now, not a window of its own, so every Studio shot is the
# whole Tailscode window with the sheet up (the click coordinates are the 2x device pixels of the sheet's
# first shelf tile and its words box in a 1920x1080 window).
wshot() {
    local id
    id=$(h run "$PYX" "$HERE/winid.py" "$1")
    [ -n "$id" ] || { echo "no window $1" >&2; return 1; }
    h run sh -c "xwd -display :$DISP -id $id -silent | magick xwd:- $OUT/$2.png"
}

mock_stop() {
    [ -s "$T/mock.pid" ] && kill "$(cat "$T/mock.pid")" 2>/dev/null || true
    rm -f "$T/mock.pid"
}

mock_start() {
    mock_stop
    sleep 0.5
    (
        cd "$T/scripts"
        MOCK_OUTPUT=$T/mockout MOCK_RESULTS=${1:-studio/01-lighthouse.png} MOCK_PORT=$MOCK_PORT \
            MOCK_RENDER_SECONDS=14 MOCK_PAUSE_AT_STEP=15 setsid python3 mock-comfyui.py >"$T/mock.log" 2>&1 &
        echo $! >"$T/mock.pid"
    )
    sleep 1
    head -4 "$T/mock.log"
    grep -q "Address already in use" "$T/mock.log" && { echo "port $MOCK_PORT is held by a mock this script did not start" >&2; return 1; }
    return 0
}

shelf_order() {
    local i=1
    for f in 01-lighthouse 02-aurora-cabin 03-sauna 04-cat-roof 05-station 06-fox 07-ramen 08-paper-boats 09-greenhouse 10-cabin-interior 11-portrait-fjord; do
        [ -f "$T/mockout/studio/$f.png" ] && touch -d "$((i * 7)) minutes ago" "$T/mockout/studio/$f.png"
        i=$((i + 1))
    done
}

forge_env() {
    local a=$T/assets
    export TAILSCODE_DEMO_SKETCH="$a/cat-sketch.jpg,$a/poster-aurora-cabin.png,$a/poster-cat-roof.png,$a/poster-sauna.png,$a/poster-lighthouse.png,$a/poster-fox.png,$a/poster-station.png"
}

stage_assets() {
    python3 "$HERE/make-assets.py" "$T/art" "$T/assets"
    "$HERE/mkclips.sh"
}

stage_chat() {
    local m=$T/mockout/studio
    local drive="3500:openid=demo-c1;6000:landingchat=$m/01-lighthouse.png,$m/02-aurora-cabin.png"
    shoot desk-dark-chat "$drive" 12
    h move 860 1232
    sleep 1.5
    h move 880 1233
    sleep 2
    h shot "$OUT/desk-dark-rail.raw.png" >/dev/null
    magick "$OUT/desk-dark-rail.raw.png" -crop 3840x2160+0+0 +repage "$OUT/desk-dark-rail.png"
    rm -f "$OUT/desk-dark-rail.raw.png"
    shoot desk-light-chat "$drive" 12 'tailscode.appearance="light"'
}

stage_split() {
    local drive="3000:mark=0;3100:mark=4;3200:mark=7;3300:mark=2;4000:marksplit=sideBySide;6000:chord=ctrl+w a;6500:chord=ctrl+w a"
    shoot desk-dark-split "$drive" 14
    shoot desk-light-split "$drive" 14 'tailscode.appearance="light"'
}

studio_done() {
    shoot "$1.pre" "3500:openid=demo-c1;5000:image" 12 'tailscode.image.aspect="landscape"' "tailscode.appearance=\"$2\""
    h click 3560 366
    sleep 7
    h click 1800 1930
    sleep 0.5
    h type "$LIGHTHOUSE_PROMPT"
    sleep 2
    h move 2400 1900
    sleep 1
    wshot Tailscode "$1"
}

stage_studio() {
    shelf_order
    mock_start
    studio_done desk-dark-studio dark
    studio_done desk-light-studio light
}

stage_paint() {
    shelf_order
    mv "$T/mockout/studio/01-lighthouse.png" "$T/mockout/lighthouse.src"
    mock_start lighthouse.src
    shoot paint "3500:openid=demo-c1;5000:image;6500:imagetype=$LIGHTHOUSE_PROMPT;7500:imagego" 20 'tailscode.image.aspect="landscape"'
    wshot Tailscode paint
    mv "$T/mockout/lighthouse.src" "$T/mockout/studio/01-lighthouse.png"
    shelf_order
    mock_start
}

stage_forge() {
    forge_env
    shoot forge-running "3500:openid=demo-c1;5000:forge=running" 12 'tailscode.image.aspect="landscape"'
    wshot Tailscode forge-running
    shoot forge-done "3500:openid=demo-c1;5000:forge=history;9000:fstate=done" 14 'tailscode.image.aspect="landscape"'
    wshot Tailscode forge-done
}

stage_states() {
    python3 "$HERE/compose-states.py" "$OUT/desk-dark-studio-states.png" \
        "$OUT/paint.png" "$OUT/desk-dark-studio.png" "$OUT/forge-running.png" "$OUT/forge-done.png"
}

stage_stop() {
    h stop || true
    mock_stop
}

[ $# -gt 0 ] || { sed -n '2,19p' "$0"; exit 2; }
for stage in "$@"; do
    case $stage in
    mock) mock_start ;;
    assets) stage_assets ;;
    chat) stage_chat ;;
    split) stage_split ;;
    studio) stage_studio ;;
    paint) stage_paint ;;
    forge) stage_forge ;;
    states) stage_states ;;
    stop) stage_stop ;;
    all)
        stage_assets
        stage_chat
        stage_split
        stage_studio
        stage_paint
        stage_forge
        stage_states
        stage_stop
        ;;
    *) echo "unknown stage $stage" >&2; exit 2 ;;
    esac
done
