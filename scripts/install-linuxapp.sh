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

# The app is single-instance on the session bus, so launching it while the old one is still alive
# remote-activates the process already running — the script then finds a tailscode, says
# "restarted", and leaves the person on the binary they just replaced. So the old process is waited
# out by pid before anything is installed.
OLD_PIDS=$(pgrep -f "$BIN_DIR/tailscode$" || true)
WAS_RUNNING=no
[ -n "$OLD_PIDS" ] && WAS_RUNNING=yes
for pid in $OLD_PIDS; do kill "$pid" 2>/dev/null || true; done
for _ in $(seq 1 50); do
    still=""
    for pid in $OLD_PIDS; do kill -0 "$pid" 2>/dev/null && still="yes"; done
    [ -z "$still" ] && break
    sleep 0.2
done
for pid in $OLD_PIDS; do kill -9 "$pid" 2>/dev/null || true; done

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
    NEW_PIDS=$(pgrep -f "$BIN_DIR/tailscode$" || true)
    for pid in $NEW_PIDS; do
        case " $OLD_PIDS " in *" $pid "*) ;; *) echo "restarted (pid $pid)"; exit 0 ;; esac
    done
    echo "NOT restarted — the old process is still what is running" >&2
    exit 1
fi
