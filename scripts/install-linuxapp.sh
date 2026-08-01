#!/usr/bin/env bash
# Build the Linux client in release and install what was just built, so the `tailscode` on PATH is
# the code that was just written rather than whatever was there last week.
#
#   scripts/install-linuxapp.sh            # build, install, restart if it was running
#   scripts/install-linuxapp.sh --no-restart
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

cd TailscodeLinux
swift build -c release --manifest-cache none 2>&1 | grep -E "error:|Build complete" || true
BUILT=$PWD/.build/release/tailscode
[ -x "$BUILT" ] || { echo "no binary at $BUILT"; exit 1; }

WAS_RUNNING=no
pgrep -f "$BIN_DIR/tailscode$" >/dev/null 2>&1 && WAS_RUNNING=yes
pkill -f "$BIN_DIR/tailscode$" 2>/dev/null || true

mkdir -p "$BIN_DIR" "$APPS_DIR"
install -m 0755 "$BUILT" "$BIN_DIR/tailscode"

# The app's own icon rather than a stock terminal glyph: the SVG the iOS icon is generated from,
# installed into the hicolor theme where the shell and the switcher both look for it.
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$ICON_DIR"
install -m 0644 "$ROOT/Resources/AppIcon.svg" "$ICON_DIR/tailscode.svg"
gtk4-update-icon-cache -q -t -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

cat > "$APPS_DIR/tailscode.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Tailscode
Comment=Drive your coding agents over Tailscale
Exec=$BIN_DIR/tailscode
Icon=tailscode
Terminal=false
Categories=Development;
StartupWMClass=tailscode
DESKTOP
update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "installed $("$BIN_DIR/tailscode" --version 2>/dev/null || echo "$BIN_DIR/tailscode")"

if [ "${1:-}" != "--no-restart" ] && [ "$WAS_RUNNING" = yes ]; then
    nohup "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    sleep 2
    pgrep -f "$BIN_DIR/tailscode$" >/dev/null && echo "restarted"
fi
