#!/usr/bin/env bash
# Sync, build, install on a specific iPhone simulator, and pull screenshots (onboarding + demo chat).
set -euo pipefail

EX=(--exclude '.git' --exclude '.build' --exclude 'DerivedData' --exclude '*.xcodeproj' --exclude build)
rsync -az --delete "${EX[@]}" "$HOME/Dev/swift/CodingAgentKit/" macbook:Dev/swift/CodingAgentKit/
rsync -az --delete "${EX[@]}" "$HOME/Dev/ios/Tailscode/" macbook:Dev/ios/Tailscode/

ssh macbook "TAILSCODE_HOST=$(printf %q "${TAILSCODE_HOST:-}") TAILSCODE_PASSWORD=$(printf %q "${TAILSCODE_PASSWORD:-}") bash -l" <<'REMOTE'
set -e
BUNDLE=com.guitaripod.tailscode
rm -f ~/tailscode-onboarding.png ~/tailscode-live.png ~/tailscode-demo.png
cd ~/Dev/ios/Tailscode
xcodegen generate >/dev/null
xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build \
  > /tmp/tailscode-run-build.log 2>&1 \
  || { grep -E "error:|BUILD FAILED" /tmp/tailscode-run-build.log | tail -25; exit 1; }
grep -E "BUILD SUCCEEDED" /tmp/tailscode-run-build.log | tail -1
APP=$(find build/Build/Products -name Tailscode.app -maxdepth 3 | head -1)
DEV=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 1[567].* \(/{print $2; exit}')
echo "APP=$APP  DEV=$DEV"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl uninstall "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"

xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
sleep 3
xcrun simctl io "$DEV" screenshot ~/tailscode-onboarding.png >/dev/null 2>&1 && echo ONBOARD_OK

if [ -n "${TAILSCODE_HOST:-}" ]; then
  xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
  SIMCTL_CHILD_TAILSCODE_HOST="$TAILSCODE_HOST" \
    SIMCTL_CHILD_TAILSCODE_PASSWORD="${TAILSCODE_PASSWORD:-}" \
    xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
  sleep 5
  xcrun simctl io "$DEV" screenshot ~/tailscode-live.png >/dev/null 2>&1 && echo LIVE_OK
else
  echo "LIVE_SKIPPED (TAILSCODE_HOST not set)"
fi

xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$DEV" "$BUNDLE" --demo >/dev/null
sleep 7
xcrun simctl io "$DEV" screenshot ~/tailscode-demo.png >/dev/null 2>&1 && echo DEMO_OK
REMOTE

SHOTS=(onboarding demo)
if [ -n "${TAILSCODE_HOST:-}" ]; then SHOTS+=(live); fi
for f in "${SHOTS[@]}"; do scp -q macbook:tailscode-$f.png /tmp/tailscode-$f.png; done
echo "screenshots -> /tmp/tailscode-{onboarding,live,demo}.png"
