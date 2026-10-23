# Neural trace: performance

What the head costs, what can be taken away without taking anything from the picture, and whether it should be drawn with Metal. Everything below that has a number was measured on the real assets and the real shader; what was not measured says so.

## The answer

- **Metal on iOS and the Mac. On Linux, the CPU: a delta compositor in Core. Not OpenGL.**
  - On iOS a layer cannot carry the per-channel tint this look is built on: `CALayer.filters`, `backgroundFilters` and `compositingFilter` are documented "not supported on layers in iOS". Without a shader the choices are one pre-tinted picture per theme and state, or thirteen masked layers (offscreen passes on every frame). Core Image kernels are Metal underneath.
  - It is the path the orb already takes (`PresenceOrbView` is an `MTKView` that pauses when its frame is `settled` and when it has no window), so the lifecycle, the `isPaused` discipline and the tempo (`CAFrameRateRange.activityTempo`) already exist.
  - Linux cannot use a `GtkGLArea`. `shim.c` records why the orb left it: on the vendor's EGL stack "an animating GL area leaks about seventy megabytes a minute, whatever the render callback does", and the orb is the reason the app draws its creature on the CPU. A brain that animates for the whole of a turn on that stack is out. The Linux client composites on the CPU: the rest picture of the head is composited once per theme and size, and each frame only the pixels that move are recomputed (the active zone's rectangle, the eye, and a sparse list of fibre pixels for the ripple), across cores, into a cairo surface. The same pure-Swift compositor in Core is the reference for the shader, the golden for the tests and the painter for share posters on every client.
- **The fill cost is not the problem.** On an RTX PRO 6000 the whole head is 16 µs a frame at 1280 × 840. A phone GPU is a small fraction of that card, so the absolute figure does not carry over; what carries over is the ratios below. The costs that matter on a phone are frames drawn while nothing changes, memory and wake-ups, and those are policy, not shader work.

## Measured

### GPU time, real GPU

Chromium with ANGLE over Vulkan reaches the NVIDIA card (`--headless=new --enable-gpu --use-angle=vulkan --enable-features=Vulkan --ignore-gpu-blocklist`); the default headless shell silently falls back to SwiftShader, so the frame costs quoted earlier in `docs/neural-trace.md` were software figures. `EXT_disjoint_timer_query_webgl2`, 120 draws, the smallest of three medians, the shader exactly as in `hero2.js`. `docs/neural-trace-mocks/src/bench.py` reproduces it.

| Pass | 1280 × 840 | 2560 × 1680 |
|---|---|---|
| interior now (full screen, 7 fetches) | 8.1 µs | 23.6 µs |
| early-out outside the dome | 6.6 | 17.3 |
| **drawn as the dome's mesh only** | **6.5** | **12.4** |
| dome mesh, packed channels (5 fetches) | 5.9 | 11.8 |
| plus sRGB colour texture | 5.9 | 11.7 |
| one zone's quad, 3 fetches | 2.5 | 2.9 |
| front now (full screen, 6 fetches, blended) | 8.3 | 24.0 |
| front as one static blit | 4.2 | 10.8 |
| eye, ear and ribs quad only | 2.5 | 2.8 |
| **a working frame now** (interior + front) | **16.4** | **47.6** |
| dome packed + front now | 14.2 | 35.8 |
| dome packed + eye quad (front static) | 8.4 | 14.5 |

The 2× scale (a Retina Mac or an iPad) is where the mesh matters: coverage, not arithmetic, is what the card pays for. The sRGB texture format changes nothing in speed; it is for correct blending.

### What each layer can lose

The whole composite, rebuilt with one layer replaced by a down-and-up-sampled copy, against the full-resolution reference (PSNR; above about 40 dB is invisible in this content).

| Change | PSNR | SSIM | Verdict |
|---|---|---|---|
| glass at half resolution | 51.5 dB | .9985 | free |
| interior colour at half | 41.3 | .9977 | free |
| bloom at 1/8 instead of 1/4 | 50.1 to 52.8 | .9991+ | free |
| chassis at half | 39.1 | .9866 | keep full (edges, rivets, seams) |
| the four colour/mask groups at half | 34 to 36 | .98 | keep full (starfield, hex lines) |
| masks quantised to 6 bits | 54.7 | .9999 | free |
| colour layers quantised to 6 bits | 50.7 | .9965 | free |

### Block compression

ARM's astcenc at its thorough setting on the real files. Per-channel PSNR, so a channel bleeding into another would show.

| Layer | ASTC 4×4 (8 bpp) | ASTC 6×6 (3.6 bpp) | ASTC 8×8 (2 bpp) |
|---|---|---|---|
| chassis | 53.1 to 53.9 dB | 45.3 to 47.2 | 41.6 to 43.8 |
| interior | 49.4 to 50.5 | 41.4 to 42.0 | 37.7 to 38.0 |
| glass | 55.1 to 55.9 | 49.8 to 50.5 | 44.8 to 48.1 |
| masks (unpacked RGB) | 65.4 to 105 | 50.9 to 94 | 44.7 to 99 |
| masks packed into RGBA (12 channels in 3 textures) | 57.5 to 82.8 | 47.6 to 66.4 | not run |

Nothing bleeds between channels, and 6×6 stays above 47 dB on every mask channel. 8×8 is out for the colour layers (the interior drops to 37.7 dB).

### Memory

| | Now (RGBA8) | Proposed |
|---|---|---|
| chassis | 4.3 MB | ASTC 4×4, 1.05 MB |
| interior | 4.3 | ASTC 6×6, 0.47 |
| glass | 4.3 | half resolution, ASTC 4×4, 0.27 |
| masks | 5 × 4.3 = 21.5 | 3 packed RGBA (the visor backing is dropped), ASTC 6×6, 1.4 |
| bloom | 5 × 0.27 = 1.3 | 1/8 resolution, packed into 3, about 0.2 |
| **total** | **35.7 MB** | **about 3.4 MB, 4.5 MB with mips** |

The bundle carries the same bytes as ASTC (about 3.4 MB) in place of 0.6 MB of WebP; it also removes the decode and the 36 MB transient. The fetch count falls from 13 to 9 (interior 7 to 5, front 6 to 4).

### Linux: CPU time per frame of the CPU compositor

Process CPU time (`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`, every worker counted) per frame on the real layers, release build, i7-14700K, the delta frames drawn by one worker with the 16-row floor the stage sets, the full frames by four. `TailscodeCore/Tests/TailscodeCoreTests/NeuralRealAssetsTests.swift` (`cpuTimePerFrame`) prints the same measurements.

| Frame | 760 × 499 before | after | 1536 × 1008 before | after |
|---|---|---|---|---|
| full, settled | 25.9 ms | 4.5 | 97.5 | 24.8 |
| full, settled, one worker | 16.7 | 3.2 | 65.3 | 13.7 |
| full, with a dive | 64.9 | 34.5 | 270 | 154 |
| delta, working (shell zone breathing, ripple) | 9.24 | 1.26 | 36.3 | 5.2 |
| delta, thinking | 4.64 | 0.97 | 19.0 | 3.9 |
| delta, sweep (whole dome) | 24.6 | 3.45 | 100 | 14.4 |
| delta, needs approval (heartbeat) | 4.29 | 0.30 | 17.5 | 1.2 |
| delta, compacting (crunch and sweep) | 35.5 | 10.0 | 143 | 39.7 |
| resident set, idle / after a live turn | 16 / 16 MB | 18 / 22 | 65 / 65 | 74 / 90 |

What paid, in the order it was found:

- **Cost follows lit pixels, not the dirty rectangle.** `NeuralLitIndex` holds, once per size, which of the twelve channels (and whether the interior has alpha) light each pixel; a delta draws the pixels of the channels that changed, clipped to the dirty region, from ascending lists built when first asked for and cached. A pixel then sums only the channels it is lit by, in channel order, so the answer is the one the every-pixel loop gives.
- **A full render is two memcpy and the lit pixels.** The interior's rest picture existed; the front's (chassis and glass, nothing glowing) is now made once too (`frontRest`). A frame draws only the pixels a channel lights over them.
- **The gamma encode is a lookup, not `powf`.** A log-spaced table finds the one rounding threshold a value can be next to, so the byte is `byte(powf(x, 1 / 2.2))` except where the two differ by a rounding tie (35 bytes in the 36 goldens, never by more than one level).
- **The ripple is a table.** The sine and cosine of the distance to the active point are kept for every link pixel (the last two points), so the ripple at a pixel is two products and a subtraction; the sine and the square root are paid once per zone change.
- **Library calls out of the loops.** `rounded(.down)` is a call on a baseline x86-64, and `SIMD3.clamped` and the generic pointwise min and max were not inlined; the floors are a truncation and a step, the clamps are written out.
- **The crunch skips what is clear.** A flag per 8 × 8 block says whether a bilinear sample taken in it can read any of the four layers, the pixel's nearest zone is a table, and a pixel outside the box of everything lit is the rest picture.
- **Workers cost processor time.** The same full frame costs 3.2 ms with one worker, 3.7 with two and 4.5 with four on this machine, so a pass gives a worker only when it has 100 000 pixels for it: on the stage a full frame is drawn by one worker whatever `fullWorkers` says, and at 1536 wide by up to four. The stage's `deltaWorkers` of one stays right.

What did not: a vectorised `pow` for the dive (`powf` is 3.4 ns, the polynomial 13), a hand-written `exp` for the sweep (slower than `expf`), skipping blank blocks in a dive (the zoomed picture has almost none), and a branchless encode (slower on real data, which is mostly dark). A dive frame is bilinear reads of four layers and stays at about 1.8 times cheaper.

## What to do, in order

1. **Run at the app's tempo.** `ActivityTuning.frameRate` is 30 (24 at the least), pinned through `CAFrameRateRange.activityTempo` for every mark, and its own comment says a swell or turn "needs no more than this many frames". Breath (1.9 s), heartbeat (1.6 s, the sharpest feature at about 70 ms a beat) and sweep (1.05 s) all fit; the largest breath step at 30 fps is 3.6 percent of the range. The mocks ran at the display rate; they now step at 30. Only a dive and a scrub use the display's rate, and they last a second.
2. **Draw nothing that did not change.** The orb's rule: pause when the state is still, when the view has no window, when it is scrolled out of sight, when the window is occluded, and when the app is inactive. `MTKView.isPaused = true` with `enableSetNeedsDisplay` (documented as behaving like a `UIView`) for rest, hover and theme changes.
3. **Draw the dome, not the screen.** A triangle fan of the window outline (about 100 vertices, a Core constant) instead of a full-screen triangle: 20 percent faster at 1280 and 47 percent at 2560, and the pixels outside the head are never touched. Apple states A11 and later improved `discard`, so the mesh is for coverage rather than for avoiding `discard`.
4. **Compress and pack** as in the tables: ASTC on Apple (every Apple GPU from the A8 up, Apple silicon Macs included; BC is only guaranteed from the A17 and M3 generation, so it is not an option there), BC7 where the Linux driver offers it, else RGBA8, with the same packed layout. Precompiled textures upload with `replace(region:)` and no decode. Mipmaps stay in (about a third more) so a head shown at 365 pt does not shimmer. The few Intel Macs macOS 26 still supports have no ASTC: keep an RGBA8 set only in the Mac build.
5. **One set of textures per process**, loaded once at idle on a background queue, kept while any brain is open (`PaneLifetime`), shared by every window and pane. A glyph stands in until it is ready.
6. **`CAMetalLayer.maximumDrawableCount = 2`** (valid from iOS 11.2 and macOS 10.13.2, default 3): one drawable fewer (4.3 MB at 1280 × 840) and a frame less of latency. Draw rarely, so two is plenty.
7. **No per-frame allocation.** A triple-buffered uniform ring filled by `NeuralFrame.at` (13 intensities, 13 tones, a dozen scalars). The mocks allocate typed arrays per draw; the clients must not.
8. **Let the render server run the nodes.** A waiting node's heartbeat and a running node's breath are `CAKeyframeAnimation`s pinned with `runAtActivityTempo()` (the app already does this for its marks), so they cost no app CPU. Past about 60 nodes the layers give way to instanced SDF shapes in the same pass.
9. **Incremental layout.** `NeuralLayout.append` is O(1) per tool part (a per-zone counter for the slot, an edge to the previous group, a via dot when both sides fan); a transcript is rebuilt on every streamed token, so the brain's input changes only when a tool part appears or changes status, and never per token. Edges are de-duplicated by path (this brought a 174-step turn from about 170 wires to a few dozen).
10. **Function constants for the variants** (light-theme spill, ripple, sweep, crunch, rainbow): the pipeline is specialised at creation so a state that does not use a term pays nothing for it.
11. **Linux**: the Core CPU compositor behind three overlaid drawing areas (interior, nodes, front), the tick at the activity tempo through `gtk_widget_add_tick_callback`, a frame only when something moves, work split over cores with `concurrentPerform`, no GL area anywhere.
12. **Governor**: `TileGovernor.animation(level:reducedMotion:)` already decides what a level may animate; calm draws everything, strained drops the ripple, sweep and crunch, critical keeps the glyph. Low-power mode counts as strained (the client reads `isLowPowerModeEnabled`; Core has no setting).

## Worth doing only if a phone profile asks for it

- **Static front plus an eye overlay**: the chassis and glass drawn once into a texture and redrawn only on a theme or size change, with the eye, ear and ribs as a tiny quad. Measured saving 5.8 µs of a 14 µs frame on the card, but on a phone the compositor blends that static layer over the interior every frame, so part of it moves rather than goes away.
- **Rest composite plus zone quads**: bake the plate and its rest glow into one texture per theme and add only what moves (one zone: 2.5 µs against 8.1). It needs a persistent offscreen target and a re-bake on every theme and state change.
- **One pass with the nodes in the shader**: a single opaque layer, no layer sync, the nodes get the bloom too. It needs a numeral atlas and an accessibility overlay. Not needed unless layer compositing shows in Metal System Trace.

## Not worth it

- Half-resolution masks, chassis or the whole stack (34 to 39 dB), ASTC 8×8 on colour (37.7 dB).
- Core Animation filters for the tint (unsupported on iOS), pre-tinted images per theme, SpriteKit, SceneKit, Core Image kernels.
- Hand-optimising `pow` and `sin`: the sRGB format saved nothing measurable and the ripple's `sin` is gated by a constant already.
- Rendering the interior below the screen's resolution while it animates: the dive zooms into it.

## Verified, refuted, not found

From the platform documentation: layer filters unsupported on iOS (verified); `maximumDrawableCount` 2 or 3, default 3, but from iOS 11.2 not 13 (corrected); `MTKView` on-demand drawing (verified); `preferredFrameRateRange` iOS 15 and macOS 14, `NSView.displayLink` macOS 14 (verified); ASTC on Apple2 and later, BC on Apple9 only with some Apple7 and Apple8 iPad parts (verified); sRGB conversion on sample and write in hardware (verified); function constants specialise at pipeline creation (verified). `GtkGLArea` has `auto-render` and `queue_render`, but is not used: see the Linux note above.

Not found in Apple's documentation, so not relied on: that `half` arithmetic is faster (an unsourced rule of thumb; measure with Metal System Trace).

## To measure next

On the iPhone Air in Xcode's Metal System Trace: GPU time per frame for the interior and the front, with the assets as ASTC and mipmapped; energy over a minute of a live turn at the activity tempo against 60 fps; time to first picture on a cold open. On Linux, CPU time per frame of the delta compositor and the resident set across a long turn.

## Applied: what the audit found in the existing clients and what was done (2026-10-17)

The three clients were read for clocks that ignore settled, hidden or occluded, per-frame allocation, work per streamed token and the orb's CPU cost. Each item below was changed in the same change as the brain.

| Finding | Change | Measured |
|---|---|---|
| LiveCascade repainted the whole answer on every display frame for the whole turn (iOS, Mac) | Core `CascadeTempo` (`.stopped`, `.activity`, `.display`), `LiveCascade.tempo/isResting/textRevision/paintRevision/restPhase`: the band finishes its pass at the activity tempo and the row rests; clients key repaints on the revision and repaint the tail | iOS demo send: 70 + 52 ticks over a turn's writing bursts against about 60 a second; Mac 20 s of a streaming turn 4.30 s CPU before, 1.93 s after (Lines), 2.77 s with the brain |
| Linux reveal read text every frame (`reveal.c`, `ChatPaneCascade`, `CascadePainter`) | the frame fast path reads no text, the label's base render node is cached, the clock follows Core's tempo | the reveal runs at the display rate while calm (about 2 points of a core on a 60 Hz harness; `TAILSCODE_REVEAL_RATE=30` restores the old rate) |
| Linux `noteDoubledRows` hashed bodies per token | `DoubledRowWatch` hashes only the row whose length changed | |
| Transcript rebuild and diff scaled with the conversation (iOS `ChatViewController`, Mac `TranscriptViewController`) | rows remembered per message by revision (iOS `SegmentRowMemo` extended, Mac `TranscriptRowBuilder`), the turn cache keeps 4,096 turns, `keepRead` fires only when the newest message changed | iOS one streamed token: 28.0 to 7.4 ms of rows at 2,400 messages, 75 to 21 ms at 6,000; Mac 1.5 to 0.6 ms at 703 rows |
| Per-badge `CADisplayLink`s (iOS, Mac) | `CAKeyframeAnimation` on the render server locked to absolute time | no app CPU for a breathing badge |
| Display links gated on the window only (Mac call face, forge ring, studio stage, tile runtime, orb) | one `DisplayGate`: window occluded or app inactive stops them | |
| Linux orb: per-pixel eight blobs with `expf` and `atan2f` | zero weights skipped, bytes identical but one level | 0.32 to 0.20 ms a frame at 1x, 1.17 to 0.78 at 2x; the orb's cost on a live turn about 1.6 points of a core to about 0.1 |
| Linux aura: 384 `cairo_stroke` a frame | segments cached and batched by colour; gradient strokes are smooth where round caps drew a bead at every joint | 0.81 to 0.28 ms a frame |
| Per-orb Metal devices (orb, aurora) | one process-wide `NeuralMetalContext` (device, queue, library, pipelines) warmed off the main thread and shared | |
| `Theme.Ramp.font` had no cache; Aurora built colours every frame | fonts memoised per role, colours resolved once per theme change | |
| Full-size image decode on the main thread (`ImageBubbleCell`), Game Center at launch, a 100 ms stall monitor forever | ImageIO thumbnails off main with the full bytes kept for the viewer, Game Center at idle, the monitor backs off to 250 ms after 5 s without a touch | |
| Always-on one-second timers (Mac Seatbelts, Watchdog) | stop when nothing changes | |

Not done: the iOS data-source diff is not tail-only, a single 90-message turn costs 3.4 to 3.9 ms a token on the Mac because the turn is re-read whole (an incremental turn read in `NeuralTurnCache` would fix it), the Linux Seatbelts one-second tick and the Linux cascade's chained entrance timeouts were not revisited, and nothing was measured on a phone (Metal System Trace on the iPhone Air is still the next measurement).

## Mac, scroll handoff and per-state costs (2026-10-23)

`TailscodeMac --bench brain` (Release, the macbook, main-thread CPU in a window that is never ordered front) before and after the scroll handoff, the hover revalidation and the bounded realize loop. The machine was shared with other builds (load average 35 to 130), so absolute figures are upper bounds; before and after were run back to back and agree within the noise.

| | before | after |
|---|---|---|
| scroll event over the step list (median) | 0.003-0.005 ms | 0.003 ms |
| scroll event over the account, 29 / 174 / 600 steps (median) | 0.43 / 0.83 / 1.42 ms | 0.42 / 0.84 / 1.42 ms |
| open one brain, 29 / 174 / 600 steps (median, move landed at once) | 29.8 / 36.7 / 31.9 ms | 27.8 / 35.3 / 36.7 ms |
| close one brain (median) | 11.0 / 16.8 / 18.2 ms | 11.7 / 16.9 / 17.3 ms |
| streamed token as a card, brain's own mean, 100 / 600 / 2,400 turns | 0.214 / 0.299 / 1.144 ms | 0.200 / 0.295 / 0.785 ms |
| streamed token open, brain's own mean, 100 / 600 / 2,400 turns | 0.690 / 0.644 / 0.611 ms | 0.612 / 0.805 / 0.585 ms |
| nothing arriving, open | 0.9 / 0.0 / 0.0 ms of each second | 0.8 / 0.1 / 0.0 |

The scroll handoff asks Core once per event (a few reads of the scroller's geometry), so it costs nothing a wheel can feel; the account's 0.4-1.4 ms an event is its realize, unchanged. `--bench brain-open[=rounds]` repeats the open and close for `sample`; on the loaded machine the main thread's own time was spread over string and Unicode-property work in the account and list builds with no single hot spot.

## Opening a long chat (2026-10-23)

Opening a chat used to read every turn into steps and make a `NeuralBrainModel` for each, on the main thread, in one go: about 0.35 ms a turn on the phone's simulator, so a 300-turn chat paid 36 ms inside the push and the first back swipe. It now places each brain from its **outline** and reads a turn's steps, makes its model, answer and prompt only when something looks at it.

- `NeuralTurnOutline` (Core, `NeuralTurns.outline(messages:running:awaiting:)`) is one pass over a turn's parts that classifies them and builds no detail line, output excerpt or diff tally: whether the turn is a brain (`stepCount`), the part its row goes before (`anchor`, `anchorMessageID`), the few parts the client keeps its own rows for (`keptPartIDs`, so `consumes(_:)` is a set lookup and no set of every part is built), the task-board calls, the answer, how it ended. A test holds it to the turn `NeuralTurns.partition` reads for every demo conversation and for 4,000 random turns, part by part.
- `NeuralTurnCache.partitionList` returns a `NeuralTurnList` whose elements are `NeuralTurnSlot`s: the outline now, the `NeuralTurn` the first time the list is indexed at it (`isRead(at:)` says whether), and a `generation` that is the same for as long as the turn is the same turn. A streamed token still replaces only the tail slot; every earlier slot, read or not, is shared.
- iOS `BrainStore` stamps a settled turn's row from its generation, outcome and face inputs and never from its model, so reading a model for the first time leaves the row exactly as it was and no cell is reconfigured by being looked at. The newest turn and a running one keep their model-derived stamp and are made at once, because the chat's status, haptics and Live Activity read them. Find reads `searchText(for:)` (made once per generation) and, while the bar is open and the chat is seen, a `BrainSearchWarmer` reads the rest in slices of 2 ms, newest first; a keystroke before it is done searches what is read, and the search runs again when it finishes. The Mac does the same in `TranscriptViewController` (`startFindIndex`). Linux reads a turn when its row's widget is made.
- Classifying a tool name (`ToolCall.summaryKind`) costs 2 us for a name the table knows and 8 for one it does not, and a transcript asks it of every step it holds; `ToolKindMemo` (`ToolCall.cachedKind`) answers it once per name. That alone took the eager partition of a light turn from 33 to 11 us.

What a cold open pays for Megatron, the same conversations before and after (Release; Core on the i7-14700K, the phone on the iOS 26.5 simulator built `-O` on an M-series Mac under load, median of three runs; the Mac and Linux are their own Release builds):

| | before | after |
|---|---|---|
| Core, partition + models + rows, 40 / 300 / 1,500 turns of one thought and four tools | 5.8 / 27.6 / 136 ms | outlines 0.08 / 0.61 / 3.1 ms |
| Core, the same with 24-step turns, 40 / 300 / 1,500 | 27 / 207 / 1,104 ms | outlines 0.62 / 4.7 / 26 ms |
| iOS `BrainStore.prepare`, 40 / 300 / 1,500 turns | 2.2 / 15.5 / 76.7 ms | 0.14 / 0.66 / 2.85 ms |
| iOS `prepare`, 24-step turns, 40 / 300 turns | 15.0 / 111 ms | 0.81 / 3.7 ms |
| iOS, 40 turns of 24 steps and 20 KB outputs | 25.6 ms | 1.5 ms |
| iOS, the model of a turn nobody had looked at, made when its card is configured | 0.006 ms (it existed) | 0.06 ms (one turn), 0.12 at 1,500 |
| iOS, the open bench (`TAILSCODE_BENCH_OPEN`), Megatron's share of one open: all passes / longest pass, 40 turns | 2.6 / 2.3 ms | 1.8 / 0.4 ms |
| the same, 300 turns | 36.1 / 30.7 ms | 5.1 / 1.5 ms |
| the same, 1,500 turns | 94.9 / 81.5 ms | 12.3 / 3.4 ms |
| iOS, a streamed token on 40 turns of 24 steps, brain preparation | 0.101 ms | 0.105 ms |
| iOS, the same with 20 KB outputs | 0.139 ms | 0.144 ms |
| iOS, a process after 30 open and pop cycles of a 300-turn chat | 56 MB, every view released | 55 MB, every view released |
| Mac `--bench brain-cold`, 40 / 300 / 1,500 turns of 14 messages | 13.3 / 139.7 / 1,731.8 ms | 0.53 / 2.1 / 10.3 ms |
| Mac `--bench brain-stream`, the first whole read in a run at 600 / 2,400 turns | 344 / 3,567-3,714 ms | 5 / 19-21 ms |
| Mac, a streamed token as a card, the brain's own mean, 600 / 2,400 turns | 0.38-0.40 / 0.45 ms | 0.42-0.53 / 0.41 ms (the machine was loaded; the median is 0.02 / 0.01 ms in both) |
| Linux, the brain ledger's first pass, 40 / 300 / 1,500 turns of 14 messages | 6.7 / 52.9 / 264.6 ms | 0.5-0.9 / 3.5-3.9 / 20.5-23.5 ms |

The iOS open bench's longest single main-thread turn at push (110-150 ms at 40 to 300 turns, 227-237 ms at 1,500) is not Megatron's: the Lines style measures the same (134-137 ms at 40 turns, 91 at 300), and it is the chat's own build, the row builder and UIKit's layout of the first screen. What Megatron added to it was a pass of 2.3 ms at 40 turns, 30.7 at 300 and 81.5 at 1,500; it is now 0.4, 1.5 and 3.4.

The cost that is left grows with the conversation, about 1.9 us a turn of one thought and four tools on the phone and about 12 us a 24-step turn on the desktop, because every turn is still placed when a chat opens: the row builder walks every message and asks the layout about each, and a turn has to be placed for it to be asked. The pass is therefore under 2 ms up to about 700 short turns or 150 long ones on the phone and passes it linearly beyond that. Placing turns on demand, as the builder reaches them, would make it independent of the length once the builder itself walks a window of the conversation instead of all of it; the store's loops over `turnIDs` and the table are the next cost after the outlines.

`NeuralColdOpenBenchTests` (`NEURAL_COLD_BENCH=1`, release) prints the Core figures; the in-app probe is `TAILSCODE_NEURAL_PERF=1` with `TAILSCODE_NEURAL_STATE=shell TAILSCODE_NEURAL_LARGE=174` ("open cold N turns", "then a token"); `TAILSCODE_BENCH_OPEN` also logs `bench brain prepare` and `bench brain realise` lines for the store's own passes. On the Mac `TailscodeMac --bench brain-cold[=40,300,1500]`, on Linux the `efficiency` brain group of the selftest (`TAILSCODE_BRAIN_GROUP=efficiency`) prints "brain ledger: a cold pass".

