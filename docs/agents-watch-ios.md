# Agents Watch on iPhone, iPad and iPhone Duo

Asked for: the Watch wall the Linux desk opens from the sidebar's Agents card, on iPad and iPhone Duo, "equally visually looking and functioning regardless of screen orientation", something to leave open on a desk while working; Metal and effects for events, subtle and not distracting; behaviour people can customise. Design first.

The language of the wall is already decided and shared (`docs/agents-watch.md`, Core `AgentWall`): states, honesty, slots that never move, plain words, hold-to-approve, burn-in care, dimming. This document adds what a touch screen in any pose needs, the Metal renderer, the event effects, and the settings. Canvas with the live prototype, every pose, the effects catalogue and the settings sheet: https://claude.ai/artifact/4hUgD58STksJC8maDoUb31. Mocks: `docs/agents-watch-ios-mocks/`.

## 1. What carries over unchanged

Everything `AgentWall.read` already says: the thirteen states and their glyphs, mood and headline, the watch cap of six, worker squads (`WallSquad`) and their capacity by session count, rails, the calm screen, `AgentPlain` words, quiet meaning *no events seen*, failures that stay until seen, the hour ribbon that hatches what this device did not see. The iOS wall reads the same `AgentWall` the Linux wall reads; it adds no state of its own.

## 2. Screens and poses

The grid comes from `WallGrid` (count and the screen's own shape). What iOS adds is where the chrome goes, chosen from the scene's geometry on every layout pass, never from the device model, never cached:

| Screen | Size (pt) | Layout |
|---|---|---|
| iPad, landscape | 1376 × 1032 | Stack: headline and clock across the top, grid, hour ribbon and Recent along the foot |
| iPad, portrait | 1032 × 1376 | Stack; 2 × 3, or one row per session with its workers beside it |
| Duo open, wide | 951 × 669 | Stack, clear of the 84 pt camera column on the trailing edge |
| Duo open, tall | 669 × 951 | Stack; headline over two lines |
| Duo book | 951 × 669, fold 455.5–495.5 | Two pages: columns forced to two, one per page, so no tile and no word sits on the fold; headline left, clock right; ribbon left, Recent right |
| Duo laptop | 669 × 951, fold 455.5–495.5 | The wall above the fold; the base below is a desk clock, the headline, the hour, Recent and the controls (an ask's hold-to-approve lives there too, never only there) |
| Duo closed | 466 × 678 | Stack, compact: rails fold into the watch line |
| Duo closed, tent | 678 × 466 | Side: a clock column beside the tiles |
| iPhone on a stand | 912 × 420 | Side, same as the tent |
| External display | any | The wall's own window, moved to the display in Stage Manager; the device keeps the board |
| Stage Manager window | any | Whatever the window's shape says |

Rules:

- **Side** when the screen is landscape and shorter than 560 pt; **stack** otherwise; **book** and **laptop** only while the fold's division region is active (`UIWindowScene` reserved regions, read every pass; an empty answer is not proof there is no fold, and the hinge angle never decides layout).
- **Units in points.** `unit = min(height, width × 1.15) / 100`, with floors in points (title 13, words 13, small 11). A small screen shows less, never smaller: worker tiles collapse to dots before they shrink, the rails become `+N also running`, the history list gives way before the words do.
- **The ground bleeds** under the camera column, the home indicator and the fold; content keeps the safe area. No status bar is drawn.
- **Turning keeps slots.** Rotation, folding and window resizes re-run the layout and morph each tile from its old frame to its new one in 0.6 s; nothing reorders. Effects in flight follow their tile.

## 3. The renderer

One `MTKView` behind everything, one render pass a frame, triple-buffered uniforms, nothing allocated per frame:

1. **Ground**: the theme's dark gradient, the mood bloom, the grid, light spilled by each tile onto the ground (computed at quarter resolution and upsampled; it is low frequency), ground ripples, the overdue edge.
2. **Glass plates**: instanced rounded rectangles from a distance field: the glass fill, the state's wash, border, rim, an edge sheen, hatching for away.
3. **Glyphs**: orbs, context rings, crawling dashes, the orbiting dot, check, cross, square, hatched disc; one instanced draw.
4. **Motes and particles**: points with added light, stepped on the CPU in fixed buffers (48 on a phone, 96 on an iPad).

**Words are UIKit**, above the Metal view: crisp at any size, Dynamic Type and VoiceOver as they come, and no glyph atlas to maintain. Liquid Glass (`UIGlassEffect`) is kept for the controls capsule and the peek; the tiles' glass is drawn in Metal, because a system glass over a backdrop that changes every frame resamples it every frame, and one pass is cheaper and looks the same on iOS 18.

The renderer (`WallRenderer`, shaders, buffers) lives in a small `TailscodeMetal` package that both Apple clients link, so the Mac wall is the same code in an AppKit window.

## 4. Events and their effects

Core gains two toolkit-free pieces, tested against `MockBackend`:

- **`WallEvents`** compares two reads and says what changed: a session joined or left, asked, was answered, finished, failed, retried, went quiet, came back, compacted; a step landed; a worker started, ended, went quiet or stuck; a machine went away or came back.
- **`WallEffects`** turns events into timed primitives (ring, ground ripple, spark, thread, dissolve, bloom, gather, scatter, drain) with start, duration, anchor (tile, worker, orb), colour role and amplitude. Clients only draw them, so the three walls move alike.

| Event | Gesture | Length | Still |
|---|---|---|---|
| Step lands | a spark runs into the heartbeat's now edge, the orb brightens | 0.45 s, two a second per tile at most | the bar alone |
| Sub-agent starts | a thread of motes from the session's orb condenses into the worker's tile | 1.1 s | the tile fades in |
| Sub-agent ends | it dissolves back toward its session; a ring of unknown ending cools for 30 s | 1.5 s | the ring |
| Turn finishes | one ring exhales from the orb, the ground ripples once, the tile cools over a minute | 1.8 s | the check |
| Needs you | two knocks ripple out under the tile, motes turn toward it; a knock every 4.2 s | 1.3 s | the amber tile and its clock |
| Overdue | the screen's edge breathes, one breath in 9 s; the border heats | continuous | a steady edge |
| Hold to approve | a ring fills under the finger for 0.8 s, then Face ID; amber folds into the working colour | 1.4 s | the ring |
| Fails | a cross, one low red bloom and a few shards | 1.6 s | the cross |
| Retries | the dashes crawl; each attempt pulses once | 1.2 s | standing dashes |
| Goes quiet | one cold ripple a minute over a flat heartbeat | 2.6 s | none |
| Compacts | the context ring drains like liquid, motes swirl into the orb | 2.6 s | the ring steps down |
| Arrives, leaves | motes gather into the tile; leaving, it scatters and lands in Recent | 1.3 s | a fade |

Rules: one gesture per event, under two seconds; drawn under the words; nothing pulses faster than once a second and no change in brightness is large or sudden; at most 40 at once and 3 per tile, and an ask or a failure is never the one dropped; a burst of steps coalesces; no effect moves a tile. **Subtle** is the default, **Lively** multiplies amplitude by 1.6 within the same caps, **Off** keeps state changes and drops gestures, **Still** (or Reduce Motion) swaps each for a crossfade and stops the field.

## 5. Budget

| When | Frames |
|---|---|
| An event playing | 60 fps on ProMotion, 30 elsewhere (`preferredFrameRateRange`) |
| Something breathing | 30 fps |
| Dimmed and calm | 1 fps: the clock and the drift |
| Hidden, backgrounded, locked | 0 |
| Low Power Mode | 20 fps, field still, effects Subtle |
| Thermal serious / critical | 15 fps without the field / one still frame |

Target under 1.5 ms of GPU a frame on A17 Pro, read from command buffer GPU times in a DEBUG overlay. The wall exists only in the foreground; keep-awake (`isIdleTimerDisabled`) holds only while it is on screen, and lets go below 20 % battery when not charging, saying so in the watch line.

## 6. Settings

One Core value, `WallStyle`, read by all three walls under the same names; stored per device (UserDefaults on iOS, SettingsFile on Linux), never synced.

| Setting | Values | Studio (default) |
|---|---|---|
| Preset | Studio, Night desk, Showcase, custom | Studio |
| Effects | Off, Subtle, Lively | Subtle |
| Field | Motes, Currents, Aurora, None | Motes |
| Light from tiles | on, off | on |
| Events that move | steps, sub-agents, endings, needs you, failures, retries and silence, compaction, arrivals | all |
| Dim when calm for | 5, 10, 30 min, never | 10 min |
| Night | off, 22:00–07:00, always (warmer, dimmer, no field) | off |
| Keep the screen on | while charging, always, never | while charging |
| Still | on, off (also on with Reduce Motion) | off |
| On the wall | clock, last hour, Recent and also running, sub-agent tiles | all |
| Approve from the wall | hold, then Face ID; never, open the chat | hold, then Face ID |

Night desk: no field, no light, only asks, endings and failures move, dim after 5 minutes. Showcase: Aurora and Lively. Colours always follow the app's theme, its dark side. The sheet opens from the wall's Style control, the one place it lives.

## 7. Touch, keys and access

- Tap a tile: the peek over the dimmed wall (doing now, last steps, agents, meters, Open chat, Nudge, Stop); back to the wall by itself after 20 s.
- Press and hold an amber tile 0.8 s: the ring fills, Face ID (`AgentsApprovalGate`), then the answer goes the board's way (`.needsChat` opens the chat). A tap only says *hold to approve*. Deny is a tap.
- Tap the ground: the controls capsule (Done, Watch · Now · Hour, Dim, Style) for 3 s.
- iPad keyboard: 1–6 peek, D dim, K keep-awake, Esc leave; the Agents shortcut from the registry opens it.
- Pointer: a tile lifts 2 pt under the pointer.
- VoiceOver: each tile is one element read as a sentence ("Fix reconnect test, working, changing Backoff.swift, 6 minutes"); an ask is announced once. Increase Contrast strengthens borders and drops glows; Reduce Transparency makes the glass solid.

## 8. Where it lives

- The Agents board gets the Watch lens beside Now (and Hour where regular width), Watch first, as on Linux. iPad's sidebar gets the Agents row that opens it; its context menu offers *Open in New Window* (its own scene, so it can sit beside Tailscode in Stage Manager).
- StandBy keeps the Live Activity it has; the wall needs the app open, and is not a widget.

## 9. Parity

| Capability | iPhone · iPad | Mac | Linux |
|---|---|---|---|
| `agentsWatch` | gap → implemented | gap → implemented (same renderer) | implemented |
| `agentsWatchEffects` (new) | Metal | Metal | Cairo paints the same primitives |
| `agentsWatchStyle` (new) | implemented | implemented | implemented |
| `agentsLocalWords` | stays a gap | stays a gap | implemented |

## 10. Decided (2026-10-29)

1. **The Mac comes in the same pass**, with the same renderer, as the Agents window's Watch lens (its default, as on Linux), fullscreen and keep-awake.
2. **Linux draws the effects now**, in Cairo, from the same Core shapes; it also gets the Style settings.
3. **Free.** The wall is a viewer; nothing on it is gated.
4. **It never opens by itself**, and offers nothing. Ways in: the Agents board's Watch button (every iPhone and iPad), Open in New Window on iPad (its own scene, so it can sit in Stage Manager or on a display), the keyboard on iPad, and the Mac and Linux Agents windows.
5. **Performance first.** One render pass, instanced, preallocated, triple-buffered; words change once a second, never per frame; the frame cap of §5 is a Core function every client obeys; nothing draws while hidden.
6. **One place to change it**: Style on the wall's own controls. No second copy in Settings.

## 11. Mocks, and what looking at them changed

The prototype on the canvas is WebGL standing in for Metal (`docs/agents-watch-ios-mocks/watch-engine.js`: the timings, layout rules and shader maths are the spec). Rendering it on every pose changed five things:

- Tiles on an iPad were mostly empty: the words grew to three lines and the last steps now list under them in past tense (*Changed Backoff.swift*), fading with age.
- The heartbeat read as dots: bars got a higher floor and a taller strip.
- Worker names lost to their ages in narrow tiles: the name wins and the age goes.
- Recent and Also running collided on half-width rails: a narrow rail shows Recent and one `+N also running` chip.
- The laptop base had one orphan button: it now carries the ask's hold, Dim and Style as three pills on the stable base.

## 12. Core API (the build contract)

All toolkit-free, in `TailscodeCore`, tested on Linux. Clients only draw.

- `AgentWall.read(…, pages: Bool = false)` and `reflowed(…, pages:)`: with `pages`, `WallGrid` puts tiles in two columns (one per page of a book), rows = ⌈n/2⌉, one tile alone in one column, never a span across the fold.
- `WallStyle` (`WallStyle.swift`): `Codable` with tolerant decoding (a missing or unknown key keeps the Studio value), presets `.studio`, `.nightDesk`, `.showcase`, and every field of §6 (`preset`, `effects`, `field`, `light`, `moves`, `dimAfter: TimeInterval?`, `night`, `keepAwake`, `still`, `showsClock`, `showsHour`, `showsRails`, `showsSquads`, `approvals`). `amplitude` (0, 1, 1.6), `moves(_ kind: WallEvent.Kind)`, `isNight(at:calendar:)` (22:00–07:00 local for `.scheduled`), `encoded()`/`decoded(_:)` as JSON text; changing any field by hand makes `preset` `.custom`.
- `WallEvents.between(_ previous: AgentWall?, _ next: AgentWall) -> [WallEvent]` (`WallEvents.swift`): `joined`, `left`, `asked`, `answered`, `finished`, `failed`, `stopped`, `retried`, `quiet`, `resumed`, `compacted` (context share fell by 0.2 or more), `away`, `back`, `step` (a working tile's newest step or words changed, or its beat's last bucket grew), `workerStarted`, `workerEnded`, `workerQuiet`, `workerStuck`. A first read (`previous` nil) says nothing.
- `WallEffect` and `WallEffectQueue` (`WallEffects.swift`): an effect is a kind (`spark`, `thread`, `dissolve`, `exhale`, `groundRipple`, `knock`, `fracture`, `pulse`, `approved`, `drain`, `gather`, `scatter`, `fade`), the tile and worker it hangs on, `start` and `duration` on the client's seconds clock, an ink role, an amplitude, a seed, and for `drain` the context share it falls from and to. The queue maps events to effects per §4 (two knocks 0.34 s apart, exhale plus a ripple, fracture plus a red ripple), honours `style.moves` and `style.amplitude`, turns everything into `fade` (or nothing, for spark, thread, dissolve, gather, scatter) when `style.still`, coalesces sparks to two a second per tile, holds at most 40 live and 3 per tile, never drops an ask's or a failure's, and prunes finished ones.
- `WallCadence.cap(effectsLive:breathing:dimmedCalm:hidden:lowPower:thermal:proMotion:) -> Int` (`WallCadence.swift`): 0, 1, 15, 20, 30 or 60 by §5.
- `WallPalette` and `WallInk` (`WallPalette.swift`): the Linux `WatchPalette` formulas from a theme's dark `Palette`, `night()`, `ink(for: WallState)`, `ink(_ role:)`, `mood(_:hasFailure:)`.
- `WallLayout.make(width:height:safe:fold:wall:style:drift:)` (`WallLayout.swift`): the modes of §2 (`stack` reproduces the Linux `WatchGeometry`; `side`, `book`, `laptop` as the prototype), every rectangle in points: headline (and its line count), watch line, clock, date, grid, a cell per tile, squad rectangles from `WallSquad`, ribbon, rails, controls (laptop base), the calm centre; `WallLayout.reading(width:height:safe:fold:)` gives the `aspect`, `gridAspect` and `pages` to read the wall with.
- `WallMotes` (`WallMotes.swift`): the Linux `WatchMotes` field, count by area (18 to 96), with a four-point trail for Currents.
- `WallScene.build(_:)` (`WallScene.swift`): one frame as plain values for a renderer: tint and its strength, vignette, dim, drift, lights (≤ 8), ripples (≤ 12), plates, glyphs (drawn over) and glows (added light), dots (motes and particles). Glyph kinds, plate looks, breath and knock periods and every effect's shapes are the prototype's (`docs/agents-watch-ios-mocks/watch-engine.js`: `tileGlyph`, `workerGlyph`, `plateLook`, `tileSwell`, `drawFx`) and the Linux painters' (`AgentsWatchGlyph`, `AgentsWatchTilePaint`). Effect shapes are also available alone (`WallEffectShapes.shapes(for:at:anchor:unit:)`) for the Cairo wall.
- Parity: `agentsWatchEffects`, `agentsWatchStyle`.
