#!/usr/bin/env bash
# Put the change in front of the person: build TailscodeMac for release and replace the app in
# /Applications. This is the last step of any Mac work — a build that only ever exists under
# build-mac/ is a change nobody can use, and the app the person launches from the Dock is the one
# that has to have it.
#
#   scripts/install-macapp.sh            # build and install
#   scripts/install-macapp.sh --launch   # and open it
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/bin:$PATH

xcodegen generate >/dev/null
xcodebuild -project Tailscode.xcodeproj -scheme TailscodeMac -configuration Release \
    -destination "platform=macOS" -derivedDataPath build-macrel build > /tmp/tailscode-macrel.log 2>&1 || {
    grep -E "error:" /tmp/tailscode-macrel.log | sort -u | tail -30
    echo "** BUILD FAILED **"
    exit 1
}

APP=build-macrel/Build/Products/Release/TailscodeMac.app
pkill -f "Tailscode.app/Contents/MacOS/TailscodeMac" 2>/dev/null || true
rm -rf /Applications/Tailscode.app
cp -R "$APP" /Applications/Tailscode.app
codesign --force --deep --sign - /Applications/Tailscode.app 2>/dev/null

printf 'installed /Applications/Tailscode.app — %s\n' \
    "$(/Applications/Tailscode.app/Contents/MacOS/TailscodeMac --version)"

if [[ "${1:-}" == "--launch" ]]; then
    open /Applications/Tailscode.app
fi
