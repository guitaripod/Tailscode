#!/bin/bash
# The Mac marketing shots of the Studio and the compact chat, from a debug build of this checkout:
# mac-{dark,light}-studio, mac-dark-painting, mac-dark-video, mac-{dark,light}-viewer, mac-dark-chat,
# as 2880x1800 masters (full/) and 1920x1200 web copies. Every Studio shot is the whole window with the
# sheet up over the conversation; the viewer shots stack the media viewer's sheet over the finished Studio.
#
#   ART=<dir of real art + manifest.json> scripts/landing-shots-mac.sh [shot ...]
#
# Shots: studio-dark studio-light painting video viewer-dark viewer-light chat (default: all). Environment:
#   ART          the folder the art agents rendered (lighthouse.png ... , read by the assets script)
#   MOCK_HOST    where the stand-in ComfyUI runs (default arch, over ssh; "localhost" runs it here)
#   MOCK_PORT    its port (default 8202)
#   SITE         where the webp files are written (default ~/Dev/web/midgarcorp/public/screenshots/tailscode)
#   WORK         scratch (default /tmp/tailscode-landing-mac)
#   BUILD=0      reuse the app copy under $WORK from an earlier run
#   KIT          the CodingAgentKit checkout (default ~/Dev/swift/CodingAgentKit)
#
# The app is a copy with its own bundle id and defaults domain, so the installed Tailscode and the
# person's own preferences are never touched, and a debug build is what honours the staging
# variables (TAILSCODE_IMAGE_ENDPOINT, _IMAGE_SEED, _DEMO_ONLY, _VIDEO_CLIP, _VIDEO_POSTERS,
# _VIDEO_CLEAN). Nothing here can capture a real screen: the offscreen --shot path draws the view
# tree at 2x (--shot-scale) with the title bar (--shot-chrome); the Studio is a sheet inside that window,
# so it is part of the picture. Only processes this script started are ever stopped.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ART=${ART:?set ART to the folder holding the rendered pictures and manifest.json}
MOCK_HOST=${MOCK_HOST:-arch}
MOCK_PORT=${MOCK_PORT:-8202}
SITE=${SITE:-$HOME/Dev/web/midgarcorp/public/screenshots/tailscode}
WORK=${WORK:-/tmp/tailscode-landing-mac}
KIT=${KIT:-$HOME/Dev/swift/CodingAgentKit}
DOMAIN=com.guitaripod.tailscode.landing
APP=$WORK/app/Tailscode.app
BIN=$APP/Contents/MacOS/TailscodeMac
SHOTS=("$@")
[ ${#SHOTS[@]} -gt 0 ] || SHOTS=(studio-dark studio-light painting video viewer-dark viewer-light chat)
LIGHTHOUSE_SEED=$(python3 -c "import json,sys; print([m['seed'] for m in json.load(open('$ART/manifest.json')) if m['name']=='lighthouse'][0])")
LIGHTHOUSE_PROMPT=$(python3 -c "import json,sys; print([m['prompt'] for m in json.load(open('$ART/manifest.json')) if m['name']=='lighthouse'][0])")
MOCK_PID_FILE=$WORK/mock.pid
MOCK_ENDPOINT=http://$MOCK_HOST:$MOCK_PORT
mkdir -p "$WORK"

build_app() {
    local spec=$ROOT/project.landing.yml
    sed "s#path: ../../swift/CodingAgentKit#path: $KIT#" "$ROOT/project.yml" >"$spec"
    (cd "$ROOT" && /opt/homebrew/bin/xcodegen generate --spec "$spec" >/dev/null)
    rm -f "$spec"
    (cd "$ROOT" && xcodebuild -project Tailscode.xcodeproj -scheme TailscodeMac -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO build 2>&1 \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
    rm -rf "$WORK/app"
    mkdir -p "$WORK/app"
    cp -R "$WORK/dd/Build/Products/Debug/TailscodeMac.app" "$APP"
    plutil -replace CFBundleIdentifier -string "$DOMAIN" "$APP/Contents/Info.plist"
    codesign --force --deep --sign - "$APP" 2>&1 | tail -1
}

prepare_assets() {
    python3 "$ROOT/scripts/landing-shots-mac-assets.py" "$ART" "$WORK"
    /opt/homebrew/bin/ffmpeg -y -loglevel error -i "$ART/cat-roof.png" \
        -vf "crop=1728:950:0:100,zoompan=z='1+0.0005*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=120:s=1280x704:fps=24,format=yuv420p" \
        -c:v libx264 -crf 18 -movflags +faststart "$WORK/clip.mp4"
}

stop_mock() {
    [ -f "$MOCK_PID_FILE" ] || return 0
    if [ "$MOCK_HOST" = localhost ]; then
        kill "$(cat "$MOCK_PID_FILE")" 2>/dev/null || true
    else
        ssh "$MOCK_HOST" "kill $(cat "$MOCK_PID_FILE") 2>/dev/null || true"
    fi
    rm -f "$MOCK_PID_FILE"
}

stage_mock() {
    if [ "$MOCK_HOST" = localhost ]; then
        mkdir -p "$WORK/mock/output/studio" "$WORK/mock/output/results"
        rsync -a --exclude 01-lighthouse.png "$ART/mock-output/studio/" "$WORK/mock/output/studio/"
        cp -p "$ART/mock-output/studio/01-lighthouse.png" "$WORK/mock/output/results/"
        cp "$ROOT/scripts/mock-comfyui.py" "$WORK/mock/"
    else
        ssh "$MOCK_HOST" 'mkdir -p ~/landing-mac-mock/output/studio ~/landing-mac-mock/output/results'
        rsync -a --exclude 01-lighthouse.png "$ART/mock-output/studio/" "$MOCK_HOST:landing-mac-mock/output/studio/"
        rsync -a "$ART/mock-output/studio/01-lighthouse.png" "$MOCK_HOST:landing-mac-mock/output/results/"
        rsync -a "$ROOT/scripts/mock-comfyui.py" "$MOCK_HOST:landing-mac-mock/"
    fi
}

start_mock() {
    local seconds=$1 pause=$2
    stop_mock
    sleep 1
    if curl -s -m 3 "$MOCK_ENDPOINT/system_stats" >/dev/null; then
        echo "something already answers at $MOCK_ENDPOINT; pick another MOCK_PORT" >&2
        exit 1
    fi
    if [ "$MOCK_HOST" = localhost ]; then
        rm -f "$WORK"/mock/output/studio/tailscode-demo-new-*
        (cd "$WORK/mock" && MOCK_OUTPUT=$WORK/mock/output MOCK_PORT=$MOCK_PORT MOCK_RENDER_SECONDS=$seconds \
            MOCK_PAUSE_AT_STEP=$pause MOCK_PAUSE_FROM_JOB=1 MOCK_RESULTS=results/01-lighthouse.png \
            python3 mock-comfyui.py >mock.log 2>&1 &
            echo $! >"$MOCK_PID_FILE")
    else
        ssh "$MOCK_HOST" "cd ~/landing-mac-mock; rm -f output/studio/tailscode-demo-new-*; \
            MOCK_OUTPUT=\$HOME/landing-mac-mock/output MOCK_PORT=$MOCK_PORT MOCK_RENDER_SECONDS=$seconds \
            MOCK_PAUSE_AT_STEP=$pause MOCK_PAUSE_FROM_JOB=1 MOCK_RESULTS=results/01-lighthouse.png \
            setsid nohup python3 mock-comfyui.py >mock.log 2>&1 </dev/null & echo \$!" >"$MOCK_PID_FILE"
    fi
    sleep 2
    curl -s -m 5 "$MOCK_ENDPOINT/system_stats" >/dev/null || { echo "mock not answering at $MOCK_ENDPOINT" >&2; exit 1; }
}

appearance() {
    defaults write "$DOMAIN" tailscode.theme suomi
    defaults write "$DOMAIN" tailscode.appearance "$1"
    defaults write "$DOMAIN" tailscode.image.aspect landscape
    defaults write "$DOMAIN" tailscode.lastSession demo-c5
}

capture() {
    local out=$1 delay=$2
    shift 2
    env TAILSCODE_DEMO_ONLY=1 "$@" timeout 150 "$BIN" --demo "${OPEN[@]}" --shot "$out" \
        --shot-delay "$delay" --shot-size 1440x900 --shot-scale 2 --shot-chrome 2>&1 | grep -E "^SHOT" || {
        echo "no picture for $out" >&2
        exit 1
    }
}

studio() {
    local name=$1 look=$2
    appearance "$look"
    start_mock 6 0
    OPEN=(--open studio)
    capture "$WORK/$name.png" 24 TAILSCODE_IMAGE_ENDPOINT="$MOCK_ENDPOINT" \
        TAILSCODE_IMAGE_PROMPT="$LIGHTHOUSE_PROMPT" TAILSCODE_IMAGE_SEED="$LIGHTHOUSE_SEED"
}

viewer() {
    local name=$1 look=$2
    appearance "$look"
    start_mock 6 0
    OPEN=(--open studio)
    capture "$WORK/$name.png" 26 TAILSCODE_DRIVE="17000:sfocus;18000:skey=space" TAILSCODE_IMAGE_ENDPOINT="$MOCK_ENDPOINT" \
        TAILSCODE_IMAGE_PROMPT="$LIGHTHOUSE_PROMPT" TAILSCODE_IMAGE_SEED="$LIGHTHOUSE_SEED"
}

painting() {
    appearance dark
    start_mock 6 10
    OPEN=(--open studio)
    capture "$WORK/mac-dark-painting.png" 11 TAILSCODE_IMAGE_ENDPOINT="$MOCK_ENDPOINT" \
        TAILSCODE_IMAGE_PROMPT="$LIGHTHOUSE_PROMPT" TAILSCODE_IMAGE_SEED="$LIGHTHOUSE_SEED"
}

video() {
    appearance dark
    OPEN=(--open forge:done)
    capture "$WORK/mac-dark-video.png" 8 TAILSCODE_VIDEO_CLIP="$WORK/clip.mp4" \
        TAILSCODE_VIDEO_POSTERS="$WORK/posters" TAILSCODE_VIDEO_CLEAN=1
}

chat() {
    appearance dark
    OPEN=(--open "stage:$WORK/messages.json,rail=down,scroll=top")
    capture "$WORK/mac-dark-chat.png" 20
}

publish() {
    python3 - "$WORK" "$SITE" "$@" <<'EOF'
import sys, os
from PIL import Image
work, site, *names = sys.argv[1:]
os.makedirs(os.path.join(site, "full"), exist_ok=True)
for name in names:
    picture = Image.open(os.path.join(work, name + ".png")).convert("RGB")
    picture.save(os.path.join(site, "full", name + ".webp"), "WEBP", quality=86, method=6)
    picture.resize((1920, 1200), Image.LANCZOS).save(os.path.join(site, name + ".webp"), "WEBP", quality=84, method=6)
    print(name, picture.size, os.path.getsize(os.path.join(site, name + ".webp")) // 1024, "KB web,",
          os.path.getsize(os.path.join(site, "full", name + ".webp")) // 1024, "KB full")
EOF
}

cleanup() {
    stop_mock
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ "${BUILD:-1}" = 0 ] || build_app
prepare_assets
[ "$MOCK_HOST" != localhost ] || mkdir -p "$WORK/mock"
stage_mock
produced=()
for shot in "${SHOTS[@]}"; do
    case $shot in
        studio-dark) studio mac-dark-studio dark; produced+=(mac-dark-studio) ;;
        studio-light) studio mac-light-studio light; produced+=(mac-light-studio) ;;
        painting) painting; produced+=(mac-dark-painting) ;;
        video) video; produced+=(mac-dark-video) ;;
        viewer-dark) viewer mac-dark-viewer dark; produced+=(mac-dark-viewer) ;;
        viewer-light) viewer mac-light-viewer light; produced+=(mac-light-viewer) ;;
        chat) chat; produced+=(mac-dark-chat) ;;
        *) echo "unknown shot $shot" >&2; exit 2 ;;
    esac
done
publish "${produced[@]}"
