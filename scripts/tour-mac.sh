#!/usr/bin/env bash
# One measured walk of the Mac app's surfaces. Usage: scripts/tour-mac.sh live|demo [extra app args…]
set -u
MODE="${1:-live}"
shift || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build-mac/Build/Products/Debug/TailscodeMac.app/Contents/MacOS/TailscodeMac"
LOG="$HOME/Library/Logs/tailscode.log"
ARGS=()
[ "$MODE" = "demo" ] && ARGS+=(--demo)
SCRIPT="2500:single;3000:mark=launch-idle;9000:mark=sidebar-scroll;9100:scroll=sidebar,8;\
17500:mark=chat-cycle;17600:cycle=10;\
23000:mark=transcript-scroll;23100:scroll=transcript,8;\
32000:mark=composer-typing;32100:type=The reconnect path retries with a capped backoff and jitter. ;40000:mark=composer-clear;40100:draftclear;\
42000:mark=panes;42100:split=4;46000:tile=focus,2;47000:tile=focus,1;48000:tile=zoom;50000:tile=zoom;\
52000:mark=resize;52100:resize=4;\
58000:mark=theme-place;58100:theme=place;\
63000:mark=theme-back;63100:theme=outerrim;\
68000:mark=agents;68100:open=agents;76000:closewindows;\
78000:mark=prefs;78100:open=preferences;80000:closewindows;\
82000:mark=usage;82100:open=usage;85000:closewindows;\
87000:mark=studio;87100:open=studio;94000:sheetclose;95000:closewindows;\
97000:mark=done;100000:quit"
TAILSCODE_FRAME_WATCH=1 TAILSCODE_DRIVE="$SCRIPT" "$APP" ${ARGS[@]+"${ARGS[@]}"} "$@" >/tmp/tour-$MODE.out 2>&1 &
PID=$!
echo "tour $MODE pid $PID"
for _ in $(seq 1 110); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill -0 "$PID" 2>/dev/null && kill "$PID"
grep -a "\[$PID\]" "$LOG" > "/tmp/tour-$MODE.log" 2>/dev/null || true
grep -ac "Frame watch," "/tmp/tour-$MODE.log" || true
