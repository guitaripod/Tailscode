# The Mac's frame budget

What the AppKit client costs and how it is measured. The contract is the same as Linux's
(`docs/linux-performance.md`): no work for a state a person cannot see, and no repeating work whose
result would say what it already says.

## Measuring

Two things are readable from outside the process, so a run over ssh is enough:

- `TAILSCODE_FRAME_WATCH=1` — `FrameWalk` starts a display link on the main window's content view.
  Every wait a person can feel (50 ms) is a log line as it happens, and every two seconds the
  stretch is a summary: `Frame watch, <stage>: 240 frames, worst wait 8 ms, 0 late, 0 of 50 ms or more`.
  A stage is named by the drive script's `mark=<name>`, so one run reads as one line per surface.
- `TAILSCODE_TRACE=1` — `Pace.traceStart/traceEnd` write the length of a named stage to the log
  (`sidebar.render: 13 ms`, `transcript.apply: 2 ms`, `preferences.open: 104 ms`), which is how a
  pass is priced without Instruments.

`scripts/tour-mac.sh live|demo` drives one run through the surfaces: launch, the list scrolled,
ten chats opened, the transcript scrolled, typing, a four-pane split with focus and zoom, a live
resize, a switch to a scenery theme and back, and the Agents, Settings, Usage and Studio windows.
It needs the debug build at `build-mac` and a live server configured.

## The steady state

On the MacBook (120 Hz) against the real fleet — 1,796 sessions across macbook and arch, a turn
running, Outer Rim's sky painting — the tour's recurring stages cost no frame a person can feel:

| Stage | Result |
|---|---|
| idle after launch | 17–29 ms worst, nothing late enough to see |
| the list scrolled | one 54 ms wait in the first two seconds (first row rendering), then 8–17 ms |
| the transcript scrolled | 8–36 ms worst, nothing felt |
| typing in the composer | 8–43 ms worst, nothing felt |
| a live window resize | 17–26 ms worst |
| a theme switch with scenery | 17–34 ms worst |

The passes behind those numbers, in process:

| Pass | Cost |
|---|---|
| `SidebarViewController.render` on 1,800 sessions | 13 ms median, 24 ms worst |
| `TranscriptViewController.apply` for a streamed state | 1–6 ms |
| `TranscriptViewController.apply` when a chat opens | 30–50 ms, plus the sidebar's own draw |

## While turns stream

`--bench sidebar[=<chats>:<seconds>]` (needs `TAILSCODE_HOST` and `TAILSCODE_PASSWORD`) puts the chat
list alone in a borderless window parked off every screen, pads the server's listing with idle copies
to `<chats>` and measures every draw the server's pushes and the ten-second poll cause: draws a
second, each draw's main-thread CPU, the median of each stage, and what the walk cost off the main
thread. Run it from a re-signed copy with its own bundle id and `CFFIXED_USER_HOME`, so the person's
preferences are never written. Against the MacBook's bridge padded to 2,100 chats with four Haiku turns
streaming steps:

| A draw of the list | Before | After |
|---|---|---|
| main thread, median | 21.4 ms | 4.4 ms |
| main thread, p90 | 25.3 ms | 6.9 ms |
| main thread, worst | 28.6 ms | 7.1 ms |

Before, the draw was the fleet walk (6.7 ms), sections (3.8), the fleet's word to the notices (3.6),
the vocabulary (1.6) and reloading the three to five rows a push changes (4.4, three quarters of a
millisecond a row for a new cell measured with automatic heights). Now a draw a push or the poll asks
for walks the fleet on the cooperative pool (`SidebarWalk`: rows against their memo, orphaned
bookmarks, the archive count, scope and filter, sections, vocabulary and, when the listing moved, the
observations), and a draw begun meanwhile makes it stale (`drawGeneration`); a press, a key, a filter
typed and the first listing still draw in the same turn. A changed chat row on screen whose news line
keeps its one line, or its none, is dressed again in its own cell instead of reloaded. The walk costs
7-10 ms on another core; the notices still hear the whole fleet on the main thread (1.8 ms), because
re-observing an unchanged row is what tells them the listing still says it.

## What changed

The list is a pure function of `rows`, and it used to be recomputed whole — every session worded,
every store decoded, every push its own draw — up to five times a second while turns streamed:

- Every row's `SessionRowModel` is remembered (`RowMemo`) against the facts it was worded from: the
  session, its flags, this device's presence and the bucket its age falls in. An unchanged row costs
  a lookup, not ten string allocations; an age changes when its word would.
- The stores the rows are decided from (`saved`, pins, the archive as identities, the unread
  evaluator) are read once (`StoreReadings`) and dropped by each store's own notification.
- A listing push replaces one entry in place (binary insert) instead of filtering and re-sorting two
  thousand, and draws at most once per 200 ms — the bridge pushes a change per chat that moves.
- What speaks for the whole fleet (activity observations, the inbox reconcile, withholding a
  banner for a chat read elsewhere, an XPC call) runs only when the listing actually moved.
- A store that speaks while a draw carrying its news is already running no longer draws again.
- A window nobody can see defers its draw until it is back, instead of rebuilding a list into an
  occluded window every time a turn moves.
- A row's identity — not two thousand key strings — is what a pass compares to the last one.

The live pipeline had one bug worth more than all of the above: the run-loop observer that charges a
frame's cost to the governor was installed once and never removed, so after the first streamed frame
every run-loop turn — twice per turn, forever — enqueued a main-queue block that did nothing, kept
the loop awake, and made `LoopLoad` read its own bookkeeping as load. It lives for the one turn it
was made for now. A hidden window drains its edge services (notices, presence) four times a second
and never lays out or commits a frame.

Elsewhere, each item measured before it was changed:

- **Transcript** — the live row's unread height is remembered until the reveal crosses a line
  (`unrevealedMemo`) instead of laying the whole prefix of the answer out on every wave frame; the
  picture sweep no longer forces a layout pass inside a scroll notification; the first fill builds
  12 rows a hop rather than 40.
- **Composer** — the pills, the party popover and the model dial compare what they would draw before
  drawing it; a streamed token no longer restyles a pill, re-measures three destination labels,
  folds a catalogue six times or restarts a breathing halo.
- **Window shell** — a focus move no longer rebuilds the chat list; dividers label once per
  structural change and only relayout when their geometry moved; the overflow strip keeps its chips
  and their widths; split positions are written once per drag instead of eight times a frame, and
  the snapshot is encoded off the main thread; the sky's gradient and colours are built once per
  tint rather than per halo star.
- **Studio** — a reference picture's aspect is read once per path instead of on every layout pass;
  hidden overlays are not measured; socket progress is coalesced to one update a frame; shelf facts
  cache their misses.
- **Agents** — an unchanged wall is adopted without measuring every tile again, and a tile fits from
  the level that last worked; the board applies its id delta instead of reloading every row with
  automatic heights; the peek updates in place and does not draw for a folded inspector; Hour keeps
  its 5 s cadence.
- **Brain** — the NOW line truncates with a handful of measurements instead of one per dropped
  character per drawn frame; the edge fade, the pulse animations and the theme change stop rebuilding
  what is already on screen; a row that cannot be seen defers its card and picture.
- **Settings** — pages are made the first time their tab is shown; opening the window used to build
  all seven.

## What is left

Opening something is still a single main-thread cost, because the window (or the pane, or the
chat's first rows) is built in one turn:

| Opened | Cost |
|---|---|
| the app, restoring four panes | 250 ms worst, during the first second only |
| a four-pane split | 280 ms |
| a large chat (1,500 messages) | 50–170 ms, the first rows and two whole-conversation folds |
| the Agents window | 190 ms (was 160: the fixture path differs between runs) |
| Settings | 117 ms (was 299) |
| Usage | 90–120 ms |
| the Studio | 90 ms (was 122) |

The next lever is the one the transcript's fill already pulls: build a window's or a split's panes a
few at a time across frames, rather than all in the turn that asked for them.
