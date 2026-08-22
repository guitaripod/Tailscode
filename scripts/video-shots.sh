#!/usr/bin/env bash
# Sync, build, install on an iPhone simulator, and photograph every state the video surface has.
# Each state is a named board (TAILSCODE_VIDEO_STATE, read by ForgeRunner.stage) so a face this
# screen only wears mid-render can be looked at without a renderer on the tailnet.
set -euo pipefail

STATES=${*:-unconfigured down ready waking queued running saving done failed stopped empty}

EX=(--exclude '.git' --exclude '.build' --exclude 'DerivedData' --exclude '*.xcodeproj' --exclude build)
rsync -az "${EX[@]}" "$HOME/Dev/swift/CodingAgentKit/" macbook:Dev/swift/CodingAgentKit/
rsync -az --delete "${EX[@]}" "$HOME/Dev/iOS/Tailscode/" macbook:Dev/iOS/Tailscode/

ssh macbook "STATES=$(printf %q "$STATES") APPEARANCE=$(printf %q "${APPEARANCE:-}") bash -l" <<'REMOTE'
set -e
BUNDLE=com.guitaripod.tailscode
rm -f ~/tailscode-video-*.png
cd ~/Dev/iOS/Tailscode
xcodegen generate >/dev/null
xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build \
  > /tmp/tailscode-video-build.log 2>&1 \
  || { grep -E "error:|BUILD FAILED" /tmp/tailscode-video-build.log | tail -25; exit 1; }
grep -E "BUILD SUCCEEDED" /tmp/tailscode-video-build.log | tail -1
APP=$(find build/Build/Products -name Tailscode.app -maxdepth 3 | head -1)
DEV=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 1[567].* \(/{print $2; exit}')
echo "APP=$APP  DEV=$DEV"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl uninstall "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"

for state in $STATES; do
  # A state may name a section to scroll to as "<state>@<section>", so the settings and the
  # history below the fold are photographable without a finger.
  section=""
  case "$state" in *@*) section=${state#*@}; state=${state%@*} ;; esac
  xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
  open=""
  case "$section" in renderer-editor) open=renderer; section="" ;; esac
  SIMCTL_CHILD_TAILSCODE_VIDEO_STATE="$state" SIMCTL_CHILD_TAILSCODE_VIDEO_SCROLL="$section" \
    SIMCTL_CHILD_TAILSCODE_VIDEO_OPEN="$open" \
    SIMCTL_CHILD_TAILSCODE_APPEARANCE="${APPEARANCE:-}" \
    xcrun simctl launch "$DEV" "$BUNDLE" --demo >/dev/null
  sleep 6
  name=$state${section:+-$section}${open:+-editor}${APPEARANCE:+-$APPEARANCE}
  xcrun simctl io "$DEV" screenshot ~/tailscode-video-$name.png >/dev/null 2>&1 \
    && echo "SHOT $name"
done
xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
REMOTE

for state in $STATES; do
  name=$(printf '%s' "$state" | sed -e 's/@renderer-editor/-editor/' -e 's/@/-/')
  name=$name${APPEARANCE:+-$APPEARANCE}
  scp -q macbook:tailscode-video-$name.png /tmp/tailscode-video-$name.png || true
done
echo "screenshots -> /tmp/tailscode-video-<state>.png"
