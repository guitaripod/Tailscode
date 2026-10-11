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

- **RSS grows linearly with the tokens streamed, and M1 did not change that.** The slope is 7–9 MiB/min at N = 1 against 5.9–6.5 before, and grows with N × R: 30 MiB/min at N = 5, 41 at N = 8, 78 at N = 5 and R = 200, 123 at N = 8 and R = 200. Divided by the token events streamed it is about 1.1–2 KiB each at every N and R, against the mock's own replay log of about 80 bytes per token. The `heap` field (bytes malloc reports in use) moves with it (N = 5: 209 → 275 MiB in 160 s), so it is held bytes rather than fragmentation, while the transcript rows stay at their windowed count (400 per pane). What holds it was unattributed here; the Follow-up below attributes it (a fill, the harness's own log and allocator fragmentation, not per-token retention). It is bounded by the length of a reply, not a backlog: N = 8 ended a 3-minute turn at 788 MiB with a 10 GiB cap. A 5 MB/min slope is not met by this pipeline, and nothing in M1 aims at it.
- **Busy share still misses at N ≥ 2.** One pane is at 20 % (baseline 58–60 %), but the share grows with N: 41 / 60 / 68 / 70 / 88 % at N = 2 / 3 / 4 / 5 / 8. Applies fall a long way (4.8 to 26.6 per second over all panes, against 78 per pane per second) and they are bounded, but the M1 as-built notes measured each apply of a streaming pane as a relayout, a scroll and a repaint, and this run did not separate those costs again. The 0.35 budget is met only at N = 1.
- **Startup trips the governor.** Opening five or eight 600-row panes (the first fill, one pane per frame) already keeps the loop at 0.9 busy for several seconds, and the governor escalates to level 2 at 10 s, before the send. N = 8 reaches level 4 two seconds after the send. So at N ≥ 5 the app streams at levels 3–4 for the whole window: the cascade clock is off (`live ticks 0`, `paints 0`), the reveal is arrival-granularity, and frames sit at 26–36/s on the level's 30 fps cap. At N = 4 the escalation comes late (66–76 s after launch) and ends at level 3. That is the stall rule doing what it was written to do (the Follow-up below traces it to the backfill never resting, and fixes it), but it means these runs never show N ≥ 5 at calm, and the 60 fps and the cascade cannot be had there with today's costs. No run was seen to de-escalate (the Follow-up below finds why: the relax delay doubled on a climb).
- **Worst slice.** The lag timer's worst value is under 120 ms in every run but one N = 4 run (125 ms). The ring saw exactly one second above 120 ms in each run that passed through level 3, and each of them is 2 s after the transition into level 3: 140 ms at 78 s (N = 4, entered at 76 s), 166 ms at 20 s (N = 5 at R = 80, entered at 18 s), 155 ms at 20 s (N = 5 at R = 200, entered at 18 s). `docs/tiling.md`'s as-built notes (M0, Linux) say `MemoryRelief` is asked on an escalation into 3 or 4; whether that is the slice was not tested.
- **Drain pass p95 is above 4 ms** from N = 2 up (5–7.5 ms at the median window), so a single pass overruns its 4 ms budget there; the maximum pass is 7–11 ms, never more.
- **Not run.** The hammer, the zoom run and the structural-verb budget were not part of this matrix and are not measured here.

### Follow-up (wt/l1c)

Measured 2026-10-11 on `wt/l1c` (release build, same capped scope, same load, same method as above: R = 80, K = 600, 180 s of streaming, RSS slope after 60 s), on its own display (`TAILSCODE_DEV_DISPLAY_NUM=96`). Host load average 4.6–6.5. Raw logs are not committed. "Before" is the After M1 table above; `scripts/soak-tiles.sh` now keeps the flight ring (`flight.ring`, `flight.txt`) and prints its shed transitions. Each follow-up cell is one run except N = 1, which is two; the first-escalation range for N = 8 is three runs (30 s, 24 s and 16 s after launch, the last two with replies cut at 40 s), and a 30 s-turn run at N = 5 never escalated at all.

| Measure (before → after) | N=1 | N=5 | N=8 |
|---|---|---|---|
| shed level at the send (ring) | 0 → 0 | 2 → **0** | 2 → **0** |
| first escalation, s after launch (send at 12 s) | none → none | 10 → **88** | 10 → **16–30** |
| busy while opening, max of the first 13 ring seconds | — → 0.48, 0.49 | 0.95 → **0.55** | 0.95 → **0.60** |
| seconds at busy >= 0.65 before the send | — → 0 | 4–6 → **0** | 4–6 → **0** |
| worst ring stall in the first 13 s (ms) | 61 → 57, 59 | 102 → 105 | 111 → 109 |
| transcript rows realised after the open | 400 → 400 | 2 000 → 1 000 | 3 200 → 1 450 |
| top level reached | 0 → 0 | 4 → 4 | 4 → 4 |
| RSS peak (MiB) | 373, 372 → 372, 372 | 606 → **498** | 788 → **605** |
| RSS slope (MiB/min) | 6.9, 8.5 → **5.5, 3.8** | 29.9 → **20.9** | 41.2 → **30.7** |
| main-thread CPU, p50 and p95 (%) | 20, 23 → 20, 22 | 62, 70 → 55, 67 | 86, 88 → 78, 81 |
| frames/s | 60 → 60 | 36.0 → **46.7** | 29.6 → **37.0** |
| lag p95, median window (ms) | 1.4 → 2.8, 1.8 | 16.6 → **11.9** | 28.1 → 21.6 |
| worst lag (ms) | 10, 12 → 12, 10 | 31 → 28 | 65 → **117** |
| deepest `pending` | 5, 3 → 4, 3 | 11 → 11 | 20 → 16 |
| threads (min–max) | 73–75 → 74–77 | 90–93 → 90–94 | 103–111 → 104–107 |

What changed, and what did not:

- **The open no longer trips the governor.** The cause was not one slow slice but a loop that never rested. A pane fills an opened transcript in 20-row chunks, one per frame across the window; a chunk and the layout it causes cost 35–40 ms on this software renderer, so five panes of 400 rows were 90 back-to-back frame cycles at 0.9 busy for about six seconds, and the busy rule escalated by two levels at 1.5 s of 0.85. Two changes: each hop now rests until the main-thread CPU spent since the last one is at most 0.4 of the time since (`FillTurns`), and a pane the focus is not on realises 150 rows rather than 400 (the governor's calm peer window, which Linux never applied). Busy during the open is now 0.4–0.6, the ladder stays at 0 until streaming begins, and N = 5 streams at level 0 for the first 76 s after the send (60 fps, cascade clock on) where it started the turn at level 2. N = 8 reaches level 1 4–18 s after the send (three runs) instead of level 4 two seconds after it. The send is not a slice either. With the duty cycle alone, five or eight sends in one main-loop turn still produced a 245–519 ms frame cycle, which the stall rule reads as a two-level jump (three runs: 245, 298 and 498 ms, each followed by level 2); with 150-row peers the ring's worst stall in the seconds around the send is 50 ms at N = 5 and 65 ms at N = 8.
- **Streaming load still sheds at N >= 5.** Busy reaches 0.65 and holds there as the answers grow, and every run still ends at level 4 (N = 5 at 145 s, N = 8 at 53 s after launch). That is the busy rule working: at N = 8 the main thread is 78 % busy at level 4, 60 % of it frame cycles, on a cairo software renderer. The change is when it happens, not whether.
- **Recovery was broken on the doc's side, and is fixed.** The relax delay doubled after any two escalations inside two minutes, and a single climb 0 to 4 is three, so a level 4 that the load had left waited 80–120 s before its first step down and was still at level 2 after a 200 s window (N = 5, `--turn 30`: 4 to 3 at 128 s, 3 to 2 at 143 s, nothing after). The doubling now counts only an escalation that follows a relax by under two minutes, which is the oscillation it exists for (`docs/tiling.md` 5.4). Proof: N = 8, R = 80, replies ended 40 s after the send (`scripts/soak-tiles.sh --panes 8 --seconds 170 --turn 40`): level 4 at 43 s, load stops at about 58 s, 4 to 3 at 79 s, 3 to 2 at 94 s, 2 to 1 at 142 s, 1 to 0 at 157 s (an earlier run of the same: 75, 91, 114, 129 s). The two late steps wait on busy staying under 0.30, and the soak's own frame watcher holds an idle loop at 0.28–0.30; an idle app is near 0, so 15 s a step is what it would take. The unit tests pin both halves (`TileGovernorTests`: a climb leaves the delay alone; load returning after a relax doubles it up to 120 s; a level 4 steps down at 34.5, 49.5, 64.5 and 79.5 s from 14.5 s of quiet).
- **Remaining slices.** The first 13 s still show a 105–109 ms ring stall at N = 5 and 8, which is the opening frame cycle itself (restore, the first tail of each pane and the sidebar, all in the `SplitHost`/`MainWindow` code this work did not restructure). The 117 ms worst lag at N = 8 is the second after the entry into level 3, as noted above (a 138 ms stall was also seen at that point in a separate run, with and without a `MemoryRelief` handler registered, so it is not the relief); not investigated.

### Where the resident size goes (M1 miss, attributed)

The 6.9 to 41 MiB/min of the table was not 1.1–2 KiB of retention per token event. N = 1, R = 200 for 300 s (heap fields in the soak line are `mallinfo2`; two other runs of the same shape agree):

| Window (s after launch) | RSS slope | malloc in use | free inside arenas |
|---|---|---|---|
| 32–92 | 24.4 MiB/min | 9.5 | 16.4 |
| 92–152 | 13.1 | 9.3 | 4.3 |
| 152–212 | 17.4 | 14.3 | 10.0 |
| 212–272 | 7.9 | 1.2 | 0.9 |
| 272–312 | 3.5 | −0.5 | 3.5 |

malloc-in-use rises 92 to 124 MiB over the first 210 s and then stops, while the tokens keep coming at 200 a second. A leak per event would not stop; a fill would. N = 1, R = 80 for 600 s agrees: RSS slope 7.3, 4.6, 1.9, 3.8 MiB/min over four successive two-minute windows (malloc in use 4.5, 5.3, −0.2, −0.6), 423 MiB at the end. What the slope was made of:

- **The harness holds a copy of the stream.** `MockBackend` appends every streamed step to a per-session log (`state.appendedEvents[sessionID, default: []].append(step)`), and `MemoryLayout<MockScriptStep>.stride` is 304 bytes: 1.4 MiB/min at N = 1, R = 80, and N × R × 304 B/s in general, 11 MiB/min of the 41 at N = 8. It is one large array doubling at 16 384, 32 768 and 65 536 steps, so it lands in malloc's mapped blocks (`heapMapped`, 36 to 56 MiB in the 220 s run, a +19 MiB step at 200 s) and is steps, not a slope. A real bridge's events are never held by the client. jemalloc profiling (`LD_PRELOAD=libjemalloc.so.2`, `prof:true`, `jeprof --base`) of the live bytes between 32 s and the end of an R = 200 run: 18.1 MB net, 9.2 MB of it that array.
- **The rest of the in-use growth is the transcript widgets filling in.** The same profile attributes about 4.8 MB to row widgets (`markupLabel` 1.6, tables 1.2, code blocks 0.75, row insertion 0.7, boxes and labels 0.5) and 3.8 MB to allocations with no app frame above them (GLib, Pango, the Swift runtime). The streamed answer is heavier per row than the synthetic history it replaces in the 400-row window (tables, code blocks, long prose), and the window turns over in about a minute at R = 200. The markdown and syntax memos are not it: `mdCache` 219 KiB flat and `synCache` 0.1 to 0.5 MiB, against their 8 MiB caps.
- **Fragmentation is the other half of the slope.** The arenas hold 40–60 MiB free by the end of 3–5 minutes (`heapFree`), most of the gap between RSS and what malloc has in use, because a row built by a pump thread and freed on the main thread leaves chunks in an arena nobody else reuses. `malloc_trim(0)` at the end of a 110 s run returned 15.1 MiB of 373 at R = 80 and 26.4 MiB of 447 at R = 200 (the tails only). Capping glibc at two arenas (`mallopt(M_ARENA_MAX, 2)`, `TAILSCODE_MALLOC_ARENAS`) measurably helps: N = 1, R = 200, 120 s, two runs each, default / two arenas: RSS at the end 395, 389 / 370, 372 MiB, free inside arenas 45, 41 / 18, 17 MiB, in-use slope unchanged (10.3, 10.9 against 11.0, 11.2 MiB/min), main-thread CPU unchanged (23, 23 against 24, 23 %); one arena gave 364 MiB and 9 MiB free in one run, not adopted: it is one run, and a single arena serialises the row pumps with the main thread, which that run did not price. The RSS *slope* of the two-arena runs (14.4, 14.3) sits inside the spread of the default runs (17.9, 13.0): the gain is in the level, about 20 MiB at two minutes, not the rate.
- **A `malloc_trim` on `MemoryRelief` did not help and was not kept.** It returned about 20 MiB at the escalation into level 3 and the app had them back within the second (N = 8: 494 to 474 to 502 MiB in successive ring records). Linux registers no `MemoryRelief` handler at all today, so levels 3 and 4 evict nothing; that is a gap against 5.6, not changed here.
- **One thing is not attributed.** In the 600 s run the RSS stepped up 6 and 9 MiB at 565 s and 575 s with malloc's own accounting (in use, free, mapped) flat: anonymous memory malloc did not hand out. It recurs at a pace of one or two steps in ten minutes and does not follow the token rate.

The soak's 5 MiB/min budget can therefore only be gated after the fill, which at R = 80 is not over until about the ninth minute (R = 200 N = 1: 210 s); the run that shows it flat is the 600 s one above (1.9 and 3.8 MiB/min in its third and fourth windows, before the unattributed steps). N = 1 with the arena cap at the standard 180 s window: 5.5 and 3.8 MiB/min.

### Commands

```sh
cd TailscodeLinux && swift build -c release && cd ..
export TAILSCODE_DEV_DISPLAY_NUM=95
scripts/soak-tiles.sh --panes 1 --seconds 180 --no-assert     # and --panes 2, 3, 4, 5, 8
scripts/soak-tiles.sh --panes 5 --rate 200 --seconds 120 --no-assert
scripts/soak-tiles.sh --panes 8 --rate 200 --seconds 120 --no-assert
```

The flight ring of a run is `$STATE/home/state/tailscode/flight.ring` of the harness and is deleted by the next start, so copy it out between runs and read it with `XDG_STATE_HOME=<dir> tailscode --flight`.

## After M3 (Linux)

Measured 2026-10-11 on `wt/l3` (the canvas, `a5cc6c3b` plus the glance footer fit and the drag-bench verbs; nothing in the streaming path differs from the committed code), the same release build type, capped scope, load (`SoakWorld`, K = 600, R = 80, one send per pane, one list upsert per streaming session per second) and 180 s of streaming as the two tables above. The harness ran on its own displays (85, 86, 87), so nothing touched the desktop. The host was loaded by other agents again (load average 13–17).

What changed under the soak: the nested panes are gone, every pane sits in one canvas, and densities are applied — the governor's budget (four whole chats at 28 cores while calm) and the room decide which chats are whole, and the rest are glance tiles fed at the shed level's glance rate from a `.glance` lease. Peers that are whole realise `TileGovernor.peerRowWindow` rows. The canvas does not touch the stream path.

Two things make the columns below different from the M1 columns more than the code does:

- **The harness window is small.** The soak's window is the app's default size, so the canvas is 1069 × 552 and a 3 × 3 grid of eight panes gives each 356 × 184, under the 200-point height a whole chat needs. All eight chats are therefore glances from the first frame (`f/g/x` 0/8/0 in the ring), nothing is applied but the tiles, and that run measures the cheapest case the design has, not N = 8 under load. The second N = 8 column is the same load in a 2500 × 1350 window (`SOAK_DRIVE_PREFIX='2000:winsize=2500x1350'`), where 4 chats are whole and 4 are glances.
- **No run shed.** N = 5 stayed at level 0 for all 180 s in the second run (the first run's ring was not kept); N = 8 in the large window moved 0 → 1 once, at 194 s. In M1 N = 5 was at level 4 from 72 s (level 2 from the open) and N = 8 at level 4 from 14 s.

### Results at R = 80 tok/s, K = 600, 3 minutes streaming

| Measure | N=5 run 1 | N=5 run 2 | N=8, default window | N=8, 2500 × 1350 | M1 N=5 | M1 N=8 |
|---|---|---|---|---|---|---|
| outcome | steady | steady, level 0 | steady, all glance | steady, level 0 → 1 once | steady, shed to 4 | survived, shed to 4 |
| whole / glance / hidden (ring `f/g/x`) | 4/1/0 (ring lost) | 4/1/0 | 0/8/0 | 4/4/0 | not applied | not applied |
| RSS peak (MiB) | 548 | 530 | 515 | 677 | 606 | 788 |
| RSS slope (MiB/min) | 32.2 | 27.5 | 19.3 | 24.3 | 29.9 | 41.2 |
| threads (min–max) | 91–95 | 90–92 | 100–102 | 101–106 | 90–93 | 103–111 |
| fds | 27 flat | 27 flat | 27 flat | 27 flat | 27 flat | 27 flat |
| deepest `pending` | 13 | 11 | 10 | 16 | 11 | 20 |
| lag p50 / p95, median window (ms) | 0.7 / 7.5 | 0.8 / 10.3 | 0.6 / 1.4 | 0.8 / 18.1 | 1.1 / 16.6 | 8.7 / 28.1 |
| worst lag (ms) | 93 | 31 | 40 | 38 | 31 | 65 |
| lag-silent 5 s windows | 0 | 0 | 0 | 0 | 0 | 0 |
| frames/s | 49.4 | 58.3 | 58.6 | 54.8 | 36.0 | 29.6 |
| state applies/s, all panes | 14.7 | 16.6 | 0 | 5.2 | 24.4 | 26.6 |
| apply ms/s on GTK thread | 29.6 | 32.7 | 0 | 11.7 | 49.9 | 58.2 |
| drain pass p95 / max (ms) | 5.1 / 21.9 | 5.8 / 7.9 | 3.9 / 4.9 | 6.1 / 8.6 | 5.9 / 9.8 | 6.9 / 10.3 |
| most drain slots ready at once | 5 | 5 | 8 | 8 | 4 | 7 |
| process CPU (% of one core) | 225 | 363 | 21 | 367 | 442 | 661 |
| main-thread CPU p50 / p95 (%) | 47 / 63 | 56 / 61 | 11 / 12 | 54 / 63 | 62 / 70 | 86 / 88 |
| loop-meter busy p50 / p95 (ring) | — | 0.58 / 0.68 | 0.02–0.13 | 0.57 / 0.78 | 0.63 / 0.72 | 0.86 / 0.92 |
| seconds with a slice over 120 ms (ring) | — | 0 of 173 | — | 0 of 174 | 1 of 178 | 0 of 179 |

### Against the 10.7 starting budgets (N = 5)

| Measure | Budget | M1 | M3 |
|---|---|---|---|
| main-loop busy p95 | ≤ 0.35 | 0.72 (loop meter) | 0.68: **misses**, closer; the share was 0.78 at N = 8 with four chats whole |
| worst main-loop slice | ≤ 120 ms | 1 second at 166 ms | none in 173 s: **met** |
| RSS slope after warm-up | ≤ 5 MB/min | 30 MiB/min | 27–32 MiB/min: **misses**, unchanged; the canvas does not touch what holds the memory |
| threads, fds | flat ± 4 | met | met |
| deepest mailbox | ≤ 1 | 11 `pending`, 4 slots ready | 11–13 `pending`, 5 slots ready (one state each): the scripted `pending_max <= 1` still fails, the queue is bounded |
| drain per frame | p95 ≤ 4 ms | 5.9 ms | 5.1–5.8 ms: **misses** |
| structural verb | ≤ 1 frame, 0 re-parents | not run | 0 re-parents over 50 verbs (selftest `tile host`); the last canvas allocation after one was 0.6 ms: **met** |
| divider step | live if ≤ 8 ms, else ghost | — | mean 7.0 ms, p95 24 ms across a width change with a 400-row focused pane (Release, harness); the adaptive rule flips to a ghost after two steps over 8 ms. A height-only step costs 0.2 ms |

### What the numbers say

- **The frame clock holds and the loop is calmer at the same load.** N = 5 draws 49–58 frames a second where M1 drew 36 and shed to level 4; no second of the ring has a slice over 120 ms. Applies fall from 24 to 15–17 a second because a glance applies at the glance rate and whole peers at five a second. The governor never needed to shed in the large-window runs, which is also why the cascade clock stayed on (13–18 live frame-clock callbacks).
- **The default window cannot hold eight chats whole**, and the result says so rather than flattering the code: all eight are tiles, the main thread is at 11 %, and nothing in M1's N = 8 column is comparable to it. The comparable column is the large window: 677 MiB (788), lag p95 18 ms (28), main-thread p95 63 % (88), 54.8 frames a second (29.6).
- **RSS growth is where it was.** 19–32 MiB/min across all four columns, 1.1–2 KiB per streamed token as before; the canvas does not change it and `releaseRows` does not help a pane that is still streaming. The 5 MB/min budget stays unmet and unattributed.
- **Not measured here:** the hammer and zoom runs (`--hammer`, `--zoom-at`) were not run on the canvas in this matrix; the structural-verb budget is read from the selftest, not from a soak.

### Commands

```sh
cd TailscodeLinux && swift build -c release && cd ..
export TAILSCODE_DEV_DISPLAY_NUM=85
scripts/soak-tiles.sh --panes 5 --seconds 180 --no-assert
scripts/soak-tiles.sh --panes 8 --seconds 180 --no-assert
SOAK_DRIVE_PREFIX='2000:winsize=2500x1350' TAILSCODE_DEV_GEOM=2560x1400x24 scripts/soak-tiles.sh --panes 8 --seconds 180 --no-assert
```

`scripts/soak-tiles.sh` now copies the flight ring into the run's output directory (`flight.ring`), read with `XDG_STATE_HOME=<dir> tailscode --flight`, and accepts `SOAK_DRIVE_PREFIX` for drive verbs that run before the open.

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

### Mac canvas, Release

Measured 2026-10-11 on the reference Mac (macOS 27.2, Xcode 27, **Release** builds from `scripts/build-macapp-isolated.sh --release --root m2`, wt/m2 at the merge of wt/mc) with `TailscodeMac --bench tiles=N:80:600:20`: N panes of the frame-placed canvas (`TileHost`, grid arrangement) on `SoakWorld` sessions of 600 messages in a 1600×1000 window ordered front with the display awake (`caffeinate -u`), the shed governor running (`Seatbelts` sampling once a second, its decisions applied to the host), one send per pane, 20 s of 80 tok/s firehose after a 2 s ramp. Busy and worst slice are the main run loop's (`LoopMeter`, 1 s windows); main CPU is the main thread's own CPU time over the window; the divider step is a 6 pt move of the first divider that changes widths (every row re-measures), timed with its layout, 24 steps 40 ms apart while the panes keep streaming, once with rows live and once with rows held the way a pointer drag holds them (`TileHost.holdRows`); footprint is `phys_footprint` at the end of the 20 s. Each N is one 20 s run; two runs of the same N differ by up to 0.2 busy when the governor sheds during the load burst, so the second block lists the first run's reading where it disagreed.

| Measure | N=2 | N=4 | N=5 | N=8 |
|---|---|---|---|---|
| main busy mean / p95 | 0.44 / 0.81 | 0.47 / 0.73 | 0.29 / 0.42 | 0.35 / 0.42 |
| main thread CPU (share) | 0.43 | 0.46 | 0.28 | 0.35 |
| share spent applying frames | 0.07 | 0.07 | 0.05 | 0.07 |
| worst slice (ms) | 66 | 58 | 155 | 71 |
| lag p95 / worst (ms) | 24 / 36 | 26 / 36 | 28 / 126 | 27 / 45 |
| divider step, rows live, median / p95 (ms) | 44.5 / 48.9 | 46.8 / 53.9 | 39.1 / 42.2 | 40.7 / 57.2 |
| divider step, rows held (a real drag), median / p95 (ms) | 8.4 / 9.8 | 9.0 / 11.1 | 9.2 / 11.6 | 8.8 / 9.2 |
| footprint at end (MiB) | 279 | 462 | 233 | 304 |
| shed level held (panes live / glance at the end) | calm (2 / 0) | calm (4 / 0) | loaded (1 / 4) | busy (3 / 5) |
| frames applied per pane per s | 11.1 | 7.1 | 1.8 | 1.5 |
| frames charged (layout and commit set off), each | 17.3 ms | 20.3 ms | 26.0 ms | 27.2 ms |
| zoomed onto one (5 s): busy mean, worst slice | 0.50, 89 ms | 0.50, 123 ms | 0.24, 73 ms | 0.25, 51 ms |
| hidden panes still applying | 0 of 1 | 0 of 3 | 0 of 4 | 0 of 7 |

The first run of the same code (before the divider step moved to a width-changing divider and gained its held variant) read N=2 0.46 / 70 ms, N=4 0.45 / 60 ms (and 0.47 and 0.45 on two later runs), N=5 0.47 / 77 ms **calm** with 4 panes live and one glance and 493 MiB, N=8 0.35 / 77 ms busy. N=5 is therefore bimodal: calm at 0.47 when the load burst stays under the governor's 0.65 for 2 s, `loaded` at 0.29 when it does not. N=8 never loads in 20 s (`loaded in 20004 ms`: a glance or parked pane holds no transcript), and sits at `busy` for the whole window.

What it says:

- **Busy at four streaming panes is 0.45–0.47 in Release, against the 0.35 target.** Not met. It does not grow with N (0.44 at two panes, 0.47 at four): the cost is the focused pane's streaming, and a single zoomed pane costs 0.49–0.50, because the drain is duty-limited (`MacHostClock.duty` 0.25: a pass and the commit it sets off may take a quarter of the time since it started) and peers apply at what is left. The 0.35 and 0.29 readings are the governor shedding (cascade capped at 30 Hz at `busy`, peers glance tiles), not the calm pipeline getting cheaper.
- **Where the main thread goes at four panes** (`sample` of the main thread over 8 s of streaming, 1 017 non-idle samples): about two thirds in AppKit's display cycle after a frame (Auto Layout of the transcript's view tree about 18 %, `NSViewBackingLayer.display` and `display_if_needed` about 23 %, the rest Core Animation commit and observers), about 18 % in the display link's own callout, almost all of it `applyNewestFrame` (16 %: row build 3 %, `apply(state:rows:)` 4 %, the composer 1 %; the wave's paint is 0.4–0.5 ms a tick at 87–99 ticks a second), about 6 % in the pin-to-bottom corrector and 1.5 % in the governor's own sample. Applying is 0.05–0.07 of the thread in every column; the layout and display each applied frame sets off is 17–27 ms. The row builds are therefore not the cost: moving them off the main thread (`SingleFlightPump`, as Linux does) would take about 3 % of the busy samples, 10 % with the rest of the apply.
- **Two levers measured, neither shipped.** `duty` 0.15 left busy at 0.42 and halved the frames applied (2.4 per pane per second); 0.10 shed to `busy` and failed to load in 20 s. The cascade link at 60 Hz read 0.41 and at 30 Hz 0.36 with the level still `calm`: roughly 2 ms of layout and display a tick, on top of the painter's own 0.5, which is the doctrine's price for a 120 Hz reveal (`CLAUDE.md` asks for up to 120 Hz on the Mac). Getting to 0.35 calm needs the live row to stop re-laying out its whole answer on every wave tick (paint only the band the wave covers), which is a change to the cascade rather than the tiling.
- **Divider step: 8.4–9.2 ms through the path a pointer takes, 39–47 ms with rows live.** A drag holds transcript rows from mouse-down and catches every pane up once at the release (0.1–1.0 ms while streaming, 43–47 ms for four idle full panes), so the 16 ms budget is met where it is a drag; a divider moved by a call that does not hold rows (the bench's first leg, a keyboard nudge) re-measures every row of every full pane at the new width and costs what a resize costs. Legacy `SplitPaneHost`, 4 panes, in the same bench: 13.4 ms median live (it nudges its own first divider, which is not the same divider, so the two are not like for like), 0.36 busy but at `loaded` with 2.7 frames per pane per second.
- **No hitch over 100 ms: not met around a zoom and under shedding.** The worst slice is 58–71 ms while streaming at N=2, 4 and 8, 155 ms at N=5 when the governor was shedding, and the zoom itself is one 123 ms (N=4) or 150 ms (N=5, first run) slice, the focused pane re-laying out 600 rows at the full width.
- **Footprint** ends at 233–462 MiB for 2–8 panes (Debug: 309–827), flat in N once peers hold the governor's row window.

### Mac, cascade rate by streaming count

Measured 2026-10-11 on the same Mac and bench as above (Release, `--bench tiles=N:80:600:20`, one run per cell, `scripts/build-macapp-isolated.sh --root mcap --release`), before and after `CascadeRate` (Core): the cascade link and the shared drain link take their range from the number of full panes with a turn running and the governor's level, instead of 60-120 Hz at every count. Rate table (`CascadeRate.ceiling`): 0 or 1 streaming 120 Hz (the display's own rate, range 60-120), 2 streaming 60 (30-60), 3 or more 30 (10-30); a peer never above 30; from busy up the governor's tick cap applies on top (30, 20, 10, none) and from loaded nothing exceeds 30. The count is read once a second with the governor's sample, so a rate follows a change within a second.

| Measure | N=1 | N=2 | N=4 | N=5 | N=8 |
|---|---|---|---|---|---|
| streaming panes (rate asked) | 1 (120) | 2 (60) | 4 (30) | 4 live + 1 glance (30) | 3 live + 5 glance (30, `busy`) |
| main busy mean, before | 0.47 | 0.43 | 0.46 | 0.45 | 0.35 |
| main busy mean, after | 0.46 | 0.40 | 0.37 (0.36 on a second run) | 0.37 | 0.36 |
| main busy p95, before / after | 0.71 / 0.67 | 0.65 / 0.65 | 0.79 / 0.43 | 0.64 / 0.43 | 0.43 / 0.45 |
| worst slice streaming (ms), before / after | 66 / 58 | 67 / 79 | 74 / 91 | 86 / 78 | 178 / 129 |
| cascade frames per s (focused pane), before / after | 94 / 98 | 97 / 56 | 89 / 32 | 88 / 32 | 27 / 28 |
| frames applied per pane per s, before / after | 16.5 / 17.2 | 12.5 / 9.6 | 7.0 / 3.4 | 5.8 / 2.6 | 1.5 / 1.5 |
| zoomed onto one (5 s): busy, before / after | 0.50 / 0.49 | 0.47 / 0.24 | 0.26 / 0.51 | 0.25 / 0.51 | 0.34 / 0.34 |
| zoomed onto one: worst slice (ms), before / after | 57 / 50 | 108 / 63 | 75 / 122 (153 on the second run) | 111 / 54 | 53 / 106 |
| shed level during the zoom, before / after | calm / calm | calm / loaded | loaded / calm | loaded / calm | busy / busy |

What it says:

- **Busy at four streaming panes fell from 0.46 to 0.36-0.37, against the 0.35 target.** Not met, by 0.01-0.02. Two panes read 0.40 (from 0.43) and five 0.37 (from 0.45). One pane alone is unchanged (0.46, 98 cascade frames a second), which is the point: the 120 Hz reveal is still there whenever one pane is the only one writing.
- **The price is peers.** Frames applied per pane per second at four panes halved (7.0 to 3.4) because the shared drain link also runs at 30, so a peer's transcript advances in coarser steps; the focused pane's reveal is unaffected in character (32 frames a second against 89, at 0.68 ms each).
- **The zoom columns moved the other way for a reason that is not the rate.** Before, the zoom at N=4 and N=5 ran at `loaded` (instant reveal, 0.25) because the governor had shed during the burst; after, the window stayed `calm` the whole run, so the zoomed pane streams at 120 Hz and costs the single-pane 0.51. The N=2 zoom went the other way (it shed to `loaded` after). Read the zoom columns as the shed level's, not the rate's.
- **Worst slice, target 100 ms.** Streaming: met at N=1 (58), 2 (79), 4 (91; 88 on a second run), 5 (78), missed at N=8 (129, from 178). Around a zoom: met at N=1, 2, 5 (50, 63, 54), missed at N=4 (122, and 153 on the second run: the focused pane re-laying out 600 rows at the full width) and N=8 (106).

```sh
scripts/build-macapp-isolated.sh --root mcap --release --run "--bench tiles=4:80:600:20"
```

```sh
ssh macbook 'caffeinate -u -t 2'
scripts/build-macapp-isolated.sh --root m2 --release --run "--bench tiles=4:80:600:20"
scripts/build-macapp-isolated.sh --root m2 --release --run "--bench tiles --counts 2,4"   # open, divider, resize for canvas and legacy, then the streaming pass for each
scripts/build-macapp-isolated.sh --root m2 --release --run "--bench tiles=4:80:600:20 --legacy"
```
