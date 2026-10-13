#!/usr/bin/env bash
# Archive, export and (with --upload) deliver an iOS App Store build from THIS Mac, for the days the
# stable-macOS build guest is gone. release.sh is the preferred road while the host runs a major
# beta: a guest stamps a stable BuildMachineOSBuild, and a major-beta host stamps one Apple bounces
# with ITMS-90111. The host rule is Marcus's: a point beta (27.2) builds and uploads locally. The
# script prints the stamp and the SDK so the host line is read before anything is delivered, and
# refuses a build number the iOS train already holds.
#
# Usage: scripts/release-ios-local.sh <build-number> <marketing-version> [--upload]
set -euo pipefail
export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH
cd "$(dirname "$0")/.."

[ $# -ge 2 ] || { echo "usage: scripts/release-ios-local.sh <build-number> <marketing-version> [--upload]" >&2; exit 2; }
BUILD=$1
MARKETING=$2
UPLOAD=0
[ "${3:-}" = "--upload" ] && UPLOAD=1

APP_ID=6791660932
VAULT=$HOME/.config/midgar/signing
PROFILE_DIR=$HOME/Library/Developer/Xcode/UserData/Provisioning\ Profiles
KIT=${KIT:-$PWD/../../swift/CodingAgentKit}
OUT=build/release-ios

PROFILE_FILES=(
  "$VAULT/tailscode-appstore-2026.mobileprovision"
  "$VAULT/tailscode-widget-appstore-2026.mobileprovision"
  "$VAULT/tailscode-nse-appstore-2026.mobileprovision"
)
for file in "${PROFILE_FILES[@]}"; do
  [ -f "$file" ] || { echo "no App Store profile at $file" >&2; exit 1; }
done
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
    ["asc", "builds", "list", "--app", app, "--platform", "IOS", "--limit", "50", "--output", "table"],
    capture_output=True, text=True).stdout
taken = {line.split("│")[2].strip() for line in out.splitlines() if line.count("│") > 4}
if build in taken:
    print(f"build {build} is already on the iOS train", file=sys.stderr)
    sys.exit(1)
print(f"build {build} is free on the iOS train")
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
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS
trap cleanup_keychain EXIT

PROFILES_PLIST=$OUT/profiles.txt
: > "$PROFILES_PLIST"
for file in "${PROFILE_FILES[@]}"; do
  DECODED=$(mktemp)
  security cms -D -i "$file" > "$DECODED"
  UUID=$(plutil -extract UUID raw "$DECODED")
  NAME=$(plutil -extract Name raw "$DECODED")
  IDENTIFIER=$(plutil -extract Entitlements.application-identifier raw "$DECODED")
  rm -f "$DECODED"
  cp "$file" "$PROFILE_DIR/$UUID.mobileprovision"
  printf '%s\t%s\n' "${IDENTIFIER#*.}" "$NAME" >> "$PROFILES_PLIST"
  echo "profile ${IDENTIFIER#*.} -> $NAME"
done

OPTIONS=$OUT/ExportOptions.plist
python3 -I - "$OPTIONS" "$PROFILES_PLIST" <<'PY'
import plistlib, sys
path, profiles = sys.argv[1:3]
mapping = dict(line.rstrip("\n").split("\t") for line in open(profiles) if line.strip())
with open(path, "wb") as handle:
    plistlib.dump({
        "method": "app-store-connect",
        "teamID": "P4DQK6SRKR",
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": mapping,
        "stripSwiftSymbols": True,
        "uploadSymbols": True,
        "destination": "export",
    }, handle)
PY

xcodegen generate >/dev/null

ARCHIVE=$OUT/Tailscode.xcarchive
rm -rf "$ARCHIVE" "$OUT/export"
xcodebuild archive \
  -project Tailscode.xcodeproj -scheme Tailscode -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
  -skipPackagePluginValidation -skipMacroValidation \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$MARKETING" > "$OUT/archive.log" 2>&1 || {
  grep -E "error:" "$OUT/archive.log" | sort -u | tail -20
  echo "archive FAILED, log at $OUT/archive.log" >&2
  exit 1
}
[ -d "$ARCHIVE" ] || { echo "no archive produced" >&2; exit 1; }

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" -exportOptionsPlist "$OPTIONS" > "$OUT/export.log" 2>&1 || {
  tail -20 "$OUT/export.log"
  echo "export FAILED, log at $OUT/export.log" >&2
  exit 1
}

IPA=$(find "$OUT/export" -maxdepth 1 -name '*.ipa' | head -1)
[ -n "$IPA" ] || { echo "no ipa exported" >&2; exit 1; }
EXPANDED=$OUT/expanded
rm -rf "$EXPANDED"
mkdir -p "$EXPANDED"
/usr/bin/unzip -q "$IPA" -d "$EXPANDED"
INFO=$(find "$EXPANDED/Payload" -maxdepth 2 -name Info.plist -path '*.app/Info.plist' | head -1)
BINARY=$(dirname "$INFO")/$(plutil -extract CFBundleExecutable raw "$INFO")
echo "version  $(plutil -extract CFBundleShortVersionString raw "$INFO")"
echo "build    $(plutil -extract CFBundleVersion raw "$INFO")"
echo "host     $(plutil -extract BuildMachineOSBuild raw "$INFO" 2>/dev/null || echo unknown)"
xcrun vtool -show-build "$BINARY" | grep -E "platform|sdk" | head -3
[ "$(plutil -extract CFBundleVersion raw "$INFO")" = "$BUILD" ] || { echo "the ipa does not carry build $BUILD" >&2; exit 1; }
[ "$(plutil -extract CFBundleShortVersionString raw "$INFO")" = "$MARKETING" ] || { echo "the ipa does not carry version $MARKETING" >&2; exit 1; }
for extension in "$(dirname "$INFO")"/PlugIns/*.appex; do
  [ -d "$extension" ] || continue
  [ "$(plutil -extract CFBundleVersion raw "$extension/Info.plist")" = "$BUILD" ] || { echo "$extension does not carry build $BUILD" >&2; exit 1; }
done
echo "artifact $IPA"

if [ "$UPLOAD" = 1 ]; then
  asc builds upload --app "$APP_ID" --ipa "$IPA" --version "$MARKETING" --build-number "$BUILD" --wait
fi
