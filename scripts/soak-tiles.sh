#!/usr/bin/env bash
# The tiling soak: N panes streaming at once in the headless harness, measured.
#
#   scripts/soak-tiles.sh --panes 5 --rate 80 --rows 600 --seconds 180
#   scripts/soak-tiles.sh --panes 5 --seconds 60 --hammer         structural verbs + resizes
#   scripts/soak-tiles.sh --panes 5 --seconds 120 --zoom-at 60    zoom one pane halfway
#   scripts/soak-tiles.sh ... --paragraph 8000                    every reply segment is one unbroken 8000-character paragraph
#   scripts/soak-tiles.sh ... --shed 1                            hold the governor at a level (0 calm … 4 critical)
#   scripts/soak-tiles.sh ... --trim                              malloc_trim(0) 5 s before the end, with the resident size either side
#   scripts/soak-tiles.sh ... --turn 40                           every reply ends after 40 s, so the load stops and recovery can be read
#   scripts/soak-tiles.sh ... --assert                            exit 1 past docs/tiling.md 10.7
#   scripts/soak-tiles.sh ... --build                             release build first
#   SOAK_DRIVE_PREFIX='2000:winsize=2500x1350' scripts/soak-tiles.sh ...   drive verbs run before the open (a bigger window, so every pane has room to be whole)
#
# The app runs from the worktree's own release build (TailscodeLinux/.build/release), because a
# debug build measures the optimiser's absence. The whole harness — Xvfb, bus, app — runs inside
# a systemd scope capped at 10 GiB with no swap, so a runaway is killed in its cgroup instead of
# taking the desktop with it. OOMPolicy=continue lets the kernel kill only the app, so this script
# survives to report the death instead of being stopped with the rest of the scope. The harness is
# always stopped on exit.
#
# What it reads: the app's own `SOAK` lines (every 5 s, see TailscodeLinux/Sources/TailscodeLinux/
# Soak.swift) and a 1 s external sample of /proc/<pid> (rss, threads, fds, cpu), which keeps
# counting even when the app's main loop does not.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PANES=5 RATE=80 ROWS=600 SECONDS_=180 WARMUP=60 HAMMER=no ZOOM_AT="" ASSERT=no BUILD=no
ARRANGE=grid LABEL="" OUT="" SHED="" PARAGRAPH="" TURN="" TRIM=no
while [ $# -gt 0 ]; do
    case "$1" in
    --panes) PANES=$2; shift ;;
    --rate) RATE=$2; shift ;;
    --rows) ROWS=$2; shift ;;
    --seconds) SECONDS_=$2; shift ;;
    --warmup) WARMUP=$2; shift ;;
    --hammer) HAMMER=yes ;;
    --zoom-at) ZOOM_AT=$2; shift ;;
    --arrange) ARRANGE=$2; shift ;;
    --assert) ASSERT=yes ;;
    --no-assert) ASSERT=no ;;
    --build) BUILD=yes ;;
    --label) LABEL=$2; shift ;;
    --shed) SHED=$2; shift ;;
    --paragraph) PARAGRAPH=$2; shift ;;
    --turn) TURN=$2; shift ;;
    --trim) TRIM=yes ;;
    --out) OUT=$2; shift ;;
    *) sed -n '2,20p' "$0" >&2; exit 2 ;;
    esac
    shift
done
SUFFIX=""
[ "$HAMMER" = yes ] && SUFFIX="$SUFFIX-hammer"
[ -n "$ZOOM_AT" ] && SUFFIX="$SUFFIX-zoom$ZOOM_AT"
LABEL=${LABEL:-n${PANES}-r${RATE}-k${ROWS}-s${SECONDS_}$SUFFIX}
OUT=${OUT:-${TMPDIR:-/tmp}/tailscode-soak/$LABEL}
export TAILSCODE_DEV_DISPLAY_NUM=${TAILSCODE_DEV_DISPLAY_NUM:-78}
STATE=${TAILSCODE_DEV_STATE:-${XDG_RUNTIME_DIR:-/tmp}/tailscode-dev/$TAILSCODE_DEV_DISPLAY_NUM}
HARNESS=$REPO/scripts/dev-linuxapp.sh

if [ "$BUILD" = yes ]; then
    (cd "$REPO/TailscodeLinux" && swift build -c release 2>&1 | grep -E "error:|Build complete")
fi
[ -x "$REPO/TailscodeLinux/.build/release/tailscode" ] ||
    { echo "no release build — run with --build" >&2; exit 1; }

if [ -z "${SOAK_IN_SCOPE:-}" ]; then
    exec systemd-run --user --scope --quiet -p MemoryMax=10G -p MemorySwapMax=0 -p CPUQuota=1200% \
        -p OOMPolicy=continue \
        -- env SOAK_IN_SCOPE=1 "$0" \
        --panes "$PANES" --rate "$RATE" --rows "$ROWS" --seconds "$SECONDS_" --warmup "$WARMUP" \
        --arrange "$ARRANGE" --label "$LABEL" --out "$OUT" ${SHED:+--shed "$SHED"} \
        ${PARAGRAPH:+--paragraph "$PARAGRAPH"} ${TURN:+--turn "$TURN"} $([ "$TRIM" = yes ] && echo --trim || true) \
        ${SUFFIX:+$([ "$HAMMER" = yes ] && echo --hammer || true)} ${ZOOM_AT:+--zoom-at "$ZOOM_AT"} \
        "--$([ "$ASSERT" = yes ] && echo assert || echo no-assert)"
fi

mkdir -p "$OUT"
cleanup() { "$HARNESS" stop >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

"$HARNESS" stop >/dev/null 2>&1 || true
rm -rf "$STATE/home"

SEND_MS=12000
DRIVE="4000:soakopen=$ARRANGE;$SEND_MS:soaksend;$((SEND_MS + 200)):soakstats"
[ "$HAMMER" = yes ] && DRIVE="$DRIVE;$((SEND_MS + 3000)):soakhammer=$((SECONDS_ - 10))"
[ "$TRIM" = yes ] && DRIVE="$DRIVE;$((SEND_MS + SECONDS_ * 1000 - 6000)):soakstats;$((SEND_MS + SECONDS_ * 1000 - 5500)):soaktrim;$((SEND_MS + SECONDS_ * 1000 - 5000)):soakstats"
[ -n "$SHED" ] && DRIVE="2000:shed=$SHED;$DRIVE"
[ -n "${SOAK_DRIVE_PREFIX:-}" ] && DRIVE="$SOAK_DRIVE_PREFIX;$DRIVE"
[ -n "$ZOOM_AT" ] && DRIVE="$DRIVE;$((SEND_MS + ZOOM_AT * 1000)):szoom;$((SEND_MS + ZOOM_AT * 1000 + 100)):soakstats"
export TAILSCODE_SOAK="$PANES:$RATE:$ROWS:${TURN:-$((SECONDS_ + 60))}${PARAGRAPH:+:$PARAGRAPH}"

echo "soak $LABEL: TAILSCODE_SOAK=$TAILSCODE_SOAK drive=$DRIVE out=$OUT" >&2
"$HARNESS" start --release --no-build --clean --drive "$DRIVE" -- --demo
PID=$(cat "$STATE/app.pid")
CLK=$(getconf CLK_TCK)

: >"$OUT/proc.csv"
started=$(date +%s.%N)
end=$(echo "$started + $SEND_MS / 1000 + $SECONDS_" | bc)
died=""
while :; do
    now=$(date +%s.%N)
    [ "$(echo "$now >= $end" | bc)" = 1 ] && break
    if ! kill -0 "$PID" 2>/dev/null; then
        died=$(echo "$now - $started" | bc)
        break
    fi
    rss=$(awk '/^VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null || echo 0)
    thr=$(awk '/^Threads/{print $2}' "/proc/$PID/status" 2>/dev/null || echo 0)
    fds=$(ls "/proc/$PID/fd" 2>/dev/null | wc -l)
    cpu=$(awk '{sub(/.*\) /,""); print $12 + $13}' "/proc/$PID/stat" 2>/dev/null || echo 0)
    printf '%s %s %s %s %s\n' "$(echo "$now - $started" | bc)" "${rss:-0}" "${thr:-0}" "$fds" "$cpu" >>"$OUT/proc.csv"
    sleep 1
done
cp "$STATE/app.log" "$OUT/app.log"
cp "$STATE/home/state/tailscode/flight.ring" "$OUT/flight.ring" 2>/dev/null || true
mkdir -p "$OUT/state/tailscode"
if cp "$STATE/home/state/tailscode/flight.ring" "$OUT/state/tailscode/flight.ring" 2>/dev/null; then
    XDG_STATE_HOME="$OUT/state" "$REPO/TailscodeLinux/.build/release/tailscode" --flight >"$OUT/flight.txt" 2>&1 || true
fi
[ -f "$OUT/flight.txt" ] && { grep -E "shed [0-9]->[0-9]|stall" "$OUT/flight.txt" | sed -E "s/ +/ /g" || true; }
journal_oom=$(journalctl --user --since "@${started%.*}" 2>/dev/null | grep -iE "oom|memory.max" | tail -3 || true)

python3 - "$OUT" "$SEND_MS" "$WARMUP" "$ASSERT" "$CLK" "${died:-}" "$PANES" "$journal_oom" <<'PY'
import re, statistics, sys
out, send_ms, warmup, assert_mode, clk, died, panes, oom = sys.argv[1:9]
send, warmup, clk, panes = int(send_ms) / 1000, float(warmup), float(clk), int(panes)
log = open(f"{out}/app.log", errors="replace").read().splitlines()
soak = []
for line in log:
    if line.startswith("SOAK "):
        soak.append({k: float(v) for k, v in (f.split("=") for f in line[5:].split())})
sends = [l for l in log if l.startswith("SOAKSEND")]
opened = [l for l in log if l.startswith("SOAKOPEN")]
hammer = [l for l in log if l.startswith("SOAKHAMMER")]
proc = [list(map(float, l.split())) for l in open(f"{out}/proc.csv") if l.strip()]

def slope(points):
    if len(points) < 3: return float("nan")
    xs, ys = zip(*points)
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else float("nan")

def pct(values, p):
    if not values: return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))]

live = [s for s in soak if s["t"] > send + 10 and s["dt"] > 2]
timed = [s for s in live if s.get("lagN", 1) > 0]
warm = [p for p in proc if p[0] > send + warmup]
rate = lambda key: statistics.fmean(s[key] / s["dt"] for s in live) if live else float("nan")
rss_slope = slope([(p[0] / 60, p[1]) for p in warm])
cpu_pts = [(p[0], p[4]) for p in proc if p[0] > send + 10]
cpu_pct = (cpu_pts[-1][1] - cpu_pts[0][1]) / clk / (cpu_pts[-1][0] - cpu_pts[0][0]) * 100 if len(cpu_pts) > 1 else float("nan")
thr = [p[2] for p in warm] or [0]
fds = [p[3] for p in warm] or [0]
summary = {
    "opened": opened[-1] if opened else "SOAKOPEN never",
    "sent": sends[-1] if sends else "SOAKSEND never",
    "died": died or "no",
    "rss_peak_mib": max((p[1] for p in proc), default=0) / 1024,
    "rss_end_mib": proc[-1][1] / 1024 if proc else 0,
    "rss_slope_kib_min": rss_slope,
    "died_at_s_after_send": float(died) - send if died else float("nan"),
    "thr_min_max": (min(thr), max(thr)),
    "fds_min_max": (min(fds), max(fds)),
    "pending_max": max((s["maxPending"] for s in live), default=float("nan")),
    "pending_last": live[-1]["pending"] if live else float("nan"),
    "lag_silent_windows": len(live) - len(timed),
    "lag50_median_ms": statistics.median(s["lag50"] for s in timed) if timed else float("nan"),
    "lag95_median_ms": statistics.median(s["lag95"] for s in timed) if timed else float("nan"),
    "lag95_worst_ms": max((s["lag95"] for s in timed), default=float("nan")),
    "lag_max_ms": max((s["lagMax"] for s in live), default=float("nan")),
    "live_ticks": statistics.median(s["ticks"] for s in live) if live else float("nan"),
    "tick_runs_s": rate("tickRuns"),
    "frames_s": rate("frames"),
    "frame_ms_s": rate("frameMs") if live and "frameMs" in live[0] else float("nan"),
    "parses_s": rate("parses"),
    "parse_hits_s": rate("parseHits"),
    "list_saves_s": rate("listSaves"),
    "list_save_ms_s": rate("listSaveMs"),
    "paints_s": rate("paints"),
    "paint_ms_s": rate("paintMs"),
    "cpu_pct": cpu_pct,
    "main_cpu_p50": statistics.median(s["mainCpu"] for s in live) if live else float("nan"),
    "main_cpu_p95": pct([s["mainCpu"] for s in live], 0.95),
    "applies_s": rate("applies"),
    "apply_ms_s": rate("applyMs"),
    "drains_s": rate("drains") if live and "drains" in live[0] else float("nan"),
    "drain_guarded_s": rate("guarded") if live and "guarded" in live[0] else float("nan"),
    "drain_ready_max": max((s.get("ready", 0) for s in live), default=float("nan")),
    "drain_p95_ms": statistics.median(s["drainP95"] for s in live if "drainP95" in s) if live and "drainP95" in live[0] else float("nan"),
    "drain_max_ms": max((s.get("drainMax", 0) for s in live), default=float("nan")),
    "hammer": hammer[-1] if hammer else "-",
    "windows": len(live),
}
with open(f"{out}/summary.txt", "w") as f:
    for k, v in summary.items():
        line = f"{k:20} {v:.1f}" if isinstance(v, float) else f"{k:20} {v}"
        print(line); f.write(line + "\n")
if oom.strip(): print("journal: " + oom.replace("\n", " | "))

budgets = [
    ("main loop busy p95 <= 0.35 (main-thread cpu share)", summary["main_cpu_p95"] / 100 <= 0.35),
    ("worst main-loop slice <= 120 ms", summary["lag_max_ms"] <= 120),
    ("rss slope <= 5 MB/min", summary["rss_slope_kib_min"] <= 5 * 1024),
    ("threads flat +-4", summary["thr_min_max"][1] - summary["thr_min_max"][0] <= 8),
    ("fds flat +-4", summary["fds_min_max"][1] - summary["fds_min_max"][0] <= 8),
    ("deepest queue <= 1", summary["pending_max"] <= 1),
    ("survived", not died),
]
failed = [name for name, ok in budgets if not ok]
for name, ok in budgets: print(f"{'PASS' if ok else 'FAIL'}  {name}")
if assert_mode == "yes" and failed: sys.exit(1)
PY
