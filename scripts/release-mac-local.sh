#!/usr/bin/env bash
# Archive, export and (with --upload) deliver a Mac App Store build from THIS Mac, for the days the
# stable-macOS build guest is gone. release-mac.sh is the preferred road: a guest stamps a stable
# BuildMachineOSBuild, and a major-beta host stamps one Apple bounces with ITMS-90111. This host
# rule is Marcus's: a point beta (27.2) builds and uploads locally. The script prints the stamp
# and the SDK so the host line is read before anything is delivered, and refuses a build number
# the macOS train already holds.
#
# Usage: scripts/release-mac-local.sh <build-number> <marketing-version> [--upload]
set -euo pipefail
export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH
cd "$(dirname "$0")/.."

[ $# -ge 2 ] || { echo "usage: scripts/release-mac-local.sh <build-number> <marketing-version> [--upload]" >&2; exit 2; }
BUILD=$1
MARKETING=$2
UPLOAD=0
[ "${3:-}" = "--upload" ] && UPLOAD=1

APP_ID=6791660932
BUNDLE=com.guitaripod.tailscode
VAULT=$HOME/.config/midgar/signing
PROFILE_FILE=$VAULT/tailscode-mac-appstore-2026.provisionprofile
PROFILE_DIR=$HOME/Library/Developer/Xcode/UserData/Provisioning\ Profiles
KIT=${KIT:-$PWD/../../swift/CodingAgentKit}
OUT=build/release-mac-store

[ -f "$PROFILE_FILE" ] || { echo "no Mac App Store profile at $PROFILE_FILE" >&2; exit 1; }
[ -d "$KIT" ] || { echo "no CodingAgentKit at $KIT" >&2; exit 1; }
if [ -n "$(git -C "$KIT" status --porcelain)" ]; then
  echo "CodingAgentKit has uncommitted changes: a release ships the committed Kit" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "the working tree is not clean: a release ships what is committed" >&2
  exit 1
fi

python3 -I - "$BUILD" "$APP_ID" <<'PY'
import subprocess, sys
build, app = sys.argv[1], sys.argv[2]
out = subprocess.run(
    ["asc", "builds", "list", "--app", app, "--platform", "MAC_OS", "--limit", "50", "--output", "table"],
    capture_output=True, text=True).stdout
taken = {line.split("│")[2].strip() for line in out.splitlines() if line.count("│") > 4}
if build in taken:
    print(f"build {build} is already on the macOS train", file=sys.stderr)
    sys.exit(1)
print(f"build {build} is free on the macOS train")
PY

mkdir -p "$PROFILE_DIR" "$OUT"
KEYCHAIN=$PWD/$OUT/signing.keychain-db
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')

cleanup_keychain() {
  security list-keychains -d user -s $ORIGINAL_KEYCHAINS
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
}
rm -f "$KEYCHAIN"
P12_PASSWORD=$(cat "$VAULT/midgar_distribution.p12.password")
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$VAULT/midgar_distribution.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security import "$VAULT/midgar_mac_installer.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS
trap cleanup_keychain EXIT

INSTALLER=$(security find-identity -v "$KEYCHAIN" | grep -oE '"(Mac Installer Distribution|3rd Party Mac Developer Installer)[^"]*"' | head -1 | tr -d '"')
[ -n "$INSTALLER" ] || { echo "no installer identity in the vault p12" >&2; exit 1; }
INSTALLER=${INSTALLER%%:*}

DECODED=$(mktemp)
security cms -D -i "$PROFILE_FILE" > "$DECODED"
UUID=$(plutil -extract UUID raw "$DECODED")
PROFILE_NAME=$(plutil -extract Name raw "$DECODED")
rm -f "$DECODED"
cp "$PROFILE_FILE" "$PROFILE_DIR/$UUID.provisionprofile"
echo "profile $BUNDLE -> $PROFILE_NAME, installer $INSTALLER"

OPTIONS=$OUT/ExportOptions.plist
python3 -I - "$OPTIONS" "$BUNDLE" "$PROFILE_NAME" "$INSTALLER" <<'PY'
import plistlib, sys
path, bundle, profile, installer = sys.argv[1:5]
with open(path, "wb") as handle:
    plistlib.dump({
        "method": "app-store-connect",
        "teamID": "P4DQK6SRKR",
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "installerSigningCertificate": installer,
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": {bundle: profile},
        "stripSwiftSymbols": True,
        "uploadSymbols": True,
        "destination": "export",
    }, handle)
PY

xcodegen generate >/dev/null

ARCHIVE=$OUT/TailscodeMacStore.xcarchive
rm -rf "$ARCHIVE" "$OUT/export"
xcodebuild archive \
  -project Tailscode.xcodeproj -scheme TailscodeMacStore -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$MARKETING" > "$OUT/archive.log" 2>&1 || {
  grep -E "error:" "$OUT/archive.log" | sort -u | tail -20
  echo "archive FAILED, log at $OUT/archive.log" >&2
  exit 1
}
[ -d "$ARCHIVE" ] || { echo "no archive produced" >&2; exit 1; }

env PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" -exportOptionsPlist "$OPTIONS" > "$OUT/export.log" 2>&1 || {
  tail -20 "$OUT/export.log"
  echo "export FAILED, log at $OUT/export.log" >&2
  exit 1
}

PKG=$(find "$OUT/export" -maxdepth 1 -name '*.pkg' | head -1)
[ -n "$PKG" ] || { echo "no pkg exported" >&2; exit 1; }
EXPANDED=$OUT/expanded
rm -rf "$EXPANDED"
pkgutil --expand-full "$PKG" "$EXPANDED"
INFO=$(find "$EXPANDED" -path '*.app/Contents/Info.plist' | head -1)
BINARY=$(dirname "$INFO")/MacOS/$(plutil -extract CFBundleExecutable raw "$INFO")
echo "version  $(plutil -extract CFBundleShortVersionString raw "$INFO")"
echo "build    $(plutil -extract CFBundleVersion raw "$INFO")"
echo "host     $(plutil -extract BuildMachineOSBuild raw "$INFO" 2>/dev/null || echo unknown)"
xcrun vtool -show-build "$BINARY" | grep -E "platform|sdk" | head -3
[ "$(plutil -extract CFBundleVersion raw "$INFO")" = "$BUILD" ] || { echo "the pkg does not carry build $BUILD" >&2; exit 1; }
echo "artifact $PKG"

if [ "$UPLOAD" = 1 ]; then
  asc builds upload --app "$APP_ID" --pkg "$PKG" --wait
fi
