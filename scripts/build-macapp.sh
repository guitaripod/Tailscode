#!/usr/bin/env bash
# Sync + build the AppKit client on the Mac over Tailscale, then prove it reaches a real server.
# A Mac reached over ssh has no window server, so --selftest stands in for a screenshot: it
# resolves the configured servers, lists their sessions, opens the newest and waits for a state.
#
#   TAILSCODE_HOST=http://100.x.y.z:4098 TAILSCODE_PASSWORD=… scripts/build-macapp.sh
#   scripts/build-macapp.sh --launch     # also open the window on the Mac's own screen
set -euo pipefail

LAUNCH=no
[[ "${1:-}" == "--launch" ]] && LAUNCH=yes

if [[ "${HOSTNAME:-$(uname -n)}" != macbook* ]]; then
    RSYNC_EXCLUDES=(--exclude '.git' --exclude '.build' --exclude 'build' --exclude 'build-*' --exclude 'DerivedData' --exclude '*.xcodeproj')
    rsync -az "${RSYNC_EXCLUDES[@]}" ~/Dev/swift/CodingAgentKit/ macbook:Dev/swift/CodingAgentKit/
    rsync -az --delete "${RSYNC_EXCLUDES[@]}" ~/Dev/iOS/Tailscode/ macbook:Dev/iOS/Tailscode/
fi

ssh macbook "TAILSCODE_HOST=$(printf %q "${TAILSCODE_HOST:-}") TAILSCODE_PASSWORD=$(printf %q "${TAILSCODE_PASSWORD:-}") TAILSCODE_BACKEND=$(printf %q "${TAILSCODE_BACKEND:-claude}") LAUNCH=$LAUNCH bash -l" <<'REMOTE'
set -e
cd ~/Dev/iOS/Tailscode
xcodegen generate >/dev/null
if ! xcodebuild -project Tailscode.xcodeproj -scheme TailscodeMac -configuration Debug \
    -destination "platform=macOS" -derivedDataPath build-mac build > /tmp/tailscode-mac-build.log 2>&1; then
    grep -E "error:" /tmp/tailscode-mac-build.log | sort -u | tail -30
    echo "** BUILD FAILED **"
    exit 1
fi
echo "** BUILD SUCCEEDED **"

APP=~/Dev/iOS/Tailscode/build-mac/Build/Products/Debug/TailscodeMac.app
if [ -n "$TAILSCODE_HOST" ]; then
    "$APP/Contents/MacOS/TailscodeMac" --selftest
fi
if [ "$LAUNCH" = "yes" ]; then
    pkill -f "TailscodeMac.app/Contents/MacOS/TailscodeMac" 2>/dev/null || true
    open -n "$APP" --env TAILSCODE_HOST="$TAILSCODE_HOST" \
        --env TAILSCODE_PASSWORD="$TAILSCODE_PASSWORD" --env TAILSCODE_BACKEND="$TAILSCODE_BACKEND"
    sleep 4
    pgrep -fl "TailscodeMac.app/Contents/MacOS/TailscodeMac" | head -1
fi
REMOTE
