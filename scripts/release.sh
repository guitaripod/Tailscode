#!/usr/bin/env bash
# Archive + upload an App Store build via the stable-macOS build VM.
#
# The host Mac runs a beta macOS, so a local `xcodebuild archive` would be
# rejected with ITMS-90111. buildvm archives inside a stable guest instead.
# CodingAgentKit lives outside this repo, so the guest never sees it via the
# relative package path — stage a copy under vendor/ and repoint project.yml.
#
# Usage: scripts/release.sh <build-number> [marketing-version]
set -euo pipefail

BUILD=${1:?usage: scripts/release.sh <build-number> [marketing-version]}
MARKETING=${2:-}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KIT=$ROOT/../../swift/CodingAgentKit
STAGE=/tmp/tailscode-release
SIGNING=$HOME/.config/midgar/signing

[ -d "$KIT" ] || { echo "no CodingAgentKit at $KIT" >&2; exit 1; }

echo "== staging $ROOT → $STAGE"
mkdir -p "$STAGE"
rsync -a --delete \
  --exclude .git --exclude build --exclude build-sim --exclude build-device \
  --exclude DerivedData --exclude vendor --exclude '*.xcuserstate' \
  "$ROOT/" "$STAGE/"

# --delete-excluded is deliberate: a stale .build in the vendored Kit makes
# xcodebuild link objects whose enum layouts predate the sources it compiles.
echo "== vendoring CodingAgentKit"
mkdir -p "$STAGE/vendor/CodingAgentKit"
rsync -a --delete --delete-excluded \
  --exclude .git --exclude .build --exclude '.swiftpm' \
  "$KIT/" "$STAGE/vendor/CodingAgentKit/"

/usr/bin/sed -i '' 's|path: \.\./\.\./swift/CodingAgentKit|path: vendor/CodingAgentKit|' "$STAGE/project.yml"
grep -q 'path: vendor/CodingAgentKit' "$STAGE/project.yml" || { echo "package path not repointed" >&2; exit 1; }

exec "$HOME/Dev/buildvm/bin/buildvm" build \
  --dir "$STAGE" \
  --scheme Tailscode \
  --profile "$SIGNING/tailscode-appstore-2026.mobileprovision" \
  --profile "$SIGNING/tailscode-widget-appstore-2026.mobileprovision" \
  --profile "$SIGNING/tailscode-nse-appstore-2026.mobileprovision" \
  --build "$BUILD" \
  ${MARKETING:+--marketing "$MARKETING"}
