#!/usr/bin/env bash
# Build the GTK4/libadwaita client, prove it reaches a real server, and render it on a headless
# X display so the loop closes without borrowing the user's screen.
#
#   TAILSCODE_HOST=http://100.x.y.z:4098 TAILSCODE_PASSWORD=… scripts/build-linuxapp.sh
#   scripts/build-linuxapp.sh --shot     # also write /tmp/tailscode-linux.png
#   scripts/build-linuxapp.sh --run      # leave it running on the harness display
#
# Both delegate to scripts/dev-linuxapp.sh, which is the fuller loop: input, drive verbs, logs.
set -euo pipefail

cd "$(dirname "$0")/../TailscodeLinux"

swift build --manifest-cache none 2>&1 | grep -E "error:|warning: .*never used|Build complete" || true

BIN=.build/debug/tailscode

if [ -n "${TAILSCODE_HOST:-}" ]; then
    "$BIN" --selftest
fi

# Rendering is the harness's job, and the harness keeps ONE app alive rather than starting another
# one per look: a nested X server and a private session bus, so nothing lands on the real desktop
# and nothing joins the instance the person is using.
HARNESS="$(dirname "$0")/dev-linuxapp.sh"

case "${1:-}" in
--shot)
    "$HARNESS" start --no-build >/dev/null
    "$HARNESS" shot /tmp/tailscode-linux.png
    ;;
--run)
    "$HARNESS" start --no-build
    "$HARNESS" status
    ;;
esac
