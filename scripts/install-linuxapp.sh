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

# The binary is installed away from the checkout that built it, so the running program has no way to
# walk back to its source. This is the only link, and the app believes it only after checking it
# against the binary actually running — hence the size and mtime, read after the install.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tailscode"
SRC=$(cd .. && pwd)
mkdir -p "$STATE_DIR"
BIN="$BIN_DIR/tailscode"
DIRTY=false
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then DIRTY=true; fi
printf '{"schema":1,"component":"tailscode-linux","installedAt":"%s","installedBy":"scripts/install-linuxapp.sh","flavour":"release","binary":{"path":"%s","size":%s,"modifiedAt":"%s"},"source":{"path":"%s","describe":"%s","commit":"%s","branch":"%s","upstream":"%s","dirty":%s},"marketingVersion":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$BIN" \
    "$(stat -c %s "$BIN")" \
    "$(date -u -r "$BIN" +%Y-%m-%dT%H:%M:%SZ)" \
    "$SRC" \
    "$(git -C "$SRC" describe --tags --always --dirty 2>/dev/null)" \
    "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" \
    "$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    "$DIRTY" \
    "$("$BIN" --version 2>/dev/null | awk '{print $NF}')" \
    > "$STATE_DIR/install.json"

# The desktop entry and icons are owned by the app itself (DesktopIntegration writes the
# GApplication-id-named files on every launch — the name GNotification and the Wayland shell
# both match against). The script only clears the misnamed entry earlier versions wrote.
rm -f "$APPS_DIR/tailscode.desktop"
update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "installed $("$BIN_DIR/tailscode" --version 2>/dev/null || echo "$BIN_DIR/tailscode")"

# A restart has to look like a launch. The desktop's own portal only grants a key from the whole
# session to an app it can name, and it names one by the systemd scope its .desktop entry started
# it in — an app resurrected with a bare `nohup` inherits the caller's cgroup instead, is refused an
# app id, and quietly loses its global chord until the next launcher click.
if [ "${1:-}" != "--no-restart" ] && [ "$WAS_RUNNING" = yes ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --scope --quiet \
            -u "app-com.guitaripod.tailscode-$$" \
            "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    else
        nohup "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    fi
    sleep 2
    NEW_PIDS=$(pgrep -f "$BIN_DIR/tailscode$" || true)
    for pid in $NEW_PIDS; do
        case " $OLD_PIDS " in *" $pid "*) ;; *) echo "restarted (pid $pid)"; exit 0 ;; esac
    done
    echo "NOT restarted — the old process is still what is running" >&2
    exit 1
fi
