#!/usr/bin/env bash
# Build the Linux client in release and install what was just built, so the `tailscode` on PATH is
# the code that was just written rather than whatever was there last week.
#
#   scripts/install-linuxapp.sh            # build, install, restart if it was running
#   scripts/install-linuxapp.sh --no-restart
set -euo pipefail

cd "$(dirname "$0")/.."
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

cd TailscodeLinux
# No `|| true` here: with pipefail a failed build must abort the install, or a stale binary from
# the last good build gets installed and "installed/restarted" lies about what is running.
swift build -c release --manifest-cache none 2>&1 | grep -E "error:|Build complete"
BUILT=$PWD/.build/release/tailscode
[ -x "$BUILT" ] || { echo "no binary at $BUILT"; exit 1; }

WAS_RUNNING=no
pgrep -f "$BIN_DIR/tailscode$" >/dev/null 2>&1 && WAS_RUNNING=yes
pkill -f "$BIN_DIR/tailscode$" 2>/dev/null || true

mkdir -p "$BIN_DIR" "$APPS_DIR"
install -m 0755 "$BUILT" "$BIN_DIR/tailscode"

# The desktop entry and icons are owned by the app itself (DesktopIntegration writes the
# GApplication-id-named files on every launch — the name GNotification and the Wayland shell
# both match against). The script only clears the misnamed entry earlier versions wrote.
rm -f "$APPS_DIR/tailscode.desktop"
update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "installed $("$BIN_DIR/tailscode" --version 2>/dev/null || echo "$BIN_DIR/tailscode")"

if [ "${1:-}" != "--no-restart" ] && [ "$WAS_RUNNING" = yes ]; then
    nohup "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    sleep 2
    pgrep -f "$BIN_DIR/tailscode$" >/dev/null && echo "restarted"
fi
