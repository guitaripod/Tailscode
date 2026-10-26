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
| External display | any | The wall in its own non-interactive scene; the iPad or Duo stays the remote (Now board) |
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

Night desk: no field, no light, only asks, endings and failures move, dim after 5 minutes. Showcase: Aurora and Lively. Colours always follow the app's theme, its dark side. The sheet opens from the wall's Style control and from Settings › Agents › Watch.

## 7. Touch, keys and access

- Tap a tile: the peek over the dimmed wall (doing now, last steps, agents, meters, Open chat, Nudge, Stop); back to the wall by itself after 20 s.
- Press and hold an amber tile 0.8 s: the ring fills, Face ID (`AgentsApprovalGate`), then the answer goes the board's way (`.needsChat` opens the chat). A tap only says *hold to approve*. Deny is a tap.
- Tap the ground: the controls capsule (Done, Watch · Now · Hour, Dim, Style) for 3 s.
- iPad keyboard: 1–6 peek, D dim, K keep-awake, Esc leave; the Agents shortcut from the registry opens it.
- Pointer: a tile lifts 2 pt under the pointer.
- VoiceOver: each tile is one element read as a sentence ("Fix reconnect test, working, changing Backoff.swift, 6 minutes"); an ask is announced once. Increase Contrast strengthens borders and drops glows; Reduce Transparency makes the glass solid.

## 8. Where it lives

- The Agents board gets the Watch lens beside Now (and Hour where regular width), Watch first, as on Linux. iPad's sidebar gets the Agents row that opens it; its context menu offers *Open in New Window* (its own scene, so it can sit beside Tailscode in Stage Manager).
- With an external display connected, the wall can go to it as its own scene while the device keeps the board.
- StandBy keeps the Live Activity it has; the wall needs the app open, and is not a widget.

## 9. Parity

| Capability | iPhone · iPad | Mac | Linux |
|---|---|---|---|
| `agentsWatch` | gap → implemented | gap → implemented (same renderer) | implemented |
| `agentsWatchEffects` (new) | Metal | Metal | Cairo paints the same primitives |
| `agentsWatchStyle` (new) | implemented | implemented | implemented |
| `agentsLocalWords` | stays a gap | stays a gap | implemented |

## 10. Decisions to make

1. **Mac in the same pass.** Recommended: yes; the renderer is shared and the Mac's wall is a declared gap today.
2. **Linux effects now.** Recommended: yes, in Cairo from `WallEffects`, so the three walls keep moving alike; GL only if a measurement asks.
3. **Pro.** Recommended: the wall stays free; it is a viewer, and Pro already carries delegation.
4. **Open by itself.** Recommended: no. At most an offer when the device is charging in landscape on Home, off by default.

## 11. Mocks, and what looking at them changed

The prototype on the canvas is WebGL standing in for Metal (`docs/agents-watch-ios-mocks/watch-engine.js`: the timings, layout rules and shader maths are the spec). Rendering it on every pose changed five things:

- Tiles on an iPad were mostly empty: the words grew to three lines and the last steps now list under them in past tense (*Changed Backoff.swift*), fading with age.
- The heartbeat read as dots: bars got a higher floor and a taller strip.
- Worker names lost to their ages in narrow tiles: the name wins and the age goes.
- Recent and Also running collided on half-width rails: a narrow rail shows Recent and one `+N also running` chip.
- The laptop base had one orphan button: it now carries the ask's hold, Dim and Style as three pills on the stable base.
