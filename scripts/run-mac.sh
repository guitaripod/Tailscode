#!/usr/bin/env bash
# Sync, build, install on a specific iPhone simulator, and pull screenshots (onboarding + demo chat).
set -euo pipefail

EX=(--exclude '.git' --exclude '.build' --exclude 'DerivedData' --exclude '*.xcodeproj' --exclude build)
rsync -az --delete "${EX[@]}" "$HOME/Dev/swift/CodingAgentKit/" macbook:Dev/swift/CodingAgentKit/
rsync -az --delete "${EX[@]}" "$HOME/Dev/ios/Tailscode/" macbook:Dev/ios/Tailscode/

ssh macbook 'bash -l' <<'REMOTE'
set -e
BUNDLE=com.guitaripod.tailscode
cd ~/Dev/ios/Tailscode
xcodegen generate >/dev/null
xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build 2>&1 \
  | (grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true) | tail -25
APP=$(find build/Build/Products -name Tailscode.app -maxdepth 3 | head -1)
DEV=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 1[567].* \(/{print $2; exit}')
echo "APP=$APP  DEV=$DEV"
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl uninstall "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"

xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
sleep 3
xcrun simctl io "$DEV" screenshot ~/tailscode-onboarding.png >/dev/null 2>&1 && echo ONBOARD_OK

xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
SIMCTL_CHILD_TAILSCODE_HOST=http://100.91.211.44:4096 \
  SIMCTL_CHILD_TAILSCODE_PASSWORD=tailscode \
  xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
sleep 5
xcrun simctl io "$DEV" screenshot ~/tailscode-live.png >/dev/null 2>&1 && echo LIVE_OK

xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$DEV" "$BUNDLE" --demo >/dev/null
sleep 7
xcrun simctl io "$DEV" screenshot ~/tailscode-demo.png >/dev/null 2>&1 && echo DEMO_OK
REMOTE

for f in onboarding live demo; do scp -q macbook:tailscode-$f.png /tmp/tailscode-$f.png; done
echo "screenshots -> /tmp/tailscode-{onboarding,live,demo}.png"
