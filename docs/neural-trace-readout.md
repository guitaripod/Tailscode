# Neural trace: the card, the docked stage and the readout

Second pass on the brain's chat surface, from Marcus's review of the first build on Linux: the inline brain is too small to read at a glance, the move from inline to open is a jump, and the open head sits centred with its hover card floating over the picture, covering the thing being read. This document is the contract for the next pass. Linux ships first; the Core pieces below are toolkit-free so the Mac and iOS take the same behaviour afterwards.

## What changes, in one paragraph

A settled turn is a **card**, about 112 px tall, whose picture is the head itself (rest render, one light per zone sized by what the turn did there) with the turn's numbers beside it, instead of a 28 px glyph on a text line. Opening it **docks the head to the left** of the row and gives the right side to a **readout**: whatever is hovered, focused or pinned is read out there in full (the command, the agent's reason for it, the output, the diff, what it relates to), tied to its node by a leader line; with nothing hovered the readout is the turn's digest, and while the turn runs it follows the step that is happening now. The card becomes the stage by one choreographed move (about 320 ms, display rate, ease-out) in which the card's own head is the element that travels and grows.

## 1. The card (collapsed turn)

Size and place: full row width, 112 px tall in Comfortable density, 84 px in Compact (`ChatDensity`), a raised canvas surface with the theme's hairline and a 3 px left edge in the turn's tone (accent for settled, danger for failed, attention for waiting; quiet for stopped). The whole card is one button (cursor, focus ring, Enter/Space opens); Replay and Rows are small secondary buttons that do not open it.

Left, the picture (148 x 97 at Comfortable, 112 x 73 at Compact; the head's 640:420 aspect, never cropped): the real head, rendered once per theme and size as a dark rest picture and shared by every card, with, per card, a soft light centred on each zone's well whose radius and strength follow the zone's step count (`NeuralGlyph`'s rule: 44 + 12 x min(n, 4) design units at .62 + .1 x min(n, 4) opacity), the eye wearing the settled colour (model family, effort bars), a danger ring on a zone with an unrecovered failure and nothing on an empty zone. A card is therefore recognisable by which parts of the head are lit, which is the whole point of the zones. It costs one shared surface plus six radial gradients per card; never a compositor render per card.

Right, three lines:
1. Headline: the count as the display number ("25 tools", `Typography` display role, tabular), then duration, then the tally (`+5 -2`) and the failure clause ("1 failed, then passed") in the tone of its meaning.
2. Zone strip: up to six chips for the zones that have steps (zone glyph in its colour, label, count), in zone order, each a hit target that opens the brain already diving into that zone.
3. Digest: one sentence from `NeuralReading` ("Ran 18 commands, read 3 files, edited 2. Wrote out/demo/tailscode-demo.mp4."), one line, truncated by whole clauses never mid-word.

Hover: the picture's lights rise 15 %, the card lifts its hairline to the tone, the pointer is a hand. Narrow rows (under 460 px) drop the zone strip first, then the digest; the picture, headline, Replay and Rows stay.

A running turn has no card: the latest turn is open (section 2) and becomes a card when the next turn starts or the person closes it.

## 2. The open brain: stage left, readout right

Breakpoint on the row's width W:

| W | Layout |
|---|---|
| 860 and up | Split: stage S = clamp(0.54 W, 420, 720) flush to the row's left edge, 24 px gutter, readout R = min(W - S - 24, 560), at least 300; if W - S - 24 exceeds 560 the stage grows to absorb it up to 760 |
| 560 to 859 | Split with a narrower stage (S = 0.5 W) and R = the rest, the readout's type one step down |
| under 560 | Stacked: the stage full width (cap 760) and the readout below it, as a two-line strip that grows to the full readout when something is pinned |

The stage's height is S x 420 / 640. The readout is exactly as tall as the stage in a split (min 300) and scrolls inside when its content is taller; under it, across the full row, sits the footer: scrubber, Replay, Share, provenance chips ("In the answer"), as before. The row never changes height while the pointer moves.

The stage has no frame of its own beyond what the head's chassis draws (no card around the picture): it sits directly on the transcript's canvas so the readout reads as its HUD, not as a second box. The readout is a plain column: no card, a 1 px hairline on its left edge in the quiet ink, content on the canvas.

### The leader line

When a node is hovered, focused or pinned, a thin line (1.25 px, the zone's tone at 70 %) leaves the node, runs on the same 45-degree routing the wires use (a short stub, a diagonal, then horizontal) to the readout's left edge and ends in a 4 px dot beside the readout header. It is drawn in the node layer, above the wires, below the nodes, never through other nodes' labels (route around the node cluster by going up or down first, whichever side has fewer nodes under it), and animates in over 120 ms by drawing along its length. A pinned node keeps its line steady; a hovered node's line fades 120 ms after the pointer leaves unless the pointer moves into the readout (then it stays: the readout is something you can move into to select text, scroll, press a button).

### The readout

Three modes, one component. Content cross-fades in 90 ms when the subject changes; the panel itself never moves.

**Step** (hover, focus or pin). From the top:
1. Header row: the zone's shape glyph in its colour, the zone label (PLAN, SENSE, ACT, SHELL, DELEGATE, SAY) in the label role, a status chip (DONE, FAILED, RUNNING, WAITING FOR YOU, STALLED, STOPPED, RETRIED) in its tone, and on the right "18 of 29" tabular. The pinned state adds a small pin mark.
2. Subject: the tool's name in the heading role, then its primary argument as the thing you came to read: a shell command in the mono role, wrapped (never truncated) up to 4 lines with "Show all" for longer; a path with the directory dimmed and the file name emphasised and a Copy button; a search pattern with its scope; a URL; a subagent's description.
3. Why: a short quotation block with a 2 px left rule in the zone's tone and the label WHY, holding the reasoning or note that came immediately before this step in the transcript (up to 240 characters, whole words, "Show more" expands in place). A step with nothing before it (a first call) omits the block; this is the line that turns mechanics into intent.
4. Result: for a shell step the output lines in the mono role, the first 8 in the dim ink (failed output in the danger tone, the line that matches `error:`/`FAILED` in full ink), "N more lines" expands the block to a scrollable region (max the panel's height); for an edit a mini diff of up to 14 changed lines with gutters, removed lines on a danger wash, added on an accent wash, "+5 -2" in the header of the block; for a read the path and the lines read; for a search its first matches; for a subagent the result's first lines and an "Open agent" button that reveals its card.
5. Relations: chips that light the related nodes on hover and pin them on click: "same file as 3, 5, 22", "same command as 11", "retried at 11" (a failed step with a later identical success), "caused by 7" is NOT shown (the transcript does not say it).
6. Footer facts in the quiet ink, tabular: message number, clock time (the message's), "started 21:52:22". No duration appears anywhere until the bridge stamps tool times (see `docs/neural-trace-states.md`): never infer one.

**Digest** (nothing hovered, turn settled). The headline sentence of the turn; the zone bars (a horizontal bar per zone, length proportional to the busiest, click dives into the zone); a timeline strip: one tick per step in order, coloured by zone, failures taller and in danger, the answer's end marked, hover a tick = hover that node, drag across = scrub (it is the scrubber in another form: the footer keeps the scrubber, the strip is the map); **Changed** (each edited or written file: path, +/- bars, click pins its step); **Failures** (each failed step with its first output line and "retried at N" or "never retried"); **Answer** (the final message's first line) with the provenance chips.

**Now** (the turn is running and nothing is hovered or pinned): follows the step that is happening: a "NOW" label with the pulse of the state, the tool and its argument as in Step, the WHY block from the live reasoning, the output tail streaming (last 8 lines, auto-scrolling, mono, with a quiet caret), and under it "So far": the digest's headline and zone bars compactly. Hovering or pinning any node shows that step instead; 1.5 s after the pointer leaves and nothing is pinned the panel returns to Now with a cross-fade. A step that waits on the person (approval, question) replaces Now with the ask in the attention tone and a button that scrolls to the approval or question card, because the approval itself is not duplicated here.

**Zone** (after clicking a zone name or chip): the zone's steps as a list (number, title, argument on one line, status tone), selectable; this is the dive's list, moved from an overlay into the panel. The head dives into the zone on the left as before; Esc surfaces.

**Replay**: Step mode, driven by the playhead: the panel shows the step currently firing and a log of the steps before it (newest first) so the replay reads as a transcript scrolling past.

## 3. The transition: card to stage (and back)

One choreography object in Core (`NeuralTransition`), driven by a progress value p in [0, 1] from the display clock; Core owns every curve, the client only applies the numbers. Opening takes 320 ms with `easeOutCubic` on geometry (snappy: 70 % of the movement in the first 40 % of the time), closing 220 ms with `easeInCubic` reversed, a new turn arriving (previous collapses while the new one opens) 280 ms with both at once.

Opening, in order (all times from the press):

| t (ms) | What moves |
|---|---|
| 0 | The card's picture lifts off the card: it becomes the traveller. Its rect interpolates from the card's picture rect to the stage rect (both in row coordinates), a scale from about 0.23 to 1. The row's height eases from the card's height to the stage's height over the same time. The scroll anchor holds the row's top (no jump of the content above); content below is pushed by the row's height as it grows. |
| 0 to 90 | The card's text, chips and tone edge fade out and slide 8 px left; the card's surface fades out. |
| 40 to 200 | The head "powers on": the interior's sweep band crosses once left to right (`NeuralFrame.sweep`, tone live) while the zones come up from their card brightness to rest (the traveller is the real head, so nothing is redrawn at the end). |
| 120 to 300 | The nodes appear in step order, staggered across 150 ms (each pops from 0.6 to 1.0 scale with a 6 % overshoot and fades in), while the wires draw along their length (dash offset) just behind them; ties last. |
| 150 to 320 | The readout fades in and slides from 24 px right to 0; its first content (Now or Digest) cross-fades in 90 ms after it lands. |
| 240 to 320 | The footer (scrubber, Replay, Share, chips) fades in. |

Closing is the same in reverse, faster, with no overshoot: footer and readout out first (0 to 100), nodes and wires gone by 150, the head shrinks back into the card's picture rect while the card fades in under it, the row height eases back; the card's lights are already correct because the card's picture draws from the same turn.

Rules: the traveller is one surface (the settled interior and front from the compositor at the stage size, scaled with cairo's bilinear filter during the move: sharp enough at 0.23 to 1.0 for 300 ms, no per-frame compositor work except the sweep's six frames); live compositor frames take over at p = 1. Display rate during the move (`NeuralTempo.display`), 30 fps otherwise. Reduced motion: a 120 ms crossfade, no travel, no sweep, no stagger. A strained or critical `TileGovernor` level: no sweep, no stagger, 160 ms. If the row is off screen when the state changes (a toggle by keyboard from the find bar), no animation, just the end state. The person can press during the move: reverse from the current p, never restart.

## 4. The paths

1. **Scanning history.** A scroll through an old conversation reads as a column of cards: each says how big the turn was and which parts of the head it used; failures wear the danger edge and ring so they catch the eye.
2. **Opening one.** Click or Enter on a card; the head travels left, the readout opens on the Digest. The previous open brain collapses at the same time (one open per conversation) with the same move reversed, so the two motions cross rather than queue.
3. **Reading a step.** Move over a node: the readout switches in 90 ms, the leader line draws, the related nodes' wires light. Move the pointer toward the readout: the line stays, the content stays; select text, press Copy, scroll the output, press "Show all". Move away: 400 ms later the digest returns (Now when live).
4. **Pinning.** Click a node (or Enter when focused): the pin mark appears, the readout stops following the pointer; another click on the same node, Esc or a click on empty stage unpins. Clicking a relation chip pins the related step.
5. **Keyboard.** The stage takes focus on Tab; Left/Right and Up/Down walk steps in order and by zone, Return pins, Esc clears, `c` copies the subject (command or path), `o` expands the output, Tab moves from the stage to the readout's buttons then the footer. The readout is a labelled region; every change is announced by `NeuralReading.announcement`.
6. **Watching live.** The latest turn is open while it runs; the readout says Now, with the output tail streaming; nothing ever steals the pointer or the scroll. When the turn ends the head settles (eye takes the family colour), the readout cross-fades to the Digest and stays open until the next turn begins or the person closes it.
7. **Waiting on the person.** A waiting node knocks (the heartbeat), the readout shows the ask in the attention tone and a "Go to approval" button; the node is also announced.
8. **Dive.** Zone name or zone chip on the card: the head dives, the readout shows the Zone list, a row in it pins that step on the stage. Esc surfaces.
9. **Replay.** Replay on the card or the footer: opening (if closed) then the playhead; the readout is the Replay log; scrubbing the timeline strip or the footer scrubber moves the same playhead.
10. **Share.** Footer, as built.
11. **Find.** In-conversation find that matches a step opens that turn's brain and pins the step, with the match highlighted in the readout's text.
12. **Narrow or tiled panes.** Below 560 px the stack layout; the readout strip shows the title line and status only until pinned, then grows; the move is the same choreography with the readout sliding up instead of in from the right.
13. **Empty and tiny turns.** A turn of one or two steps still gets a card (picture and numbers) and opens to the same layout; nothing is hidden for being small.
14. **Failure and retry.** The failed node wears its ring; hovering it reads the error output in full ink; its relation chip "retried at 11" pins the retry; the digest's Failures list is the fast path through every failure.

## 5. Details that decide whether it feels right

- The picture on the card and the stage head are the same surfaces, so the travel never swaps images; check the colour of the card's rest render equals the stage's rest at every theme (both come from the compositor with the same palette).
- The readout's text never reflows while the pointer moves between two nodes: the panel has a fixed width and content height changes are absorbed by its scroll region, with the header row and the footer facts pinned at the top and bottom of the panel.
- Hover intent: a node is "entered" after 40 ms of pointer rest or at once when the pointer arrives from another node; leaving a node starts a 400 ms grace so a drift across a wire does not flash the digest.
- The leader line is part of the node layer's wire set (same stroke caps, same colour space) so it looks printed on the same board.
- Numbers are tabular wherever they can change (step counter, counts, the tally); the mono role is used for commands, paths, output and the clock only; labels use the label role with tracking; no new type sizes.
- The readout's links to the transcript use the same words as the rows ("Rows", "Open agent").
- Colours come only from the theme's slots through `NeuralPalette` and the activity tones; the diff washes are the accent and danger slots at 14 % alpha on the canvas.
- Scroll anchor: every height change in the row holds the row's top; if the row's top is above the viewport (opening a card that is partly scrolled off) the anchor is the viewport top and nothing visible jumps.
- Hit testing is in design space with the existing slop; the readout does not capture the pointer outside its own rect, so moving from a node to the right edge of the stage never lands in a dead strip: the 24 px gutter belongs to the stage for hover purposes.

## 6. Core pieces (toolkit-free, shared by all three clients)

- `NeuralReadout`: `NeuralReadout.make(model:selection:mode:...)` returns the content for the panel as plain values: header (zone, label, status, counter, pinned), subject (kind, primary text, secondary), why (text, expandable), result blocks (output lines with tones, diff lines with kinds, read facts, matches, subagent summary), relation chips (kind, label, step ids), facts, and for the digest the headline, zone bars, timeline ticks, changed files, failures, answer. Every word comes from `NeuralReading`; every step id is from the layout.
- `NeuralBrainCard`: the card's content: headline, tally, failure clause, zone chips (zone, count, tone), digest sentence, picture lights (zone, radius, strength), tone edge.
- `NeuralStageMetrics`: `NeuralStageMetrics.make(width:density:)` returns the layout (split or stacked, stage rect, readout rect, gutter, footer, card height, picture rects), so the breakpoint arithmetic exists once.
- `NeuralTransition`: `NeuralTransition(direction:from:to:reduceMotion:level:)`, `.frame(at p:)` returns every element's rect, alpha and scale (traveller, card text, card surface, row height, sweep amount, node reveal count and per-node progress, wire draw fraction, readout offset and alpha, footer alpha) and `.duration`; `.reversed(from p:)` for a press mid-move.
- `NeuralLeader`: `NeuralLeader.route(from node:, to anchor:, around nodes:)` returns the polyline in design space and its length for the draw-along animation.

Clients draw these; they decide only how a rect is painted.
