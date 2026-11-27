# Back and Forward: the chat trail

A mouse's thumb buttons (4 and 5 in a person's head, GDK buttons 8 and 9, `NSEvent` buttons 3 and 4)
walk the chats a pane has shown, the way a browser's do. The capability is `AppCapability.chatTrail`;
the phone answers `notApplicable` because its navigation stack already is the trail.

## What a trail is

`ChatTrail` (Core, toolkit-free) is one pane's history: a chat once, newest last, with a place in it.

- Opening a chat the trail already holds moves it to the end instead of adding a second copy, so
  hopping between two chats from the list leaves those two and Back and Forward are the hop.
- Opening a chat from the middle ends what lay ahead of it, as a browser does.
- At most `ChatTrail.limit` (64) chats.
- A chat that is deleted leaves every trail (`forget`); one that is only missing from a listing, or
  is already on screen in another pane of a split, is stepped over and stays.
- A press with nowhere to go does nothing and says nothing.

`ChatTrail.Direction(gdkButton:)` reads 8 and 11 as Back and 9 and 10 as Forward, the two pairs the
kernel and browsers both use (`BTN_SIDE`/`BTN_EXTRA` and `BTN_BACK`/`BTN_FORWARD`);
`Direction(cocoaButton:)` reads 3 and 4. `chat.back` and `chat.forward` (alt+left, alt+right, normal
mode) are registered actions, so the keyboard, the cheatsheet and `keybindings.json` reach them too.
They are in `ShortcutRegistry.appActions`, which a phone drops from its bindings.

## Why it is fast

A step moves the trail's place at once; the pane catches up once. `ChatTrail.settle()` says where the
pane should be, and a client calls it after every queued event and before the next paint:

- **Linux:** `Gtk.beforePaint` is an idle at `G_PRIORITY_HIGH_IDLE + 10`, between `GDK_PRIORITY_EVENTS`
  and `GDK_PRIORITY_REDRAW`. Every press already queued is dispatched first, the pane opens the chat
  the burst ended on, and the frame that follows draws it. A burst opens one chat and builds nothing
  it walked past (`trailburst=N` proves it: one `open begin` for N presses).
- **Mac:** the settle is a main-queue async block in the same event turn.

While a hand is hopping, work that only matters to a chat that is being stayed in keeps out of the way
for `ChatTrail.quiet` (0.3 s) after each hop:

- `FillTurns.hold` keeps the backfill of rows above the first screen from taking its turn, so a hop
  costs the first screen's rows, not the first screen and a twenty-row chunk the next press throws away
  (an urgent hop, a page that is not full, still goes at once).
- The chat list's redraw is debounced the same way (`sidebarHoldUntil`, a `flush` of the coalescer on
  each hop), so it is drawn once, at the end, with the chat the burst ended on marked. With two
  thousand chats it was the largest single cost of a hop.

The chats either side of the place are warmed after a hop (`ConversationWarmer`) when their rows are
not already remembered, so the next press finds its words in memory. The hub keeps a conversation's
stream through its grace period, so hopping redials nothing.

## Measuring it

`trailbench=N` (a `TAILSCODE_DRIVE` verb) hops back and forth N times, each hop drawn before the next,
and prints the press-to-frame time and the main thread's own CPU time per hop:

    TRAILBENCH hops=40 shown p50=…ms p95=…ms max=…ms cpu p50=…ms p95=…ms max=…ms

Use long conversations: `TAILSCODE_SOAK=3:1:600:1` with `--demo` gives three 600-message chats, and
`openid=soak-1`, `soak-2`, `soak-3` visit them. `shown` includes the frame clock's pacing; `cpu` is
what the processor was asked for. `back`, `forward`, `trail` and `trailburst=N` are the other verbs.

### On a Steam Deck

`scripts/deck-linuxapp.sh` runs the release build on a Deck without installing anything there: the
binary travels with the libraries it was linked against, glibc included, patched to find them beside it
(SteamOS has an older glibc, no libadwaita and no Swift). `sync` bundles and copies, `start` runs it on a
private Xvfb inside the bundle (software renderer, nothing on the Deck's screen, so a game is never
interrupted) or, with `TAILSCODE_DECK_SCREEN=:1`, on the game display with the GPU renderer, and `do`
feeds it drive verbs. Both processes are units of the Deck user's systemd manager, because the Deck's
logind kills whatever an SSH session started the moment it ends. `perf` is on the Deck:

    perf record -F 1999 --call-graph fp -p $(pgrep -u deck -f '^/home/deck/tailscode-deck/bin/tailscode') -- sleep 9

On the Deck the cost of a hop is Pango and HarfBuzz shaping the rows it builds (about 28% of the main
thread over a bench run), then GTK's layout: the way to make a hop cheaper is to build fewer rows, which
is what the hold does.
