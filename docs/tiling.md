# Tiling: design

Status: proposed 2026-10-05, nothing built. This is the spec the implementation follows. Where a fact is unverified it says so; where a number is a starting point it is in Appendix C and gets tuned from flight-recorder data.

## 1. Why

On 2026-10-05 the Linux desktop hard-froze while four or five chats were tiled. The cause is unproven (journal: no OOM kill, no NVIDIA Xid in the last minute, a machine-wide stall from 22:33:26, Steam launching a game at the same time; the app logged nothing about tiling, so there is no evidence either way). What is certain:

- Nothing stops an app from taking the machine down: `systemd-oomd` and `earlyoom` are inactive, the app and user slice have no memory limit, swappiness is 10 over a 16 GB swapfile.
- Tiling multiplies everything by N and bounds nothing. Verified in code: every pane runs its own conversation and its own per-state row build; every state is posted to the main thread above redraw priority with no coalescing; the cascade's markup parse cache holds one entry for the whole process (its comment, "one live row at a time", is false with several streaming panes); the cascade tick has no frame cap; every session-list upsert does a synchronous encode and write on the GTK thread; there is no pane cap; hidden panes keep streaming; every structural verb re-parents every pane (two SEGVs already). Mac is the same shape: each pane a full live `TranscriptViewController`, rows built on the main thread, 12–26 ms per pane per live-resize step.
- The nested native split widgets (`GtkPaned`, `NSSplitViewController`) force re-parenting, post-hoc ratio patching (a 120 ms retry on Linux, a double `applyRatios` plus `suppressCapture` races on the Mac) and a per-build minimum size that goes stale when the window shrinks.

The model (`SplitLayout`) is right and stays. Everything around it changes.

## 2. Principles and invariants

Each invariant is checked by a test, a selftest assertion or a grep gate (section 10).

1. **I1. No unbounded queue.** Stream events never post to the UI thread one by one. Producers overwrite a latest-wins slot; one drain per frame reads it.
2. **I2. No synchronous disk IO on the UI thread** in any per-state, per-verb or per-frame path.
3. **I3. Every pane resource has an owner.** Ticks, timers, Tasks, observers and streams belong to a `PaneLifetime`; `shutdown`, demotion to parked and hiding cancel all of it. After `shutdown` the pane's weak reference is nil in the selftest.
4. **I4. A pane is never re-parented after creation.** Structure changes are rect changes. A debug counter proves it.
5. **I5. Parked and hidden panes own zero clocks and zero streams.**
6. **I6. Every cache is capped and evictable** through `MemoryRelief`.
7. **I7. Ratios are intent.** A clamped or hidden-pane presentation never writes a ratio back. Only a divider drag, a nudge or equalize does.
8. **I8. A structural verb costs one layout pass** and no widget construction beyond the new pane's shell.
9. **I9. Safety outranks preference.** At shed level 3 and above, pins, "keep all live" and animations are ignored, and the UI says why.
10. **I10. The recorder never holds content.** Counts and durations only: no titles, ids, text.

## 3. Architecture

```
Core model (pure)         SplitLayout, PaneContent, PanePlacement, PaneArrangement, SplitSnapshot v2
Core runtime (toolkit-free, no @MainActor)
                          ConversationHub, LatestWins, SingleFlightPump, TileDrain,
                          TileGovernor, LoopLoad, HostPressure, MemoryRelief,
                          FlightRecorder, SafeRestore, GlanceReading
Host (per toolkit)        TileCanvas (one flat container, solver callback, dividers),
                          TileShell (chrome), overflow strip, restore banner,
                          sensors (loop meter, watchdog, pressure), recorder writer
Content (per toolkit)     ChatPane / TranscriptViewController (full), GlanceTile, parked face,
                          web / video / draw slots
```

Data flow for one streamed token:

```
backend event -> Kit AgentConversation (one per session, shared) -> hub fan-out
  -> per-consumer LatestWins slot (O(1), marks dirty once)
  -> full consumer: SingleFlightPump builds rows off-main (Linux) or time-boxed on main (Mac)
  -> TileDrain (one per window, frame-driven): applies focused first, then attention, then peers,
     within a 4 ms budget; leftovers wait for the next frame
  -> glance consumer: GlanceReading from the last few messages, at the level's rate
  -> hub edge service (once per session): notifications, queue drain, presence
```

Two host rules shape everything:

- **Core never touches the main queue.** `g_application_run` does not drain libdispatch's main queue (see `DelegateRunner.swift`), so any Core type that awaits a `@MainActor` hangs forever on Linux with no log. Core runtime types are `Sendable` classes with a lock and a host-supplied `HostClock`.
- **The host owns delivery.** `HostClock` is the one seam: `now() -> TimeInterval` (monotonic seconds) and `requestDrain()` (idempotent while a drain is pending).

## 4. Core model

All new files live in `TailscodeCore/Sources/TailscodeCore/Tiling/`. Signatures below are shapes, not final text.

### 4.1 Content and density

```swift
public enum PaneKind: String, Codable, Sendable { case empty, chat, web, video, draw }

public enum PaneContent: Codable, Sendable, Equatable {
    case empty
    case chat(SplitPaneSession)
    case web(String)
    case video(String)
    case draw(String)
    public var kind: PaneKind { get }
}

public enum PaneDensity: Int, Codable, Sendable, Comparable { case parked, glance, full }
```

`PaneContent` encodes as `{"kind":"chat","profileID":…,"sessionID":…}`; an unknown kind decodes as `.empty` so a newer snapshot never invalidates an older app. Only chat supports all three densities. Web and draw are `full` or `parked`. Video is `full` only while it is the focused pane or the only video pane in the window, otherwise `parked` (paused, poster and title). An empty pane is the chooser and is always `full`.

### 4.2 Sizing

`PaneSizing.minimum(kind:density:)` returns a `PaneMinimum`; the host may report a larger natural minimum for a slot (`minimum` closure on placement) and Core takes the max.

| Kind / density | Min width × height (pt) |
|---|---|
| chat full | 280 × 200 |
| chat glance | 200 × 88 |
| web | 280 × 200 |
| video | 280 × 158 |
| draw | 360 × 300, or the slot's reported minimum |
| empty (chooser) | 240 × 160 |

- **Density follows geometry.** A chat pane whose rect falls below 280 × 200 is `glance`; at 296 × 216 or more it may be `full` again (16 pt hysteresis so a drag across the threshold does not flicker). Dragging a divider small turns a chat into a status tile, and making it big turns it back. The governor can demote further, never promote past what geometry allows.
- Layout clamps use the **glance** minimum for chat, because a chat can always degrade. `PaneDropTarget.minimumPaneExtent` (280) stays as the threshold below which a drop only fills.
- Gutter between siblings: 1 pt. Divider hit target: 9 pt (4 pt either side), drawn over the gutter.

### 4.3 Placement

`SplitLayout.placement(in:scale:stripHeight:minimum:) -> PanePlacement` is a pure function of the tree and the container size.

```swift
public struct PanePlacement: Sendable, Equatable {
    public var frames: [PaneID: SplitRect]
    public var dividers: [DividerPlacement]
    public var hidden: [PaneID]
    public var hiddenReason: HiddenReason?
    public var stripNeeded: Bool
}

public struct DividerPlacement: Sendable, Equatable {
    public var id: SplitID
    public var axis: SplitAxis
    public var line: SplitRect
    public var hit: SplitRect
    public var parent: SplitRect
    public var position: Double
    public var lowest: Double
    public var highest: Double
}
```

Rects are in the container's logical points, origin top-left (the Mac canvas is flipped), and are the only geometry any host uses. `SplitLayout.frames(in:)` (unit rects, used by `neighbor`) stays for direction logic.

**Algorithm.**

1. Bottom-up, `minExtent(node, axis)`: a pane returns its minimum along the axis; a split along that axis returns `min(first) + gutter + min(second)`; a split across it returns `max(min(first), min(second))`.
2. Top-down, a split with ratio `r` and extent `E` along its axis computes `cut = (E - gutter) · r`, clamps it to `[minExtent(first), E - gutter - minExtent(second)]`, snaps to the scale (`round(cut · scale) / scale`; GTK passes scale 1 because allocations are integer logical pixels, the Mac passes the backing scale) and gives the second child the exact remainder. Child rects therefore sum to the parent's with no seam.
3. **Infeasible trees.** If `E < minExtent(first) + gutter + minExtent(second)` at any split, panes are dropped from the *least recently focused* until the remaining tree (built with the existing `removing(_:from:)`) is feasible, never below one pane (the focused one). Dropped panes go to `hidden` with reason `.noRoom`, are parked, and appear as chips in the overflow strip. The tree is untouched; growing the window brings them back exactly where they were. This is the desktop version of "a window too narrow for columns is one stack".
4. **Zoom.** The zoomed pane gets the whole container; every other pane is `hidden` with reason `.zoomed`. Zoomed-away panes park and show as chips in the same strip, so a zoomed window still says what the others are doing.
5. `stripNeeded` is true when `hidden` is non-empty. The solver first runs at full height; if the strip is needed it runs again at `height - stripHeight` (monotone, so one retry settles it).

**Dragging.** `SplitLayout.drag(_:to:in:)` takes a divider id, a pointer coordinate along the divider's axis in the parent's coordinates and the current placement. It clamps to `[lowest, highest]` (each is the position at which a neighbouring subtree reaches its minimum), converts to a ratio over `E - gutter` and calls `setRatio`. Because the clamp lives in Core, both toolkits drag identically and no pane can be squeezed below its minimum by any gesture. Hosts stop capturing ratios on a timer: the ratio is written when the drag moves, and persistence is coalesced (4.6).

**Keyboard resize.** `SplitLayout.nudge(_:toward:by:in:)` moves the nearest ancestor divider on the focused pane's edge. Step 16 pt, 64 pt with shift; the same function backs divider key handling and the `ctrl+w` chords.

### 4.4 Verbs

Existing verbs keep their semantics: `split`, `close`, `focus`, `focusNeighbor`, `toggleZoom`, `exchange`, `equalize`, `setRatio`. New pure verbs on `SplitLayout`, each with a test:

| Verb | Meaning |
|---|---|
| `swap(a, b)` | exchange two leaves anywhere in the tree; ids, focus and history unchanged |
| `promote(p)` | `swap(p, masterLeaf)`; master is the first leaf of the root's first child |
| `rotate(forward:)` | cycle the leaf order through the same tree shape |
| `move(p, onto: t, edge:)` | remove `p`, split `t` on that edge; powers dragging a pane's strip onto another pane |
| `moveToEdge(p, edge:)` | remove `p`, wrap the root so `p` takes the far edge (vim `ctrl+w H/J/K/L`) |
| `arrange(_ arrangement, order:)` | rebuild the tree for the given pane ids; ids, focus, zoom, history preserved |
| `cycleFocus(forward:)` | next pane in reading order, hidden panes skipped |

`split` gains one guard: it refuses when the focused pane's rect, halved on the chosen axis, would leave either half below the glance minimum. The refusal is a one-line toast ("No room for another split here"), not silence. Keyboard and drop paths share the guard; today only drops check size.

**Chords.** Added to `ShortcutRegistry.all` in `Shortcuts.swift`, normal context, all behind the existing `ctrl+w` prefix. The registry's conflict reporter gates collisions (token spellings follow `KeySpec`).

| Action | Default | Notes |
|---|---|---|
| `split.cycle` / `split.cycleBack` | `ctrl+w w` / `ctrl+w shift+w` | `focus.cycle` (`tab`) keeps cycling regions |
| `split.promote` | `ctrl+w return` | swap into the main slot |
| `split.rotate` / `split.rotateBack` | `ctrl+w r` / `ctrl+w shift+r` | |
| `split.moveFar{Left,Down,Up,Right}` | `ctrl+w shift+h/j/k/l` | |
| `split.grow{Wider,Narrower,Taller,Shorter}` | `ctrl+w >` `<` `+` `-` | nudge |
| `split.arrange` | `ctrl+w a` | cycles columns, rows, grid, main and stack |
| `split.pin`, `split.park` | unbound | menu, palette, strip context menu |

New `KeyAction` cases: `.cycleSplit(Bool)`, `.promoteSplit`, `.rotateSplits(Bool)`, `.moveSplitToEdge(SplitDirection)`, `.resizeSplit(SplitDirection)`, `.arrangeSplits`, `.pinSplit`, `.parkSplit`.

### 4.5 Arrangements

`SplitArrangement` (side by side, stacked, grid) gains `mainStack` (main on the left at ratio 0.58, the rest stacked on the right, equal heights) and `mainTop`. `SplitEven.layout(count:as:)` is generalised to `arrange(ids:as:)` so the same builder serves bulk-open (fresh ids) and re-arranging live panes (existing ids). Bulk-open of three or more chats offers all four, with `mainStack` first for 4–9. `SplitEven.limit` (9) stays the bulk limit; the interactive limit is geometric.

Arrangements are shapes, not modes: the tree stays freely editable afterwards, and `SplitEven.shape(of:)` keeps reading a shape back from any tree.

### 4.6 Snapshot v2

Key unchanged: `tailscode.layout.tree`.

```swift
public struct SplitSnapshot: Codable, Sendable, Equatable {
    public let schema: Int
    public let layout: SplitLayout
    public let contents: [String: PaneContent]
    public let pinned: [String]
    public let sessions: [String: SplitPaneSession]
    public let videos: [String: String]
    public let pages: [String: String]
    public let draws: [String: String]
}
```

- **Dual-write for two releases.** v2 writes `contents` and the four legacy dictionaries, so a downgrade still restores. The reader prefers `contents` and falls back to the dictionaries (migration). The legacy fields are dropped in the release after.
- `session(for:)`, `video(for:)`, `page(for:)`, `draw(for:)` stay as accessors, so `SplitTab`, `SplitTabs` and the hosts keep compiling.
- **Sanity on decode.** More than 12 panes: keep the first 12 in reading order and drop the rest (recorded). Duplicate ids, non-finite ratios and unknown focus keep `isValid` discarding the whole snapshot.
- **Persistence is coalesced.** Hosts call `LayoutStore.schedule(snapshot)`: one trailing write 250 ms after the last change, flushed on every exit path. Linux routes through `SettingsFile.set` (already 750 ms coalesced); the Mac currently encodes the whole snapshot to `UserDefaults` on every divider notification and every focus change, which stops.
- A lone chat pane writes nothing, as today. A lone slot writes.

### 4.7 As built (core model)

Where the code settled a question this spec left open, or had to differ from it:

- **`split` stays unguarded.** The room guard is `SplitLayout.canSplit(_:axis:in:)` (false when either half of the pane's current rect, less the gutter, is below the glance minimum on that axis); hosts call it before `split` and toast the refusal. Keeping `split` itself unguarded keeps every existing caller and test, and the guard needs a placement `split` does not have.
- **`PanePlacement` also carries `bounds`** (the area the panes and seams tile: the container less the strip) **and `strip`** (the strip's rect when needed), so hosts never recompute them.
- **Divider coordinates.** `DividerPlacement.position`, `lowest`, `highest` and the `to:` of `drag` are the first side's extent measured from the parent rect's leading edge along the axis (the seam's start, not its centre). A host subtracts `parent.x` (or `y`) from the pointer.
- **Resize verbs.** `nudge(_:toward:by:in:)` moves the divider on the pane's `toward` edge (the opposite one when the pane touches the window there) by that many points in that direction; `grow(_:along:by:in:)` is vim's grow/shrink; `resize(_:_:step:in:)` maps the chords: `KeyAction.resizeSplit(.right)` wider, `.left` narrower, `.down` taller, `.up` shorter. Steps are `PaneSizing.keyboardStep` (16) and `keyboardStepLarge` (64).
- **Promote on the main pane** swaps it with the first pane of the root's other side and follows the new main (dwm's zoom), so the same key toggles two panes.
- **Zoom.** Every structural verb (`swap`, `promote`, `rotate`, `move`, `moveToEdge`) clears the zoom as `exchange` does; `arrange` keeps it; `cycleFocus` unzooms when it moves (as `focusNeighbor` does) and skips only panes hidden for `.noRoom`.
- **Never-focused panes** (an arrangement focuses only its first pane) are hidden before any focused pane, the later in reading order first.
- **Arrangements.** `mainTop` is built and read back but is not in the `ctrl+w a` cycle (`SplitArrangement.cycle`: columns, rows, grid, main and stack) nor in bulk offers; for three chats the offer is the three old shapes then main and stack. `shape(of:)` reads one pane beside a line of the other axis as `mainStack`/`mainTop`, so a hand-built "split right, then split the right pane down" now reads as main and stack rather than grid.
- **Snapshot.** `SplitSnapshot` moved to `Tiling/SplitSnapshot.swift` with its public API and key unchanged; it is built from `contents` (the four-dictionary initialiser migrates, a pane named twice takes draw, then page, then video, then chat, as the Linux restore did). The truncation is reported by `SplitSnapshot.decodeReporting(_:)` (`droppedPanes`); `decode(_:)` returns the truncated snapshot.
- **`TrailingWriter<Value>`** (`Tiling/TrailingWriter.swift`) is the generic coalescing writer behind `LayoutStore.schedule`: newest value wins, one write `delay` (0.25 s) after the last schedule on its own utility queue, `flush()` writes synchronously and in order.
- **Pane moves.** `PaneMovePayload` (`application/x-tailscode-pane`), `PaneMoveIntent` (`.swap`, `.move`), `PaneDropTarget.move(_:onto:zone:)`, `PaneDropZone.moveVerb` and `SplitLayout.apply(_:)`.

## 5. Core runtime

### 5.1 Primitives

```swift
public protocol HostClock: Sendable {
    func now() -> TimeInterval
    func requestDrain()
}

public final class LatestWins<Value: Sendable>: @unchecked Sendable {
    public func post(_ value: Value) -> Bool
    public func take() -> Value?
}
```

`post` overwrites the slot and returns `true` only on the clean-to-dirty transition, so the caller schedules exactly one wake. `take` is O(1).

```swift
public final class SingleFlightPump<Input: Sendable, Output: Sendable>: @unchecked Sendable {
    public init(work: @escaping @Sendable (Input) -> Output,
                deliver: @escaping @Sendable (Output) -> Void)
    public func offer(_ input: Input)
    public func cancel()
}
```

At most one `work` runs; offers during a run replace the pending input; when work finishes it runs again from the latest input if one is pending. CPU is bounded by one build per pane and a stale state is never built. A process-wide gate limits concurrent builds to `max(1, cores / 4)`.

```swift
public final class TileDrain: @unchecked Sendable {
    public init(clock: HostClock, budget: TimeInterval)
    public func register(_ slot: DrainSlot) -> DrainToken
    public func run(until deadline: TimeInterval)
}

public struct DrainSlot: Sendable {
    public let pane: PaneID
    public let priority: DrainPriority
    public let minInterval: TimeInterval
    public let hasWork: @Sendable () -> Bool
    public let apply: @Sendable () -> Void
}
```

`DrainPriority`: `focused`, `attention` (needs you or failed), `full`, `glance`. `run` applies slots in priority order, rotating the start within a class so peers do not starve, skips a slot whose `minInterval` has not elapsed (glance rate), always runs at least one ready slot, and stops at the deadline. A leftover marks the drain pending again. **Settled means silent:** with no dirty slot there is no tick, no timer and no wake.

`TileDrain.run(until:)` returns a `DrainOutcome` (applied panes, ready leftovers, and `wakeAt` when only a slot's `minInterval` holds it back, so the host arms one timer instead of draining every frame); `run()` uses the drain's own budget from now; `update(_:to:)` changes a registered slot's priority in place; a `DrainToken` cancels idempotently. `SingleFlightPump.init` takes the `BuildGate` (default `.shared`).

### 5.2 ConversationHub

One live conversation per `(profile, session)`, process-wide.

```swift
public struct LiveKey: Hashable, Sendable { public let profileID: String; public let sessionID: String }

public enum LiveInterest: Int, Comparable, Sendable { case watching, glance, full }

public protocol LiveEdges: Sendable {
    func observe(_ key: LiveKey, _ state: ConversationState)
}

public final class ConversationHub: @unchecked Sendable {
    public init(open: @escaping @Sendable (LiveKey) async -> AgentConversation?,
                clock: HostClock, edges: LiveEdges)
    public func lease(_ key: LiveKey, interest: LiveInterest,
                      dirty: @escaping @Sendable () -> Void) -> LiveLease
}

public final class LiveLease: @unchecked Sendable {
    public func take() -> LiveFrame?
    public func set(interest: LiveInterest)
    public func cancel()
}

public struct LiveFrame: Sendable { public let state: ConversationState; public let sequence: UInt64 }
```

- The hub owns the single `AgentConversation` per key and one `states()` subscription. The Kit already fans one run loop out to many subscribers, but panes today each build their own instance (Linux `ChatPane.swift`, `MainWindow.keepWatching`; Mac `TranscriptViewController`, `MainWindowController`, `ConversationWarmer`). Two panes on one chat, or a pane plus a background watch, therefore share one reducer, one refresh chain and one persist chain.
- Each lease has a `LatestWins<LiveFrame>`; `dirty` fires once per clean-to-dirty transition and must be O(1) on any thread.
- **Shape as built.** `ConversationHub.init` also takes `grace` (default 5 s) and a `schedule` closure (default: a detached `Task.sleep`), because `HostClock` has no timer; the grace ends when the injected clock says so, and a timer that fires early re-arms. `LiveEdges` gains `needsStream(_:) -> Bool` (default `true`), the question a `watching`-only key asks, and the host calls `hub.reevaluate(key)` when its answer changes. `LiveLease` adds `hasFrame` (a drain slot's `hasWork`) and `conversation()` (the shared `AgentConversation`, for sending); the hub adds `conversation(for:)`, `latest(_:)`, `isStreaming(_:)`, `keys`, `leaseCount(_:)`. A lease releases itself on deinit. A subscription that ends on its own (an open that failed, a stream that finished) is not redialled until the next lease or reevaluation.
- **Interest** picks what the hub does, not what the consumer sees. `full` and `glance` leases keep the stream. `watching` keeps it only for edge services (a held send queue, a turn the person asked to be told about).
- **Parked panes hold no lease.** Their face comes from the list feed the sidebar already has (`AgentSession` fields via `sessionListChanges()` or the 10 s listing: running, background work, model, updated time). That feed is enough for a name, an activity face and a needs-you dot, and it costs nothing per pane. It is why parking can free the stream instead of keeping it "subscribed but not rendered".
- **Last lease out.** After a 5 s grace (so a rebalance does not redial), the hub cancels its subscription, which stops the Kit's run loop. The Kit's `stop()` cancels the persist task and can drop the last cache write; the hub accepts that (the cache is a warm start, not truth) unless the Kit exposes a flush, which the hub calls first.
- **Edge services run once per session, here.** `LiveEdges.observe` is called for every state the hub receives, once per key, regardless of how many panes show the chat. The clients implement it with the existing code, moved out of the panes: `ActivityWatch.observeConversation` and notifications, `TurnHandoff`, the send-queue drain, presence ledger. This removes duplicate notifications and the duplicate-drain hazard.
- **Atomic drain.** `SendQueueStore` gains `takeFirst(profileID:sessionID:) -> QueuedSend?` under the existing locks plus an advisory `flock` on `queue.json.lock` (also taken by every write), reading the queue fresh from disk so another process's write is seen; today's read, `takeFirst`, `save` triple is not atomic, and a pane plus a background watch can send the head twice. The hub is the only caller.
- **opencode connection cost.** claude-bridge multiplexes one socket per server (`BridgeStream`). opencode opens one SSE connection per `events(for:)`, each decoding the server's entire event firehose and filtering. N distinct opencode chats are N connections no matter what the hub does. The hub still halves the problem (one per session, none for parked panes), and the Kit follow-up is an `OpenCodeEventHub` that shares one SSE per server the way `BridgeStream` does. It is a separate project, listed in section 12.

### 5.3 GlanceReading

A glance reads at most the last three messages plus the turn in flight, never the whole transcript.

```swift
public struct GlanceReading: Sendable, Equatable {
    public let activity: ActivityKind?
    public let session: SessionPresence
    public let tail: String
    public let question: String?
    public let model: String?
    public let effort: String?
    public let turnStartedAt: Date?
    public let queued: Int
    public let background: BackgroundWork?
    public func tail(maxChars: Int) -> String
}
```

- `activity` is `ActivityKind.inFlight(in:)` (bounded by the turn); `session` is `SessionPresence.reading(state, step:)`.
- `tail` is plain text: inline markdown marks stripped, a code fence shown as one `⟨code⟩` line, the last 600 characters cut at a word boundary. `tail(maxChars:)` lets the host ask for exactly the width × lines it can show.
- `question` is the awaiting `AskUserQuestion` text, or the pending permission's one-line summary.
- `effort` is the level word the answer was asked for in (`ChatMessage.reasoningEffort`): `ModelEffort` is a caseless namespace of rules, not a value, so the level travels as the model's own spelling and the host reads its heat through `EffortVocabulary`. The turn's start and model are looked for within the last 64 messages.
- **Excluded on purpose:** `SessionSpend` and an estimated `ContextFill` are O(n). A glance shows `ContextFill` only when the reverse scan finds a reported value (cheap), and never spend.

### 5.4 Density and the governor

`TileGovernor` is a mutating value type driven by an injected clock, like `StreamCadence` and `ActivityWatch`.

```swift
public struct GovernorSample: Sendable {
    public var loopBusy: Double
    public var worstStall: TimeInterval
    public var host: HostPressure
    public var ownMemory: Double?
    public var thermal: ThermalState
    public var lowPower: Bool
    public var reducedMotion: Bool
}

public struct PaneFacts: Sendable {
    public var id: PaneID
    public var kind: PaneKind
    public var focused: Bool
    public var placed: Bool
    public var width: Double
    public var height: Double
    public var attention: PaneAttention
    public var lastTouched: TimeInterval
    public var pinned: Bool
}

public struct GovernorDecision: Sendable {
    public var level: ShedLevel
    public var densities: [PaneID: PaneDensity]
    public var animation: AnimationBudget
    public var rowWindows: [PaneID: Int]
    public var reasons: [ShedReason]
}

public struct TileGovernor: Sendable {
    public mutating func evaluate(now: TimeInterval, sample: GovernorSample,
                                  panes: [PaneFacts], setting: LiveBudget) -> GovernorDecision
}
```

**Density assignment**, in order:

1. Hidden, zoomed-away, overflow and window-occluded panes are `parked`.
2. A chat pane under the full threshold (4.2) is `glance`.
3. The focused pane is `full` (if its kind supports it).
4. Remaining `full` slots, up to the level's budget, go to: needs-you or failed panes first, then panes with a running turn the person touched in the last 60 s, then most recently focused. Pinned panes sort first and count against the budget, but are ignored at level 3 and above.
5. Everything else that is a chat is `glance`.
6. A promoted pane stays `full` for at least 8 s unless the budget drops (dwell), so a busy turn does not make panes trade places.

**As built.** `GovernorSample` also carries `occluded` (minimized or suspended: chats and videos park) and `watchdog` (the stall hint that jumps to 4). `PaneAttention` is `quiet < running < failed < needsYou`. `GovernorDecision` also carries `transition` (`shed a→b reason`, for the recorder), `fullBudget`, `liveChats` and `chats` (the chip's numbers) and `preferenceOverridden` (the chip says a pin or `Keep all live` was ignored); `rowWindows` omits the focused pane, which uses the person's preference. The full-density threshold is an injected `FullDensityRule` (280 × 200, +16) until the host connects it to `PaneSizing`. Ranking for the remaining full slots is pinned (below level 3), then a pane still inside its 8 s dwell (unless the budget dropped since the last evaluation), then needs-you or failed, then running and touched in the last 60 s, then most recently touched. An explicit setting (`count(n)` or `all`) replaces the automatic budget at levels 0–2 and is capped at 1 from level 3. The sustain timers restart at each escalation, so each further step needs a fresh sustained period. The doubled relax delay returns to 20 s after ten minutes without an escalation. `TileGovernor.hold(atLeast:until:)` is the safe restore's floor. A tick cap of 0 means no pane clocks and a glance rate of 0 means frozen.

**Shed levels.** `base = clamp(cores / 4, 2, 4)`; the setting `Auto | 1…6 | All` overrides `base` but never exceeds the level's cap at 3 and above.

| Level | Name | Full budget | Cascade reveal | Tick cap | Glance rate | Peer row window |
|---|---|---|---|---|---|---|
| 0 | calm | base | on (focused only) | 30 fps | 4 Hz | 150 |
| 1 | busy | max(2, base − 1) | on (focused only) | 30 fps | 2 Hz | 100 |
| 2 | loaded | 1 | instant | 20 fps | 1 Hz | 60 |
| 3 | strained | 1 | off, pulses off | 10 fps | 0.5 Hz | 0 |
| 4 | critical | 1 | off | none | frozen; wake on needs-you | 0 |

**Transitions** (constants in Appendix C):

- Escalate one level when the 2 s loop-busy average is at least 0.65 for 3 s. Escalate two when it is at least 0.85 for 1.5 s or a stall of 250 ms or more happens. At most one escalation per 2 s.
- Relax one level after 20 s below 0.30, at most once per 15 s. After two escalations inside two minutes the relax delay doubles, up to 120 s. This stops promote, load, demote oscillation.
- Floors: host memory strained floors at 2, critical at 4; own memory at or above 70% of the memory-high limit floors at 2, at or above 90% at 4 with `MemoryRelief`; thermal serious floors at 2, critical at 4; low-power mode floors at 1.
- The watchdog (5.5) can jump straight to 4.
- Every transition logs `level a → b` and its reason to the recorder.

**Visible state.** The window chrome carries one quiet chip, `Live 2 of 5`; when level > 0 it reads `Live 2 of 5 · busy` (or `· memory`, `· warm`), and its popover explains and offers `Keep all live` (ignored at level 3+, and says so). Demoted panes wear a `Glance` or `Paused` badge on the identity strip; pinned panes wear a pin. Nothing about the state is hidden.

**Demotion mechanics.** Demoting a chat from full to glance detaches its body from the shell but keeps the pane object alive for 20 s (cheap re-promotion), then releases it (rows, widgets, Pango layouts). Promotion restores the row window lazily through the existing earlier-rows machinery. A demoted pane gives up its clocks immediately (I3).

### 5.5 Sensors

All sensors feed `GovernorSample`; the platform pieces are in sections 7 and 8.

- **`LoopLoad`.** The platform reports `idle` and `busy` slices; Core keeps a 1 s and a 2 s window and exposes `busy` ratio and `worstSlice`. Linux wraps the poll function (`g_main_context_set_poll_func`), so busy equals wall minus time inside `g_poll`. The Mac uses a `CFRunLoopObserver` on before-waiting and after-waiting.
- **`StallWatchdog`.** A helper thread pings the loop every 500 ms. No answer for 3 s: write a recorder line with the main thread's state and CPU ticks (Linux reads `/proc/self/stat` and `/proc/self/task/<pid>/wchan`, the Mac uses `thread_info`), set an atomic hint the loop applies as level 4 the moment it resumes. No answer for 10 s: write a deep record. The watchdog never touches UI.
- **`HostPressure`** (`nominal`, `strained`, `critical`). Linux: `/proc/pressure/memory` (`some avg10 ≥ 20` strained, `full avg10 ≥ 5` critical) and `MemAvailable` (< 12% strained, < 6% critical), polled at 1 Hz. Mac: `DispatchSource.makeMemoryPressureSource` (`.warning`, `.critical`), plus `task_vm_info.phys_footprint` against `min(8 GiB, 0.15 · physical)`. Thresholds start conservative and are tuned from recorder data.
- **Own memory.** Linux reads the app's cgroup `memory.current` and `memory.high` (`/sys/fs/cgroup<path>`) when readable, else `/proc/self/statm` against fractions of `MemTotal`. Mac uses `phys_footprint`.
- **Thermal and low power.** Mac: `ProcessInfo.thermalState`, `isLowPowerModeEnabled`. Linux: neither (not read).

### 5.6 MemoryRelief

A registry of `evict(level)` handlers. At level 3 handlers trim to half their cap; at 4 they empty. Registered: `ImageCache`, `MediaImageCache`, Pango markdown and syntax caches, `rememberRows` / `sessionRows` (6 sessions), the Mac's kept pages (3 per pane), `ConversationWarmer`, glance readings of parked panes. Every cache that does not register fails I6 review.

### 5.7 FlightRecorder

The black box that answers the next freeze.

- **File.** A fixed-size ring of 192-byte ASCII slots (JSON, space-padded, newline-terminated), 3600 slots (≈ 675 KB, about an hour at 1 Hz). Each record carries a monotonic `n`; the reader finds the maximum. No index to corrupt.
- **Write.** `pwrite` to slot `n % 3600`, then `fdatasync`, once per second, plus immediately on a level change or a stall. At most one second is lost to a hard freeze.
- **Location.** Linux: `$XDG_STATE_HOME/tailscode/flight.ring`. Mac: `~/Library/Logs/Tailscode/flight.ring` (inside the sandbox container for the store build).
- **Record.** `t` (epoch ms), `n`, `rss` (KiB), `thr`, `fds`, panes by density (`f/g/x`), `lv` (level), `busy`, `stall` (ms), `mb` (deepest mailbox), `dr` (drain p95 ms), `ps` (PSI some/full or pressure enum), `av` (available MB), `own` (fraction of limit), `rl` (relayout ms during drags), `ev` (event string: `shed 1→2 busy`, `stall 3200ms D`, `relief`, `restore unclean`).
- **Encoding as built.** Keys in write order: `t`, `n`, then `lv`, `busy`, `stall`, `rss`, `p` (panes as `"full/glance/parked"`), `ps`, `av`, `own`, `mb`, `thr`, `fds`, `dr`, `rl`, then `ev`; nil fields are omitted. A full record does not fit 191 bytes with every field and an event, so the event keeps its first 32 characters and the fields are dropped from the tail of that list (`rl` first) until it fits; the event is then given whatever room remains. Slots are printable ASCII, so `→` is written `->` and anything else non-ASCII as `?`. The header uses `ver`, `tk`, `gsk`, `gl` (24 characters each) with `ev:"launch"`. `FlightRing.write(_:sync:)` numbers the record itself; `FlightRing.read(url:last:)` reads a ring another process is writing; a slot whose `n % slots` is not its index is treated as torn.
- **Launch header record.** App version, GTK/AppKit version, and on Linux the GSK renderer type name (`G_OBJECT_TYPE_NAME` of the surface's renderer) and the GL vendor. What renderer the installed app actually uses on this machine is currently unverified; the recorder settles it.
- **Privacy (I10).** No titles, ids, paths or text.
- **Reading.** `tailscode --flight [minutes]` (and `TailscodeMac --flight`) prints the ring decoded, newest last; Settings ▸ Diagnostics offers Copy. A clean exit appends `ev:"exit clean"`.

### 5.8 SafeRestore

A `LaunchLedger` (`launch.json` next to the ring) holds `{launchID, startedAt, cleanExit, panes, level}`. It is written at launch with `cleanExit:false` and flipped to `true` on every exit path (`SettingsFile.flush()` on Linux, `applicationWillTerminate` on the Mac). The decision is a pure function `RestorePlan.decide(ledger, snapshot)`.

- **As built.** The ledger also carries `previousUnclean` (whether the launch before it ended unclean), set by `LaunchLedger.begin(url:panes:level:now:)`, which reads the previous ledger and writes the new one with `cleanExit:false`; `markClean(url:launchID:)` flips only its own launch's ledger. The decision is `RestorePlan.decide(ledger:paneCount:previousUnclean:)` (or `decide(ledger:paneCount:)` reading the streak from the ledger) and returns `mode` (`staggered` or `parked(bannerCount:)`), `unclean`, and `floor` (`.loaded`, level 2) with `floorDuration` 600 s, which the host passes to `TileGovernor.hold(atLeast:until:)`. `RestorePlan.wakeSchedule(focused:recent:)` returns `(pane, offset)` pairs 300 ms apart. Dates are encoded as epoch milliseconds.
- **Clean previous exit.** Restore the shape at once, then wake panes staggered: focused first, then the rest in most-recently-focused order, 300 ms apart, each into the density the governor assigns. A restore never opens N streams in one frame.
- **Unclean exit with three or more panes.** Restore the shape with every chat pane `parked` and a banner in the canvas: "Tailscode didn't close normally last time. 5 chats are paused." with `Resume all` and `Resume one by one`. A second unclean exit in a row also floors the shed level at 2 for ten minutes. This breaks a freeze loop in which relaunch recreates the exact load that froze the machine.
- **Unclean exit, one or two panes.** Restore normally (staggered).
- Restore never waits on the network to draw the window's shape (unchanged).

### 5.9 PaneLifetime

```swift
public final class PaneLifetime: @unchecked Sendable {
    public func add(_ cancel: @escaping @Sendable () -> Void)
    public func cancelAll()
}
```

Every tick id, timer, `Task`, observer token and lease a pane creates is registered. `cancelAll` runs on `shutdown`, on demotion to parked and when the pane is hidden. This closes the leaks the audit found (`resumeTask` and `canvasSettle` survive `shutdown`; `FreshCanvasScroll` retains the scroller until its rise finishes).

## 6. Tiles

### 6.1 TileShell

The generic chrome, one per pane, owned by the host and independent of content: identity strip (title, activity face, density badge, pin), focus ring, drop target, the body slot, and the accessibility element. Chat, slots, glance and parked faces are bodies. `ChatPane` stops being the universal pane.

- **Content swaps are explicit.** `TileShell.setContent(_:)` shuts the old body down (cancelling its `PaneLifetime`) before the new one is built. Today a pane turned into a slot keeps its chat stream running hidden, and opening a chat into a slot pane leaves the slot showing; both are latent bugs the shell removes.
- **PaneHost protocol.** The roughly 35 `host.` uses in `ChatPane.swift` (and the Mac's `makePane` closures plus its responder-chain reach into `MainWindowController`) become one narrow protocol: window and dialog parent, toasts, shortcut table and pending chords, sidebar and rows cache, watching, fleet and quota data, chat actions, lane doors. The Mac keeps the responder-chain path working (`view.window?.windowController`) while the closures move behind the protocol.
- **Identity strip** shows only when more than one pane exists (as today). New: the density badge and pin, and `also open in pane 3` when two panes show one chat.
- **Focus ring and press routing are unchanged in meaning.** A press is routed from the toplevel before the widget under the pointer acts; a divider, a hidden pane and the chrome between panes activate nothing.

### 6.2 Full tile

A chat pane in `full` density is today's pane with these changes:

- It gets states from a hub lease, not its own `AgentConversation`. Linux builds rows through a `SingleFlightPump` off the main thread; the Mac builds on the main thread inside the drain's budget (its builder memoises per message by equality, the per-state cost is small, and the Mac pane is `@MainActor`); moving Mac builds off-main is a follow-up only if `--bench-tiles` shows more than 4 ms.
- Applying a state happens in `TileDrain.apply`, never from a per-state main-thread post.
- The cascade reveal runs only in the focused pane. Peers at `full` show text at arrival granularity. The shim's reveal parse cache is keyed per label (not one process-wide entry), so two reveals never evict each other.
- Row windows follow the governor: focused uses the person's `transcriptWindow` preference, peers use 150/100/60 by level. Total realised row widgets in a window are capped at 1200 plus the focused pane's window.
- Per-pane clocks are gated by the governor's tick cap and registered in the pane's `PaneLifetime`.
- The 1 s ticker and its subagent, usage, spend and git refreshes run only for `full` panes.

### 6.3 Glance tile

A status tile that reads like a peek at the conversation. Minimum 200 × 88; it is content-layer (palette-owned, no glass).

```
┌──────────────────────────────────────────┐
│ ◉ Fix the paged export          Glance   │  header 24 pt: activity face · title (semibold) · badge
│ …reading the failing test, the pager     │  tail: last words, bottom-anchored, 2…8 lines
│ clamps the offset before the query       │
│ ▮▮▯▯▯ opus   2:41   ⏳2   ⚙ 1            │  footer 18 pt: model dot + effort bars · turn clock · queue · background
└──────────────────────────────────────────┘
```

- Face, tone and motion are `ActivityKind`'s, driven by the shared clock at the activity tempo; a settled pane holds perfectly still. Reduced motion drops the movement and keeps glyph, word and colour.
- Tail text is `GlanceReading.tail(maxChars:)` with `maxChars = columns × lines` from the tile's own size, wrapped and ellipsised by the toolkit. It updates at the level's glance rate, with no per-glyph reveal and no animation.
- When the turn is waiting on you, the tail is the question (or the permission's summary) in the attention tone and the footer reads `Answer…`.
- **Interaction.** Press: focus and promote to full (if the budget is full, the least recently used full peer drops to glance). Double-click: zoom. Context menu: Open full, Keep live, Pause, Close, plus the pane menu. Hover shows the same actions as small buttons. There is no input field in a glance; a field is cost and an accessibility burden for something one press away.
- Type uses existing `TypeRole`s (title, answer-at-caption-size, tabular label). A new role goes into `Typography.spec` with a `TypographyTests` claim; no client invents a size.
- Accessibility: one group element labelled "Pane 2 of 5, <title>, <activity word>, <first line of tail>"; the action buttons are real controls.

### 6.4 Parked tile

No stream, no clocks. It shows the title, the activity face from the list feed, the last glance reading kept in memory for 10 minutes (dimmed, with its age), and `Resume`. A needs-you or finished state arrives through the list feed and the existing turn-wait machinery, never through a pane stream. Resuming takes a hub lease; if the budget is full it joins as glance.

### 6.5 Slots

- Web and draw: `full` while placed, `parked` while hidden (the page or the painter is shut down and its address kept, as the snapshot already does).
- Video: libmpv draws into a `GtkGLArea` on Linux, and a continuously rendering `GtkGLArea` leaks about 70 MB/min inside the NVIDIA EGL driver on this machine. At most one video plays per window, only while visible and unzoomed-away; every other video slot is paused with its poster. The Mac plays through AVKit and follows the same one-playing rule.
- Draw is a gap on the Mac in both builds; a restored `.draw` content restores as an empty pane there, as today.

### 6.6 Overflow strip

Shown when `hidden` is non-empty: 28 pt at the bottom of the canvas, one chip per hidden pane (activity face, title truncated to 18 characters, a needs-you dot), `+N` when chips overflow. Press: focus the pane (unzoom if zoomed, or swap it in for the least recently focused placed pane when there was no room). On the Mac it is a glass capsule (chrome); on Linux a plain bar in the palette.

### 6.7 Restore banner

A non-modal strip at the top of the canvas (not a toast: it must wait for the person). Text and the two buttons from 5.8, a dismiss control, and it never covers a pane's composer.

## 7. Linux

### 7.1 Window

Unchanged outside the tree: `AdwApplicationWindow` → `AdwToastOverlay` → vertical `GtkPaned` (top: horizontal `GtkPaned` of sidebar and content; bottom: terminal) → content `AdwToolbarView` → the container. The container is now `TileCanvas` instead of `GtkOverlay` + `treeBox` + nested paned. `holdSidebarFloor` (190) stays. The window has no minimum size today; the canvas reports a small minimum (220 × 120 plus the strip) so any window size is valid and the placement hides panes instead of overflowing.

### 7.2 TileCanvas

A `GtkWidget` subclass and a `GtkLayoutManager` subclass in C, in a new `tile.c` / `tile.h` inside the `CGtkShim` target (SwiftPM compiles it alongside `shim.c`). The shim already defines custom GObject types (`TailscodeSurfacePaintable`, the pattern to copy); it has no widget or layout-manager subclass yet. Swift cannot subclass GObject.

```c
GtkWidget *tailscode_tile_canvas_new(void);
void tailscode_tile_canvas_set_solver(GtkWidget *canvas, TailscodeTileSolve solve, void *box);
void tailscode_tile_canvas_set_minimum(GtkWidget *canvas, int width, int height);
void tailscode_tile_canvas_add(GtkWidget *canvas, GtkWidget *child, int layer);
void tailscode_tile_canvas_remove(GtkWidget *canvas, GtkWidget *child);
void tailscode_tile_canvas_invalidate(GtkWidget *canvas);
void tailscode_tile_sink_place(TailscodeTileSink *sink, GtkWidget *child, int x, int y, int w, int h);
```

- `measure` returns the configured minimum and a natural size of zero (the canvas expands).
- `allocate` calls the Swift solver with `(width, height, scale 1)`; the solver is Core's placement, pure and microseconds, and reports each placed child through the sink. For every child: placed → `set_child_visible(TRUE)` and `gtk_widget_allocate(child, w, h, -1, gsk_transform_translate(NULL, &(graphene_point_t){x, y}))`; not placed → `set_child_visible(FALSE)`.
- **Layers by sibling order**: pane shells first, dividers above, overlays (drop highlight, strip, banner) last, so an overlay can never be hidden by a pane. Reordering uses `gtk_widget_insert_before`.
- **`dispose` unparents every child** (the standard GTK4 custom-container requirement, and the root of the `GtkPaned` double-release SEGV).
- Pane shells set `gtk_widget_set_overflow(HIDDEN)`: a square clip. **No shadow, blur, opacity below one, filter or rounded clip** on a pane shell or divider; each forces an offscreen render per pane under the GL renderers and is a texture tax under cairo. Which renderer the installed app uses is unverified; the rule holds for all.
- **No `GtkGLArea` in the canvas** except the single playing video pane.
- `Gtk.detachFromParent` gains a canvas case (`tailscode_tile_canvas_remove`); the paned branches stay for the sidebar and terminal paneds.
- There is **no re-parenting**: a pane shell is added once and removed once. A debug counter increments on any add of a widget that already has a parent and the selftest asserts zero across a hammer run.

### 7.3 Dividers

Each divider is a 9 pt-wide (or tall) child with a centred 1 pt line (`Gtk.hairline` in the palette's separator colour), a `GtkGestureDrag`, a resize cursor (`gtk_widget_set_cursor_from_name` with `col-resize` / `row-resize`; the shim has no cursor helper beyond `pointer`, so add one) and `can_focus`.

- **Pointer.** `drag-update` converts the offset to a parent-space coordinate and calls `SplitLayout.drag`, then `tailscode_tile_canvas_invalidate`. Hover and active draw a 2 pt accent line. Double-click equalizes (the paned double-click helper's behaviour, now on the divider).
- **Live or ghost.** Relayout of a pane's transcript is height-for-width over every realised row widget (the transcript is a plain `GtkBox`, not virtualised). The canvas measures the last relayout. Under 8 ms it commits live every frame; over 8 ms it moves a 2 pt ghost line with the pointer and commits once on release. The decision is adaptive per drag, the measurement goes to the recorder (`rl`), and M3 acceptance requires relayout of a 400-row pane to be measured and the threshold set from that number, not this one.
- **Keyboard.** A focused divider: arrow keys call `nudge` (16 pt, shift 64), Home and End go to the extremes. The press-routing capture at the toplevel still sees the press first and answers "no pane", as intended.
- **Accessibility.** Role `GTK_ACCESSIBLE_ROLE_SEPARATOR` with `VALUE_NOW`, `VALUE_MIN`, `VALUE_MAX` (percent of the extent) and a label ("Divider between pane 1 and pane 2"), updated through `gtk_accessible_update_property` (the shim wraps `tailscode_set_accessible_label`; add the value properties).

### 7.4 Sensors and limits

- **Loop meter.** Install `g_main_context_set_poll_func` at startup with a wrapper that timestamps entry and exit of `g_poll`. Busy equals wall minus time in poll; worst slice is the longest span between poll returning and the next poll call.
- **Drain.** `TileDrain` runs from a `GSource` at `GDK_PRIORITY_REDRAW + 10`: below the paint, so it takes the gap between frames and cannot starve painting. A 100 ms `g_timeout` at `G_PRIORITY_DEFAULT` is the starvation guard: if the drain has not run for 100 ms it runs one ready slot, so a stream's ending state can never queue behind an animation forever (the bug `tailscode_on_main`'s comment records). Latest-wins makes the guard cheap and harmless: skipped states are simply never built.
- **Watchdog.** A pthread; reads `/proc/self/stat` and `/proc/self/task/<pid>/wchan` on a stall.
- **Pressure.** Read `/proc/pressure/memory` and `/proc/meminfo` at 1 Hz on the watchdog thread; deliver to the governor through the host clock. `/proc/pressure` availability inside Flatpak is unverified; a missing file means `nominal`.
- **Occlusion.** `GDK_TOPLEVEL_STATE_MINIMIZED`, and `GDK_TOPLEVEL_STATE_SUSPENDED` (the enumerator exists in the installed 4.22 headers; its availability tag and whether KWin sets it are unverified, so it is a bonus signal, not a dependency). Occluded means all chat panes park.
- **Resource limits.** `ResourceGuard.apply()` at startup, before the window:
  1. Parse `/proc/self/cgroup`. If the unit is `app-io.github.guitaripod.Tailscode-<n>.scope` (or `.service`), the app owns it. KDE names launcher scopes `app-<desktop-id>-<pid>.scope`; `install-linuxapp.sh` restarts into `app-io.github.guitaripod.Tailscode-$$` explicitly. A terminal launch lands in the terminal's scope; **never touch that**: skip, and rely on the in-process governor.
  2. Read the unit's `MemoryMax`; if it is finite, an administrator set it: leave everything alone.
  3. Otherwise call `org.freedesktop.systemd1.Manager.SetUnitProperties(unit, runtime=true, [...])` over the session bus (GIO's D-Bus is already linked), with `MemoryHigh`, `MemoryMax`, `MemorySwapMax=0`, `CPUWeight=60`, `TasksMax=4096`. Verified on 2026-10-05 on this machine: `systemctl --user set-property --runtime` from inside a throwaway `app-…` scope applied unprivileged and the cgroup's `memory.max` file changed; a prefix drop-in `app-<id>-.scope.d/*.conf` in `~/.config/systemd/user/` also applied to a transient scope with a matching name. The D-Bus call itself is untested and gets a test in M0; the `systemctl` command (spawned) is the fallback.
  4. Values: `MemoryHigh = clamp(0.10 · MemTotal, 2 GiB, 8 GiB)`, `MemoryMax = clamp(0.16 · MemTotal, 3 GiB, 12 GiB)` (6.2 GiB and 9.9 GiB on this 62 GiB machine). `MemoryHigh` throttles instead of killing; `MemoryMax` kills the app's cgroup, not the desktop. `MemorySwapMax=0` stops the app from turning a leak into swap thrash.
  5. Opt-out `TAILSCODE_NO_LIMITS=1`; `tailscode --limits` prints what was applied and why.
- **Flatpak.** The sandbox cannot reach the user manager; only the in-process governor applies. Stated, not hidden.
- **After a kill.** The app vanishes (the desktop does not). The next launch sees an unclean ledger and restores parked (5.8).

### 7.5 Content

- `ChatPane` gains the `PaneHost` protocol, the hub lease, `PaneLifetime`, density hooks (`setDensity`, `setRowWindow`, `setLiveResize`) and loses `showWeb/showVideo/showDraw/showChooser` to `TileShell` bodies. The identity label moves to the shell.
- New `GlanceTile`, `ParkedFace`, `OverflowStrip`, `RestoreBanner` (GTK widgets, CSS in `MatrixTheme`), `TileHost` (replaces `SplitHost`, same public surface so `MainWindow` changes are small: `activePane`, `orderedPanes`, `pane(showing:)`, `splitActive`, `split(_:edge:)`, `collapse`, `closeActive`, `focusNeighbor`, `zoomActive`, `exchangeActive`, `equalize`, `pane(at:in:)`, `focus`, `restore`, `snapshot`, `persist`, plus the new verbs).
- `rememberDividers` stops capturing ratios on the 10 s refresh loop; ratios are written when a drag moves.
- `SessionListCache.save` on the GTK thread becomes a coalesced off-main write (Core already has `scheduleSave`, which is `@MainActor` and so unusable from the GTK paths; add a non-actor variant with the same 2 s coalescing).
  As built: `SessionListCache.enqueueSave(_:)` and `flushEnqueuedSave()` (call it on every exit path); the write runs on a serial utility queue, newest list wins.
- Press routing (`onPressCapture` → `pressLanded` → `TileHost.pane(at:)`) is unchanged; `Gtk.contains` already returns false for unmapped (hidden) panes.
- Keyboard: `installKeymap`'s ctrl+w dispatch gets the new `perform` cases.
- **Linux localization:** `Localized.text` resolves through `Bundle.main`; whether the Linux build ships translations is unverified (no catalog wiring found in `Package.swift` or the packaging scripts). New strings are written through `Localized.text` and added to the catalog for the Apple clients regardless.

### 7.6 Linux: what "good" means

- A 5-pane layout at 1600 × 1000 under the harness: the main loop busy ratio stays under 0.35 with 5 chats streaming 80 tokens/s into 600-row transcripts (Appendix C budgets); no stall over 120 ms; RSS slope under 5 MB/min after warm-up; thread and fd counts flat.
- A split, close, exchange or zoom never constructs more than the new pane's shell and never re-parents.
- Window shrink to 700 px with three side-by-side panes hides the least recently used pane into the strip and brings it back on growth, with ratios intact.
- `geom`, `handles`, `splits` drive verbs read the canvas (rects, divider centres, hidden list) so the harness can aim a real XTEST drag at a divider.
- Wayland and KWin specifics the harness cannot show (it is X11, cairo, llvmpipe, no AT-SPI): fractional scale (allocations are integer logical pixels; GTK scales), real pointer cursors, configure timing, AT-SPI. These are validated by hand on the real desktop with the recorder running (10.5).

## 8. macOS

### 8.1 Window

Keep the outer structure: window → outer `NSSplitViewController` (sidebar item: `NSSplitViewItem(sidebarWithViewController:)`, 240–400 pt scaled by `UIScale`; content item) → `contentSplit` (vertical: tile host above, `TerminalPane` below, terminal compiled out of the store build). The unified toolbar's `.sidebarTrackingSeparator` binds to the outer split's divider, so replacing only what is inside the tile host leaves it intact. `contentMinSize` stays 640 × 420; placement guarantees any content size is valid.

### 8.2 TileCanvasView

`TileHost: NSViewController` keeps `SplitPaneHost`'s public surface (`bootstrap`, `active`, `panes`, `paneCount`, `orderedPanes`, `pane(showing:)`, `eachPane`, `splitActive(axis:)`, `split(_:edge:)`, `collapse(to:)`, `closeActive`, `focusNeighbor`, `zoomActive`, `exchangeActive`, `equalize`, `pane(atWindowPoint:)`, `focus(_:grabKeyboard:)`, `restore`, `snapshot`, `persist`, `applyFocusStyling`, the host callbacks `makePane`, `onPaneOpened`, `onFocusChanged`, `onLayoutChanged`, `onChatDropped`, `chatTitleForDrop`) plus the new verbs. Its view is `TileCanvasView`:

- A flipped, layer-backed, **full-bleed** `NSView`. It places pane shells by frame in `layout()` from Core's placement (no Auto Layout between panes; pane roots set `translatesAutoresizingMaskIntoConstraints = true` and keep their own internal constraints, the same pattern `RowHost` uses in `TranscriptColumn`). A frame is set only when it changed.
- No `NSSplitView`, no `NSSplitViewController`, no `NSSplitViewItem` inside the tree. The Parity anchors `"SplitPaneHost"`, `"showChooser"`, `"onChatDropped"`, `"pressLanded"` and `"NSSplitViewItem(sidebarWithViewController"` must keep appearing in Mac files; `"SplitPaneHost"` moves to `"TileHost"` with the manifest answer updated in the same change.
- **Hide, don't detach.** Zoom and overflow hide pane views (`isHidden`), which also takes them out of `pane(atWindowPoint:)` (it skips hidden views). Nothing is removed and re-added on a structural verb, so first responder, an in-progress IME composition, scroll position, the cascade's display link and web/AV views are never disturbed (today's `rebuild()` re-parents every pane).
- **Safe area.** The pane's top inset depends on `view.safeAreaInsets.top`, which requires the canvas to be a plain full-bleed content view under the full-size-content-view toolbar region. Whether the inset flows through unchanged is unverified; M4 checks it with `--tree` and `--shot` before anything else.
- **Appearance.** Focus border colours are `CGColor`s and go stale on a palette change; the canvas re-applies on `viewDidChangeEffectiveAppearance` and on `MacTheme.Chrome`'s change (as `applyFocusStyling` is asked to today).

### 8.3 Dividers

`TileDividerView` (a 9 pt hit view over the 1 pt gutter):

- `resetCursorRects` adds `.resizeLeftRight` / `.resizeUpDown` (today the cursor comes for free from `NSSplitView`; there is no custom cursor code to reuse).
- `mouseDown` tracks the drag: each `mouseDragged` converts the point to the parent's coordinates, calls `SplitLayout.drag`, and lays out the canvas. `clickCount == 2` equalizes (the logic of `DividerSplitView.mouseDown`, moved).
- **Live always on the Mac**: `TranscriptColumn` relayout is the measured 12–26 ms per pane (not improved by the frame-placed column), so a two-pane drag is within budget. The recorder logs it, and `--bench-tiles` fails the milestone if a two-pane drag step exceeds 16 ms on the reference Mac.
- **Accessibility.** `accessibilityRole = .splitter`, `accessibilityValue` (0…1), `accessibilityOrientation`, `accessibilityPerformIncrement/Decrement` (a nudge), label "Divider between pane 1 and pane 2".

### 8.4 Live resize

The window's live resize changes every rect at once. Per pane the relayout is 12–26 ms, so four full panes cost 50–100 ms a step. During `NSWindow.inLiveResize` (`viewWillStartLiveResize` / `viewDidEndLiveResize`), the canvas tells non-focused panes `setLiveResize(true)`: they take their new frame immediately but defer re-measuring their rows (rows keep their old width and are clipped or padded), and on the end each peer relayouts once, one pane per frame. The focused pane stays live. Glance and parked faces are cheap and never defer.

### 8.5 Sensors and limits

- **Frame clock.** One `CADisplayLink` from `NSView.displayLink(target:selector:)` (macOS 14 and later; Core baseline is 15, the Mac target 26) on the canvas drives `TileDrain`; it is paused whenever nothing is dirty. `preferredFrameRateRange` follows the governor's tick cap. The pane's own cascade link (60–120 Hz today) is capped the same way and exists only for the focused pane.
- **Loop meter.** A `CFRunLoopObserver` on before-waiting and after-waiting, timestamps in mach time.
- **Watchdog.** A `DispatchSourceTimer` on a global queue pings `DispatchQueue.main`; same thresholds as 5.5; main-thread CPU ticks via `thread_info`.
- **Pressure.** `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`, `phys_footprint` from `task_info(TASK_VM_INFO)`, `ProcessInfo.thermalState`, `isLowPowerModeEnabled`. None of these are read anywhere in the Mac client today.
- **Occlusion.** `NSWindow.didChangeOcclusionStateNotification`: not `.visible` parks every chat pane.
- **No cgroup.** macOS has none; the in-process governor, `MemoryRelief` and the critical-level banner are the whole mechanism. Stated, not hidden.

### 8.6 Content

- `TranscriptViewController` conforms to the pane-body protocol: `PaneHost` replaces the `makePane` closures, a hub lease replaces its own `AgentConversation` (it also stops `ConversationWarmer` building a third instance for the same chat), `PaneLifetime` replaces the scattered task and timer fields, density hooks (`setDensity`, `setRowWindow`, `setLiveResize`) are added, and it finally learns it can be hidden (today it has no visibility handling at all: no `viewDidAppear`, no occlusion, no hidden check; a hidden pane keeps its stream, ticker and display link).
- `GlanceTileView` (content-layer, `MacTheme.Ramp` roles, `ActivityBadgeView` for the face), `ParkedFaceView`, `OverflowStripView` (an `NSGlassEffectContainerView` capsule: chrome), `RestoreBannerView`. No glass on glass: the glance tile and parked face are palette-owned content.
- The Mac `persist()` stops encoding the snapshot on every notification (4.6).
- `snapshot()` keeps recording pages under the store build while `restore` drops them (a pre-existing asymmetry): with `PaneContent` a store build restores a `.web` or `.video` content it cannot show as `.empty`, and records that it did.

### 8.7 Menu, keys, accessibility

View menu (Panes group): Split Right ⇧⌘D, Split Down ⌥⇧⌘D, Close Split ⇧⌘W, Zoom Split ⇧⌘↩, Focus Split ⌥⌘←/→/↑/↓ (all as today), plus Arrange ▸ (Columns, Rows, Grid, Main and Stack), Promote to Main, Rotate Panes, Next Pane ⌥⌘] and Previous Pane ⌥⌘[ (collisions in `MainMenu.swift` checked at implementation), Keep Live, Pause Pane, Swap Split, Even Out Splits. Items enable on `paneCount > 1` as today, and the menu reads `boundChord` for the new items instead of the static chords the existing ones use (shortcuts are rebindable). The `ctrl+w` family arrives through the registry unchanged.

VoiceOver: the canvas is a group labelled "Panes"; each shell is a group "Pane 2 of 5, <title>, <activity>" with `accessibilityChildren` in reading order (`layout.paneIDs`); a rotor ("Panes") lists them; dividers are splitters as above. Today `SplitPaneHost` has no accessibility code at all.

### 8.8 macOS: what "good" means

- Four panes streaming 80 tokens/s each into 600-row transcripts: main-thread busy under 0.35, no hitch over 100 ms in `--bench-tiles`.
- Two-pane divider drag step at most 16 ms; window live resize with four panes at most one live pane plus deferred peers, peers settle one per frame after release.
- Hiding, zooming and restoring never lose first responder or a half-typed composer.
- Both distributions: the direct build keeps web, video, terminal; the store build compiles them out and its manifest answers `.varies`.
- Sidebar tracking separator, toolbar, full screen and Stage Manager sizes unaffected; `--tree` shows no `AMBIGUOUS` flags.
- What cannot be verified from Linux: any real render, live-resize feel, glass and scroll-edge look, display-link rates, VoiceOver, sandbox behaviour. `--tree`, `--shot` and `--bench-tiles` over ssh cover geometry and numbers; the rest is a short manual checklist run on the Mac (10.5). The display must be awake (`caffeinate -u`) or animations stall.

## 9. Parity, localization, docs

**New capabilities** in `CapabilityRegistry`, each answered in all three manifests (exhaustive switch, one case per line):

| Capability | iOS | Linux | Mac |
|---|---|---|---|
| `paneDensity` (full, glance, parked; live budget chip; pin) | n/a: one conversation fills a phone | implemented (`GlanceTile`) | implemented (`GlanceTileView`) |
| `paneArrangements` (main and stack, promote, rotate, arrange cycle) | n/a | implemented | implemented |
| `paneOverflow` (hidden panes as chips; zoom shows them too) | n/a | implemented | implemented |
| `paneResizeByKey` (divider keys, nudge chords, accessible splitter) | n/a | implemented | implemented |
| `paneRearrange` (drag a pane's strip onto another) | n/a | implemented | implemented |
| `safeRestore` (unclean-exit restore parked, staggered wake) | n/a | implemented | implemented |
| `flightRecorder` (ring, `--flight`, Settings ▸ Diagnostics) | n/a: MetricKit and the log viewer already carry it | implemented | implemented |
| `resourceGuard` (launch limits where the OS allows, pressure response) | n/a | implemented, `partial` for terminal launches and Flatpak (`missing:` stated) | `.partial`: no cgroups; pressure response only |

`splitPanes`, `newPaneChooser`, `chatDragToPane` and `clickToActivate` change anchors only (`SplitHost` → `TileHost`, `SplitPaneHost` → `TileHost`); their specs gain the hidden-pane and density sentences. `scripts/parity.sh --check` gates; the capability and the three answers land in the same change as the first feature that needs them, never ahead of it.

**Localization.** Every new user-facing string goes through `Localized.text` and into `Resources/Localizable.xcstrings` with the ten translations (`extractionState: manual`, serialised so existing entries stay byte-identical; check with `git diff --patience`; the Mac is checked with `-AppleLanguages "(de)"` and `--tree`). Appendix B lists them. No completeness script exists; adding one is part of M5. A `bulk` agent does the ten translations from that list.

**Docs.** This file stays as the design record. When a milestone lands, the doctrine paragraph goes into `CLAUDE.md` Conventions (the repo's place for doctrine), the registry specs carry the behavioural contract, and the memory directory gets the war stories. `README.md` must not name release versions (the Stop hook enforces it).

## 10. Verification

### 10.1 Core tests (Swift Testing, `TailscodeCore/Tests`)

- **Placement (property, seeded LCG as `RowDiffTests` does, 200 seeds).** For random trees and sizes: rects of placed panes plus gutters tile the container exactly (area sum, no overlap, no gap); no placed rect is below its minimum; hidden panes are the least recently focused and at least the focused pane is placed; growing the container back restores the original rects; no ratio in the tree changes across a solve (I7).
- **Verbs (property).** Random verb sequences (split, close, swap, promote, rotate, move, arrange, zoom, nudge, drag) keep `isValid`, preserve every surviving `PaneID`, keep the focus on an existing pane, and keep `focusHistory` consistent.
- **Drag.** Clamps at both ends; a drag never produces a rect below a minimum; double drag equals single drag to the same point.
- **Arrangements.** Every arrangement for 1…9 panes is valid, equalised, preserves ids; `shape(of:)` round-trips.
- **Snapshot.** v1 decodes into v2; v2 decodes with unknown future kinds as `.empty`; dual-write round-trips through an older reader (simulated by decoding with the legacy-only struct); more than 12 panes truncates; corrupt input is discarded.
- **Governor.** Table-driven timelines: escalation by busy, by stall, by pressure; floors; relax delay and its doubling; dwell; budget assignment order (attention, touched, recent, pinned); pin ignored at level 3; geometry demotion with hysteresis; no oscillation over a 10-minute synthetic trace at constant load.
- **Mailbox, pump and drain.** `LatestWins` keeps only the newest and signals once; `SingleFlightPump` never runs two works, always ends on the newest input, never builds a stale input; `TileDrain` honours priority, rotates peers, respects `minInterval`, always makes progress, reports leftovers, and is silent with no work.
- **Hub.** Two leases on one key share one conversation (a fake `AgentConversation` counts opens); interest changes keep or release the stream; last lease out stops after the grace; edges fire once per state regardless of lease count; a queued message is taken exactly once under concurrent callers (`takeFirst`).
- **Glance.** `GlanceReading` reads only the tail (a fake state with 100 000 messages in under a millisecond); markdown stripped; `tail(maxChars:)` cuts at a word.
- **Recorder.** Ring wrap, max-`n` recovery after a simulated torn tail, slot width, no content fields.
- **SafeRestore.** Decision table over (clean, unclean, panes, repeated).
- **ResourceLimits plan.** `clamp` arithmetic for 8, 16, 62 and 256 GiB.
- **Shortcuts.** The new actions parse, have no conflicts with the registry, appear in `helpSections()`.

### 10.2 Selftests

Each is a `checkX() throws -> Int` in the existing style. Linux fits inside its 150 s watchdog, Mac inside 90 s.

- **Linux `tile canvas`:** build the canvas headless-free where possible (GTK needs a display, so this one runs in the harness); split, close, exchange, zoom, arrange ×50 in a hammer; assert re-parent counter 0; assert every placed child's allocation equals the solver's rect; assert hidden children are not child-visible; assert dispose leaves no children.
- **Mac `tile canvas`:** frames equal Core placement for a set of trees; hidden views are `isHidden` and excluded by `hitTest`; no view's superview changes across verbs; first responder survives a split.
- **Both:** `pane lifetime` (weak reference nil after shutdown and after demotion to parked), `parity` (existing), `flight ring` write/read, `restore plan`.

### 10.3 Drive verbs (Linux; Mac gets the same under its drive hooks)

`stall=<ms>` blocks the main thread (exercises the watchdog and shed), `pressure=<nominal|strained|critical>` injects host pressure, `shed=<0…4>` forces a level, `soakopen`, `soaksend`, `soakhammer`, `soakstats` (below), `flight` prints the last ring records. Existing `split`, `sfocus`, `sclose`, `szoom`, `sxchg`, `seq`, `splits`, `geom`, `handles`, `drag`, `drop` keep working and read the canvas.

### 10.4 Soak

There is no firehose today (`MockBackend` replays scripted steps with a per-step delay; `DemoWorld` has two prebuilt backends; no fake HTTP bridge). The soak is built in-process:

- `TAILSCODE_SOAK=N:R:K[:T]` (environment, honoured only with `--demo`) installs `SoakWorld` (Core): one `MockBackend` with `N` sessions, each with a prebuilt transcript of `K` messages and `interactive: true` reply turns of thousands of tiny `partTextDelta` steps at `1000/R` ms for `T` seconds, plus one list upsert per streaming session per second as a busy bridge sends. The drive verbs `soakopen` (one session per pane), `soaksend` (a prompt in every pane in the same main-loop turn), `soakhammer=<s>` (split/close/zoom/exchange/equalize/focus and window resizes on a 1.2 s beat) and `soakstats` drive it; the app prints a `SOAK` line every 5 s. It is an environment variable rather than a `soak=` drive verb so the listing the app makes at launch already carries the soak server and no verb has to force a second one. M0 measured today's code with it: `docs/tiling-baseline.md`.
- `scripts/soak-tiles.sh` runs the harness (`scripts/dev-linuxapp.sh start --release --no-build -- --demo`) **inside `systemd-run --user --scope -p MemoryMax=10G -p MemorySwapMax=0`** so a regression kills the harness, never the desktop, drives `soak=5:80:600` plus a hammer of verbs and window resizes for 10 minutes, then asserts from the flight ring: loop busy p95, worst stall, RSS slope, thread and fd drift, mailbox depth at most 1, drain p95, zero re-parents, level transitions bounded.
- The Mac runs the same through `--bench-tiles <transcript.json …>`, which (unlike `--bench`) builds panes in an ordered-front window and checks the numbers in Appendix C. A bench run without an ordered-out window prices every layout with a fresh engine and is wrong by 10–100×; the new bench is written for a never-ordered-front window as `--bench` is.
- **Gaps stated.** The harness is X11, cairo, llvmpipe and has no AT-SPI; it validates CPU, memory, loop behaviour and counts, not NVIDIA, Wayland or KWin.

### 10.5 Real-desktop protocol (manual, run once per milestone that touches a host)

Linux: install, open five chats in a master-stack, send in all five, leave the recorder running ten minutes, drag a divider, shrink and grow the window, zoom and unzoom, pause one, force-quit and relaunch (the banner appears), then `tailscode --flight 15` and read it. The recorder's header says which renderer ran. Mac: the same on the Mac plus VoiceOver through the rotor, full screen, a palette change, store build and direct build.

### 10.6 Gates

There is no PR CI (the only workflow builds on tags). Gates are local: `scripts/parity.sh --check` (existing Stop hook), and a new `scripts/tiling-check.sh` that runs `swift test --filter Tile` in `TailscodeCore` and the Linux selftest, wired into the Stop hook only when the diff touches tiling paths. The soak is on demand and mandatory before a release that touches a host.

### 10.7 Performance budgets

Starting points, replaced by measured numbers at the end of M0 and set in Appendix C:

| Measure | Budget |
|---|---|
| main loop busy, 5 panes streaming 80 tok/s, 600 rows | p95 ≤ 0.35 |
| worst main-loop slice | ≤ 120 ms |
| RSS slope after 2 min warm-up | ≤ 5 MB/min |
| thread count, fd count over 10 min | flat ± 4 |
| deepest mailbox | ≤ 1 |
| drain per frame | p95 ≤ 4 ms |
| structural verb to rects settled | ≤ 1 frame, 0 re-parents |
| two-pane divider step (Mac) | ≤ 16 ms |
| two-pane divider step (Linux) | live if ≤ 8 ms, else ghost |

## 11. Milestones

Each milestone is shippable on its own, ends with the install step for the client it touches (Linux: `scripts/install-linuxapp.sh`, report version and pid; Mac: say plainly that it cannot be installed from Linux and name `scripts/install-macapp.sh` to run on the Mac, then verify `--version`), and is committed by pathspec (several sessions share one git index).

**M0. Seatbelts and evidence (Linux and Mac, no tiling change).**
`FlightRecorder` format and writers, `LoopLoad`, `StallWatchdog`, `HostPressure`, `ResourceGuard` (Linux), `LaunchLedger` + `RestorePlan` + staggered wake + the banner, `--flight`, `--limits`, renderer in the launch record. Tests and drive verbs `stall`, `pressure`, `flight`.
*Accept:* kill -9 mid-run leaves a readable ring with the last second; `systemctl --user show` of an install-script-launched app shows the three limits; a forced stall writes a stall record and sheds; an unclean ledger restores five panes parked with the banner; the soak harness (10.4) exists and its baseline numbers replace Appendix C's starting points.
*Rollback:* every piece is additive.

**M1. Stop the bleeding in the current structure.**
Core primitives first (`LatestWins`, `SingleFlightPump`, `TileDrain`, `PaneLifetime`), then applied to the existing panes: stream-to-main coalescing (Linux and Mac), per-label reveal cache, cascade only in the focused pane and capped, non-actor `SessionListCache` coalesced save on Linux, park hidden panes (cancel stream and clocks on zoom-away), one conversation per session via a first `ConversationHub`, atomic `SendQueueStore.takeFirst`, a pane cap from room (refuse a split below the glance minimum), Mac coalesced `persist()`.
*Accept:* the soak at 5 panes meets the budgets with the old nested hosts; mailbox depth ≤ 1; hidden panes own no clocks.
*Rollback:* each item is a separate commit.

**M2. Core model and governor.**
`PaneContent`, `PaneSizing`, `PanePlacement`, new verbs, arrangements, snapshot v2 with dual-write, `TileGovernor`, `GlanceReading`, `MemoryRelief`, new `KeyAction`s and chords, all tests in 10.1. No host change yet; the legacy hosts keep running. *Accept:* the full Core suite passes; placement property tests at 200 seeds.

**M3. Linux canvas.**
`tile.c`, `TileHost`, dividers, `TileShell`, glance, parked face, strip, `PaneHost` protocol, hub leases in `ChatPane`, density hooks, the new verbs and chords, accessibility, selftest and drive verbs. The legacy `SplitHost` stays behind `TAILSCODE_LEGACY_TILING=1` for one release. *Accept:* 7.6 in full, soak green, real-desktop protocol clean.

**M4. macOS canvas.**
`TileCanvasView`, `TileHost`, dividers, live-resize deferral, glance, parked face, strip, sensors, menu, accessibility, `--bench-tiles`, selftest. Legacy `SplitPaneHost` behind a defaults key for one release. Parity anchors move in the same change. *Accept:* 8.8 in full on the Mac, both distributions build.

**M5. Rearrange, polish, delete.**
`paneRearrange` (drag a strip onto a pane), localization of all strings and a completeness script, doctrine paragraph in `CLAUDE.md`, delete the legacy hosts and the dual-written snapshot fields (the release after). *Accept:* parity matrix fully answered, no `GtkPaned` or `NSSplitView` left inside the tile tree.

## 12. Risks and open decisions

Decisions for the owner, with the default taken here:

1. **Automatic glance for peers.** Default on, with a visible chip and `Keep all live` (ignored at level 3+). The alternative, all panes always full, is what froze the machine.
2. **Base live budget** of `clamp(cores / 4, 2, 4)`. Tuned from M0 data.
3. **Safe-restore threshold** of three panes after an unclean exit.
4. **Memory limits** (10% and 16% of RAM, clamped). The app is killed, not the desktop; a legitimately huge session near the limit loses its process. `TAILSCODE_NO_LIMITS=1` and an administrator's own `MemoryMax` override it.
5. **Ghost versus live divider drag on Linux**, decided by measurement in M3.
6. **New chords** (`ctrl+w w`, `return`, `r`, `a`, the move and resize family). The registry's conflict reporter is the arbiter.

Risks:

- **GTK relayout cost.** The transcript is a `GtkBox` of live row widgets, not a virtualised list. Row windows, glance and ghost drags contain it; they do not remove it. A `GtkListView` transcript is the structural fix and is a separate project (it touches cascade, selection, hover, find and fresh-canvas).
- **Kit follow-ups** (separate repo, not blocking): an opencode event multiplexer (one SSE per server), and a flush on `stop()`.
- **`@MainActor` on Linux.** Any Core addition that awaits the main actor hangs silently. Review checklist item: no `@MainActor`, no `DispatchQueue.main` in Core runtime.
- **Reverse coupling on the Mac** (`view.window?.windowController as? MainWindowController`): the responder-chain path must keep working while closures move behind `PaneHost`.
- **Real cause unknown.** If the next freeze shows a GPU stall rather than memory or loop starvation, the recorder will say so (renderer, pressure, stall records) and the governor's inputs get a GPU term. The seatbelts help either way: nothing here depends on the hypothesis being right.

## Appendix A. Files

**Core (new, `Tiling/`)**: `PaneContent.swift`, `PaneSizing.swift`, `PanePlacement.swift`, `PaneArrangement.swift`, `TileGovernor.swift`, `LoopLoad.swift`, `HostPressure.swift`, `MemoryRelief.swift`, `LatestWins.swift`, `SingleFlightPump.swift`, `TileDrain.swift`, `ConversationHub.swift`, `GlanceReading.swift`, `FlightRecorder.swift`, `SafeRestore.swift`, `ResourceLimitsPlan.swift`, `PaneLifetime.swift`. **Core (changed)**: `SplitLayout.swift` (verbs, placement, snapshot v2), `SplitEven.swift` (`arrange(ids:as:)`, `mainStack`), `SplitTabs.swift` (accessors), `PaneDrop.swift` (payload for pane moves), `Shortcuts.swift` (actions and chords), `SendQueueStore.swift` (`takeFirst`), `SessionListCache.swift` (non-actor coalesced save), `Parity.swift` (capabilities).

**Linux (new)**: `CGtkShim/tile.c`, `include/tile.h`, `TileHost.swift`, `TileCanvas.swift`, `TileShell.swift`, `GlanceTile.swift`, `ParkedFace.swift`, `OverflowStrip.swift`, `RestoreBanner.swift`, `LoopMeter.swift`, `Watchdog.swift`, `PressureSensor.swift`, `ResourceGuard.swift`, `FlightWriter.swift`. **Linux (changed)**: `ChatPane.swift`, `ChatPaneCascade.swift`, `CascadePainter.swift`, `shim.c` (per-label reveal cache, cursor and accessible-value helpers), `MainWindow.swift`, `Gtk.swift`, `Parity.swift`, `SelfTest.swift`, `main.swift`, `MatrixTheme.swift`. **Linux (deleted after M5)**: `SplitHost.swift`.

**Mac (new)**: `TileHost.swift`, `TileCanvasView.swift`, `TileDividerView.swift`, `GlanceTileView.swift`, `ParkedFaceView.swift`, `OverflowStripView.swift`, `RestoreBannerView.swift`, `LoopMeter.swift`, `Watchdog.swift`, `MemoryPressure.swift`, `FlightWriter.swift`. **Mac (changed)**: `TranscriptViewController.swift`, `MainWindowController.swift`, `MainMenu.swift`, `Parity.swift`, `SelfTest.swift`, `MacShot.swift`. **Mac (deleted after M5)**: `SplitPaneHost.swift`.

**Scripts**: `soak-tiles.sh`, `tiling-check.sh`; `install-linuxapp.sh` unchanged in behaviour (its restart already lands in a matching scope).

## Appendix B. Strings (all ten translations)

Live, Glance, Paused, Keep live, Pause this pane, Resume, Live %@ of %@, busy, memory, warm, Keep all live, Arrange, Columns, Rows, Grid, Main and stack, Promote to main, Rotate panes, Next pane, Previous pane, Pane %@ of %@, Divider between pane %@ and pane %@, also open in pane %@, %@ more, No room for another split here, Tailscode didn't close normally last time. %@ chats are paused., Resume all, Resume one by one, Answer…, Open full, Panes, Diagnostics, Copy diagnostics.

## Appendix C. Constants

| Constant | Value |
|---|---|
| gutter / divider hit | 1 pt / 9 pt |
| chat full minimum, hysteresis | 280 × 200, +16 |
| chat glance minimum | 200 × 88 |
| strip height | 28 pt |
| hard pane ceiling on decode | 12 |
| drain budget, starvation guard | 4 ms, 100 ms |
| glance rate by level | 4, 2, 1, 0.5 Hz, frozen |
| stream grace after last lease | 5 s |
| demoted pane kept alive | 20 s |
| parked reading kept | 10 min |
| promotion dwell | 8 s |
| escalate / critical thresholds | busy ≥ 0.65 for 3 s / ≥ 0.85 for 1.5 s or stall ≥ 250 ms |
| relax | busy < 0.30 for 20 s, ≥ 15 s apart, doubling to 120 s |
| watchdog ping, stall, deep | 500 ms, 3 s, 10 s |
| PSI strained / critical | memory some avg10 ≥ 20 / full avg10 ≥ 5 |
| MemAvailable strained / critical | < 12% / < 6% |
| own memory floors | ≥ 70% of high → level 2, ≥ 90% → level 4 |
| MemoryHigh, MemoryMax | clamp(10%, 2–8 GiB), clamp(16%, 3–12 GiB) of MemTotal |
| MemorySwapMax, CPUWeight, TasksMax | 0, 60, 4096 |
| recorder | 192 B slots × 3600, 1 Hz, `fdatasync` per second |
| staggered wake | 300 ms apart |
| unclean restore parked at | ≥ 3 panes |
| divider keyboard step | 16 pt, 64 pt with shift |
| live-drag threshold (Linux) | 8 ms per relayout |
| row windows: focused / peers by level | preference / 150, 100, 60, 0 |
| total realised peer row widgets | 1200 |
