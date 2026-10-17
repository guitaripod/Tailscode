# Neural trace: the card, the docked stage and the readout

Second pass on the brain's chat surface, from Marcus's review of the first build on Linux: the inline brain is too small to read at a glance, the move from inline to open is a jump, and the open head sits centred with its hover card floating over the picture, covering the thing being read. This document is the contract for the next pass. Linux ships first; the Core pieces below are toolkit-free so the Mac and iOS take the same behaviour afterwards.

## What changes, in one paragraph

A settled turn is a **card**, about 112 px tall, whose picture is the head itself (rest render, one light per zone sized by what the turn did there) with the turn's numbers beside it, instead of a 28 px glyph on a text line. Opening it **docks the head to the left** of the row and gives the right side to a **readout**: whatever is hovered, focused or pinned is read out there in full (the command, the agent's reason for it, the output, the diff, what it relates to), tied to its node by a leader line; with nothing hovered the readout is the turn's digest, and while the turn runs it follows the step that is happening now. The card becomes the stage by one choreographed move (about 320 ms, display rate, ease-out) in which the card's own head is the element that travels and grows.

## 1. The card (collapsed turn)

Size and place: full row width, 112 px tall in Comfortable density, 84 px in Compact (`ChatDensity`), a raised canvas surface with the theme's hairline and a 3 px left edge in the turn's tone (accent for settled, danger for failed, attention for waiting; quiet for stopped). The whole card is one button (cursor, focus ring, Enter/Space opens); Replay and Rows are small secondary buttons that do not open it.

Left, the picture (132 x 96 at Comfortable, 100 x 72 at Compact; the head's own bounds, design x 64 to 640 over the full 420 height, an aspect of 576:420: the empty 64 units left of the chassis are trimmed, nothing of the head is cropped): the real head, rendered once per theme and size as a dark rest picture and shared by every card, with, per card, a soft light centred on each zone's well whose radius and strength follow the zone's step count (`NeuralGlyph`'s rule: 44 + 12 x min(n, 4) design units at .62 + .1 x min(n, 4) opacity), the eye wearing the settled colour (model family, effort bars), a danger ring on a zone with an unrecovered failure and nothing on an empty zone. A card is therefore recognisable by which parts of the head are lit, which is the whole point of the zones. It costs one shared surface plus six radial gradients per card; never a compositor render per card.

Right, three lines:
1. Headline: the count as the display number ("25 tools", `Typography` display role, tabular), then duration, then the tally (`+5 -2`) and the failure clause ("1 failed, then passed") in the tone of its meaning.
2. Zone strip: up to six chips for the zones that have steps (zone glyph in its colour, label, count), in zone order, each a hit target that opens the brain already diving into that zone.
3. Digest: one sentence from `NeuralReading` ("Ran 18 commands, read 3 files, edited 2. Wrote out/demo/tailscode-demo.mp4."), one line, truncated by whole clauses never mid-word.

Hover: the picture's lights rise 15 %, the card lifts its hairline to the tone, the pointer is a hand. Narrow rows (under 460 px) drop the zone strip first, then the digest, use the Compact picture, and move Replay and Rows under the headline; the picture, headline, Replay and Rows stay.

A running turn has no card: the latest turn is open (section 2) and becomes a card when the next turn starts or the person closes it.

## 2. The open brain: stage left, readout right

Breakpoint on the row's width W:

| W | Layout |
|---|---|
| 860 and up | Split: stage box S = clamp(0.54 W, 420, 720) (the head trimmed to its own bounds, so the chassis is flush with the column's left edge), 24 px gutter, readout R = min(W - S - 24, 560), at least 300; if W - S - 24 exceeds 560 the stage grows to absorb it up to 760 |
| 560 to 859 | Split with a narrower stage (S = 0.5 W) and R = the rest, the readout's type one step down |
| under 560 | Stacked: the stage full width (cap 760) and the readout below it, as a two-line strip that grows to the full readout when something is pinned |

The stage's height is S x 420 / 576. The readout is as tall as the stage in a split and never under 420 (the row is then 420 tall and the stage sits at its top), and scrolls inside, with a 16 px fade at its foot, when its content is taller; under it, across the full row, sits the footer: Replay, scrubber, Rows, Share and Close, with the provenance chips ("In the answer") from 960 px up; under 640 px Replay is its icon and the chips and Close go. The row never changes height while the pointer moves.

The stage has no frame of its own beyond what the head's chassis draws (no card around the picture): it sits directly on the transcript's canvas so the readout reads as its HUD, not as a second box. The readout is a plain column: no card, a 1 px hairline on its left edge in the quiet ink, content on the canvas.

### The leader line

When a node is hovered, focused or pinned (and, in Now mode, for the running node), a thin line (1.25 px, the zone's tone at 70 %) leaves the node, runs on the same 45-degree routing the wires use (a short stub, a diagonal, then horizontal) to the readout's left edge and ends in a 5 px dot on the hairline at the node's own row (clamped 16 px inside the header and the footer), marked by a 3 x 24 px tab on the hairline in the zone's tone. It does not end at the header: from a node low in the head that line is a 270-unit diagonal through every zone in between (see L7). It is drawn in the node layer, above the wires, below the nodes, never through other nodes' labels (route around the node cluster by choosing among lanes up to 90 units above or below the node, the cheapest by length, node hits and zone-label hits; the label boxes are 4 units wider than their text), and animates in over 120 ms by drawing along its length. A pinned node keeps its line steady; a hovered node's line fades 120 ms after the pointer leaves unless the pointer moves into the readout (then it stays: the readout is something you can move into to select text, scroll, press a button).

### The readout

Five modes, one component. Content cross-fades in 90 ms when the subject changes; the panel itself never moves.

**Step** (hover, focus or pin). From the top:
1. Header row: the zone's shape glyph in its colour, the zone label (PLAN, SENSE, ACT, SHELL, DELEGATE, SAY) in the label role, a status chip (DONE, FAILED, RUNNING, WAITING FOR YOU, STALLED, STOPPED, RETRIED) in its tone, and on the right "18 of 29" tabular. The pinned state adds a small pin mark.
2. Subject (the relations of item 5 follow it directly, before WHY): the tool's name in the heading role, then its primary argument as the thing you came to read: a shell command in the mono role, wrapped (never truncated) up to 4 lines with "Show all" for longer; a path with the directory dimmed and the file name emphasised and a Copy button; a search pattern with its scope; a URL; a subagent's description.
3. Why: a short quotation block with a 2 px left rule in the zone's tone and the label WHY, holding the reasoning or note that came immediately before this step in the transcript (up to 240 characters, whole words, "Show more" expands in place). A step with nothing before it (a first call) omits the block; this is the line that turns mechanics into intent.
4. Result: for a shell step the output lines in the mono role, the first 8 (5 when the readout is under 480 px wide) in the dim ink (failed output in the danger tone, the line that matches `error:`/`FAILED` in full ink), "N more lines" expands the block to a scrollable region (max the panel's height); for an edit a mini diff of up to 14 changed lines with gutters, removed lines on a danger wash, added on an accent wash, "+5 -2" in the header of the block; for a read the path and the lines read; for a search its first matches; for a subagent the result's first lines and an "Open agent" button that reveals its card.
5. Relations: chips that light the related nodes on hover and pin them on click: "same file as 3, 5, 22", "same command as 11", "retried at 11" (a failed step with a later identical success), "caused by 7" is NOT shown (the transcript does not say it).
6. Footer facts in the quiet ink, tabular: message number, clock time (the message's), "started 21:52:22". No duration appears anywhere until the bridge stamps tool times (see `docs/neural-trace-states.md`): never infer one.

**Digest** (nothing hovered, turn settled). The headline sentence of the turn; the zone bars (a horizontal bar per zone, 6 px tall on an 18 px pitch, length proportional to the busiest, click dives into the zone) with the timeline strip directly under them as one block; then Failures when there are any, then Changed, then Answer. The timeline strip: one tick per step in order, coloured by zone, failures taller and in danger, the answer's end marked (its label sits left of the mark so it never clips), hover a tick = hover that node, drag across = scrub (it is the scrubber in another form: the footer keeps the scrubber, the strip is the map); **Changed** (each edited or written file: the last two directories dimmed after an ellipsis, the file name emphasised, +/- bars, click pins its step); **Failures** (each failed step with its first output line and "retried at N" or "never retried", placed above Changed because it is the thing a person came to find); **Answer** (the final message's first line) with the provenance chips.

**Now** (the turn is running and nothing is hovered or pinned): follows the step that is happening, keeps the leader line to its node, and shows: a "NOW" label with the pulse of the state, the tool and its argument as in Step, the WHY block from the live reasoning, the output tail streaming (last 8 lines, auto-scrolling, mono, with a quiet caret), and under it "So far": the digest's headline and one row of zone chips (the card's, not the bars). Hovering or pinning any node shows that step instead; 1.5 s after the pointer leaves and nothing is pinned the panel returns to Now with a cross-fade. A step that waits on the person (approval, question) replaces Now with the ask in the attention tone and a button that scrolls to the approval or question card, because the approval itself is not duplicated here.

**Zone** (after clicking a zone name or chip): the zone's steps as a list (number, title, argument on one line, status tone), selectable; this is the dive's list, moved from an overlay into the panel. The head dives into the zone on the left as before; Esc surfaces. The dive keeps the full 640-unit frame (no trim) because the zone fills it, and its leader is drawn in pixels above the nodes.

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
12. **Narrow or tiled panes.** Below 560 px the stack layout (no leader line: the strip is directly under the stage and wears the zone's tone on a 3 px left edge); the readout strip shows the title line and status only until pinned, then grows; the move is the same choreography with the readout sliding up instead of in from the right.
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

## 7. Third pass: the step list, and a smaller head (from Marcus's second review)

Marcus, after using the docked stage: "I want the robot to be relatively smaller than it currently is, and the list of actions that have been done should have a great way to browse through them for both mouse and keyboard. Currently you gotta hover over the numbers with the mouse and that's not great and it's not cohesive. Make this UX supreme." Reading: the head is a map, not a handle; every action the agent took needs an index you can walk without aiming at a 20 px node, and the list, the head and the readout must be one thing.

### Layout

The head shrinks to a map: Hs = clamp(0.27 W, 280, 340) wide (a 1280 row gives 340, a 1000 row 280; the 576 x 420 crop keeps its aspect, so 248 and 204 tall). The READOUT is R = clamp(0.5 W, 360, 640) wide at the right (640, 500 and 430 at 1280, 1000 and 860) after the 24 px gutter; the left column takes the rest, Lw = W - 24 - R (616, 476, 406). The column holds, from the top, the head flush with the gutter and, left of it, the ZONE FILTER PANEL (one row per zone: glyph, label, count bar, count, the key that toggles it; a FAILED row under a rule; this replaces the chips and the digest's bars, which were the same thing), then 8 px, then the STEP LIST (header 36, rows 28 each, 4, hint 24). The panel needs 150 px (Lw - Hs - 16); below that (860 to 900 px) it becomes a row of glyph-and-count chips above the list. The row's height is head height + 8 + the list block, never under 460, with 8 rows listed at 1000 and 9 at 1280: 500 and 572. A client may list more rows when the window is tall (rows = clamp(floor((viewport height x 0.55 - head - 80) / 28), 8, 14)) and the readout grows with the row. Under 860 the head stays on top (max 280 wide, centred), the filter chips follow it, and the list follows full width (up to 10 rows); the readout is not a column then: the cursor row EXPANDS IN PLACE (accordion) to show the readout's content under it, one expanded row at a time, so a phone and a split pane browse the same list the same way. Footer, leader and transition as before; the traveller now lands on the smaller head rect.

### The list

Header: a search field (a quiet "Search /" button until `/` opens it into a 240 px field) and the count "29 steps", or "5 of 29" in the accent when filtered. The zone filters and the failed toggle live in the panel beside the head (chips under 900 px). Rows are 28 px (32 on touch), in step order, virtualized:

- zone edge 3 px in the zone's tone, zone glyph 18 px box (the shape fills about 13 px), the step number (tabular, right-aligned in 24 px), the title in the heading weight (60 px column), the argument on the same line in the mono role and the dim ink (a path middle-ellipsised by measured width so the directory head and the file name survive; a command cut at the end), and on the right the status: nothing for done, a danger mark for failed, a dashed-ring mark with "retried at N" for a failed step that was retried, an attention mark for waiting, the running pulse for running, a quiet mark for stopped.
- thoughts and notes are rows too: a quote glyph and the first line in italics, so the list reads as the agent's account in order; a step that fans out (parallel calls of one message) shares a bracket on the left, 10 px wide, drawn only between rows that are neighbours in the filtered list.
- a failed row wears a danger wash at 8 percent; the cursor row an accent wash at 14 percent, a 1 px accent ring and a 2 px accent bar inside the zone edge (the zone edge keeps its tone: replacing it with the accent lost which zone the cursor was in); the hover row a 6 percent wash and a copy button at the right edge.
- when the turn is running new rows slide in over 120 ms at the end; the list follows the newest step until the person scrolls up or sets a cursor, then a pill "Following paused: jump to latest (End)" appears at the foot; pressing it, or End, resumes.

### One selection

There is exactly one cursor (what used to be the pin). Hover is a preview and never moves the cursor; leaving a hover returns the readout to the cursor, or to the digest (or Now) when there is none. A click on a row or a node sets the cursor; the head rings that node, the leader line runs from it to the readout, the list scrolls to show the row, and the readout shows the step. Hovering a row rings its node in the head and previews it in the readout, exactly as hovering the node does. Filters dim the head's other nodes to 28 percent, so the head always shows what the list shows. Esc clears in this order: the legend, the search text, the filters, the cursor, and only then (a fourth press) collapses the brain. Filtering keeps the cursor if it still matches.

### Keyboard (the brain is a focus group: Tab enters the list, a visible focus ring; every key also works when focus is on the stage)

| Key | Does |
|---|---|
| Up, Down, k, j | previous, next step in the filtered list (sets the cursor) |
| PageUp, PageDown | 8 steps |
| Home, End, g, G | first, last (End on a running turn also resumes following) |
| Left, Right, h, l | previous, next step in the same zone |
| [ and ] (or p and n) | previous, next failed step |
| r | go to the related step (the retry of a failure, the other use of a file) |
| 1 to 6 | toggle the zone filters (PLAN, SENSE, ACT, SHELL, DELEGATE, SAY), 0 clears them |
| ! or x | failed only |
| / | focus search: type to filter by title, argument and output, Enter takes the first match, Esc clears |
| Enter | move focus into the readout (its Copy and Show all buttons), Enter again returns to the list |
| Space | expand or collapse the long output or diff in the readout |
| c, C | copy the step's command or path, copy its output |
| ? | the key legend as a popover; a one-line hint (key caps and four verbs: browse, filter, copy, keys) sits under the list when there is room |

### Mouse

Click a row or node: cursor. Double-click a row: cursor and focus into the readout. Right-click a row or node: a menu (Copy command or path, Copy output, Copy step as Markdown, Show only this zone, Go to related, Show in Rows). Wheel: scrolls whatever is under the pointer (list, readout, transcript), kinetic and eased. Zone chip: toggles its filter, shift-click or double-click solos it. Drag across the timeline strip: scrubs. Hover a row: preview and node ring, as above. The copy button on a hovered row copies the step's subject and shows "Copied" for a second.

### Model (Core, shared by all three clients)

`NeuralStepList` (rows from the model's steps: kind, number, zone, title, argument with its ellipsis rule, status mark, related step, fan-out bracket, group; the filter state; the visible index; the cursor; following; `rows(visibleIn:)`) and `NeuralBrowse`, a pure reducer from (state, key or pointer action) to (state, effects), where effects are `scrollTo(row)`, `copy(subject)`, `focusReadout`, `expandOutput`, `collapse` and so on, so the three clients map their events to actions and draw the effects, and the key table above exists once. `NeuralStageMetrics` gains the list region, the filter panel and the new head size (see Design review 2 for the rule and the numbers).

## Design review

Rendered and looked at on 2026-10-17 from the compositor's own output (CPU renderer, 1536 x 1008, corrected palettes), in Rosé Pine, Dawn, Tokyo Night and Phosphor. Boards: `docs/neural-trace-mocks/K-cards`, `K2-edge-tones`, `L-readout-shell`, `L2-edit-diff`, `L3-digest`, `L4-now-and-ask`, `L5-zone-list`, `L6-four-themes`, `L7-review-before-after`, `M-transition-sheet`, `M2-live`, `N-narrow` (.webp); sources in `docs/neural-trace-mocks/src/readout/`; the standalone pages are `.tailscode/design/neural-trace/K-readout.html` and `M-live.html`. Edits made to the spec above, in the order the looking found them:

1. **Leader ends on the node's row, not at the header.** From a node low in the head the header-anchored line was a 270-unit diagonal through PLAN, ACT and the wires, and read as a scratch across the picture (L7, left). A line on the node's own row, routed by lane around other nodes and zone labels, reads as a printed trace; a 3 x 24 px tab on the readout's hairline gives it somewhere to land. The route search (lane, diagonal start, hits) is the part `NeuralLeader.route` has to implement: the label avoidance matters (the first version cut through PLAN).
2. **Stage trimmed to the head's bounds (design x 64 to 640).** The render has 66 units of empty canvas on the left, so the head looked indented 70 px from the prompt's rule. Trimmed, the chassis is flush with the column and the head is 11 percent larger at the same row width (1.21 px per unit at 1280, was 1.09). Cost: the stage is S x 420 / 576, 507 px tall at 1280 instead of 457. The card picture is trimmed the same way so the traveller never changes crop mid-move: 132 x 96 (was 148 x 97, which sat 7.5 px from the card's edge; 96 puts 8 px above and below on the 4 px grid) and, at Compact, 100 x 72 (was 112 x 73) with 6 px above and below.
3. **Readout never under 420 px (was "min 300").** At 1000 px the stage is 394 px tall and a failing shell step (header 40, subject 56, relations 36, WHY 76, output 8 lines, footer 32) needed 470. 420 shows the whole output but its last lines; below 480 px wide the output is 5 lines. A 16 px fade at the foot of the scroll region says that more is below.
4. **Relations moved under the subject, above WHY.** At 1280, with the spec's order, "retried at 9" fell below the fold on the very step it exists for (L7, left). A relation is one 24 px row; it costs nothing where it is.
5. **Digest order and density.** Zone bars 6 px on an 18 px pitch with the timeline fused under them, then Failures, then Changed, then Answer (was bars, timeline, Changed, Failures, Answer). At 456 px the old order put Failures and Answer under the fold; now Failures is visible without scrolling. The ANSWER label moved left of its mark (it clipped), and Changed shows `…/Chat/` plus the file name, not the whole path.
6. **Now mode: So far is a headline and one row of chips**, not bars, so the output tail, the WHY and the start of So far fit in one view. Now keeps the leader to the running node. The live turn's shell zone has to stay under its 12 slots or the running node is hidden in the ganglion (open question below).
7. **Footer.** Added Rows and Close (the spec had no way to close the open row except Esc, and the card that carried it is gone); at under 960 px Close goes, under 640 px Replay is its icon and the chips go.
8. **Card.** Narrow (380) rows use the Compact picture and put Replay and Rows under the headline (the first try overlapped them with the headline). A repaired failure wears a dashed danger ring and the settled edge; only an unrepaired one wears the full ring and the danger edge, so a column of cards reads as mostly fine (K2). Waiting and Stopped say so in the headline's clause.
9. **Light themes.** Zone lights on the card picture and the stage's nodes use the lifted tones (the stage override), since they sit on a dark head; the leader, chips and text use the corrected palette. A Dawn leader in a lifted tone vanished on cream.
10. **Stacked layout (N) has no leader line.** The strip is under the stage; the zone's tone on its left edge ties it.
11. **Transition.** The numbers in section 3 hold up: easeOutCubic puts 78 percent of the movement in the first 128 ms (g = 0.46 at 60 ms, 0.76 at 120 ms). Two things only the frames showed: the card's danger ring scales up with the traveller and gets heavy mid-close, so on closing the lights return only after 130 ms; and the stage must be drawn inside the traveller (nodes scale with it) or they drift off the head for the first 120 ms.

Open, not settled by looking: whether a repaired failure should wear a ring at all (K2 argues yes, dashed; the glyph rule in `NeuralGlyph` says no); ganglion members in a dive (L5 pins a visible node, the failed `ffmpeg mux` is inside the "+7"); how a 1000 px readout should treat a 20-line output (5 lines and a fade, or a taller row); the stacked readout's pinned height (capped at 340 px here); whether "turn began" belongs in the footer facts at all.

## Design review 2

Third pass rendered on 2026-10-17 from the compositor's own pictures in Rosé Pine, Dawn, Tokyo Night and Phosphor. Boards (`docs/neural-trace-mocks/`): `O-open-brain-list`, `O2-browse-174`, `P-list-anatomy`, `Q-accordion-narrow`, `R-keyboard`, `S-transition-sheet`, `S2-live`; live pages `.tailscode/design/neural-trace/O-live.html` (every key and pointer action in the section 7 table works) and `M-live.html` (the transition, now the third-pass layout). The older L, M and N boards are marked superseded in their captions; the readout content in them stands. Sources are in `docs/neural-trace-mocks/src/readout/` (`brain.js` is the list, the panel and the controller).

What the looking changed in section 7 (edited above):

1. **Head 280 to 340 (was 280 to 380), 0.27 W (was 0.30).** At 380 the head plus a 9-row list put the open brain at 640 px tall and left 6 rows for the list: the head was still the hero. At 340 (1280) and 280 (1000) it is still a clear map: the six wells, the eye and the nodes' shapes read; the numbers inside the nodes do not (they are 5 px) and do not need to, the list carries them. Hover and cursor rings are 7 units out, 2.2 px, with a glow, because the 1.5 px ring was lost at this size.
2. **Zone filters are a panel beside the head, not chips in the list header.** With the readout capped at 640 the left column at 1280 is 616 wide and a 340 head left 276 px of nothing beside it; with chips in the list header the list lost a row and the header wrapped at 1000. The panel is the digest's zone bars turned into the filter (count bar, count, key 1 to 6, a FAILED row), so what a person reads and what they press are one control. It sits left of the head so the leader line, which leaves the head's right edge, never crosses it. Under 150 px of panel (860 to 900 px) and in the stacked layout it is a row of glyph-and-count chips.
3. **Readout 360 to 640 at 0.5 W (was "what is left").** 640 at 1280 (about 80 characters of mono, comfortable), 500 at 1000, 430 at 860. The column left of it takes the rest, so the list gets the width its arguments need: at 1280 a path of 55 characters survives.
4. **Row 28 px, zone edge 3 px, glyph box 18 px (was 14), kept.** The 14 px glyph read as a dot beside a 12.5 px title; at 18 px the shapes (circle, diamond, chipped square, hexagon, octagon, bubble) are told apart without colour. Columns, left to right: 10 bracket, 18 glyph, 24 number, 60 title, argument, status; 8 px gaps, all on the 4 px grid.
5. **Cursor is a wash, a 1 px ring and a 2 px bar inside the zone edge (was a 2 px accent edge).** An accent edge replaced the zone edge, so the row lost its zone; and a failed row under the cursor must keep its mark: the cursor wash (14 percent accent) beats the failed wash (8 percent danger), the mark stays (P).
6. **Rows per screen: 8 at 1000, 9 at 1280, more when tall.** A 29-step turn is one scroll; a 174-step turn is browsed with the filters (SHELL leaves 108 of 174, SHELL plus failed leaves 4), `[` and `]`, search and PageUp/Down (O2). The list block's height is a function of the rows asked for, so a client with a tall window shows up to 14 (rule in the layout paragraph).
7. **Accordion head 280 (was 320)** and the zone chips directly under it; the expanded row carries the readout's content (relations, WHY, output, facts) inside a 3 px zone-toned left edge, one open at a time (Q).
8. **Legend is a two-column popover, 760 wide, centred over the row** (13 rows in 7), not a tall column over the list; it names Esc's four steps. The hint line stays: four verbs, key caps at 16 px; it costs 24 px and is the only place a mouse user learns that keys exist.
9. **Transition (S).** The picture lands on the head's small rect in the left column; the panel and the header fade in 150 to 250 ms, list rows slide in 6 px from 130 ms, 12 ms apart; readout and footer as before. Row height eases to 572 at 1280.

Final numbers (W is the row width):

| | 1280 | 1000 | 860 | 700 | 520 | 380 |
|---|---|---|---|---|---|---|
| layout | split | split | split, chips | stacked | stacked | stacked |
| head Hs x Hh | 340 x 248 | 280 x 204 | 280 x 204 | 280 x 204 | 280 x 204 | 280 x 204 |
| left column Lw | 616 | 476 | 406 | W | W | W |
| filter panel | 260 | 180 | chips | chips | chips | chips |
| readout R | 640 | 500 | 430 | in the row | in the row | in the row |
| rows listed | 9 | 8 | 8 | 8 (up to 10) | 8 | 8 |
| open brain height | 572 | 500 | 536 | about 540 | about 540 | about 540 |

Paddings: list header 36, row 28, hint 24, panel row 28 (FAILED row 30), panel header 24, zone chip 28 high with 6 px glyph padding and 10 px right, row padding 8 right, status column right-aligned, copy button 24 high at 6 px from the edge, the list sits 12 px short of the readout gutter edge (scrollbar room). Readout paddings are unchanged (20 left, 12 right).

Open, not settled by looking: whether the numbers in the 280 px head should show on the ringed node only; whether the ganglion should open in the map when the cursor is on a hidden member (O rings the "+7" and says "25 of 29" in the readout); how a touch device (32 px rows) fits 8 rows in the stacked layout; whether the filter panel is too prominent on a turn with one zone (it could collapse to the chips); and the cost of key caps in the hint line against a plain text hint.

