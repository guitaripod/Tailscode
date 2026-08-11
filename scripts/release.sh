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

# A build number that was uploaded once is spent forever, and ASC only says so
# after the staging, the archive and the upload have all been paid for. Ask first.
python3 - "$BUILD" <<'PY' || exit 1
import os, sys
sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
try:
    import asc
except ImportError:
    print("!! no operator asc lib — skipping the spent-build-number check", file=sys.stderr)
    sys.exit(0)
wanted = sys.argv[1]
try:
    rows = asc.get("/v1/builds", **{"filter[app]": "6791660932", "limit": "50",
                                    "sort": "-uploadedDate"}).get("data", [])
except Exception as exc:
    print(f"!! could not reach App Store Connect ({type(exc).__name__}) — "
          "skipping the spent-build-number check", file=sys.stderr)
    sys.exit(0)
taken = {r["attributes"].get("version") for r in rows}
if wanted in taken:
    numeric = [int(v) for v in taken if v and v.isdigit()]
    print(f"build {wanted} is already on App Store Connect — next free is "
          f"{max(numeric) + 1 if numeric else '?'}", file=sys.stderr)
    sys.exit(1)
print(f"build {wanted} is free")
PY

echo "== staging $ROOT → $STAGE"
mkdir -p "$STAGE"
# build-* and nested .build trees are multi-GB host leftovers (build-mac, SPM
# caches under TailscodeLinux/TailscodeCore). Shipping them into the guest made
# the rsync hang for tens of minutes and is never needed to archive.
rsync -a --delete \
  --exclude .git --exclude build --exclude 'build-*' \
  --exclude .build --exclude '**/.build' --exclude '.swiftpm' --exclude '**/.swiftpm' \
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
