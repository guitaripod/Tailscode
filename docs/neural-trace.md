# Neural trace

A turn's thinking and working, drawn as one mecha brain instead of a stack of "N tools" lines. Everything the agent did before its final message is the brain; the final message is the answer below it. Design board: `.tailscode/design/neural-trace/` (A Cortex, B Lanes, C In the transcript, D The whole turn, E The hero, F The layout, G States, H State sheet, I Away, J Share a turn). Screens and sources: `docs/neural-trace-mocks/`. States, meters, the face, replay, provenance, the away surfaces and sharing are in `docs/neural-trace-states.md`. Pipeline: `scripts/neural-head/render.sh`.

## What the person sees

- **A settled turn is one line**: the status dot becomes a 28 pt head glyph whose zones glow by how many steps they ran, then the count, the duration and `+N −M`. A turn costs one line where it used to cost a run line per burst of tools plus a paragraph per note.
- **The live turn, and the latest one, open the brain** under the question, on the empty page the answer will stream onto. Nodes fire in order, the zone doing the work breathes, signals ripple out along the fibres from it, and the latest note the agent wrote replaces itself on one line under the brain.
- **Hover a node** for its card (tool, argument, outcome, the first lines of output, which message, what it shares a file or command with); the other zones dim and its wires light. Touch: tap, with the same card docked under the brain. Every node is also a row in a step list (the screen reader and touch path), and `Rows` lists every step.
- **Dive**: a zone's name dives into it. Chassis, glass and interior move at different rates, so the head flies past and the galaxies fill the screen. A `Task` node dives into the subagent: the same head, one level down, with the subagent's own steps and a breadcrumb back (`esc`).

## What the anatomy means

A fixed anatomy, so the shape of a turn reads before a word of it does, and where a thing sits says what it is.

| Zone | Tool family | Why it sits there |
|---|---|---|
| PLAN | reasoning | behind the visor, next to the status eye |
| SENSE | Read, Grep, Glob, Web | back of the head, beside the intake vents: inputs come in here |
| ACT | Edit, Write | top, the motor strip |
| SHELL | Bash | low back, where the neck cable enters: the brainstem |
| DELEGATE | Task, Skill, Workflow | a well of its own; the place a smaller head opens |
| SAY | the agent's notes mid-turn | the jaw: a speaker display |

Shapes carry the kind (circle, diamond, chipped square, hexagon, octagon, speech bubble) so tint is never the only signal. Wires are only what the transcript shows: one step after another, calls made together in one message (joined by a via dot), and a dashed tie where two steps touched the same file or ran the same command. No synapse is invented. A failed step holds still in the danger tone; a retry is the tie from the failed command to the passing one.

Nesting follows the scale rule: the head is the universe, a zone a galaxy, a step a star, and a subagent a head inside the head.

## Layout contract (Core owns it)

Design space 640 × 420, y down, the same on every client.

- Zone centres: think (456,150), act (348,104), sense (204,162), shell (240,284), delegate (396,250), say (520,306). Wells are 66 × 58 (say 56 × 38).
- A zone's steps take hex-spiral slots in order, spacing 28 (say 24), and only the slots whose node fits inside the dome (the jaw window for say) count: think 19, sense 19, act 16, delegate 13, shell 12, say 7. A zone that overflows gathers its last steps in one ganglion with a count, and `Rows` lists them. No physics: placement is pure arithmetic, so three clients agree.
- Calls in one message share a column or a fan; the wires between groups join through a via dot when both sides have several.
- The final answer is the trailing text after the last tool part of a turn that ended cleanly. `LiveActivityReading.turnAnswer` returns the last *message*, so a new Core reading is needed. There is no answer while the turn runs, when it ends on a tool (stopped, interrupted, answerless, failed) or on a question or approval; then the brain stands alone and the end is the card or the ask.

## Asset contract

Rendered once in Blender 5.2 (Cycles, OptiX) by `scripts/neural-head/render.sh`, everything procedural, no third-party assets. The camera maps the node plane to the design space exactly (135 mm lens at 24 units, plane 6.4 units wide), so a node at design `(x, y)` is at pixel `(x/640·W, y/420·H)` over the baked sockets.

| Image | Content | Alpha |
|---|---|---|
| `chassis` | the shell, window cut through | straight |
| `interior` | bay, back wall, fibres, rings, sockets, stars, haze | straight |
| `glass` | the dome and the jaw lens: specular and rim only | straight |
| `mask_i1` | R think, G sense, B act | none, linear |
| `mask_i2` | R shell, G delegate, B say | none, linear |
| `mask_i3` | R links (fibres), G stars | none, linear |
| `mask_c` | R seams, G eye (five bars) | none, linear |
| `mask_d` | R neck ribs, G ear rings, B visor backing | none, linear |
| `bloom_*` | the masks, pre-blurred, a quarter size, ×3 | none, linear |

Draw order: interior, nodes, then chassis and glass in one pass (glass over chassis). The nodes sit between the interior and the glass, which is what puts them inside the dome. Lossless WebP/PNG for masks (lossy chroma subsampling bleeds channels); the colour layers may be lossy.

At 1280 × 840 the thirteen textures decode to about 32 MB as RGBA8 (about 4 MB if block-compressed, an estimate that has not been measured). They load only while a brain is on screen (`PaneLifetime`).

## Shader contract

Two passes, no render-to-texture chain: a fullscreen triangle for the interior and one for the front. Per pixel: `colour + Σ mask · tone · intensity · 4 + Σ bloom · tone · intensity · 2`, tone-mapped and gamma-encoded.

- **Tones come from the theme's own slots**: think ink, sense info, act accent, shell special, delegate ink2, say accent/info, links and stars from accent/info/ink, seams and eye accent. One asset serves every theme.
- **Intensity is state**: at rest 0.5 everywhere; a hovered or active zone 1.05 to 1.2 and the rest 0.3; the eye breathes only while working; settled holds still.
- **Ripple** (links only, while working): `1 + 0.45 · sin(|uv − active| · 38 − t · 3.2)`, so signals appear to leave the zone doing the work.
- **Dive** is three uniform scales about the zone centre (chassis, glass, interior), chassis fading out past 1.5×.
- Settled means no frames: the loop runs only while something moves. Reduced motion lands at once.
- Context options matter: `antialias: false` and `alpha: false` lost the contexts in software GL; leave the defaults.

## Per client

Core (toolkit-free, never `@MainActor`): `NeuralLayout` (slots, groups, edges, ties, ganglia), `NeuralReading` (every word), `TurnAnswer`, an `AppCapability` case with all three manifests answering. iOS and the Mac: two `CAMetalLayer`s and the nodes as layers between them. Linux: a CPU delta compositor in Core drawn into overlaid drawing areas with the node widgets between (no GL area: the vendor EGL stack leaks while one animates). `TileGovernor` sheds it to the glyph at level 2 and above. A client decides only how a node is painted.

## Budget and honesty

- Performance has its own document, `docs/neural-trace-performance.md`: Metal on the Apple clients and a CPU delta compositor on Linux (the vendor EGL stack leaks while a GL area animates), the GPU timings on a real GPU, what each layer can lose, block compression, memory (35.7 MB now, about 4.5 MB proposed) and the ordered list of changes. A working frame is 16 µs on an RTX PRO 6000 at 1280 × 840; the phone's absolute figure is not measured.
- `ToolCall` has no per-call duration; only per-message times exist, so nothing is timed or sized by a duration. A "took 4 s" line needs the bridge to stamp `tool_use` and `tool_result` times from the JSONL.
- The nested head in the mock is a still of the composite during the dive and is swapped for the live brain at the end; the real clients re-render the same layers at the smaller size.
- Light themes are covered in `docs/neural-trace-states.md` (Rosé Pine Dawn is the reference).
- Wire fixtures to look at: `TURN` (29 steps, a failed command retried, two notes, a subagent) and `TURN_BIG` (174 steps) in the mock's data.

## Mocks, and what looking at them changed

- The first Blender render showed a milky sheet: a leftover boolean cutter and a closed cap in front of the interior. Both were scene bugs, not look decisions.
- Point lights are visible to the camera as white discs unless their radius is tiny.
- The hex sockets, rings and spiral dust made each zone read as a galaxy, which is what made the nested dive make sense.
- Mip-level bloom drew square halos; pre-blurred quarter-size bloom textures are smooth and cost two lookups.
- Rendering in parallel exhausted the GPU (19 GB free of 96); render one pass at a time.
