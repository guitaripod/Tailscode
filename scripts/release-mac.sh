#!/usr/bin/env bash
# Archive + upload a Mac App Store build via the stable-macOS build VM.
#
# The macOS sibling of release.sh. Same reason for the VM (a beta host stamps
# BuildMachineOSBuild and Apple bounces the upload with ITMS-90111) and the same
# staging trick (CodingAgentKit lives outside this repo, so the guest never sees
# the relative package path — vendor a copy and repoint project.yml).
#
# What differs: the scheme is TailscodeMacStore (sandboxed, hardened, no widget),
# the profile is a .provisionprofile, and the spent-build-number check asks the
# macOS pre-release train. The two platforms number independently — build 52 is
# spent on the iPhone train and free on this one — so a platform-blind check
# would reject a perfectly good number after paying for a whole VM cycle.
#
# Usage: scripts/release-mac.sh [build-number] [marketing-version] [--no-upload]
set -euo pipefail

BUILD=101
MARKETING=1.22
NO_UPLOAD=
ARGN=0
while [ $# -gt 0 ]; do
  case $1 in
    --no-upload) NO_UPLOAD=--no-upload;;
    -h|--help) echo "usage: scripts/release-mac.sh [build-number] [marketing-version] [--no-upload]"; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 2;;
    *)
      ARGN=$((ARGN + 1))
      case $ARGN in
        1) BUILD=$1;;
        2) MARKETING=$1;;
        *) echo "usage: scripts/release-mac.sh [build-number] [marketing-version] [--no-upload]" >&2; exit 2;;
      esac;;
  esac
  shift
done

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The Kit the build vendors. Overridable because the host tree may be carrying another
# session's uncommitted work: a release ships the committed Kit, never whatever is half-written
# on the machine that happens to be doing the archiving.
KIT=${KIT:-$ROOT/../../swift/CodingAgentKit}
STAGE=/tmp/tailscode-mac-release
SIGNING=$HOME/.config/midgar/signing
PROFILE=$SIGNING/tailscode-mac-appstore-2026.provisionprofile

[ -d "$KIT" ] || { echo "no CodingAgentKit at $KIT" >&2; exit 1; }
# buildvm would fail on this much later and less legibly. The profile is "Tailscode macOS App
# Store 2026" (MAC_APP_STORE, bundleId Z8A63L9289); re-mint it into the vault if it is gone.
[ -f "$PROFILE" ] || { echo "no Mac App Store profile at $PROFILE — mint one (MAC_APP_STORE, bundleId Z8A63L9289, cert WXA29XJHK2) into the vault first" >&2; exit 1; }

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
    rows = asc.get("/v1/builds", **{"filter[app]": "6791660932",
                                    "filter[preReleaseVersion.platform]": "MAC_OS",
                                    "limit": "50", "sort": "-uploadedDate"}).get("data", [])
except Exception as exc:
    print(f"!! could not reach App Store Connect ({type(exc).__name__}) — "
          "skipping the spent-build-number check", file=sys.stderr)
    sys.exit(0)
taken = {r["attributes"].get("version") for r in rows}
if wanted in taken:
    numeric = [int(v) for v in taken if v and v.isdigit()]
    print(f"build {wanted} is already on the macOS train — next free is "
          f"{max(numeric) + 1 if numeric else '?'}", file=sys.stderr)
    sys.exit(1)
print(f"build {wanted} is free on the macOS train")
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
  --scheme TailscodeMacStore \
  --platform macos \
  --profile "$PROFILE" \
  --build "$BUILD" \
  ${MARKETING:+--marketing "$MARKETING"} \
  ${NO_UPLOAD:+"$NO_UPLOAD"}
