#!/usr/bin/env bash
# Rebuild the marketing screenshot set from the demo backend.
#
# Every shot is one clean launch on a dedicated 6.9" simulator: no shared device,
# no leftover state, no touches to drive. The app's DEBUG launch hooks put each
# screen on screen by itself, so the set is reproducible and reviewable.
#
#   scripts/shots.sh                 # all shots
#   scripts/shots.sh 07-home 08-usage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE=com.guitaripod.tailscode
DEVICE_NAME=TailscodeShots
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
OUT="$ROOT/marketing/appstore/iphone"

# name | launch args | env (space separated KEY=VALUE) | seconds to settle
# "setup" runs against a fresh install with no demo backend: it is the onboarding
# guide a first launch actually shows.
SHOTS=(
  "01-live|--demo|TAILSCODE_OPEN_SESSION=demo-c1|14"
  "02-work|--demo|TAILSCODE_OPEN_SESSION=demo-c2|9"
  "03-approval|--demo|TAILSCODE_OPEN_SESSION=demo-c3|12"
  "04-question|--demo|TAILSCODE_OPEN_SESSION=demo-o2|11"
  "05-subagents|--demo|TAILSCODE_OPEN_SESSION=demo-c2 TAILSCODE_OPEN_AGENTS=first|11"
  "06-render|--demo|TAILSCODE_OPEN_SESSION=demo-o1|9"
  "07-home|--demo||6"
  "08-usage|--demo --usage||7"
  "09-chats|--demo|TAILSCODE_OPEN_CHATS=1|7"
  "10-models|--demo|TAILSCODE_OPEN_SESSION=demo-c2 TAILSCODE_OPEN_MODELS=1|9"
  "11-compaction|--demo|TAILSCODE_OPEN_SESSION=demo-c4|9"
  "setup||TAILSCODE_OPEN_GUIDE=1|6"
)

boot_device() {
  local id
  id=$(xcrun simctl list devices | awk -F'[()]' -v n="$DEVICE_NAME" '$0 ~ "    "n" \\(" {print $2; exit}')
  if [ -z "$id" ]; then
    local runtime
    runtime=$(xcrun simctl list runtimes | awk '/iOS 26/{print $NF}' | tail -1)
    id=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$runtime")
    echo "created $DEVICE_NAME ($runtime)" >&2
  fi
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl bootstatus "$id" >/dev/null 2>&1 || true
  xcrun simctl ui "$id" appearance dark >/dev/null 2>&1 || true
  xcrun simctl status_bar "$id" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 \
    >/dev/null 2>&1 || true
  echo "$id"
}

build() {
  cd "$ROOT"
  xcodegen generate >/dev/null
  xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath build build \
    >/tmp/tailscode-shots-build.log 2>&1 ||
    { grep -E "error:|BUILD FAILED" /tmp/tailscode-shots-build.log | tail -25; exit 1; }
  find "$ROOT/build/Build/Products" -name Tailscode.app -maxdepth 3 | head -1
}

install_fresh() {
  xcrun simctl uninstall "$1" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl install "$1" "$2"
}

capture() {
  local device=$1 name=$2 args=$3 envs=$4 delay=$5
  xcrun simctl terminate "$device" "$BUNDLE" >/dev/null 2>&1 || true
  local prefixed=(FOO=bar)
  for pair in $envs; do prefixed+=("SIMCTL_CHILD_${pair}"); done
  env "${prefixed[@]}" xcrun simctl launch "$device" "$BUNDLE" $args >/dev/null
  sleep "$delay"
  xcrun simctl io "$device" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $name.png"
}

mkdir -p "$OUT"
DEVICE=$(boot_device)
APP=$(build)
echo "device $DEVICE"
echo "app    $APP"
install_fresh "$DEVICE" "$APP"

for shot in "${SHOTS[@]}"; do
  IFS='|' read -r name args envs delay <<<"$shot"
  if [ $# -gt 0 ] && [[ ! " $* " == *" $name "* ]]; then continue; fi
  if [ "$name" = "setup" ]; then install_fresh "$DEVICE" "$APP"; fi
  capture "$DEVICE" "$name" "$args" "$envs" "$delay"
done

xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
echo "-> $OUT"
