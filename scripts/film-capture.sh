#!/usr/bin/env bash
# Record the scripted --tour walkthrough off a dedicated simulator.
#
# A shared simulator is not safe here: anything else that launches an app on it
# lands in the middle of the take. This boots its own "TailscodeFilm" device,
# pins the status bar to 9:41, and warms the app once so demo mode is already
# resident (unread badges only appear on the second launch).
#
# Usage: scripts/film-capture.sh [seconds] [out.mov]
set -euo pipefail

DURATION=${1:-46}
OUT=${2:-/tmp/tailscode-screen.mov}
BUNDLE=com.guitaripod.tailscode
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP=$ROOT/build-sim/Build/Products/Debug-iphonesimulator/Tailscode.app
NAME=TailscodeFilm

# gtimeout is coreutils; fall back to running bare if it is not on PATH so the
# script still works from a login shell that never sourced Homebrew.
TIMEOUT=$(command -v gtimeout || command -v /opt/homebrew/bin/gtimeout || true)
T() { if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$@"; else shift; "$@"; fi; }

udid=$(xcrun simctl list devices -j | python3 -c "
import json,sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == '$NAME':
            print(d['udid']); raise SystemExit
")
if [ -z "$udid" ]; then
  udid=$(xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-Air \
    com.apple.CoreSimulator.SimRuntime.iOS-26-5)
fi
echo "device $udid"

T 120 xcrun simctl boot "$udid" 2>/dev/null || true
T 180 xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
T 60 xcrun simctl ui "$udid" appearance dark
T 60 xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --cellularMode active --cellularBars 4 --dataNetwork wifi \
  --wifiMode active --wifiBars 3
# iOS shows the QuickPath "slide to type" tutorial the first time a keyboard
# appears, and it lands on top of the take. Mark it as already seen.
T 60 xcrun simctl spawn "$udid" defaults write com.apple.Preferences \
  DidShowContinuousPathIntroduction -bool true 2>/dev/null || true
T 60 xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences \
  DidShowContinuousPathIntroduction -bool true 2>/dev/null || true

T 180 xcrun simctl install "$udid" "$APP"

T 30 xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
T 30 xcrun simctl launch "$udid" "$BUNDLE" --demo >/dev/null
sleep 6
T 30 xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2

rm -f "$OUT"
xcrun simctl io "$udid" recordVideo --codec h264 --force "$OUT" >/tmp/film-record.log 2>&1 &
rec=$!
sleep 2
T 30 xcrun simctl launch "$udid" "$BUNDLE" --demo --tour >/dev/null
sleep "$DURATION"
kill -INT $rec
wait $rec 2>/dev/null || true
sleep 1

ffprobe -v error -show_entries format=duration -show_entries stream=width,height \
  -of default=nw=1 "$OUT"
echo "screen take -> $OUT"
