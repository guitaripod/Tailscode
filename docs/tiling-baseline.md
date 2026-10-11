# Tiling baseline: today's Linux split, measured

Measured 2026-10-06 on the code at `wt/soak` (the nested `GtkPaned` SplitHost, unchanged apart from the soak instruments). This is what the redesign in `docs/tiling.md` is judged against. Every number comes from `scripts/soak-tiles.sh` runs in the headless harness; the raw logs are not committed.

## Setup and limits

- **Load.** `SoakWorld` (Core): N sessions of K = 600 messages each (prompts, long markdown answers with lists, code blocks and tables, tool calls with output). One send per pane streams one reply of tiny `partTextDelta` events (≤ 6 characters each) at R per second, with a short tool call about every 300 tokens. While a reply streams, the soak server pushes one session-list upsert per streaming session per second, the way claude-bridge's 1 s sweep does. The list holds 200 sessions, the cap of the real cache (the real `~/.cache/session-list.json` is 200 entries and 80 KB).
- **Harness.** Xvfb (X11), GSK cairo renderer, llvmpipe, no window manager, no AT-SPI, a 60 Hz frame clock, a 1400×900 window with the terminal panel open. It measures CPU, memory, main-loop behaviour and counts. It says nothing about NVIDIA, Wayland, KWin, GL renderers or a 144 Hz monitor, where a frame clock with no cap runs 2.4× as often.
- **Process.** Release build from the worktree, inside `systemd-run --user --scope -p MemoryMax=10G -p MemorySwapMax=0 -p CPUQuota=1200% -p OOMPolicy=continue`. The desktop was never touched. Three runs hit the cap and were killed there.
- **Noise.** Other agents were running on the 28-core host, with load average between 7 and 26. Runs repeated at N = 1, 3 and 5 agree within the spreads shown. A main thread pinned near 97 % is a fact about this code, not about the host's load.
- **Proxies.**
  - "Busy" is the main thread's CPU share (`/proc/self/task/<pid>/stat`). It undercounts time blocked on the X server.
  - "Lag" is how late a 100 ms `G_PRIORITY_DEFAULT` timeout fires.
  - `pending` counts closures posted by `tailscode_on_main` that have not run yet. Each state a pane consumes posts two of them.
- **Fixture share of memory.** The mock keeps every streamed step in its replay log: about 80 bytes per token, so about 0.4 MiB/min per pane at R = 80. That is small next to the slopes below.
- **An artifact found and removed.** Any `TAILSCODE_DRIVE` run printed a `BUILD` census of several KB per state per pane: 143 MB of stdout in one 3-minute N = 3 run. That turned N = 3 into periodic 5 s stalls that do not happen without the trace. A soak run now suppresses the census (commit `fix(linux): a soak run does not print…`). The first batch of runs was discarded.

## Results at R = 80 tok/s, K = 600, 3 minutes streaming

Two values in a cell are two separate runs. RSS slope is measured after a 60 s warm-up. Rates are per second over the 5 s windows from 10 s after the send.

| Measure | N=1 | N=2 | N=3 | N=4 | N=5 | N=8 |
|---|---|---|---|---|---|---|
| outcome | steady | steady | steady, saturated | **collapsed** | **collapsed** | **OOM-killed at 10 GiB, 65–67 s after send** (3 runs) |
| RSS peak (MiB) | 371 / 374 | 454 | 531 / 536 | 4 796 | 7 874 / 6 791 | 10 290 |
| RSS slope (MiB/min) | 5.9 / 6.5 | 14.3 | 27.2 / 25.4 | 263 | 2 750 / 3 238 | 12 447 |
| threads (min–max) | 71–74 | 75–78 | 79–84 | 87–89 | 87–93 | 100–101 |
| fds | 26 flat | 26 flat | 26 flat | 26 flat | 26 flat | 26 flat |
| deepest `pending` | 10 / 11 | 32 | 66 / 71 | 11 511 | 14 912 / 11 054 | 28 785 |
| lag p50, median window (ms) | 0.1 | 3.2 | 6.2 / 6.3 | lag timer silent 19 of 34 windows | 2 596 / 751 | 6 147 |
| lag p95, median window (ms) | 6.0 / 6.3 | 13.1 | 22.1 / 23.3 | — | 2 596 / 1 375 | 6 147 |
| worst lag (ms) | 34 / 106 | 73 | 109 / 356 | 21 528 | 33 072 / 16 997 | 17 048 |
| frames/s | 59 / 56 | 48 | 27 / 23 | 0 | 0 / 1 | 0 |
| live frame-clock callbacks | 5 | 8 | 11 | 34 | 42 | 66 |
| callback runs/s | 247 / 232 | 399 | 318 / 265 | 0 | 0 / 17 | 0 |
| reveal parses/s | 47 / 43 | 54 | 118 / 109 | 184 | 251 / 137 | 139 |
| parse-cache hits/s | 148 / 135 | 318 | 396 / 346 | 400 | 405 / 565 | 634 |
| list saves/s on GTK thread | 1.0 | 2.0 | 3.0 | 3.9 | 4.3 / 4.5 | 4.8 |
| list save ms/s on GTK thread | 1.2 / 1.5 | 2.3 | 3.4 / 5.4 | 5.8 | 5.6 / 5.5 | 5.7 |
| state applies/s (separate run) | 77.5 | — | 232 | — | 388 (before collapse) | — |
| apply ms/s on GTK thread | 127–132 | — | 380–460 | — | 550–820 | — |
| process CPU (% of one core) | 126 / 134 | 227 | 304 / 299 | 407 | 448 / 459 | 447 |
| main-thread CPU p50 / p95 (%) | 58 / 62, 60 / 85 | 91 / 93 | 97 / 98, 96 / 97 | 99 / 99 | 99 / 100 | 99 / 99 |
| opening N panes: one blocking slice | — | 0.85 s | 1.40 s | 1.98 s | 2.53 s | 3.83 s |

"Collapsed" means:

- the frame clock stops (0 frames/s);
- `pending` climbs for the rest of the run;
- the lag timer often never fires within a 5 s window;
- RSS climbs by GB per minute.

The collapse begins within 3–40 s of the send at N = 5. One attribution run held for 40 s, then tipped. It never recovers while the replies stream.

### Rate sweep (where the knee is)

| Run | outcome | deepest `pending` | worst lag | frames/s | main p95 | RSS peak |
|---|---|---|---|---|---|---|
| N=1, R=200 | steady | 18 | 65 ms | 52 | 90 % | 399 MiB |
| N=2, R=200 | edge | 303 | 240 ms | 36 | 97 % | 587 MiB |
| N=3, R=200 | collapsed, then recovered | 7 345 | 9.4 s | 12 | 99 % | 3 617 MiB |
| N=5, R=40 | steady, saturated | 81 | 169 ms | 22 | 98 % | 569 MiB |
| N=5, R=200 | OOM-killed 36 s after send | 30 189 | 13.2 s | 0 | 99 % | 10 336 MiB |

The knee is not total tokens per second alone. N=2 at R=200 (400 tok/s) survives, while N=5 at R=80 (400 tok/s) and N=4 at R=80 (320 tok/s) collapse. Every visible streaming pane adds per-frame cost, and per-state cost scales with N × R. The app falls over once the two together push the main thread past about 97 %.

### Verbs

- **Hammer, N=3** (`soakhammer`, 60 s, 41 beats of split/close/zoom/exchange/equalize/focus and two window sizes):
  - no crash, and 3 panes again at the end;
  - deepest `pending` 161, worst lag 282 ms, lag p95 median 84 ms (against 22 ms without the hammer);
  - 23 frames/s.
- **Hammer, N=5:** no crash, and 5 panes at the end, but the stream had already collapsed (8 023 pending).
- **Zoom one pane, N=3** (`szoom` 75 s into streaming):
  - main-thread CPU fell from 97 % to 91 % and frames rose from 28 to 35 per second;
  - reveal parses stayed at about 200/s and process CPU kept its climb;
  - the two hidden panes kept applying every state.
- **Zoom, N=5:** zooming into an already collapsed run did not bring frames back (1.9 frames/s over the run).

## Hypothesis verdicts

**(a) Unbounded main-context backlog: supported, and it is the mechanism of failure.**

- Up to N = 3 at R = 80, `pending` stays bounded (10–71), because the consumer keeps up.
- At N ≥ 4 (R = 80), or N = 3 at R = 200, posting outruns the main thread.
- Every arriving state then posts two `G_PRIORITY_DEFAULT` idles, and these outrank `GDK_PRIORITY_REDRAW`. The frame clock stops entirely, so the app freezes rather than slowing down.
- The queue grows without bound: 11 k–30 k closures.
- Each closure holds a full `ConversationState` and its rows, so RSS grows at 0.26–12 GiB/min until the cap kills the process.
- Lag p95 degrades with N: 6 → 13 → 22 ms for N = 1 → 2 → 3, then seconds once the queue runs away.
- On the desktop of 2026-10-05 there was no memory limit, and 62 GB of RAM plus 16 GB of swap at swappiness 10. On that machine this pattern plausibly turns into a machine-wide stall rather than an OOM kill. That stall was not reproduced here: no NVIDIA, Wayland or KWin, and a capped scope.

**(b) One-entry parse cache thrashing: refuted as a cause.**

- Parses scale with the states that arrive, not with frames × panes. That is about 45 per second per streaming pane at R = 80, roughly one per arrival.
- The hit ratio does not fall as N grows: 76–77 % at N = 1 and 3, and 62–80 % at N = 5.
- Parses continue at 140–250/s even when frames are 0, so they come from `apply`, not from the reveal tick.
- A 2.7 KB `pango_parse_markup` costs 48 µs here (microbenchmark), so 250 parses/s is about 12 ms/s, or 1.2 % of the main thread.
- The cache comment ("one live row at a time") is still false, but fixing it would buy roughly 1 %.

**(c) Cascade tick with no frame cap: supported, and a contributor rather than the trigger.**

- Each streaming pane adds about 3 live frame-clock callbacks: 5 → 8 → 11 for N = 1 → 2 → 3, against 1 before the send.
- They run on every frame the clock produces. That is 59 frames/s at N = 1, the harness maximum, so about 80 callbacks/s per pane, or 190/s on a 144 Hz display.
- Frames fall as N grows (59 → 48 → 27 → 0) because the main thread is saturated. The tick itself is not capped anywhere.

**(d) Synchronous session-list save on the GTK thread: confirmed to exist, refuted as a cause.**

- There is one `SessionListCache.save` per upsert, so one per streaming session per second, at 1.1–1.4 ms each for 200 entries.
- That is 1.2 ms/s at N = 1 and 5.7 ms/s at N = 8: under 0.6 % of the main thread.
- It violates I2 and costs more on slow disks, but it is not what saturates the loop.

**(e) Hidden and zoomed-away panes keep streaming: confirmed.**

- After `szoom` at N = 3, reveal parses (about 200/s) and the background CPU climb are unchanged, so the hidden panes keep consuming, building rows and applying every state.
- Main-thread CPU drops only about 6 points and frames rise 25 %, from painting less.
- Zoom does not rescue a collapsed run.

**(f) Memory, threads and fds scale with panes: partly supported.**

- **RSS.** Under 60 s after warm-up, in steady runs, RSS grows about 6–9 MiB/min per streaming pane: 5.9–6.5 at N = 1, 14 at N = 2, 25–27 at N = 3. That is above the 5 MiB/min budget at N = 1 already, and about 15× the fixture's own log. Once collapsed, the slope is the backlog: 0.26–12 GiB/min.
- **Threads.** About +3.5 per pane: 71 at N = 1, 100 at N = 8. Flat within ±3 during every run.
- **fds.** 26 at every N, flat. With no network and a fixed X connection, this harness cannot show socket growth.
- **Opening.** Opening N panes of 600 messages is one blocking main-loop slice of about 0.5 s per pane: 3.8 s at N = 8 (I8).

**Not hypothesised, found:**

- **`apply` is the largest attributed main-thread cost.** At R = 80 the Kit's `bufferingNewest(1)` hardly coalesces, because the consumer is ready for every state. Each pane therefore applies about 78 states/s at about 1.7 ms each: 13 % of the main thread at N = 1, about 40 % at N = 3, and 55–80 % at N = 5. The rest of the saturated thread is not attributed. There is no `perf`, and `ptrace_scope=1` blocks stack sampling. It is presumably layout and paint of the panes.
- **Background CPU climbs linearly through a turn.** At N = 1, process CPU went from 70 % to 157 % over 160 s while main-thread CPU stayed at 55 %. At N = 3, under zoom, it went from 188 % to 358 %. Some off-main work per state grows with the length of the turn. It is unattributed.

## Against the 10.7 starting budgets (N = 5, R = 80, K = 600)

| Measure | Budget | Today |
|---|---|---|
| main-loop busy p95 | ≤ 0.35 | 0.996 (0.62–0.85 even at N = 1) |
| worst main-loop slice | ≤ 120 ms | 17–33 s, plus 2.5 s to open the panes |
| RSS slope after warm-up | ≤ 5 MB/min | 2.7–3.2 GiB/min (6 MiB/min at N = 1) |
| threads, fds | flat ± 4 | flat (±3 threads, fds constant) |
| deepest mailbox | ≤ 1 | 11 054–14 912 queued closures |
| drain per frame | p95 ≤ 4 ms | no drain; one state apply ≈ 1.4–2.3 ms, about 78 per pane per second |
| structural verb | ≤ 1 frame, 0 re-parents | not measured (no re-parent counter today); hammer at N = 3 raised lag p95 to 84 ms |

## Commands

```sh
cd TailscodeLinux && swift build -c release && cd ..
export TAILSCODE_DEV_DISPLAY_NUM=78
scripts/soak-tiles.sh --panes 1 --seconds 180     # and --panes 2, 3, 4, 5, 8
scripts/soak-tiles.sh --panes 5 --rate 200 --seconds 120
scripts/soak-tiles.sh --panes 5 --rate 40 --seconds 120
scripts/soak-tiles.sh --panes 3 --seconds 60 --warmup 20 --hammer
scripts/soak-tiles.sh --panes 3 --seconds 150 --zoom-at 75
scripts/soak-tiles.sh --panes 5 --seconds 180 --assert   # exit 1 past the 10.7 budgets
```

Each run writes `app.log` (the `SOAK` lines), `proc.csv` (1 s external samples) and `summary.txt` under `${TMPDIR:-/tmp}/tailscode-soak/<label>` (or `--out`). The `SOAK` fields are documented in `TailscodeLinux/Sources/TailscodeLinux/Soak.swift`. A one-off run without the script is `TAILSCODE_SOAK=5:80:600 scripts/dev-linuxapp.sh start --release --clean --drive '4000:soakopen;12000:soaksend' -- --demo`, inside the same capped scope.

## After M1 (Linux)

Measured 2026-10-11 on `wt/l1b` (source at `e9dfa7e7`; the commit above it only adds localization strings), the same release build type, the same capped scope (`MemoryMax=10G`, `MemorySwapMax=0`, `CPUQuota=1200%`, `OOMPolicy=continue`), the same load (`SoakWorld`, K = 600, one send per pane at R tok/s, one list upsert per streaming session per second) and the same window as the baseline: 180 s of streaming at R = 80, 120 s at R = 200. The headless harness ran on its own display (`TAILSCODE_DEV_DISPLAY_NUM=95`), so nothing touched the desktop. Other agents were again running on the 28-core host: load average 7.9 at the start of the first run, 10.8–11.8 at the end of the last. Two values in a cell are two separate runs; N = 5 and N = 8 were run once at R = 80, and N = 5 and N = 8 once at R = 200. Raw logs are not committed.

The pipeline under test: `ConversationHub` leases, `SingleFlightPump` row builds off the main loop, `LatestWins` mailboxes and the `TileDrain` slot walk at `GDK_PRIORITY_REDRAW + 10` (the as-built notes in `docs/tiling.md` 7.5).

### Results at R = 80 tok/s, K = 600, 3 minutes streaming

| Measure | N=1 | N=2 | N=3 | N=4 | N=5 | N=8 |
|---|---|---|---|---|---|---|
| outcome | steady | steady | steady | steady, shed to 3 | steady, shed to 4 | **survived**, shed to 4 |
| baseline outcome | steady | steady | steady, saturated | collapsed | collapsed | OOM-killed at 65–67 s |
| RSS peak (MiB) | 373 / 372 | 442 / 438 | 490 / 495 | 562 / 554 | 606 | 788 |
| RSS slope (MiB/min) | 6.9 / 8.5 | 13.5 / 18.9 | 18.2 / 19.0 | 23.6 / 21.7 | 29.9 | 41.2 |
| baseline RSS slope (MiB/min) | 5.9 / 6.5 | 14.3 | 27.2 / 25.4 | 263 | 2 750 / 3 238 | 12 447 |
| threads (min–max) | 73–75 / 74–75 | 77–80 / 77–81 | 82–86 / 82–85 | 86–90 / 85–89 | 90–93 | 103–111 |
| fds | 27 flat | 27 flat | 27 flat | 27 flat | 27 flat | 27 flat |
| deepest `pending` | 5 / 3 | 5 / 8 | 9 / 9 | 9 / 12 | 11 | 20 |
| baseline deepest `pending` | 10 / 11 | 32 | 66 / 71 | 11 511 | 14 912 / 11 054 | 28 785 |
| lag p50, median window (ms) | 0.6 / 0.6 | 0.6 / 0.6 | 0.8 / 0.7 | 0.9 / 0.9 | 1.1 | 8.7 |
| lag p95, median window (ms) | 1.4 / 2.3 | 5.9 / 5.9 | 10.0 / 9.6 | 12.4 / 12.4 | 16.6 | 28.1 |
| worst lag (ms) | 10 / 12 | 20 / 17 | 22 / 29 | 106 / 125 | 31 | 65 |
| lag-silent 5 s windows | 0 | 0 | 0 | 0 | 0 | 0 |
| frames/s | 60.0 / 60.0 | 59.9 / 59.9 | 59.4 / 59.3 | 47.0 / 44.2 | 36.0 | 29.6 |
| worst frame cycle in a 5 s window (ms) | 30 / 36 | 61 / 42 | 44 / 47 | 139 / 140 | 75 | 73 |
| live frame-clock callbacks | 5 | 7 | 9 | 0 | 0 | 0 |
| callback runs/s | 251 / 252 | 442 / 443 | 569 / 566 | 287 / 208 | 0 | 0 |
| reveal parses/s | 4.8 / 4.7 | 6.9 / 6.9 | 7.7 / 7.7 | 9.3 / 10.2 | 10.7 | 10.1 |
| parse-cache hits/s | 27.9 / 28.2 | 28.4 / 28.2 | 27.4 / 27.7 | 12.6 / 9.2 | 2.2 | 3.7 |
| list saves/s on GTK thread | 1.0 | 2.0 | 3.0 | 4.0 | 5.0 | 8.0 |
| list save ms/s on GTK thread | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.1 |
| state applies/s, all panes | 4.8 / 4.8 | 9.4 / 9.5 | 12.4 / 12.3 | 19.6 / 20.6 | 24.4 | 26.6 |
| apply ms/s on GTK thread | 10.4 / 10.1 | 19.1 / 19.2 | 25.1 / 24.4 | 40.0 / 41.4 | 49.9 | 58.2 |
| drain passes/s | 4.8 / 4.8 | 7.3 / 7.5 | 7.2 / 7.1 | 13.7 / 14.7 | 16.1 | 13.1 |
| most drain slots ready at once | 1 / 1 | 2 / 2 | 3 / 3 | 4 / 4 | 4 | 7 |
| drain pass p95, median window (ms) | 3.6 / 3.4 | 5.1 / 3.9 | 6.0 / 6.0 | 5.6 / 5.5 | 5.9 | 6.9 |
| drain pass max (ms) | 5.0 / 8.8 | 8.0 / 7.4 | 7.6 / 8.0 | 7.3 / 7.5 | 9.8 | 10.3 |
| drain passes the 100 ms guard ran, /s | 0 | 0 | 0 | 0 | 0 | 0.7 |
| shed level reached (flight ring) | 0 | 0 | 0 | 3 | 4 | 4 |
| process CPU (% of one core) | 92 / 92 | 182 / 182 | 275 / 275 | 360 / 357 | 442 | 661 |
| main-thread CPU p50 / p95 (%) | 20 / 23, 20 / 22 | 35 / 41, 36 / 41 | 54 / 60, 54 / 60 | 59 / 68, 57 / 66 | 62 / 70 | 86 / 88 |
| baseline main-thread CPU p50 / p95 (%) | 58 / 62, 60 / 85 | 91 / 93 | 97 / 98, 96 / 97 | 99 / 99 | 99 / 100 | 99 / 99 |
| loop-meter busy p50 / p95 (flight ring, second run) | 0.21 / 0.26 | 0.37 / 0.47 | 0.55 / 0.65 | 0.59 / 0.71 | 0.63 / 0.72 | 0.86 / 0.92 |
| seconds with a slice over 120 ms (ring, after 20 s) | 0 of 177 | 0 of 176 | 0 of 178 | 1 of 179 (140 ms) | 1 of 178 (166 ms) | 0 of 179 (worst 73 ms) |
| opening N panes: worst slice in the first 12 s (ms, ring) | 61 | 100 | 98 | 99 | 102 | 111 |
| baseline opening slice | — | 0.85 s | 1.40 s | 1.98 s | 2.53 s | 3.83 s |

Reading notes for the table:

- RSS slope is measured after the same 60 s warm-up. Rates are per second over the 5 s windows from 10 s after the send. The shed level and the slice counts come from the flight ring, which was kept for the second N = 1–4 run and the only N = 5 and N = 8 runs; the first N = 1–4 runs were not captured, so their level is unknown.
- "Opening: worst slice" is the largest ring stall in the first 12 s, which holds the launch and the open at 4 s (second run for N = 1–4); the first SOAK window (the launch and the open) shows `lagMax` of 23–105 ms. It is an upper bound on a per-open slice, not a clean one.
- fds are 27, not 26: one more than the baseline, flat in every run (the base count of the build, not growth).
- "Live frame-clock callbacks" are 0 from N = 4 on because the shed level there has switched the cascade clock off (see below), not because frames stopped: frames/s is 29–47.
- At N = 5 and N = 8 the median `lag` and `frames` are taken at shed level 4 for nearly the whole window. The numbers measure the app in its own most conservative state, not at calm.

### Rate sweep (where the knee is)

| Run | outcome | deepest `pending` | worst lag | frames/s | main p95 | RSS peak | RSS slope | shed level |
|---|---|---|---|---|---|---|---|---|
| N=5, R=200 | steady, shed to 4 | 11 | 38 ms | 34.1 | 76 % | 685 MiB | 78 MiB/min | 4 |
| N=8, R=200 | **survived**, shed to 4 | 18 | 80 ms | 26.1 | 89 % | 944 MiB | 123 MiB/min | 4 |
| baseline N=5, R=200 | OOM-killed 36 s after send | 30 189 | 13.2 s | 0 | 99 % | 10 336 MiB | — | — |

Other numbers of these two runs: drain pass p95 6.7 and 7.5 ms (max 9.0 and 11.0 ms), most slots ready at once 4 and 8, loop-meter busy p50 / p95 0.70 / 0.79 and 0.89 / 0.93, 1 of 119 seconds over 120 ms at N = 5 (155 ms) and 0 of 117 at N = 8 (worst 87 ms), worst frame cycle 49 and 87 ms. Neither run was killed or approached the cap.

### Shed ladder (flight ring)

The governor moves on the `busy` rule only; the pressure columns of every ring read 0.0/0.0.

| Run | transitions (seconds after launch) |
|---|---|
| N = 1, 2, 3 at R = 80 | none, level 0 throughout |
| N = 4 at R = 80 | 0→1 at 66 s, 1→2 at 71 s, 2→3 at 76 s |
| N = 5 at R = 80 | 0→2 at 10 s, 2→3 at 18 s, 3→4 at 72 s |
| N = 8 at R = 80 | 0→2 at 10 s, 2→4 at 14 s |
| N = 5 at R = 200 | 0→2 at 10 s, 2→3 at 18 s, 3→4 at 23 s |
| N = 8 at R = 200 | 0→2 at 10 s, 2→4 at 14 s |

The send is at 12 s, so at N = 5 and N = 8 the first escalation (to level 2) happens during the open, before any streaming, and the loop starts the turn already shed. Once at level 4 no run came back down within its window.

### Against the 10.7 starting budgets (N = 5, R = 80, K = 600)

| Measure | Budget | Before | After |
|---|---|---|---|
| main-loop busy p95 | ≤ 0.35 | 0.996 | 0.70 main-thread CPU share (loop meter 0.72): **misses** |
| worst main-loop slice | ≤ 120 ms | 17–33 s | 31 ms worst lag; 1 ring second at 166 ms: **marginal miss** |
| RSS slope after warm-up | ≤ 5 MB/min | 2.7–3.2 GiB/min | 30 MiB/min: **misses**, runaway gone |
| threads, fds | flat ± 4 | flat | 90–93 threads, 27 fds: met |
| deepest mailbox | ≤ 1 | 11 054–14 912 queued closures | 11 `pending`, 4 drain slots ready at once (each slot holds at most one state): the scripted check `pending_max <= 1` **fails**, the queue is bounded |
| drain per frame | p95 ≤ 4 ms | no drain | 5.9 ms (3.4–3.6 ms at N = 1): **misses** at N ≥ 2 |
| structural verb | ≤ 1 frame, 0 re-parents | not measured | not run |

### What misses, and what it means

- **RSS grows linearly with the tokens streamed, and M1 did not change that.** The slope is 7–9 MiB/min at N = 1 against 5.9–6.5 before, and grows with N × R: 30 MiB/min at N = 5, 41 at N = 8, 78 at N = 5 and R = 200, 123 at N = 8 and R = 200. Divided by the token events streamed it is about 1.1–2 KiB each at every N and R, against the mock's own replay log of about 80 bytes per token. The `heap` field (bytes malloc reports in use) moves with it (N = 5: 209 → 275 MiB in 160 s), so it is held bytes rather than fragmentation, while the transcript rows stay at their windowed count (400 per pane). What holds it is unattributed. It is bounded by the length of a reply, not a backlog: N = 8 ended a 3-minute turn at 788 MiB with a 10 GiB cap. A 5 MB/min slope is not met by this pipeline, and nothing in M1 aims at it.
- **Busy share still misses at N ≥ 2.** One pane is at 20 % (baseline 58–60 %), but the share grows with N: 41 / 60 / 68 / 70 / 88 % at N = 2 / 3 / 4 / 5 / 8. Applies fall a long way (4.8 to 26.6 per second over all panes, against 78 per pane per second) and they are bounded, but the M1 as-built notes measured each apply of a streaming pane as a relayout, a scroll and a repaint, and this run did not separate those costs again. The 0.35 budget is met only at N = 1.
- **Startup trips the governor.** Opening five or eight 600-row panes (the first fill, one pane per frame) already keeps the loop at 0.9 busy for several seconds, and the governor escalates to level 2 at 10 s, before the send. N = 8 reaches level 4 two seconds after the send. So at N ≥ 5 the app streams at levels 3–4 for the whole window: the cascade clock is off (`live ticks 0`, `paints 0`), the reveal is arrival-granularity, and frames sit at 26–36/s on the level's 30 fps cap. At N = 4 the escalation comes late (66–76 s after launch) and ends at level 3. That is the stall rule doing what it was written to do, but it means these runs never show N ≥ 5 at calm, and the 60 fps and the cascade cannot be had there with today's costs. No run was seen to de-escalate.
- **Worst slice.** The lag timer's worst value is under 120 ms in every run but one N = 4 run (125 ms). The ring saw exactly one second above 120 ms in each run that passed through level 3, and each of them is 2 s after the transition into level 3: 140 ms at 78 s (N = 4, entered at 76 s), 166 ms at 20 s (N = 5 at R = 80, entered at 18 s), 155 ms at 20 s (N = 5 at R = 200, entered at 18 s). `docs/tiling.md`'s as-built notes (M0, Linux) say `MemoryRelief` is asked on an escalation into 3 or 4; whether that is the slice was not tested.
- **Drain pass p95 is above 4 ms** from N = 2 up (5–7.5 ms at the median window), so a single pass overruns its 4 ms budget there; the maximum pass is 7–11 ms, never more.
- **Not run.** The hammer, the zoom run and the structural-verb budget were not part of this matrix and are not measured here.

### Commands

```sh
cd TailscodeLinux && swift build -c release && cd ..
export TAILSCODE_DEV_DISPLAY_NUM=95
scripts/soak-tiles.sh --panes 1 --seconds 180 --no-assert     # and --panes 2, 3, 4, 5, 8
scripts/soak-tiles.sh --panes 5 --rate 200 --seconds 120 --no-assert
scripts/soak-tiles.sh --panes 8 --rate 200 --seconds 120 --no-assert
```

The flight ring of a run is `$STATE/home/state/tailscode/flight.ring` of the harness and is deleted by the next start, so copy it out between runs and read it with `XDG_STATE_HOME=<dir> tailscode --flight`.

## Mac

Measured 2026-10-06 on the reference Mac (macOS 27.2, Xcode 27, Debug builds from `scripts/build-macapp-isolated.sh`) with `TailscodeMac --bench tiles=N:80:600:20`: N panes on `SoakWorld` sessions of 600 messages, one send per pane, 20 s of 80 tok/s firehose, in a 1600×1000 window ordered front (the display awake through `caffeinate -u`, so the display link is served). "Old" is master at `8bdf52d3` (each pane's own `AgentConversation`, every state built and applied on the main thread from the pane's stream loop) with only the bench and an apply counter added; "new" is `wt/mb` (hub leases, latest-wins mailboxes, the frame-paced drain). Busy and worst slice are Ma's `LoopMeter` (main run loop, 1 s windows); lag is how late a 100 ms main-queue timer fires, the Mac's stand-in for a queue depth; the footprint slope is a least-squares fit over the 20 s, which the growing answers themselves dominate and is noisy at that length. The Mac cannot run the Linux soak harness; there is no external process sampler here.

| Measure | N=1 old / new | N=2 | N=3 | N=4 | N=5 | N=8 |
|---|---|---|---|---|---|---|
| main busy mean | 0.66 / 0.65 | 0.95 / 0.67 | 1.00 / 0.71 | 1.00 / 0.73 | 0.95 / 0.73 | **killed past 11 GB** / 0.74 |
| main busy p95 | 0.89 / 0.80 | 1.00 / 0.84 | 1.00 / 0.87 | 1.00 / 0.90 | 1.00 / 0.95 | — / 0.87 |
| worst slice (ms) | 243 / 40 | 445 / 44 | 646 / 65 | 1 117 / 74 | 1 908 / 92 | — / 118 |
| lag p95 (ms) | 21 / 21 | 47 / 22 | 71 / 24 | 107 / 26 | 172 / 28 | — / 33 |
| worst lag (ms) | 29 / 35 | 58 / 29 | 118 / 32 | 126 / 33 | 255 / 39 | — / 47 |
| footprint at end (MiB) | 266 / 270 | 455 / 309 | 693 / 400 | 970 / 520 | 1 079 / 624 | — / 827 |
| footprint slope (MiB/min) | 122 / 34 | 293 / 97 | −13 / 90 | 131 / 130 | 117 / 144 | — / 135 |
| process CPU (% of a core) | 68 / 66 | 97 / 70 | 106 / 74 | 103 / 76 | 107 / 77 | — / 82 |
| states applied per pane per s | 64 / 49 | 49 / 25 | 33 / 16 | 21 / 12 | 16 / 9 | — / 5 |
| states folded per pane per s | 0 / 17 | 0 / 36 | 0 / 43 | 0 / 47 | 0 / 40 | — / 41 |
| zoomed onto one (5 s): busy mean | 0.57 / 0.33 | 0.80 / 0.30 | 0.98 / 0.28 | 1.00 / 0.28 | 0.80 / 0.29 | — / 0.30 |
| hidden panes still applying | — | 1 of 1 / 0 of 1 | 2 of 2 / 0 of 2 | 3 of 3 / 0 of 3 | 4 of 4 / 0 of 4 | — / 0 of 7 |

What it says:

- **The old Mac pipeline does not run away the way Linux does, but it saturates.** Each pane's stream loop awaits the main actor with the Kit's newest-only buffer, so states cannot pile up in a queue; instead the main thread is pinned at 1.00 from two streaming panes, a single run-loop slice reaches 0.4–1.9 s, and a main-queue timer arrives up to 255 ms late at five panes. Hidden panes keep applying every state, so zooming changes nothing (busy 0.80–1.00 zoomed).
- **The new pipeline is flat in N.** Busy stays 0.65–0.74 from one pane to eight, the worst slice under 120 ms, lag p95 under 35 ms. Per-pane applies fall as N rises (49 → 5 per second) and the rest are folded by latest-wins: the frame applies only the newest state. Zoomed onto one pane the main thread drops to 0.28–0.33 at every N, and parked panes apply nothing.
- **Eight panes.** The old code's footprint passed 11 GB within 12 s of opening eight 600-message panes and the process was killed; `malloc_history` puts the growth in `NSISEngine` bitsets while the window's one Auto Layout engine absorbs every pane's rows. The new code holds peers to the governor's row window (150 at calm, never under 60), so the window carries one full transcript plus 150 rows per peer, and eight panes end at 827 MiB.
- **Not met yet: busy ≤ 0.35.** Even one pane alone sits at 0.65 in a Debug build, because the focused pane's reveal paints every frame and a single apply of a long streaming answer costs 5 ms focused and 9–25 ms for a peer (the row is rebuilt and re-measured whole; 50–110 ms was seen late in a long answer). The drain caps applies at a third of the main thread, which is why busy no longer grows with N; reaching 0.35 needs the row builds off the main thread (6.2's follow-up, now justified by these numbers) and a Release-build measurement.
- **`--bench` (cached transcripts) is unchanged:** the three largest caches on this Mac measure a row arriving 0.5 ms, words arriving 0.2 ms median and a resize step 18.4–23.1 ms (against 16.8–22.8 ms before), within run-to-run noise; that path does not run through the drain.

Commands:

```sh
scripts/build-macapp-isolated.sh --root mb --run "--bench tiles=4:80:600:20"
ssh macbook 'caffeinate -u -t 2'   # before each run, or the display link is not served and the 100 ms guard paces the drain
scripts/build-macapp-isolated.sh --root mb --selftest   # includes the tiles child check
```
