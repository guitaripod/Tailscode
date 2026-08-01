#!/usr/bin/env bash
# Build the GTK4/libadwaita client, prove it reaches a real server, and render it on a headless
# X display so the loop closes without borrowing the user's screen.
#
#   TAILSCODE_HOST=http://100.x.y.z:4098 TAILSCODE_PASSWORD=… scripts/build-linuxapp.sh
#   scripts/build-linuxapp.sh --shot     # also write /tmp/tailscode-linux.png
#   scripts/build-linuxapp.sh --run      # open the window on the real desktop instead
set -euo pipefail

cd "$(dirname "$0")/../TailscodeLinux"

swift build --manifest-cache none 2>&1 | grep -E "error:|warning: .*never used|Build complete" || true

BIN=.build/debug/tailscode

if [ -n "${TAILSCODE_HOST:-}" ]; then
    "$BIN" --selftest
fi

case "${1:-}" in
--shot)
    # A nested X server rather than the session's own compositor: the screenshot then contains the
    # app and nothing else, and the same command works over ssh on a machine with no desktop.
    xvfb-run -a --server-args="-screen 0 1280x820x24" bash -c "
        env -u WAYLAND_DISPLAY GDK_BACKEND=x11 '$BIN' > /tmp/tailscode-linux-run.log 2>&1 &
        sleep 20
        import -window root /tmp/tailscode-linux.png
        pkill -f '$BIN\$' || true
    "
    echo "screenshot -> /tmp/tailscode-linux.png"
    ;;
--run)
    pkill -f "$BIN\$" 2>/dev/null || true
    nohup "$BIN" > /tmp/tailscode-linux-run.log 2>&1 &
    sleep 3
    pgrep -f "$BIN\$" >/dev/null && echo "running" || { tail -20 /tmp/tailscode-linux-run.log; exit 1; }
    ;;
esac
