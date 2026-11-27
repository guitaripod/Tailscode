#!/usr/bin/env bash
# The Linux client on a Steam Deck, built here and run there, without touching what the Deck
# is showing.
#
# SteamOS carries an older glibc than this machine's, no libadwaita and no Swift, so the release
# binary travels with the libraries it was linked against (glibc included), patched to find them
# beside it, and runs from a folder in the Deck's home. Nothing is installed into the system.
#
#   scripts/deck-linuxapp.sh sync            bundle the release build and copy it to the Deck
#   scripts/deck-linuxapp.sh start [args…]   start it on a private X display on the Deck (headless)
#   scripts/deck-linuxapp.sh do 'verb'       a TAILSCODE_DRIVE verb into the app that is running
#   scripts/deck-linuxapp.sh click X Y [B]   a real X button press on that display
#   scripts/deck-linuxapp.sh log             the app's log, from the Deck
#   scripts/deck-linuxapp.sh shot [out.png]  the private display, pulled here
#   scripts/deck-linuxapp.sh stop            the app and its display
#
# TAILSCODE_DECK_ENV="NAME=value NAME=value" adds environment to `start` (TAILSCODE_SOAK for long
# conversations, for one). TAILSCODE_DECK_SCREEN=:1 runs it on the Deck's own game display with the
# GPU renderer instead of the private one, which puts a window on the Deck's screen until `stop`.
#
# The display is an Xvfb inside the bundle, so no window appears on the Deck's screen and a game
# running on it is never interrupted; what is measured is the Deck's own CPU. Both processes are
# units of the Deck user's systemd manager, because the Deck's logind kills everything an SSH
# session started the moment it ends.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
DECK=${TAILSCODE_DECK:-deck@steamdeck}
HOME_ON_DECK=${TAILSCODE_DECK_HOME:-/home/deck}
ROOT=$HOME_ON_DECK/tailscode-deck
BUILT=${TAILSCODE_DECK_BINARY:-$REPO/TailscodeLinux/.build/release/tailscode}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/tailscode-deck
STAGE=$CACHE/bundle
DISPLAY_NUM=${TAILSCODE_DECK_DISPLAY_NUM:-88}

say() { printf '%s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
deck() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$DECK" "$@"; }

HOST_OWNS='^(libEGL|libGL|libGLX|libGLdispatch|libOpenGL|libgbm|libdrm|libvulkan|libnvidia|libva|libvdpau|libwayland-egl|libxcb-dri|libglapi|libLLVM|libgallium)'

closure() {
    ldd "$1" | awk '/=>/ && $3 ~ /^\// {print $3} !/=>/ && $1 ~ /^\/(usr\/)?lib/ && $1 !~ /ld-linux/ {print $1}' | sort -u
}

app_environment() {
    cat <<ENV
export GDK_BACKEND=x11 NO_AT_BRIDGE=1
export HOME='$ROOT/home' XDG_CONFIG_HOME='$ROOT/home/config' XDG_DATA_HOME='$ROOT/home/share'
export XDG_STATE_HOME='$ROOT/home/state' XDG_CACHE_HOME='$ROOT/home/cache'
export XDG_RUNTIME_DIR='$ROOT/run' TAILSCODE_NEURAL_DIR='$ROOT/neural'
export TAILSCODE_DRIVE_FILE='$ROOT/drive.txt' TAILSCODE_TRACE=1
unset WAYLAND_DISPLAY
ENV
}

bundle() {
    [ -x "$BUILT" ] || die "no release build at $BUILT — run: cd TailscodeLinux && swift build -c release"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/lib" "$STAGE/bin" "$STAGE/neural"
    install -m 0755 "$BUILT" "$STAGE/bin/tailscode"
    local lib name object absolute
    {
        closure "$BUILT"
        closure /usr/bin/Xvfb
        ls /usr/lib/libgcc_s.so.1 /usr/lib/libstdc++.so.6 /usr/lib/libresolv.so.2
        ls /usr/lib/libnss_files.so.2 /usr/lib/libnss_dns.so.2
    } | sort -u | while read -r lib; do
        name=$(basename "$lib")
        if [[ $name =~ $HOST_OWNS ]]; then continue; fi
        cp -L "$lib" "$STAGE/lib/$name"
    done
    cp -L /lib64/ld-linux-x86-64.so.2 "$STAGE/lib/ld-linux-x86-64.so.2"
    install -m 0755 /usr/bin/Xvfb "$STAGE/bin/Xvfb"
    cp "$REPO"/Resources/Neural/png/*.png "$STAGE/neural/"
    patchelf --set-interpreter "$ROOT/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../lib' "$STAGE/bin/tailscode"
    patchelf --set-interpreter "$ROOT/lib/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/../lib' "$STAGE/bin/Xvfb"
    for object in "$STAGE"/lib/*.so*; do
        case $(basename "$object") in
        ld-linux*|libc.so*|libm.so*|libmvec*|libresolv*|libnss_*) continue ;;
        esac
        patchelf --set-rpath '$ORIGIN' "$object" 2>/dev/null || true
    done
    for object in "$STAGE/bin/tailscode" "$STAGE"/lib/*.so*; do
        for absolute in $(readelf -d "$object" 2>/dev/null | awk '/NEEDED/ && /\[\// {gsub(/[\[\]]/, "", $NF); print $NF}'); do
            patchelf --replace-needed "$absolute" "$(basename "$absolute")" "$object"
        done
    done
    {
        echo '#!/bin/sh'
        app_environment
        echo "mkdir -p '$ROOT/home/config' '$ROOT/home/share' '$ROOT/home/state' '$ROOT/home/cache' '$ROOT/run'"
        echo "chmod 700 '$ROOT/run'"
        echo "[ -f '$ROOT/app.env' ] && . '$ROOT/app.env'"
        echo "exec dbus-run-session -- '$ROOT/bin/tailscode' \"\$@\""
    } >"$STAGE/run-app.sh"
    {
        echo '#!/bin/sh'
        echo "rm -f /tmp/.X11-unix/X$DISPLAY_NUM /tmp/.X$DISPLAY_NUM-lock"
        echo "exec '$ROOT/bin/Xvfb' :$DISPLAY_NUM -screen 0 1600x1000x24 -nolisten tcp -xkbdir /usr/share/X11/xkb"
    } >"$STAGE/run-xvfb.sh"
    chmod +x "$STAGE/run-app.sh" "$STAGE/run-xvfb.sh"
    say "bundled $(ls "$STAGE/lib" | wc -l) libraries, $(du -sh "$STAGE" | cut -f1)"
}

cmd_sync() {
    bundle
    deck "mkdir -p '$ROOT'"
    rsync -a --delete --exclude home --exclude run --exclude '*.log' --exclude drive.txt --exclude shot.png \
        -e "ssh -o BatchMode=yes" "$STAGE/" "$DECK:$ROOT/"
    say "on the Deck: $ROOT"
}

cmd_start() {
    local args=$* screen=${TAILSCODE_DECK_SCREEN:-}
    local look="DISPLAY=:$DISPLAY_NUM GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1"
    [ -n "$screen" ] && look="DISPLAY=$screen"
    deck "bash -s" <<REMOTE
set -e
cd '$ROOT'
if systemctl --user is-active --quiet tailscode-deck-app; then echo "already running"; exit 0; fi
rm -f app.env
for assignment in $look ${TAILSCODE_DECK_ENV:-}; do printf 'export %s\\n' "\$assignment" >> app.env; done
: > drive.txt
: > app.log
if [ -z '$screen' ]; then
    systemctl --user stop tailscode-deck-xvfb 2>/dev/null || true
    systemd-run --user --quiet --collect --unit=tailscode-deck-xvfb \\
        -p StandardOutput=file:'$ROOT/xvfb.log' -p StandardError=file:'$ROOT/xvfb.log' '$ROOT/run-xvfb.sh'
    for _ in \$(seq 1 50); do [ -S /tmp/.X11-unix/X$DISPLAY_NUM ] && break; sleep 0.1; done
fi
systemd-run --user --quiet --collect --unit=tailscode-deck-app \\
    -p StandardOutput=file:'$ROOT/app.log' -p StandardError=file:'$ROOT/app.log' '$ROOT/run-app.sh' $args
sleep 6
systemctl --user is-active tailscode-deck-app
REMOTE
}

cmd_do() { deck "echo '$1' >> '$ROOT/drive.txt'"; }

cmd_click() {
    local x=$1 y=$2 button=${3:-1}
    deck "DISPLAY=:$DISPLAY_NUM xdotool mousemove $x $y click $button"
}

cmd_log() { deck "cat '$ROOT/app.log'"; }

cmd_shot() {
    local out=${1:-$CACHE/deck-shot.png}
    deck "ffmpeg -loglevel error -y -f x11grab -video_size 1600x1000 -i :$DISPLAY_NUM -frames:v 1 '$ROOT/shot.png'"
    scp -q "$DECK:$ROOT/shot.png" "$out"
    say "$out"
}

cmd_stop() {
    deck "systemctl --user stop tailscode-deck-app tailscode-deck-xvfb 2>/dev/null; true"
    say stopped
}

verb=${1:-}
[ -n "$verb" ] && shift
case "$verb" in
sync) cmd_sync ;;
start) cmd_start "$@" ;;
do) cmd_do "$@" ;;
click) cmd_click "$@" ;;
log) cmd_log ;;
shot) cmd_shot "$@" ;;
stop) cmd_stop ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
