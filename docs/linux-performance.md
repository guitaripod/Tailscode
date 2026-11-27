# Linux performance

## Reading a freeze

The app explains its own next freeze. The flight ring (`tailscode --flight`) says how bad a second was (busy, stall, shed level, memory, threads); the log says what the main thread was doing and which threads burned the CPU.

### When it writes

The watchdog thread (`Watchdog.swift`, `BusySampler.swift`) writes a capture to `$XDG_STATE_HOME/tailscode/tailscode.log` (category `lifecycle`) when:

- the loop meter reads busy >= 0.9 for 5 seconds running (`SustainedBusy`, fed once a second by the governor tick; at most once per 60 s while it persists), reason `sustained busy 5.0 s`;
- the main loop has not answered the watchdog's ping for 1 s (at most once per 15 s), reason `loop silent 1.2 s`, and again at the 10 s deep stall.

Nothing is read while the app is calm: per-thread CPU snapshots are taken once a second only while a busy run is under way.

### The lines

```
watchdog: sustained busy 5.0 s · main R ? cpu=812 · rss 1269 MB · 188 threads · hot: glycin-loader(5102) 260%, tailscode(4021) 91% · build 1.78
watchdog: stack 1/3 · main: tailscode+0x6ecdae tailscode+0x391455 libgtk-4.so.1+0x2f6ab9 ...
watchdog: stack 2/3 · main: ...
```

- `main <state> <wchan> cpu=<ticks>` is the main thread's scheduler state from `/proc/self/task/<pid>/stat` and the kernel function it waits in. `R` with the ticks climbing is the app's own work. `D` with a `wchan` such as `folio_wait_bit` is a page fault or a disk wait: the loop meter counts that as busy too, because busy is wall time outside `g_poll`. `S` with a futex wchan is a lock wait.
- `hot:` are the five threads that used the most CPU over the last 5 s, as a share of one core (260% is two and a half cores), by thread name and tid. A `glycin`/`gdk-pixbuf` helper or a libdispatch worker at the top means the work is off the main thread; the main thread at the top means it is not.
- `stack i/3` are three samples 30 ms apart of the main thread's own backtrace, innermost frame first, each frame `module+0xoffset`. The first frame is the instruction the thread was executing; the others are call sites (the return address minus one). A sample the thread did not answer within 250 ms prints `no reply`: the thread is blocked in the kernel, and the summary line says where.

How the stack is taken: the watchdog thread sends the main thread a real-time signal (`SIGRTMAX-3`, `tgkill`) whose handler, in `CGtkShim/selfdiag.c`, calls glibc `backtrace()` into a preallocated buffer. The unwinder is primed at startup so the handler allocates nothing and loads nothing; the watchdog thread resolves each address to a module and offset afterwards with `dladdr`.

### Reading them back

`tailscode --stacks [count]` prints the last captures (default 3) with the frames resolved through `addr2line` against the running binary (`TAILSCODE_BINARY=<path>` names another build's binary, and the system libraries are looked up under `/usr/lib*`). A capture written by a different build than the one running says so, because offsets only resolve against the build that wrote them.

By hand, per module:

```
addr2line -f -C -i -e ~/.local/bin/tailscode 0x6ecdae 0x391455
eu-addr2line -f -C -i -e /usr/lib/libgtk-4.so.1 0x2f6ab9
```

The release binary is stripped of line tables only if it was built so; with `-g` the answer is `function at file:line`, without it a function name from the symbol table or `??`. System libraries are usually stripped: the module name alone (`libgtk-4.so.1`, `libgdk_pixbuf-2.0.so.0`) still says which toolkit layer the thread was in.

### Reading the story

1. Start from the summary: state and `hot:` split the cases. Main thread `R` and hottest: our code or a toolkit call it made. Main thread `D`/`S`: the machine or a lock. A helper process or worker at 100% or more: decode or build work that should be off the main thread.
2. Read the three stacks together. The same frames in all three are the cost; frames that change are a loop.
3. `--flight` around the same time shows the shed level and memory; the `capture` event word in the ring marks the second.

### Background work and the resource guard

Pollers the app owns wait on `BackgroundGate`: nothing is fetched, spawned or redrawn while the window is minimised, suspended or unmapped (the toplevel state, watched by the shim), the poll that was missed runs once when the window is seen, and at shed level strained and critical periods stretch three and six times (`BackgroundCadence`). The resource guard limits the app's own systemd unit: `app-<appid>-<n>.scope`, `.service` and the launcher's `app-<appid>@<hash>.service`, only when that unit's `cgroup.procs` lists this process; a terminal's scope is always left alone. `tailscode --limits` prints what it did.

## The 2026-10-17 freeze

The installed app held the main thread at busy 1.00 for twenty minutes on the 1920x2160 window and crashed three times closing. The conversation was not the cause: the bridge sends at most about 5 MB for any chat and the pane builds the last 300 messages. What was heavy was a chat with ninety-five screenshots.

### What was measured

Opening that chat in the harness at 1920x2160 (`TAILSCODE_DEV_GEOM=1920x2160x24`, the real settings copied), thirty seconds from launch, same chat restored, release builds:

| | before | after |
|---|---|---|
| peak resident | 800 MB (1.3 GB in the sampled runs) | 540-560 MB (0.49 GB sampled) |
| process CPU | 16.4-17.3 s | 13.3-13.9 s |
| worst busy second | 1.00 | 0.77-0.89 |
| worst stall | 202-248 ms | 114-164 ms |
| main thread, first 3 s, sampled | 100% non-idle | 47% |
| governor | critical within 5 s | calm |

Before, half of the non-idle main-thread samples were one path run once per picture: the landing closure, `replaceRows`, `rebuildRow`, `PictureStripView.make`, `tailscode_picture_with_intrinsic`, `gdk_texture_download`, `cairo_image_surface_create`. After, that path is absent from the profile; what is left at steady state is the brain's 30 fps clock under the software renderer, which the Brain files own.

### What changed

- Pictures: GTK's own loaders (no glycin subprocess), one shared preview surface per picture instead of a copy per widget, texture nodes under a GPU renderer and the cached surface under the cairo renderer, a two-wide decode gate that narrows with the shed level, landings gathered into one pass, failures remembered, one process-wide store that relief can shrink (`ImageDecodeGate.swift`, `PictureStore.swift`, `shim.c`).
- The sidebar draws through a scheduler spaced by the shed level and skipped while the window cannot be seen, from cached row models, with the pin and seen stores read once per draw (`SidebarRenderPlan.swift`, `MainWindow.swift`).
- The per-state apply path is incremental: workflow, spend, status, user-message count, row gaps and the doubled-row watch (`MessageMemo.swift`, `TurnScan.swift`, `UserMessageTally.swift`), and the row builder's open policy no longer waits for a build (`TranscriptRow.swift`).
- Closing the app stops its own work first: a quitting gate in every shim callback, weak handles for the chip, the sidebar rows and `FillTurns`, and `tearDown()` cancelling the window's tasks. Stale handles in the dialogs were audited and fixed (`Gtk.WeakWidget`).
- Pollers wait while the window is hidden and stretch with the shed level (`BackgroundGate.swift`); the resource guard now recognises the launcher's `.service` unit; relief trims the heap.
- The hub gives the conversation on screen the first transcript refetch and a race that could keep a stream open after its last lease is fixed (`ConversationHub.swift`).
- Kit: a refetch gate of two, byte-bounded transcript and disk caches, an O(1) rename check, persist skipping on an unchanged revision, the cache seed running beside the live read.

### The harness that measures it

`scripts/dev-linuxapp.sh run bash <script>` with `TAILSCODE_DEV_GEOM=1920x2160x24` and a second binary to compare. The script starts the binary with `TAILSCODE_TRACE=1`, resets the harness's `launch.json` to a clean exit so the shed floor does not skew the first seconds, polls `/proc/<pid>` for resident size and threads every 100 ms, and reads the flight ring at the end with the same binary's `--flight`. To see where the main thread spends a window of time, sample it with `eu-stack -1 -p <pid>` from a sampler that is an ancestor of the app (`unshare --map-user=$(id -u) --map-group=$(id -g) --keep-caps`, because `ptrace_scope` is 1).

## Switching chats

A chat opened from the list stayed invisible until the whole of its backfill had been drawn: the page was kept at opacity 0 (`pendingReveal`) until `fillComplete`, and the backfill was background work (twenty rows a hop at the calm level, eight at loaded, one hop a frame, resting 60% of the time, paused at critical). So a chat of four hundred rows showed nothing for 1.3-2.2 s at calm and 5-8 s once the governor had risen, and the same trace showed three more costs on top.

### What was measured

The harness at 1920x2160, the real settings copied, `TAILSCODE_TRACE=1`; `open+Nms` marks come from `OpenTimer` and the app's log (`first rows`, `first frame`, `revealed`, `filled`, `placeholder`). Six real chats from 26 to 737 rows, opened by `TAILSCODE_DRIVE_FILE` `openid=` lines, cold and again after other chats:

| | before | after |
|---|---|---|
| a chat opened again: visible | 1.3-2.2 s (rows, then "Loading…", then rows again) | 11-31 ms, no placeholder |
| a chat opened for the first time: visible | 1.0-2.2 s | 0.1-0.5 s |
| the same, after a pointer rested on its row | | 0.1 s |
| worst stall in a run of opens three seconds apart | 357 ms | 64 ms |
| shed level after that run | loaded for 47 s | calm throughout |

A stall of 250 ms or more raises the governor two levels at once (`TileGovernor.Tuning.stallJump`), and `loaded` shrinks every hop to eight rows and a rest of up to a second, so the first cold open of a long chat slowed every open after it. It came from laying out sixty rows in one frame.

### What changed

- The page is shown the moment what is drawn covers it (`readyToReveal`: the end of the chat is on screen and there is more above), not when the history is complete. Hops are urgent while the page is hidden or the reader is within a screen and a half of the first row that exists (`FillTurns.take(urgent:)`, `FillTurns.rush()` from the scroll handler); everything else about the backfill is still background work.
- Rows arriving above the reader move the scroll position in the same call (`holdingThePlace`: the transcript's natural height before and after at its width, written into the adjustment with `gtk_adjustment_configure`), so showing the page early moves no row. Without it the paint drift in `chatswitch` is 1762 px.
- The first apply draws a screen's worth (`firstFillRows`: 12-32 rows by page height, half of that at loaded), not forty plus a top-up.
- A conversation that has read nothing yet no longer wipes a page drawn from the rows the window kept (`holdsPaintedRows`); the empty state it opens with was taken for the truth and replaced the rows with "Loading…". That wipe also destroyed brain readout widgets with posted callbacks pending, which crashed the app (`BrainReadout.Page.watchFade`, fixed with `Gtk.WeakWidget`).
- `ConversationHub` keeps the last transcript of the six conversations it let go of for fifteen minutes (`shelved`), seeds the next lease on the key with it, and does not post the blank state a rebuilt conversation opens with over it. Registered with `MemoryRelief`.
- `RowMemo` is one process-wide table of what each message was drawn as (2,400 messages, least recently used out, registered with `MemoryRelief`), so a second visit builds nothing and a build that was 150-700 ms for three hundred messages is a few milliseconds.
- `ConversationWarmer` starts a chat a pointer has rested on for 90 ms or pressed on: a glance lease on its conversation and its tail drawn into the memo (`TranscriptRowBuilder.warm`), handed over when a pane opens it, let go after twenty seconds, at most three at once. The Mac has had this since the sidebar's own `ConversationWarmer`.

### Measuring it again

`TAILSCODE_TRACE=1` prints, for every open, `open+Nms first rows`, `first frame`, `revealed`, `filled` and any `placeholder`; a script that appends `openid=<uuid>` lines to the harness drive file at fixed times and a parser over the log is all it takes. Reset `launch.json` to a clean exit first and stop the app with SIGTERM, or the next harness starts with the shed floor at loaded and every number is the slow one. The `chatswitch` selftest holds the claims that do not need a person: a message drawn once for every builder, the first apply bounded, the page shown before the history is complete, no drift of the page's end during the backfill, a blank state leaving the page alone.

## The Agents wall at the display's pace

The wall was capped at 30 fps with its layers at 15, 12, 6 and 2, and on the desktop it ran far below even that: each layer was a full-window or tile-sized `GtkDrawingArea`, and under the Vulkan renderer a cairo node is rasterised and uploaded again whenever it lies in the damaged region, which the motes made the whole window every frame. One frame cost the main thread about 50 ms, the loop meter read busy, the governor went to critical and took the pulses away, and the wall fell to one frame a second.

### What was measured

A hidden gamescope (`gamescope --backend headless -W 2112 -H 1333 -r 144`) runs the release binary on X11 with `GSK_RENDERER=vulkan` (the real desktop's renderer), its own session bus and home with the person's wall style copied, `TAILSCODE_DRIVE="1500:agents-watch=<scene>;5000:agents-bench=10"`, and the app's own meter prints the result. Gamescope's X11 clock reports 60 Hz, so 60 is the ceiling there. Process CPU is read from `/proc`. Main-thread stacks come from `eu-stack -1` in a user namespace that keeps `CAP_SYS_PTRACE` (see the freeze recipe above).

| scene | before | after |
|---|---|---|
| squad | 1.0 fps, paint cycle mean 202 ms | 59.9 fps, 0.95 ms, CPU 5.6 % |
| busy (an ultracode tile) | 2.9 fps, 53 ms, CPU 15.5 % | 59.9 fps, 1.2 ms, CPU 6.6 % |
| alarm | 2.9 fps, 55 ms, CPU 16 % | 59.9 fps, 1.6 ms, CPU 9 % |
| calm | 39.7 fps, 13 ms, p99 69 ms, CPU 50 % | 59.9 fps, 0.7 ms, CPU 3.9 % |

Under the software renderer (`GSK_RENDERER=cairo`) the busy scene drew about 48 frames a second of mixed layers at 47 % CPU before, and draws 20 at 39 % now. After 30 s of warm-up a 15 s window under Vulkan has no frame later than 1.5 intervals and the worst paint cycle is 6-7 ms; the slow frames of the first seconds are the GPU renderer creating pipelines for node kinds it meets for the first time.

### What changed

- `CGtkShim/wallpaint.c`: a paint widget whose snapshot the Swift side builds (`WallLayer`), pictures painted once with cairo and kept as `GdkMemoryTexture`s under a GPU renderer or as a surface the cairo renderer replays (`WallPicture`, repainted only when its key, size, scale or renderer changes), and helpers for the nodes the GPU draws itself: discs, rings, rounded fills, strokes and bands, radial and linear gradients, capsules, mote fields, turns and clips, and the ultracode sweep.
- Every wall layer is nodes (`AgentsWatchFaces.swift`, `AgentsWatchBackdrop.swift`): the card's glass, wash, edge, rim and focus; the mark's ring, lit core and dashes as pictures moved by scale, turn and opacity, its waves and orbit as rings and discs; the ground as one picture with the aurora as radial gradients, each tile's light as a half-resolution picture drawn at its breath's opacity, ripples as rounded bands; motes as discs, interpolated between the field's fixed 15 Hz steps so its wander and trails are unchanged; plates, effects and the vignette as fills, gradients and discs. `SelfTestAgentsWatchGPU.swift` renders each through GSK's own node drawing and holds it against the cairo painter it replaced, for every state at several moments.
- The ultracode ring was first a conic gradient seen through a mask. The GPU renderer gives every mask an offscreen image and Vulkan allocated and freed one per frame (85 % of the busy scene's main-thread time in `ioctl`); it is now runs of linear gradients and corner borders (`tailscode_snap_sweep_band`), and the busy scene's samples show no offscreen made per frame.
- `AgentsCanvas`, which every other agents surface paints with, keeps its picture as a texture until it is told something changed, so a strip beside a moving thing is no longer rasterised again with it. Its widget owns it, as a drawing area owned its closure, and a theme change paints every live one again.
- The wall's frame clock runs at `WallCadence.smoothRate` of the display under a GPU renderer, each frame due half a refresh short of a whole number of refreshes, and answers to the desk's reduce-motion setting alone, not the shed level's pulses; at critical it holds to 30, and under the software renderer, which draws every node on the main thread, it keeps to 20.
- An accessible label the widget already carries is not set again, so a wall restating its tiles once a second sends the accessibility bus nothing.

### Measuring it again

`agents-bench=<seconds>` (`AgentsBench.swift`, `CGtkShim/frames.c`) stamps every frame the Agents window's surface actually renders (an emission hook on `GdkSurface::render`, whose own handler stops the signal; a frame-clock cycle that drew nothing is not counted) and prints `AGENTS bench`: frames and fps, the gaps against the wall's own target (`late` is a gap over 1.5 targets), the paint cycle and the layout share of it, main-thread CPU, cairo draws and megapixels, snapshots, pictures painted, stage layouts, the worst canvas allocation and the once-a-second tick. Run it in the gamescope above, not the Xvfb harness: under the cairo renderer the numbers are the software renderer's.

## The chat list's draw

The list is drawn on a cadence (`SidebarCadence`, 0.1 s when calm and visible) and again whenever a
list push, a presence change or a store notification asks for one. Every draw used to read the four
stores a row is decided from — the seen map, the pins, the saved set and the archive — and then
rebuild two thousand `profile/session` key strings for the shape it compares against the last draw.
The work that speaks for the whole fleet (activity observations, the inbox reconcile, a notice
withdrawal for a chat read elsewhere) ran on every draw too, including the nine in ten that changed
nothing but a turn's step.

A draw now reads each store once and keeps the answer until its own notification
(`SidebarReadings`), compares a 64-bit digest of the drawn order — hashed from the profile and
session ids, with no strings built — and speaks for the fleet only when the listing moved
(`sidebarListingVersion`); a read-mark sync withdraws its notices once. The archive is held as
`ArchivedChatStore.ChatKey` identities, so asking whether a row is filed away no longer builds a
line to ask a set about.

### What was measured

`sidebarbench=<rounds>` draws the list that many times in place and prints the median and p90 of
the common path (model pass, digest, row patches) and of a forced full rebuild, with the listing
in the window. Release build, the Xvfb harness, 2,093 sessions across five servers:

| | before | after |
|---|---|---|
| a draw (the path a push takes) | 13.6 ms median, 14.4 p90, 16.8 max | 9.0 ms median, 9.7 p90, 10.9 max |
| a forced rebuild of every widget | 39.0 ms median, 41.4 p90 | 34.3 ms median, 38.8 p90 |

A draw now fits a 120 Hz frame where it did not. The rebuild is the same work it was — it is
bounded by the 60 rows drawn, not by the fleet — and is paid only when the shape changed.

### With agents at work

With five turns streaming the list was asked to draw about once a second, and each draw held the
GTK thread for 17 ms at the median, 24-77 ms at p90 and up to 125 ms (`TAILSCODE_TRACE=1`'s
`renderSidebar begin`/`end`, release build, the real 2,110-chat fleet): 13 ms of the fleet-wide
model before any widget was touched (rows 4-6, filing into sections 3-5, the orb and Agents entry
1-4, the inbox and notifier 2-4, asks, the order digest) and then every row whose session had
moved rebuilt as a whole widget tree, which for a working row is every push because its age and
its step change. On the person's 144 Hz screen a frame is 6.9 ms.

A draw the listing, a presence or a store asks for (`scheduleSidebarRender`) now reads the stores
and the presence on the GTK thread, walks the fleet on a dispatch worker (`SidebarWalk`: the rows
through `SessionRowModelCache`, which the walk owns while it is out, the orphaned bookmarks, the
orb's reading, the observations when the listing moved, the sections, the vocabulary and the
digest), and patches the widgets back on the GTK thread (`presentSidebar`). One walk is out at a
time; a request made meanwhile is drawn once after it lands, and a draw made in between — a press,
a keystroke in the filter, `sidebarbench` — makes it stale, so it is dropped with its cache.
`renderSidebar()` still walks in place, because the person is looking at the row that moves. A
chat row remembers its `SidebarRow.Face` — everything it draws except the news line's words and
the age — and a reading with the same face sets those words in place (`SidebarRow.patchWords`,
the parts found by name with `Gtk.descendant(of:named:)`) instead of building the row again. The
inbox reconcile reads the marks the draw already holds rather than decoding them again.

Matched runs, the harness at 1920x1200, five Haiku turns started on the Mac's bridge fifteen
seconds before a 45-second window, release builds:

| | before | after |
|---|---|---|
| a draw on the GTK thread | 17 ms median, 24 p90, 41 max | 4 ms median, 5 p90, 6 max |
| its share of the GTK thread | 2.3 % | 0.3 % |
| the process | 23.2 % of a core, GTK thread 18.4 % | 15.6 %, GTK thread 12.3 % |

`sidebarbench=40` now prints the walk and the GTK thread's share of a draw beside the total: a
draw is the same 8.7 ms it was, 7.2 ms of it the walk, which a push no longer pays on the GTK
thread (1.5 ms median there).

### Measuring it again

`scripts/bench-linuxapp.py` walks launch, the list scrolled, seven chats, the transcript scrolled,
typing, a table stream, a four-pane split, the Agents window, a brain, the panels and a theme in
one run, and prints each stage's CPU, RSS and worst busy/stall from the flight ring, plus the
`open+Nms` marks. Run it inside the harness as the app's ancestor:

```
TAILSCODE_DEV_GEOM=1920x2160x24 TAILSCODE_DEV_STATE=… TAILSCODE_DEV_DISPLAY_NUM=78 \
TAILSCODE_BENCH_RENDERER=vulkan TAILSCODE_BENCH_SHED=0 \
scripts/dev-linuxapp.sh run gamescope --backend headless -W 1920 -H 2160 -r 120 -- \
  ~/.cache/tailscode-dev/xvenv/bin/python scripts/bench-linuxapp.py
```

`TAILSCODE_BENCH_SAMPLE_STAGES=sidebar-scroll,chat-open` also samples with `eu-stack` (inside a
user namespace that keeps `CAP_SYS_PTRACE`); `scripts/prof-linuxapp.sh` takes one ad-hoc sample of
every thread.

### The background core with five servers

With five servers configured the app used to hold about one core of background work on libdispatch
workers that disappeared with one server. Measured again on 2026-11-27 with the Kit at 0.68.0,
which passes over opencode events that cannot concern a listener before decoding them, the
workers take 1.4-4.6 % of a core with the same five servers, at rest and with five turns
streaming; one 45-second window read 32 % while five new turns were starting at once and the next
ten seconds read 1.4 %. What 0.68.0 removed — every streamed token of every session on an opencode machine decoded by each listener — is the likeliest cause; the core has not come back in these runs.
