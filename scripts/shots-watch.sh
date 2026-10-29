#!/usr/bin/env bash
# Photograph the Agents Watch wall on an iPad Pro 13-inch and an iPhone Duo simulator, from a scratch
# tree of its own on the Mac so nobody's work there is touched.
#
#   scripts/shots-watch.sh                     attention, alarm and squad on both devices, plus the Duo's
#                                              closed and book poses
#   scripts/shots-watch.sh --scenes "calm busy"   other demo scenes
#   scripts/shots-watch.sh --no-build          reuse the build of the last run
#   scripts/shots-watch.sh --keep              leave the throwaway simulators and the tree
#
# It syncs this repo and the Kit into ~/scratch/watch-ios-sim exactly as build-ios-isolated.sh lays
# out its tree, builds the Tailscode scheme for the simulator there with derived data inside it (under
# the same lock every other build on the Mac takes), creates two throwaway simulators on the iOS 27.1
# runtime, launches the app with --demo and TAILSCODE_WATCH=<scene> (and TAILSCODE_WATCH_EVENTS=1 so
# effects are in flight), and copies the PNGs to ./ios-shots (override with SHOTS_OUT). `duoctl` poses
# the Duo; without it on the Mac only the open pose is shot.
set -euo pipefail

TREE=$(cd "$(dirname "$0")/.." && pwd)
TREE_NAME=$(basename "$TREE")
KIT=$(cd "$TREE/../../swift/CodingAgentKit" && pwd)
ROOT=watch-ios-sim
REMOTE_BASE="scratch/$ROOT"
OUT=${SHOTS_OUT:-$TREE/ios-shots}
SCENES="attention alarm squad"
UIS="controls hold peek style"
BUILD=yes
KEEP=no
BUNDLE=com.guitaripod.tailscode
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-1
IPAD_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-0
IPAD_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB
DUO_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
SETTLE=${SETTLE:-6}

while [ $# -gt 0 ]; do
    case "$1" in
    --scenes) SCENES=$2; shift ;;
    --ui) UIS=$2; shift ;;
    --no-build) BUILD=no ;;
    --keep) KEEP=yes ;;
    --out) OUT=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

EXCLUDES=(--exclude .git --exclude .github --exclude .claude --exclude .build --exclude 'build' --exclude 'build-*'
    --exclude DerivedData --exclude '*.xcodeproj' --exclude marketing --exclude packaging
    --exclude TailscodeLinux --exclude docs --exclude Tailscode.storekit --exclude __pycache__)

sync_tree() {
    ssh -n macbook "mkdir -p ~/$REMOTE_BASE/iOS ~/$REMOTE_BASE/swift"
    rsync -az --delete "${EXCLUDES[@]}" "$KIT/" "macbook:$REMOTE_BASE/swift/CodingAgentKit/"
    rsync -az --delete "${EXCLUDES[@]}" "$TREE/" "macbook:$REMOTE_BASE/iOS/$TREE_NAME/"
}

build_app() {
    ssh macbook "ROOT_DIR=$REMOTE_BASE TREE_NAME=$TREE_NAME bash -l" <<'REMOTE'
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
DD=$HOME/$ROOT_DIR/dd
LOG=/tmp/watch-shots-build.log
cd "$HOME/$ROOT_DIR/iOS/$TREE_NAME"
set +e
lockf -k -t 3600 /tmp/tsmac-build.lock bash -c "
    xcodegen generate >/dev/null &&
    xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO build >$LOG 2>&1"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    grep -E "error:" "$LOG" | sort -u | tail -40
    echo "** BUILD FAILED ** (log on the Mac: $LOG)"
    exit 1
fi
tail -n 3 "$LOG"
APP=$(find "$DD/Build/Products" -maxdepth 2 -name Tailscode.app | head -1)
echo "app: $APP"
xcrun vtool -show-build "$APP/Tailscode.debug.dylib" | awk '$1 == "sdk" {print "sdk " $2}'
REMOTE
}

shoot() {
    ssh macbook "ROOT_DIR=$REMOTE_BASE SCENES='$SCENES' UIS='$UIS' SETTLE=$SETTLE BUNDLE=$BUNDLE RUNTIME=$RUNTIME IPAD_RUNTIME=$IPAD_RUNTIME IPAD_TYPE=$IPAD_TYPE DUO_TYPE=$DUO_TYPE KEEP=$KEEP bash -l" <<'REMOTE'
set -u
PATH=$HOME/.local/bin:$PATH
APP=$(find "$HOME/$ROOT_DIR/dd/Build/Products" -maxdepth 2 -name Tailscode.app | head -1)
SHOTS=$HOME/$ROOT_DIR/shots
rm -rf "$SHOTS"; mkdir -p "$SHOTS"
IPAD=$(xcrun simctl create watch-shots-ipad "$IPAD_TYPE" "$IPAD_RUNTIME")
DUO=$(xcrun simctl create watch-shots-duo "$DUO_TYPE" "$RUNTIME")
echo "ipad $IPAD duo $DUO"
cleanup() {
    if [ "$KEEP" = no ]; then
        xcrun simctl shutdown "$IPAD" >/dev/null 2>&1; xcrun simctl delete "$IPAD" >/dev/null 2>&1
        xcrun simctl shutdown "$DUO" >/dev/null 2>&1; xcrun simctl delete "$DUO" >/dev/null 2>&1
    fi
}
trap cleanup EXIT
for udid in "$IPAD" "$DUO"; do
    xcrun simctl boot "$udid" >/dev/null 2>&1
    xcrun simctl bootstatus "$udid" >/dev/null 2>&1
    xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1
    xcrun simctl install "$udid" "$APP"
done

launch() {
    local udid=$1 scene=$2 ui=${3:-}
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
    SIMCTL_CHILD_TAILSCODE_WATCH="$scene" SIMCTL_CHILD_TAILSCODE_WATCH_EVENTS=1 \
        SIMCTL_CHILD_TAILSCODE_WATCH_UI="$ui" \
        SIMCTL_CHILD_TAILSCODE_HIDE_DEMO_BADGE=1 \
        xcrun simctl launch "$udid" "$BUNDLE" --demo >/dev/null
    sleep "$SETTLE"
}

for scene in $SCENES; do
    launch "$IPAD" "$scene"
    xcrun simctl io "$IPAD" screenshot "$SHOTS/ipad-$scene.png" >/dev/null 2>&1
done

for ui in $UIS; do
    launch "$IPAD" attention "$ui"
    xcrun simctl io "$IPAD" screenshot "$SHOTS/ipad-ui-$ui.png" >/dev/null 2>&1
done

HAS_DUOCTL=no
command -v duoctl >/dev/null 2>&1 && HAS_DUOCTL=yes
if [ "$HAS_DUOCTL" = yes ]; then
    duoctl -d "$DUO" open >/dev/null 2>&1; sleep 3
    for scene in $SCENES; do
        launch "$DUO" "$scene"
        duoctl -d "$DUO" screenshot "$SHOTS/duo-open-$scene.png" >/dev/null 2>&1
    done
    for ui in $UIS; do
        launch "$DUO" attention "$ui"
        duoctl -d "$DUO" screenshot "$SHOTS/duo-ui-$ui.png" >/dev/null 2>&1
    done
    for scene in $SCENES; do
        launch "$DUO" "$scene"
        duoctl -d "$DUO" hinge 127 >/dev/null 2>&1; sleep 4
        duoctl -d "$DUO" screenshot "$SHOTS/duo-book-$scene.png" >/dev/null 2>&1
        duoctl -d "$DUO" open >/dev/null 2>&1; sleep 3
    done
    for scene in $SCENES; do
        launch "$DUO" "$scene"
        duoctl -d "$DUO" rotate portrait >/dev/null 2>&1; sleep 3
        duoctl -d "$DUO" hinge 127 >/dev/null 2>&1; sleep 4
        duoctl -d "$DUO" screenshot "$SHOTS/duo-laptop-$scene.png" >/dev/null 2>&1
        duoctl -d "$DUO" open >/dev/null 2>&1; sleep 3
        duoctl -d "$DUO" rotate landscape >/dev/null 2>&1; sleep 3
    done
    for scene in $SCENES; do
        duoctl -d "$DUO" close >/dev/null 2>&1; sleep 3
        launch "$DUO" "$scene"
        duoctl -d "$DUO" screenshot "$SHOTS/duo-closed-$scene.png" >/dev/null 2>&1
        duoctl -d "$DUO" open >/dev/null 2>&1; sleep 3
    done
else
    echo "duoctl is not installed on the Mac: only the open pose is shot" >&2
    for scene in $SCENES; do
        launch "$DUO" "$scene"
        xcrun simctl io "$DUO" screenshot "$SHOTS/duo-open-$scene.png" >/dev/null 2>&1
    done
fi
ls -1 "$SHOTS"
REMOTE
}

fetch() {
    mkdir -p "$OUT"
    rsync -az "macbook:$REMOTE_BASE/shots/" "$OUT/"
    echo "shots in $OUT"
}

if [ "$BUILD" = yes ]; then
    sync_tree
    build_app
fi
shoot
fetch
if [ "$KEEP" = no ]; then
    ssh -n macbook "rm -rf ~/$REMOTE_BASE"
    echo "removed ~/$REMOTE_BASE"
fi
