#!/usr/bin/env bash
# A 4K60 screen take of the Linux client, on a display nobody is sitting at.
#
# The dev harness (dev-linuxapp.sh) exists to look at the app; this exists to film it. Same
# refusal to touch the real desktop, same private bus and private settings, but the screen is
# 3840x2160, the app is launched at GDK_SCALE=2 so a 4K frame is a 1080p layout drawn twice as
# finely, and a recorder runs the whole time at a fixed 60fps.
#
#   scripts/record-linuxapp.sh up                     display + app, nothing recorded yet
#   scripts/record-linuxapp.sh shot [out.png]         what it looks like right now
#   scripts/record-linuxapp.sh in <cmd…>              any command inside the film display and bus
#   scripts/record-linuxapp.sh rec-start [take.mkv]   start the 60fps recorder
#   scripts/record-linuxapp.sh rec-stop               stop it
#   scripts/record-linuxapp.sh encode <take> <out>    the delivery encode
#   scripts/record-linuxapp.sh down
#
# There is no window manager on this display, so `up` also runs a stagehand: it centres every
# window the app maps after the first one and warps the pointer into it, which is both what a
# WM would do and what X's PointerRoot focus needs before a key press can land there.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
DISPLAY_NUM=${TAILSCODE_FILM_DISPLAY_NUM:-78}
FILM_DISPLAY=":$DISPLAY_NUM"
WIDTH=${TAILSCODE_FILM_WIDTH:-3840}
HEIGHT=${TAILSCODE_FILM_HEIGHT:-2160}
SCALE=${TAILSCODE_FILM_SCALE:-2}
FPS=${TAILSCODE_FILM_FPS:-60}
STATE=${TAILSCODE_FILM_STATE:-/tmp/tailscode-film/$DISPLAY_NUM}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/tailscode-dev
FLAVOUR=${TAILSCODE_FILM_FLAVOUR:-release}
LOG=$STATE/app.log
CONFIG_HOME=$STATE/home/config
DATA_HOME=$STATE/home/share
HARNESS_ENV=()

mkdir -p "$STATE" "$CONFIG_HOME" "$DATA_HOME" "$CACHE"

say() { printf '%s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

pid_of() { [ -s "$STATE/$1.pid" ] && cat "$STATE/$1.pid" || true; }
alive() {
    local pid
    pid=$(pid_of "$1")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

xvenv() {
    local python=$CACHE/xvenv/bin/python
    if [ ! -x "$python" ]; then
        python3 -m venv "$CACHE/xvenv" >/dev/null
        "$CACHE/xvenv/bin/pip" install --quiet python-xlib >/dev/null
    fi
    echo "$python"
}

# The person's own servers, drafts and theme, copied once — a take should film the real app, not
# a first run — but the window is sized to the film frame and the saved split tree is dropped, so
# every take opens on one pane and the split in the scene is a split the viewer watches happen.
seed_home() {
    [ -e "$CONFIG_HOME/tailscode" ] && return 0
    [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/tailscode" ] &&
        cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/tailscode" "$CONFIG_HOME/" 2>/dev/null || true
    [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/tailscode" ] &&
        cp -a "${XDG_DATA_HOME:-$HOME/.local/share}/tailscode" "$DATA_HOME/" 2>/dev/null || true
    mkdir -p "$CONFIG_HOME/tailscode"
    python3 - "$CONFIG_HOME/tailscode/ui.json" "$((WIDTH / SCALE))" "$((HEIGHT / SCALE))" <<'PY'
import json, os, sys
path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
settings = json.load(open(path)) if os.path.exists(path) else {}
settings.pop("tailscode.layout.tree", None)
settings["tailscode.window.width"] = width
settings["tailscode.window.height"] = height
settings["tailscode.window.maximized"] = False
settings["tailscode.uiScale"] = 1.0
json.dump(settings, open(path, "w"), indent=2)
PY
}

start_display() {
    alive xvfb && return 0
    Xvfb "$FILM_DISPLAY" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp \
        >"$STATE/xvfb.log" 2>&1 &
    echo $! >"$STATE/xvfb.pid"
    for _ in $(seq 1 100); do
        [ -S "/tmp/.X11-unix/X$DISPLAY_NUM" ] && return 0
        sleep 0.1
    done
    die "Xvfb $FILM_DISPLAY never came up — $STATE/xvfb.log"
}

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
        DISPLAY="$FILM_DISPLAY"
        GDK_BACKEND=x11
        GDK_SCALE="$SCALE"
        DBUS_SESSION_BUS_ADDRESS="$(cat "$STATE/bus.addr")"
        XDG_CONFIG_HOME="$CONFIG_HOME"
        XDG_DATA_HOME="$DATA_HOME"
        XDG_STATE_HOME="$STATE/home/state"
        # HOME and the cache too: AppCache's FileSessionCache lives in .cachesDirectory,
        # and sharing ~/.cache/tailscode with the installed app restores the person's real
        # last session — title and all — into a take.
        HOME="$STATE/home"
        XDG_CACHE_HOME="$STATE/home/cache"
        TAILSCODE_DEV_DISPLAY="$FILM_DISPLAY"
        GSK_RENDERER="${TAILSCODE_FILM_RENDERER:-cairo}"
        LIBGL_ALWAYS_SOFTWARE=1
        LP_NUM_THREADS="${LP_NUM_THREADS:-16}"
        NO_AT_BRIDGE=1
    )
}

binary() { echo "$REPO/TailscodeLinux/.build/$FLAVOUR/tailscode"; }

start_stagehand() {
    alive stagehand && return 0
    "${HARNESS_ENV[@]}" "$(xvenv)" "$REPO/scripts/film-stagehand.py" \
        >"$STATE/stagehand.log" 2>&1 &
    echo $! >"$STATE/stagehand.pid"
}

mapped_a_window() {
    "${HARNESS_ENV[@]}" "$(xvenv)" - <<'PY' 2>/dev/null
import sys
from Xlib import display
sys.exit(0 if display.Display().screen().root.query_tree().children else 1)
PY
}

cmd_up() {
    harness_env
    start_stagehand
    if alive app; then
        say "reusing pid $(pid_of app) on $FILM_DISPLAY"
        return 0
    fi
    [ -x "$(binary)" ] || die "no $FLAVOUR binary — swift build -c $FLAVOUR in TailscodeLinux"
    "${HARNESS_ENV[@]}" "$(binary)" "$@" >"$LOG" 2>&1 &
    echo $! >"$STATE/app.pid"
    for _ in $(seq 1 300); do
        sleep 0.1
        alive app || { tail -20 "$LOG" >&2; die "it exited on start"; }
        mapped_a_window && break
    done
    say "up: pid $(pid_of app) on $FILM_DISPLAY ${WIDTH}x${HEIGHT} scale $SCALE"
}

reap() {
    local pid
    pid=$(pid_of "$1")
    if [ -n "$pid" ]; then
        kill "${2:--TERM}" "$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$STATE/$1.pid"
}

cmd_down() {
    reap ffmpeg -INT
    reap app
    reap stagehand
    reap bus
    reap xvfb
    rm -f "$STATE/bus.addr"
    say "down"
}

cmd_rec_start() {
    local take=${1:-$STATE/take.mkv}
    alive ffmpeg && die "already recording"
    harness_env
    rm -f "$take"
    "${HARNESS_ENV[@]}" ffmpeg -hide_banner -loglevel warning -y \
        -f x11grab -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" \
        -draw_mouse 1 -thread_queue_size 1024 -i "$FILM_DISPLAY" \
        -c:v libx264 -preset ultrafast -qp 0 -pix_fmt bgr0 -g 120 \
        "$take" >"$STATE/ffmpeg.log" 2>&1 &
    echo $! >"$STATE/ffmpeg.pid"
    echo "$take" >"$STATE/take.path"
    sleep 1.2
    alive ffmpeg || { cat "$STATE/ffmpeg.log" >&2; die "recorder died"; }
    say "recording -> $take"
}

cmd_rec_stop() {
    reap ffmpeg -INT
    local take
    take=$(cat "$STATE/take.path" 2>/dev/null || echo "$STATE/take.mkv")
    say "take -> $take"
    ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$take" >&2 || true
}

# Delivery: 4K60 h264 high, yuv420p, faststart — the encode a browser, a phone and a Mac all play.
cmd_encode() {
    local take=${1:?take} out=${2:?out}
    mkdir -p "$(dirname "$out")"
    ffmpeg -hide_banner -loglevel warning -y -i "$take" \
        -c:v libx264 -preset slow -crf 18 -profile:v high -level 5.2 \
        -pix_fmt yuv420p -r "$FPS" -movflags +faststart -an "$out"
    ffprobe -v error -show_entries stream=width,height,r_frame_rate,nb_frames \
        -show_entries format=duration,size -of default=nw=1 "$out"
}

cmd_shot() {
    harness_env
    local out=${1:-/tmp/tailscode-film.png}
    "${HARNESS_ENV[@]}" import -display "$FILM_DISPLAY" -window root "$out"
    say "$out"
}

cmd_in() {
    harness_env
    "${HARNESS_ENV[@]}" "$@"
}

cmd_status() {
    harness_env >/dev/null 2>&1 || true
    printf 'display   %s %sx%s (%s)\n' "$FILM_DISPLAY" "$WIDTH" "$HEIGHT" \
        "$(alive xvfb && echo up || echo down)"
    printf 'app       %s\n' "$(alive app && pid_of app || echo down)"
    printf 'stagehand %s\n' "$(alive stagehand && pid_of stagehand || echo down)"
    printf 'recorder  %s\n' "$(alive ffmpeg && pid_of ffmpeg || echo down)"
    printf 'state     %s\n' "$STATE"
}

VERB=${1:-status}
shift || true
case "$VERB" in
up) cmd_up "$@" ;;
down) cmd_down ;;
status) cmd_status ;;
shot) cmd_shot "$@" ;;
in) cmd_in "$@" ;;
rec-start) cmd_rec_start "$@" ;;
rec-stop) cmd_rec_stop ;;
encode) cmd_encode "$@" ;;
log) tail "${@:--n40}" "$LOG" ;;
*) sed -n '3,17p' "$0" >&2; exit 2 ;;
esac
