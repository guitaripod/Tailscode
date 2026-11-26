#!/usr/bin/env bash
# One ad-hoc CPU sample of the Linux client while it sits still: every thread's stack, raw, plus
# the thread names, so a busy worker can be told from an idle main loop. Run it inside the harness
# display and as the app's ancestor, so eu-stack may trace it:
#
#   scripts/dev-linuxapp.sh run unshare --map-root-user --keep-caps bash scripts/prof-linuxapp.sh [wait]
#
# `wait` seconds after launch (default 7) the sampling starts; it runs 300 times at 10 ms.
set -u
BIN=${TAILSCODE_BIN:-$PWD/TailscodeLinux/.build/release/tailscode}
WAIT=${1:-7}
"$BIN" >/tmp/prof-app.log 2>&1 &
pid=$!
sleep "$WAIT"
for task in /proc/$pid/task/*; do
    printf 'TID %s %s\n' "$(basename "$task")" "$(cat "$task/comm" 2>/dev/null)"
done >/tmp/prof-tids.txt
for _ in $(seq 1 300); do
    eu-stack -q -m -b -p "$pid" 2>/dev/null
    sleep 0.01
done >/tmp/prof-all.txt
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
echo "profiled pid $pid"
