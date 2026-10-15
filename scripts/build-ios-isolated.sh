#!/usr/bin/env bash
# Compile the iPhone app for a real device on the Mac in a private, root-scoped scratch tree, so
# nobody's work on the Mac is touched and the disk is never filled by surprise. Nothing is signed,
# installed or run: this answers one question, whether the sources compile, and then takes its own
# files away.
#
#   scripts/build-ios-isolated.sh --root voice-ios         build Debug under ~/scratch/voice-ios
#   scripts/build-ios-isolated.sh --root voice-ios --cleanup
#                                                          ... and delete the scratch tree after
#   scripts/build-ios-isolated.sh --scheme TailscodeWidget compile one extension target on its own
#   scripts/build-ios-isolated.sh --warn-base master       list warnings in files changed since master
#   scripts/build-ios-isolated.sh --min-free-gb 6          refuse below this much free disk
#   scripts/build-ios-isolated.sh --root voice-ios --clean-root
#                                                          delete the tree and stop
#
# The tree is ~/scratch/<root>/{iOS/<this directory's name>,swift/CodingAgentKit}, the pair keeping
# the shape project.yml expects (the Kit two levels up). Only that pair is synced, and --delete
# only reaches inside it. xcodebuild runs under the same lock as every other build on the Mac, one
# at a time, with its derived data inside the tree. The disk is read before anything is copied and
# again inside the lock, and a Mac with less than the floor free is reported rather than built on.
set -euo pipefail

ROOT=ios-build
CONFIG=Debug
SCHEME=Tailscode
MIN_FREE_GB=4
CLEANUP=no
CLEAN_ROOT=no
WARN_BASE=
while [ $# -gt 0 ]; do
    case "$1" in
    --root) ROOT=$2; shift ;;
    --release) CONFIG=Release ;;
    --scheme) SCHEME=$2; shift ;;
    --min-free-gb) MIN_FREE_GB=$2; shift ;;
    --warn-base) WARN_BASE=$2; shift ;;
    --cleanup) CLEANUP=yes ;;
    --clean-root) CLEAN_ROOT=yes ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

case "$ROOT" in
"" | . | .. | */* | ios | ios2 | mac | mac2 | tiling)
    echo "refusing root '$ROOT': pick a name of your own that is not another session's" >&2
    exit 2
    ;;
esac

REMOTE_BASE="scratch/$ROOT"
TREE=$(cd "$(dirname "$0")/.." && pwd)
TREE_NAME=$(basename "$TREE")
KIT=$(cd "$TREE/../../swift/CodingAgentKit" && pwd)

free_kb() { ssh -n macbook "df -k / | awk 'NR==2 {print \$4}'"; }
scratch_size() { ssh -n macbook "du -sh ~/$REMOTE_BASE 2>/dev/null | cut -f1" || true; }

guard_disk() {
    local free need
    free=$(free_kb)
    need=$((MIN_FREE_GB * 1024 * 1024))
    if [ "$free" -lt "$need" ]; then
        echo "REFUSED: the Mac has $((free / 1024 / 1024)) GB free, the floor is ${MIN_FREE_GB} GB" >&2
        exit 3
    fi
}

if [ "$CLEAN_ROOT" = yes ]; then
    ssh -n macbook "rm -rf ~/$REMOTE_BASE"
    echo "removed ~/$REMOTE_BASE"
    exit 0
fi

echo "== disk before"
ssh -n macbook "df -h /"
echo "== scratch before: $(scratch_size)"
guard_disk

EXCLUDES=(--exclude .git --exclude .github --exclude .claude --exclude .build --exclude 'build' --exclude 'build-*'
    --exclude DerivedData --exclude '*.xcodeproj' --exclude marketing --exclude packaging
    --exclude TailscodeLinux --exclude docs --exclude Tailscode.storekit --exclude __pycache__)
ssh -n macbook "mkdir -p ~/$REMOTE_BASE/iOS ~/$REMOTE_BASE/swift"
rsync -az --delete "${EXCLUDES[@]}" "$KIT/" "macbook:$REMOTE_BASE/swift/CodingAgentKit/"
rsync -az --delete "${EXCLUDES[@]}" "$TREE/" "macbook:$REMOTE_BASE/iOS/$TREE_NAME/"

CHANGED=
if [ -n "$WARN_BASE" ]; then
    CHANGED=$(git -C "$TREE" diff --name-only "$WARN_BASE"...HEAD -- '*.swift'
        git -C "$TREE" diff --name-only HEAD -- '*.swift'
        git -C "$TREE" ls-files --others --exclude-standard -- '*.swift')
    CHANGED=$(printf '%s\n' "$CHANGED" | sort -u | sed '/^$/d' | tr '\n' ' ')
fi

STATUS=0
ssh macbook "ROOT_DIR=$REMOTE_BASE TREE_NAME=$TREE_NAME CONFIG=$CONFIG SCHEME=$SCHEME ROOT=$ROOT \
    MIN_FREE_KB=$((MIN_FREE_GB * 1024 * 1024)) CHANGED=$(printf %q "$CHANGED") bash -l" <<'REMOTE' || STATUS=$?
set -e
LOG=/tmp/voice-ios-$ROOT-$SCHEME.log
DD=$HOME/$ROOT_DIR/dd
cd "$HOME/$ROOT_DIR/iOS/$TREE_NAME"
set +e
lockf -k -t 3600 /tmp/tsmac-build.lock bash -c "
    free=\$(df -k / | awk 'NR==2 {print \$4}')
    if [ \"\$free\" -lt $MIN_FREE_KB ]; then echo \"REFUSED: the Mac has \$((free / 1024 / 1024)) GB free inside the lock\"; exit 3; fi
    xcodegen generate >/dev/null &&
    xcodebuild -project Tailscode.xcodeproj -scheme $SCHEME -configuration $CONFIG \
        -destination 'generic/platform=iOS' -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO build >$LOG 2>&1"
RC=$?
set -e
if [ "$RC" -eq 3 ]; then
    exit 3
elif [ "$RC" -ne 0 ]; then
    grep -E "error:" "$LOG" | sort -u | tail -40
    echo "** BUILD FAILED ** (full log on the Mac: $LOG)"
    exit 1
fi
tail -n 3 "$LOG"
echo "== warnings overall: $(grep -c 'warning:' "$LOG" || true)"
if [ -n "$CHANGED" ]; then
    echo "== warnings in files changed:"
    for file in $CHANGED; do
        grep -F "$file" "$LOG" | grep 'warning:' || true
    done | sort -u
    echo "== end of warnings in files changed"
fi
REMOTE

if [ "$CLEANUP" = yes ]; then
    ssh -n macbook "rm -rf ~/$REMOTE_BASE" || true
    echo "removed ~/$REMOTE_BASE"
fi
echo "== disk after"
ssh -n macbook "df -h /"
echo "== scratch after: $(scratch_size)"
exit "$STATUS"
