# Neural trace: states, meters and the world outside the chat

The second half of the neural trace design (`docs/neural-trace.md` is the first): what the head does in every state a conversation can be in, what it carries besides the steps, and where it appears when the app is not in front. Design board: `.tailscode/design/neural-trace/` (G States, H State sheet, I Away, J Share a turn, F The layout). Screens: `docs/neural-trace-mocks/`. Mock sources and the capture scripts: `docs/neural-trace-mocks/src/`.

## Look: what the app already says

- `ActivityKind` is the one vocabulary for "not idle" (`Activity.swift:331`). Each case carries a symbol, a glyph, a tone (live, attention, danger, quiet), a word and a motion. Live: working, thinking, writing, usingTool, delegating, inBackground (breath). Attention: stalled (still), retrying, compacting, reconnecting (sweep), needsApproval, needsAnswer (heartbeat). Quiet: queued (still), connecting (sweep), offline (still), idle. Danger: failed (still).
- Motion is arithmetic on absolute time (`ActivityPulse.phase`): breath is one raised cosine of 1.9 s with a floor of 0.34, heartbeat two beats in 1.6 s (floor 0.42, beats at phase 0.08 and 0.25), sweep a 1.05 s cycle, still fully lit. Reduced motion maps everything to still.
- The in-flight priority is compacting, needsApproval, needsAnswer, retrying, usingTool, writing, thinking (`ActivityKind.inFlight`). A quota wall in front of the model lands on `failed`.
- Three endings have no face: a turn stopped by hand, an interrupted turn and an answerless turn are cards. A pending send has ink, not a face. Unread is a dot.
- The presence orb already maps these the same way: wants you is attention and heartbeat, in flight is live and breath, failed is danger and still, offline is quiet and still.
- `docs/chat-design.md`, principle 1: one fact, one place. What is happening is the status line, what waits for you is the dock, what is true of the conversation is the facts row, what you can choose is the controls row.
- Model and effort: five bars (`EffortMeter.bars`), a power (ultracode) lights all five in the rainbow (`Ultracode.rainbowStops`), the server's choice is hollow, and the family hue is `ModelTint.Family` (fable #d97757, opus #a78bfa, sonnet #38bdf8, haiku #3fc47c, and so on).
- Context fill is `ContextFill` over `ChatMessage.context`: attention at 0.5, danger at 0.8, and a basis (reported, compacted, estimated shown with `~`).
- A voice call has its own faces (`VoiceCallFace`): connecting sweeps, listening breathes, hearing is lit and still, degraded is danger and still, ended is quiet and still.
- Surfaces away from the chat: the Live Activity draws SF Symbols and system colours only (`PhaseIcon` 36 pt expanded, 40 pt on the Lock Screen, compact `.caption2`); the notification face is drawn in UIKit (`NoticeFace.image(for:side:)`, 46 pt in the long look); the share card is a 1080-wide poster in pure geometry (`AnalyticsShare.Card`).
- Haptics: `HapticCue.Group.waiting` is send, step, needsYou, received, with a minimum gap of 0.5 s on step and 0.08 s on the rest.

## Think: the rules this sets

1. **One reading, two renderings.** The head's whole-body state is a function of the same `ActivityKind` the header, the orb and the rows read. It adds no state the app lacks, and where the app gives a state no face (stopped, interrupted, answerless) the head stays neutral and the card carries the news.
2. **The zone that lights is the tool family the header already names.** Thinking is PLAN, writing is SAY, usingTool by kind is SENSE, ACT or SHELL, delegating and a Task node are DELEGATE; a waiting approval lights the zone of the waiting tool, a question lights PLAN. Compacting, retrying, connecting, reconnecting, queued, offline and background belong to the whole head.
3. **Tone is the eye and the lit zone; motion is the activity's own.** Live is the theme's accent, attention is `warn`, danger is `danger`, quiet is the muted ink. The periods are the constants above, never a tuned number.
4. **Stillness is meaning.** Every still state is one frame and draws nothing after it. Only breath, heartbeat, sweep, a compaction and a call's listening keep a loop, and the loop stops when the state does.
5. **The eye carries one thing at a time.** While a state has a tone (live, attention, danger) the eye wears the tone. A settled turn has none, so the eye then wears who answered and how hard: the family's hue and the effort bars. This lets a collapsed turn's glyph answer "which model, and did it end well" at a glance.
6. **Every fact keeps its home.** The head does not restate the model pill, the context chip or the call strip; it is an indicator beside them, never the only place. Rows lists every step and the header still says the state in words.
7. **Claim only what the transcript can show.** Provenance matches literal paths and commands; a replay uses message times; nothing is sized or timed by a duration the wire does not carry.

## Design

### States (G, H)

| State (ActivityKind) | Tone · motion | Head |
|---|---|---|
| idle | quiet · still | rests, eye dim |
| a turn that ended well | none · still | eye wears family hue and effort bars |
| thinking | live · breath | PLAN breathes |
| usingTool Read, Grep, Web | live · breath | SENSE breathes |
| usingTool Edit, Write | live · breath | ACT breathes |
| usingTool Bash | live · breath | SHELL breathes |
| writing | live · breath | SAY breathes |
| delegating | live · breath | DELEGATE breathes; a Task node opens a smaller head |
| inBackground | live · breath | eye breathes, one satellite circles the dome, zones step back |
| needsApproval | attention · heartbeat | the waiting node and its zone beat twice, eye attention |
| needsAnswer | attention · heartbeat | the question beats in PLAN |
| stalled | attention · still | the stuck node's zone held in attention |
| retrying, reconnecting | attention · sweep | a band crosses the dome |
| compacting | attention · sweep | the band plus a crunch: the galaxies draw in, the ribs drop to what was kept |
| connecting | quiet · sweep | a quiet band |
| queued | quiet · still | dim, held |
| failed, quota wall | danger · still | eye and the failing zone hold danger, the rest steps back |
| stopped, interrupted, answerless | no face | neutral, the last node dashed |
| offline | quiet · still | dark: zones, seams and eye off, nodes desaturated |

Node-level states are separate from whole-body ones: a waiting node beats and wears attention with a `⏸` or `?`, a failed node keeps its mark, a stalled node is dashed, a stopped node is dashed and neutral.

### Face and meters (G)

- **Who and how hard.** The visor is the five-bar effort meter: a tier lights its rank, a power lights all five with the rainbow, the server's choice is five hollow bars, below low is one ember bar. The family hue colours the settled eye. A glyph's eye in a collapsed line is the same: the family hue, or danger for a turn that failed.
- **Context fill is the neck.** Six ribs light from the bottom up with the fill, quiet then attention at 0.5 then danger at 0.8; an estimate draws at half strength. Compaction drops them to what was kept while the interior crunches.
- **A voice call is the ear.** The baked ear rings follow `VoiceCallFace`: listening breathes, hearing is lit and still, connecting ripples, degraded holds danger, ended is quiet.

### Replay, provenance (F)

- **Replay a turn** is opt-in: a scrubber and a play button under the open brain, mapped from message times with long gaps compressed (a gap over 20 s plays in about 1.2 s) so eight minutes replays in about twelve seconds. It never starts by itself; coming back after an absence still reads the present once.
- **Answer to brain.** A path or command quoted in the answer lights the steps whose input or output contains it, and dims the rest. The match is literal and the answer is the trailing text after the last tool part of a turn that ended cleanly. A phrase that is not a literal token links to nothing.

### Away (I)

- Lock Screen card and the expanded island: the head replaces the tinted circle's symbol: eye is the state tone, a ring on the lit zone, dots for what the turn touched. Compact leading and minimal stay the tinted symbol; 14 pt is below a head's floor.
- Notification long look: the head at 34 to 46 pt in the tone tile, with the buttons the kind already has (Reply, Try again, Approve and Deny). No notification exists while it works.
- Home's row keeps its tinted tile and symbol: the symbol names the tool kind, which the head cannot at 24 pt, and the tile tint already carries the tone. The comparison is in the sheet; the head is not proposed there.
- The glyph is data in Core (`NeuralGlyph`: the outline points, a dot per zone with a count-based radius and opacity, an eye bar with its halo, an optional ring), so SwiftUI paths, Core Graphics and cairo draw the same thing at 28 to 46 pt.

### Share a turn (J)

A 1080-wide poster like `AnalyticsShare.Card`: brand, the head as the hero (968 by 590), the tool count and time, `+N −M` lines, a failed-then-passed note, six zone meters, the question that started it, and a footer that says it is counted from the transcript. Two looks (the app theme and one poster look). No cost or speed, because the transcript cannot prove them. The replay clip follows the same frame.

### Haptics, accessibility, budgets

- Haptics: a node firing plays `step` (the existing 0.5 s gap makes a burst of tools one felt progress), a waiting node plays `needsYou` once per heartbeat cycle start, settling plays `received`. Hover and dive play nothing.
- Spoken: `NeuralReading.spoken` writes the turn from counts ("25 tools in 8 minutes 25 seconds. Ran 18 commands, one failed and then passed. Read 3 files. Edited 2 files, 5 lines added and 2 removed."). A node is announced as "step 6 of 29, Bash, failed, swift build…". Rows is the same list. Colour is never alone: shape, the `⏸` and `?` marks, and the header's words carry every state.
- Reduced motion: every state held still in the same tone. Tone, node mark and the header still say it.
- Budgets (the numbers and the order of changes are in `docs/neural-trace-performance.md`): the brain runs at the app's activity tempo, 30 fps. `TileGovernor` calm draws the full brain; strained and above drop the ripple, the sweep and the crunch; critical keeps the glyph only. Low-power mode (read by the client, there is no Core setting) counts as strained. Only one brain is open per window.
- Light themes: the head is a dark object on any canvas. Glow tones lift toward white (`NeuralPalette.glow`) because additive light needs a dark ground, the glow no longer spills outside the chassis on a light page, and the node stage lifts its colours. Rosé Pine Dawn is the reference; the code has eight themes (the older docs say seven), each with a light face.

## Core contract

Toolkit-free, never `@MainActor`, everything pure and tested.

- `NeuralState`: from `ActivityKind` (and an ending outcome) to `{ tone, motion, zone?, whole-head effect }`.
- `NeuralFrame.at(time, state, face, meters, reduceMotion)`: the 13 channel intensities (think, sense, act, shell, delegate, say, links, stars, seams, eye, ribs, ear, visor), tone overrides as theme slots (not colours), sweep, crunch, effort, hollow, rainbow, ribs lit, ripple. Clients map slots through `NeuralPalette.glow` and draw.
- `NeuralFace`: family hue from `ModelTint.Family`, effort from `ModelDial.heat`.
- `NeuralMeters`: context ribs and tone from `ContextFill`, call ear from `VoiceCallFace`.
- `NeuralGlyph`, `NeuralReading`, `NeuralTimeline` (message times, compressed gaps), `NeuralProvenance` (literal matches), `TurnAnswer`.
- `NeuralShare.Card`: the poster geometry.

Shader uniforms (both programs): `uTone[13]`, `uInt[13]`, `uTime`, `uRipple`, `uSweep`, `uSweepAmt`, `uSweepTone`, `uCrunch`, `uCz[6]` (the zone centres), `uEffort`, `uHollow`, `uRainbow`, `uCtx`, `uSpill`, and the dive transform. The reference GLSL is `docs/neural-trace-mocks/src/hero2.js`; the Metal port is a transliteration.

## Work packets for the implementation phase

1. **Core**: the types above, `AppCapability.neuralTrace` and the three manifests, tests for the state table, the frame constants, provenance, the timeline and the glyph. Proof: `swift test` in TailscodeCore and `scripts/parity.sh --check`.
2. **Assets**: re-render at 1536 with `scripts/neural-head/render.sh` (about 20 minutes, one pass at a time; set `NEURAL_DEVICE=cpu` when the GPU is busy), choose the compression per platform, one catalog per client.
3. **iOS**: two `CAMetalLayer`s, the node layer between them, the run-line glyph, `PhaseIcon` replacement on the Lock Screen and expanded island, `NoticeFace` drawing, the share painter. Marcus installs and checks on the iPhone Air.
4. **Mac**: the same renderers, installed with `scripts/install-macapp.sh`.
5. **Linux**: two `GtkGLArea`s with epoxy, the nodes as widgets between, installed with `scripts/install-linuxapp.sh`.
6. **Kit and bridge, optional**: stamp `tool_use` and `tool_result` times so a card can say how long a step took.

## Mocks, and what looking at them changed

- The baked plate carried the glow, so "offline" could not go dark and the eye never changed: emission in the plate dropped to 12 percent and the glow now comes only from the masks.
- A global tone map crushed a light page to grey: the glow is added with a screen blend, so the page keeps its own colour.
- The neck ribs were a pixel thick and invisible: thicker, six bands, bottom-up.
- Failed left the other zones glowing and read as "something failed in shell": the rest now steps back to a tenth.
- The head's eye at 44 pt could not carry a tone: a larger eye with a halo, and the compact island keeps the symbol.
- Putting the head on Home's row added nothing the tinted tile and the symbol did not already say: kept as a comparison only.
- A working Live Activity needs no notification: the cell now says so.
- Earlier mocks breathed at 2.4 s; the app's breath is 1.9 s and its heartbeat 1.6 s: the mocks and the doc use the real constants.
- The eye could not carry both tone and identity: the state owns it, and identity shows only when settled.
- Light themes needed their own node colours inside the dark dome.

## Open

- Decide whether the glyph's eye wearing the family hue is wanted in history, or only the outcome's tone.
- Decide whether replay and the share poster ship with the first release or follow it.
- Not measured: phone frame cost, block-compressed texture size, a real GPU in the browser mocks (all captured in Chromium's software GL).
