#!/usr/bin/env bash
# Build TailscodeMac on the Mac in a private tree, so nobody's work on the Mac is touched.
#
# build-macapp.sh syncs into ~/Dev/iOS/Tailscode on the Mac with --delete, which is the directory
# Mac sessions author in. This one syncs into ~/scratch/<root>/Dev/{iOS/Tailscode,swift/CodingAgentKit}
# instead (project.yml finds the Kit two levels up, so the pair keeps its shape), builds there with
# its own derived data, and serialises with every other build on the Mac so two agents never run
# xcodebuild into one machine at once.
#
#   scripts/build-macapp-isolated.sh                       build Debug in ~/scratch/tiling
#   scripts/build-macapp-isolated.sh --root pane2          a different private tree
#   scripts/build-macapp-isolated.sh --selftest            then run --selftest against a server
#   scripts/build-macapp-isolated.sh --run "<args>"        then run the built binary with <args>
#   scripts/build-macapp-isolated.sh --release             Release instead of Debug
#   scripts/build-macapp-isolated.sh --scheme Tailscode    build the iPhone app for the simulator instead
#   scripts/build-macapp-isolated.sh --clean-root          delete the private tree and stop
set -euo pipefail

ROOT=tiling
CONFIG=Debug
SCHEME=TailscodeMac
SELFTEST=no
RUN_ARGS=""
CLEAN=no
while [ $# -gt 0 ]; do
    case "$1" in
    --root) ROOT=$2; shift ;;
    --release) CONFIG=Release ;;
    --scheme) SCHEME=$2; shift ;;
    --selftest) SELFTEST=yes ;;
    --run) RUN_ARGS=$2; shift ;;
    --clean-root) CLEAN=yes ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

REMOTE_BASE="scratch/$ROOT"
if [ "$CLEAN" = yes ]; then
    ssh macbook "rm -rf ~/$REMOTE_BASE"
    echo "removed ~/$REMOTE_BASE"
    exit 0
fi

HOST=${TAILSCODE_HOST:-100.91.211.44:4098}
PASSWORD=${TAILSCODE_PASSWORD:-tailscode}
BACKEND=${TAILSCODE_BACKEND:-claude}
EXCLUDES=(--exclude .git --exclude .build --exclude 'build' --exclude 'build-*' --exclude DerivedData --exclude '*.xcodeproj')
TREE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$(cd "$TREE/../../swift/CodingAgentKit" && pwd)

ssh macbook "mkdir -p ~/$REMOTE_BASE/Dev/iOS ~/$REMOTE_BASE/Dev/swift"
rsync -az --delete "${EXCLUDES[@]}" "$KIT/" "macbook:$REMOTE_BASE/Dev/swift/CodingAgentKit/"
rsync -az --delete "${EXCLUDES[@]}" "$TREE/" "macbook:$REMOTE_BASE/Dev/iOS/Tailscode/"

ssh macbook "ROOT_DIR=$REMOTE_BASE CONFIG=$CONFIG SCHEME=$SCHEME SELFTEST=$SELFTEST RUN_ARGS=$(printf %q "$RUN_ARGS") \
    TAILSCODE_HOST=$(printf %q "$HOST") TAILSCODE_PASSWORD=$(printf %q "$PASSWORD") \
    TAILSCODE_BACKEND=$(printf %q "$BACKEND") bash -l" <<'REMOTE'
set -e
cd ~/$ROOT_DIR/Dev/iOS/Tailscode
xcodegen generate >/dev/null
LOG=/tmp/tsmac-isolated-$(basename "$ROOT_DIR")-$SCHEME.log
DEST="platform=macOS"
[ "$SCHEME" = Tailscode ] && DEST="generic/platform=iOS Simulator"
if ! lockf -k -t 3600 /tmp/tsmac-build.lock bash -c "
    cd ~/$ROOT_DIR/Dev/iOS/Tailscode
    xcodebuild -project Tailscode.xcodeproj -scheme $SCHEME -configuration $CONFIG \
        -destination '$DEST' -derivedDataPath build-iso-$SCHEME build >$LOG 2>&1"; then
    grep -E "error:" "$LOG" | sort -u | tail -40
    echo "** BUILD FAILED ** (full log on the Mac: $LOG)"
    exit 1
fi
echo "** BUILD SUCCEEDED **"
if [ "$SCHEME" != TailscodeMac ]; then
    exit 0
fi
APP=~/$ROOT_DIR/Dev/iOS/Tailscode/build-iso-$SCHEME/Build/Products/$CONFIG/TailscodeMac.app/Contents/MacOS/TailscodeMac
echo "binary: $APP"
if [ "$SELFTEST" = yes ]; then
    TAILSCODE_HOST="$TAILSCODE_HOST" TAILSCODE_PASSWORD="$TAILSCODE_PASSWORD" TAILSCODE_BACKEND="$TAILSCODE_BACKEND" "$APP" --selftest
fi
if [ -n "$RUN_ARGS" ]; then
    "$APP" $RUN_ARGS
fi
REMOTE
