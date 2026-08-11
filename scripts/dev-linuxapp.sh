#!/usr/bin/env bash
# One long-lived headless Tailscode, off to the side of whatever the person is actually doing.
#
# The Linux client used to be developed by opening it: build, launch, look, kill, repeat — every
# round a new window on the real desktop, on top of the real work, and (because the app is
# single-instance on the session bus) another whole app stacked inside the instance already
# running. This puts the development copy on its own X display and its own session bus, with its
# own settings and its own data, and keeps ONE of it alive across every command below.
#
#   scripts/dev-linuxapp.sh start            build, then start it (or reuse the one running)
#   scripts/dev-linuxapp.sh start --clean    the same, with no settings and no servers: first run
#   scripts/dev-linuxapp.sh shot [out.png]   what it looks like right now
#   scripts/dev-linuxapp.sh click 640 400    real input, through the X server
#   scripts/dev-linuxapp.sh key ctrl+w v
#   scripts/dev-linuxapp.sh type 'hello'
#   scripts/dev-linuxapp.sh drive 'splits'   the app's own TAILSCODE_DRIVE verbs
#   scripts/dev-linuxapp.sh log -f
#   scripts/dev-linuxapp.sh status | stop | restart
#   scripts/dev-linuxapp.sh run <cmd…>       any command inside the harness display and bus
#
# Nothing here can reach the desktop: the app never sees WAYLAND_DISPLAY, and the binary itself
# refuses a real screen (DesktopGuard) unless someone passes --force-desktop by hand.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
DISPLAY_NUM=${TAILSCODE_DEV_DISPLAY_NUM:-77}
DEV_DISPLAY=":$DISPLAY_NUM"
GEOMETRY=${TAILSCODE_DEV_GEOM:-1600x1000x24}
STATE=${TAILSCODE_DEV_STATE:-${XDG_RUNTIME_DIR:-/tmp}/tailscode-dev/$DISPLAY_NUM}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/tailscode-dev
LOG=$STATE/app.log
CONFIG_HOME=$STATE/home/config
DATA_HOME=$STATE/home/share
XPYTHON=""
HARNESS_ENV=()
CLEAN_HOME=no

mkdir -p "$STATE" "$CONFIG_HOME" "$DATA_HOME" "$CACHE"

say() { printf '%s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

pid_of() { [ -s "$STATE/$1.pid" ] && cat "$STATE/$1.pid" || true; }
alive() {
    local pid
    pid=$(pid_of "$1")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# The real settings copied once, never shared: the dev app writes its own window size, split
# snapshot and preferences, and a crash mid-experiment cannot take the person's layout with it.
# `--clean` seeds nothing, which is the only honest way to see first run.
seed_home() {
    [ -e "$CONFIG_HOME/tailscode" ] && return 0
    if [ "$CLEAN_HOME" = yes ]; then
        mkdir -p "$CONFIG_HOME/tailscode"
        return 0
    fi
    [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/tailscode" ] &&
        cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/tailscode" "$CONFIG_HOME/" 2>/dev/null || true
    [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/tailscode" ] &&
        cp -a "${XDG_DATA_HOME:-$HOME/.local/share}/tailscode" "$DATA_HOME/" 2>/dev/null || true
    mkdir -p "$CONFIG_HOME/tailscode"
}

start_display() {
    alive xvfb && return 0
    Xvfb "$DEV_DISPLAY" -screen 0 "$GEOMETRY" -nolisten tcp >"$STATE/xvfb.log" 2>&1 &
    echo $! >"$STATE/xvfb.pid"
    for _ in $(seq 1 100); do
        [ -S "/tmp/.X11-unix/X$DISPLAY_NUM" ] && return 0
        sleep 0.1
    done
    die "Xvfb $DEV_DISPLAY never came up — $STATE/xvfb.log"
}

# A private session bus, because the app is single-instance per bus name: on the desktop's own bus
# a dev launch would remote-activate the installed app the person is using instead of starting.
start_bus() {
    if alive bus && [ -s "$STATE/bus.addr" ]; then return 0; fi
    rm -f "$STATE/bus.addr" "$STATE/bus.pid"
    dbus-daemon --session --fork --print-address=3 --print-pid=4 \
        3>"$STATE/bus.addr" 4>"$STATE/bus.pid"
    [ -s "$STATE/bus.addr" ] || die "no session bus"
}

harness_env() {
    start_display
    start_bus
    seed_home
    HARNESS_ENV=(
        env -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS
        DISPLAY="$DEV_DISPLAY"
        GDK_BACKEND=x11
        DBUS_SESSION_BUS_ADDRESS="$(cat "$STATE/bus.addr")"
        XDG_CONFIG_HOME="$CONFIG_HOME"
        XDG_DATA_HOME="$DATA_HOME"
        XDG_STATE_HOME="$STATE/home/state"
        # HOME and the cache too: AppCache's FileSessionCache lives in .cachesDirectory,
        # and sharing ~/.cache/tailscode with the installed app restores the person's real
        # last session — title and all — into a harness pane.
        HOME="$STATE/home"
        XDG_CACHE_HOME="$STATE/home/cache"
        TAILSCODE_DEV_DISPLAY="$DEV_DISPLAY"
        GSK_RENDERER="${TAILSCODE_DEV_RENDERER:-cairo}"
        LIBGL_ALWAYS_SOFTWARE=1
        NO_AT_BRIDGE=1
    )
}

binary() {
    local flavour=${1:-debug}
    echo "$REPO/TailscodeLinux/.build/$flavour/tailscode"
}

build() {
    local flavour=${1:-debug}
    local args=(swift build --manifest-cache none)
    [ "$flavour" = release ] && args+=(-c release)
    (cd "$REPO/TailscodeLinux" && "${args[@]}" 2>&1 |
        grep -E "error:|Build complete" || true)
    [ -x "$(binary "$flavour")" ] || die "no binary at $(binary "$flavour")"
}

xvenv() {
    local python=$CACHE/xvenv/bin/python
    if [ ! -x "$python" ]; then
        python3 -m venv "$CACHE/xvenv" >/dev/null
        "$CACHE/xvenv/bin/pip" install --quiet python-xlib >/dev/null
    fi
    echo "$python"
}

require_running() {
    alive app && return 0
    say "not running — starting it"
    cmd_start
}

mapped_a_window() {
    "$XPYTHON" - "$DEV_DISPLAY" <<'PY' 2>/dev/null
import sys
from Xlib import display
sys.exit(0 if display.Display(sys.argv[1]).screen().root.query_tree().children else 1)
PY
}

cmd_start() {
    local flavour=debug fresh=no nobuild=no drive=""
    local extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
        --release) flavour=release ;;
        --fresh) fresh=yes ;;
        --clean) CLEAN_HOME=yes ;;
        --no-build) nobuild=yes ;;
        --drive) drive=$2; shift ;;
        --) shift; extra+=("$@"); break ;;
        *) extra+=("$1") ;;
        esac
        shift
    done

    if alive app && [ "$fresh" = no ] && [ -z "$drive" ]; then
        say "reusing pid $(pid_of app) on $DEV_DISPLAY"
        return 0
    fi
    [ "$nobuild" = yes ] || build "$flavour"
    stop_app
    harness_env
    XPYTHON=$(xvenv)
    [ -n "$drive" ] && HARNESS_ENV+=(TAILSCODE_DRIVE="$drive")
    [ -n "${TAILSCODE_HOST:-}" ] && HARNESS_ENV+=(TAILSCODE_HOST="$TAILSCODE_HOST")
    [ -n "${TAILSCODE_PASSWORD:-}" ] && HARNESS_ENV+=(TAILSCODE_PASSWORD="$TAILSCODE_PASSWORD")
    [ -n "${TAILSCODE_TRACE:-}" ] && HARNESS_ENV+=(TAILSCODE_TRACE="$TAILSCODE_TRACE")
    [ -n "${TAILSCODE_ORB:-}" ] && HARNESS_ENV+=(TAILSCODE_ORB="$TAILSCODE_ORB")

    "${HARNESS_ENV[@]}" "$(binary "$flavour")" ${extra[@]+"${extra[@]}"} >"$LOG" 2>&1 &
    echo $! >"$STATE/app.pid"
    local mapped=no
    for _ in $(seq 1 200); do
        sleep 0.1
        alive app || { tail -20 "$LOG" >&2; die "it exited on start"; }
        if mapped_a_window; then mapped=yes; break; fi
    done
    [ "$mapped" = yes ] || { tail -20 "$LOG" >&2; die "it never mapped a window"; }
    say "started pid $(pid_of app) on $DEV_DISPLAY ($flavour)"
}

reap() {
    local pid
    pid=$(pid_of "$1")
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$STATE/$1.pid"
}

stop_app() { reap app; }

cmd_stop() {
    reap app
    reap bus
    reap xvfb
    rm -f "$STATE/bus.addr"
    say "stopped"
}

cmd_status() {
    local app_pid
    app_pid=$(pid_of app)
    printf 'display  %s (%s)\n' "$DEV_DISPLAY" "$(alive xvfb && echo up || echo down)"
    printf 'bus      %s\n' "$(alive bus && cat "$STATE/bus.addr" || echo down)"
    if alive app; then
        printf 'app      pid %s  rss %s KiB  cpu %s%%  threads %s  fds %s\n' \
            "$app_pid" \
            "$(ps -o rss= -p "$app_pid" | tr -d ' ')" \
            "$(ps -o %cpu= -p "$app_pid" | tr -d ' ')" \
            "$(ls "/proc/$app_pid/task" | wc -l)" \
            "$(ls "/proc/$app_pid/fd" 2>/dev/null | wc -l)"
        printf 'windows  %s\n' "$(window_count)"
    else
        printf 'app      down\n'
    fi
    printf 'log      %s\n' "$LOG"
    printf 'home     %s\n' "$STATE/home"
}

# Every window the app exported on its own bus — the count that used to climb by one per launch.
window_count() {
    harness_env >/dev/null
    "${HARNESS_ENV[@]}" gdbus introspect --session \
        --dest com.guitaripod.tailscode \
        --object-path /com/guitaripod/tailscode/window 2>/dev/null |
        grep -cE '^\s+node [0-9]+' || echo 0
}

cmd_shot() {
    require_running
    local out=${1:-/tmp/tailscode-linux.png}
    harness_env
    "${HARNESS_ENV[@]}" import -display "$DEV_DISPLAY" -window root "$out"
    local want got
    want=${GEOMETRY%x*}
    got=$(identify -format '%wx%h' "$out" 2>/dev/null || echo unreadable)
    if [ "$got" != "$want" ]; then
        rm -f "$out"
        die "shot is ${got}, harness is ${want} — that was NOT the harness display, refusing to keep it"
    fi
    say "$out"
}

# The X server answering DEV_DISPLAY must be the harness Xvfb, proven by its geometry, before a
# single event is sent: a shot of the wrong display is a lie, but a click on it drives the desk.
assert_harness_display() {
    "$(xvenv)" - "$DEV_DISPLAY" "${GEOMETRY%x*}" <<'PY' && return 0
import sys
from Xlib import display
screen = display.Display(sys.argv[1]).screen()
sys.exit(0 if f"{screen.width_in_pixels}x{screen.height_in_pixels}" == sys.argv[2] else 1)
PY
    die "$DEV_DISPLAY is not the ${GEOMETRY%x*} harness Xvfb — refusing to touch it"
}

cmd_input() {
    require_running
    harness_env
    assert_harness_display
    "${HARNESS_ENV[@]}" "$(xvenv)" "$REPO/scripts/dev-input.py" "$@"
}

cmd_run() {
    harness_env
    "${HARNESS_ENV[@]}" "$@"
}

cmd_selftest() {
    build "${1:-debug}"
    harness_env
    "${HARNESS_ENV[@]}" "$(binary "${1:-debug}")" --selftest
}

VERB=${1:-status}
shift || true
case "$VERB" in
start) cmd_start "$@" ;;
stop) cmd_stop ;;
restart) cmd_start --fresh "$@" ;;
status) cmd_status ;;
shot) cmd_shot "$@" ;;
log) tail "${@:--n40}" "$LOG" ;;
click | move | drag | scroll | key | type) cmd_input "$VERB" "$@" ;;
drive) cmd_start --fresh --drive "$1" ;;
windows) window_count ;;
run) cmd_run "$@" ;;
selftest) cmd_selftest "$@" ;;
build) build "${1:-debug}" ;;
*) sed -n '3,20p' "$0" >&2; exit 2 ;;
esac
