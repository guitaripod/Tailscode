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
