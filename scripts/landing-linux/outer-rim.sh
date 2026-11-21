#!/bin/bash
# The Linux figures of midgarcorp.cc/tailscode: the window in Outer Rim, by night and by day.
#
#   scripts/landing-linux/outer-rim.sh <output folder>
#
# Writes linux-split.png, linux-split-day.png, linux-terminal.png and linux-terminal-day.png at
# 3840x2160, the names scripts/landing-figures.py reads from <shots>/linux.
#
# Every scene is one launch of the headless harness (scripts/dev-linuxapp.sh, display
# ${TAILSCODE_DEV_DISPLAY_NUM:-84}, a 3840x2300 screen at GDK_SCALE=2) on a home this script writes
# itself and starts with --clean: the harness otherwise seeds a new home from the real settings, and a
# scripted key press then lands in a real chat. A home that holds more than its own ui.json after the
# launch stops the run before anything is typed. Build first: scripts/dev-linuxapp.sh build debug.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?output folder}
export TAILSCODE_DEV_DISPLAY_NUM=${TAILSCODE_DEV_DISPLAY_NUM:-84} TAILSCODE_DEV_GEOM=3840x2300x24 GDK_SCALE=2
unset TAILSCODE_HOST TAILSCODE_PASSWORD
HOME_DIR=${XDG_RUNTIME_DIR:?}/tailscode-dev/$TAILSCODE_DEV_DISPLAY_NUM/home
SPLIT="3000:mark=0;3100:mark=4;3200:mark=7;3300:mark=2;4500:marksplit=sideBySide;8000:chord=ctrl+w a;8600:chord=ctrl+w a;9200:chord=ctrl+w a"
mkdir -p "$OUT"

h() { "$ROOT/scripts/dev-linuxapp.sh" "$@"; }

settings() {
    python3 - "$HOME_DIR/config/tailscode/ui.json" "$@" <<'PY'
import json
import sys

values = {
    "tailscode.theme": "outerrim", "tailscode.theme.welcomed": True, "tailscode.appearance": "dark",
    "tailscode.window.width": 1920, "tailscode.window.height": 1080, "tailscode.window.maximized": False,
    "tailscode.divider.sidebar": 305, "tailscode.divider.terminal": 640, "tailscode.divider.project": 1105,
    "tailscode.pane.terminal": False, "tailscode.compactTools": True,
    "tailscode.agentNews.seen": ["demo-claude·goose"], "tailscode.agents.entryShimmered": True,
}
for pair in sys.argv[2:]:
    key, value = pair.split("=", 1)
    values[key] = json.loads(value)
json.dump(values, open(sys.argv[1], "w"))
PY
}

launch() {
    local drive=$1 wait=$2
    shift 2
    h stop >/dev/null 2>&1 || true
    rm -rf "$HOME_DIR"
    mkdir -p "$HOME_DIR/config/tailscode"
    settings "$@"
    h start --fresh --clean --no-build --drive "$drive" -- --demo | tail -1
    sleep "$wait"
    local strangers
    strangers=$(find "$HOME_DIR/config/tailscode" -mindepth 1 ! -name ui.json | head -1)
    [ -z "$strangers" ] || { h stop; echo "the harness home holds more than the demo: $strangers" >&2; exit 1; }
}

capture() {
    h shot "$OUT/$1.raw.png" >/dev/null 2>&1
    magick "$OUT/$1.raw.png" -crop 3840x2160+0+0 +repage "$OUT/$1.png"
    rm -f "$OUT/$1.raw.png"
    echo "  $1.png"
}

run_commands() {
    h click 1400 1800 >/dev/null
    sleep 0.6
    local line
    for line in "git status" "swift test" "git log --oneline -3"; do
        h type "$line" >/dev/null
        h key Return >/dev/null
        sleep 0.5
    done
    sleep 1.5
}

for face in dark light; do
    suffix=$([ "$face" = light ] && echo -day || true)
    launch "$SPLIT" 18 "tailscode.appearance=\"$face\""
    capture "linux-split$suffix"
    launch "3500:openid=demo-c3" 10 "tailscode.appearance=\"$face\"" "tailscode.pane.terminal=true"
    run_commands
    capture "linux-terminal$suffix"
done
h stop >/dev/null 2>&1 || true
echo "-> $OUT"
