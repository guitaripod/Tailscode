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

A running turn has a live card: nothing opens by itself, and the person opens the turn they want to watch.

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
6. **Watching live.** Once the person opens the running turn, the readout says Now, with the output tail streaming; nothing ever steals the pointer or the scroll. When the turn ends the head settles (eye takes the family colour), the readout cross-fades to the Digest and stays open until the person closes it or opens another.
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

## 8. Fourth pass: the right side is the agent talking to you (from Marcus's third review)

Marcus: "Everything that goes in the said category might be hard to find and it's something important. Think of the right side display as like the interface where the agent talks to you and make it specifically about that. It should also scale in width with the window. Continue polishing." Reading: the SAY zone ("Said": the notes the agent writes between its tool calls, and with them its thinking) is the agent's own voice and the part of a turn a person most wants, yet it is one quote row among 29 and a jaw-sized zone on the head. So the right display stops being a tool inspector with a quote above it and becomes the **account**: the agent's turn told in its own words, in order, with the work it did folded into the story, and the detail of any step opened inside it.

### The account (default content of the right display)

A single scrolling column, newest at the bottom while the turn runs (following, like the list) and top-aligned when settled. Its items, in the order the transcript has them:

- **Said** (a note): the agent's words in the prose role at the answer's size and leading, the model's family dot and name and the clock ("Fable, 21:46:11") in the label role above the first one and whenever the speaker or the gap changes; first-person, never rewritten or summarised. Long notes show their first 6 lines with "Show all".
- **Thought** (reasoning): muted, one line with a thinking glyph and "Show" to unfold, because thinking is long and the person is here for what was said; a thought is never mixed into a Said bubble.
- **Work** (the steps between two utterances): one compact activity line: the zone glyphs of what ran in order as small marks with counts ("3 commands, 2 reads"), failures in the danger tone with "retried at N" in words, files changed with +N -M; a press unfolds the steps in place as a list of the same rows the step list draws. The step under the cursor is always unfolded, with its detail (subject, output or diff, relations) as an inline card under its row: this is what the old Step readout was, now inside the story where the person can see what the agent said before and after it. Hovering a step previews its card below the line without unfolding the others.
- **Needs you** (an approval or a question the agent is waiting on): pinned at the TOP of the account, in the attention tone, in the agent's own words (the command it wants to run and why, or the question and its options), with "Go to approval" or "Go to question"; it is the most important thing the agent says, so it is never below the fold.
- **Answer** (the last item): "Then it answered" and the first line of the final message, a press scrolls the transcript to the answer below the brain.

Every item carries its step numbers as chips; a press on a chip sets the cursor, and the head rings the node, the list scrolls to the row and the account scrolls to the item, all three together. The cursor can sit on an utterance as well as on a step (a Said item is addressable: the list row, the account item and the head's SAY node are one thing), so `s` and `S` jump to the next and previous thing it said and Up and Down walk the account's items when focus is in it.

Each Said or Thought item has two small actions at its right edge, shown on hover or focus: Copy, and Reply: Reply puts a quote of the item in the composer ("> the iOS tour is 60 fps...") and focuses it, sending nothing; the agent is talked back to through the ordinary send, never a second channel.

### Said must be easy to find

1. The card's third line is the agent's own first words ("Fable: Building it from the existing film rig; checking the iOS footage...") with a quote glyph when it said anything; the generated sentence of counts is the fallback for a turn that said nothing. The zone chip is spelled SAID, not SAY, wherever it names the voice (filters, chips, bars, the head's label); the rest keep the verbs.
2. In the step list a Said row is a message, not a step: two lines tall (40 px), the quote glyph in the accent, the text in the ink and not dimmed, so a scan down the list finds the speech at once; Thought rows stay one muted line.
3. The filter row's SAID chip sits first, is the only chip that carries its label, and carries its count; the failed toggle moves into the list header (seven chips do not fit 346 px); `1` is SAID and `2` to `6` are PLAN, SENSE, ACT, SHELL, DELEGATE; the `s` and `S` keys and an `a` for the ask are in the key legend; solo on SAID makes the list and the account the transcript of what the agent told you.
4. The head's SAY zone brightens its ear glow with the count of what was said (as every zone does) and a node ring on the item under the cursor.

### Scales with the window

The account takes everything the left column leaves: no cap, minimum 360. The left column is the head, the filter chips and the list, Lw = clamp(0.27 W, 320, 360) wide, so the account is 910 px at 1280. Inside it the measure stays readable: prose lines stop at 78 characters (36 em, 540 px at 15 px; the text block is left-aligned and the rest stays quiet canvas), while code, output and diffs use the full width of the item. From an account of 924 px (a window of about 1310 px) it splits in two columns: the story on the left, clamp(0.42 A, 440, 680), and the open step's detail card (subject, output, diff, relations, Copy buttons) on the right (minimum 460), so a wide window reads the agent's words and the evidence side by side and nothing is unfolded in place. At 1920 the story is 645 and the detail 867; at 1440, 444 and 588. Under the threshold the detail unfolds in place under its row as above; under 860 the account is the list itself (no step list under the head): Said items as messages, work lines that unfold into the step rows, the cursor row's card open in place, one at a time.

### Core

`NeuralAccount`: `NeuralAccount.make(model:)` returns the ordered items (said, thought, work group, ask, answer) with their step ids, the zone-mark clusters and counts for work lines, the quote and the speaker/clock for utterances, `needsYou` first, plus `item(containing stepID)`, `nextSaid(after:)`, `previousSaid(before:)`; `NeuralStageMetrics` gains the account rect, its column split and the prose measure; `NeuralBrowse` gains `s S` (next/previous said), `a` (the ask), `reply(item)` and `copy(item)` effects and the SAID solo; `NeuralBrainCard` gains the agent's quote line; `NeuralStepList` gives Said rows the two-line height.

## 9. Fifth pass: a robot you can observe, in words a person reads (from Marcus's fourth review)

Marcus: "Everything must be ported. Also, this looks strange that it says 'Failed' even though it very much succeeded in its task. Think further what this window should have and how it should display things to a human reader. The idea is that this robot is an entity inside Tailscode that you can observe as it works." Two findings. First, the vocabulary reports the mechanism, not the outcome: a build that failed once and passed on the retry is the agent doing its job, and a red FAILED chip on it, or a turn that reads as failed, tells the reader the opposite of what happened. Second, the window shows what the tools did; a person wants to see what the entity is doing, why, how it is getting on, and what came of it. Every client gets all of it (the card, the docked stage, the list, the account, the transition, this pass), Linux first.

### Verdicts: what a step and a turn are, in the reader's terms

A step has one verdict (`NeuralVerdict`, Core), derived once and used by every surface (chip, list mark, node ring, card clause, headline):

| Verdict | When | Chip words | Tone |
|---|---|---|---|
| done | completed | Done (shown only in the detail, never as a list mark) | quiet |
| fixed | an error, and a later step of the same file or command passed | **Fixed on retry** (the detail says "It failed here and passed at step 12") | attention (amber), never red |
| failed | an error nobody fixed: the turn ended, or moved on without a passing retry | **Failed** | danger |
| trying again | an error in a turn that is still running and has not yet been retried | **Hit an error** (triangle glyph) | attention |
| running | in flight | Running | live |
| waiting | approval or answer pending | Waiting for you | attention |
| stalled | the machine found it stuck | Stuck | attention |
| stopped | the person stopped it | Stopped | quiet |

The error output itself is shown unchanged (a failed step's output still wears the danger ink on its lines: that is evidence, not a verdict). A step is `failed` only if it stayed failed.

A turn has one verdict too: **Done** (all steps fine), **Done after retries** (the pill still says DONE in quiet ink; the amber lives in one clause beside it, "fixed 1 error on the way" with the retry arrow, never in the pill: the outcome stays calm, how it got there is the amber part), **Needs you**, **Working**, **Stuck**, **Stopped**, **Didn't answer** (answerless), and **Failed** only when the last assistant message carries an error or the turn ended on an unfixed failure. The card's edge, the headline clause, the head's eye, the ring on a zone and the share poster follow the turn verdict: a fixed error is a dashed amber ring and "Done, fixed 1 error", never the danger ring or the word failed; an unfixed failure is the solid danger ring and "1 step failed". The Home row, the Live Activity and the notification keep their own words (they already say what the turn did, not what a step did).

### Plain words for what a step did

A step's title is a sentence a person reads (`NeuralHuman`, Core, heuristics on kind, name and arguments, no inference beyond them), with the raw tool and argument kept as the secondary line: Read becomes "Read film.sh", Grep "Searched for compaction", Edit "Edited cut-list.json (+4 -1)", Write "Wrote tailscode-demo.mp4"; Bash is classified by its first program: build (`swift build`, `xcodebuild`, `cargo build`, `make`, `npm run build`) "Built the project", test (`swift test`, `pytest`, `cargo test`, `npm test`, `jest`) "Ran the tests", git "Checked git status", "Looked at the diff", "Committed", "Pushed", install "Installed", search (`rg`, `grep`, `find`) "Searched the files", look (`ls`, `cat`, `sed -n`, `head`, `tail`, `wc`) "Looked at files", network (`curl`, `wget`) "Fetched a page", media (`ffmpeg`, `ffprobe`) "Ran ffmpeg", otherwise "Ran <program>"; a subagent "Asked an agent: <description>"; a skill "Used the <name> skill"; the task tool "Updated its plan". A retry reads "Ran the build again". The list rows, work lines and chips use these titles; the command, path or pattern follows in the mono role as before.

### What the window holds

The account (section 8) becomes the entity's window. From the top:

1. **Header, the entity and its vitals**: the model (family dot, name, effort bars) and the turn's verdict in words with its tone ("Finished, 6m 29s ago", "Working on: Ran the tests", "Waiting for you", "Stuck for 40 s"), the elapsed time, the counts (said, steps, errors fixed), and while running a pulse in the activity vocabulary. Quiet, one line, never a card.
2. **Asked**: the person's prompt that started the turn, two lines with "Show all", in the quiet ink: the context for everything under it.
3. **Needs you** (when pending): as section 8, first of the movable items.
4. **Plan** (when the agent keeps a task list: the task-tracking tool's latest todos): its own items with their states (pending, in progress, done) as a checklist, "3 of 7 done" with a 4 px bar, updated live: the agent's own plan is the best thing a person can watch. While the turn runs it is open under the Now line (compacting to segments plus the current item beside a Now line); once every item is done it folds to its one-line header, because a settled turn is read from the story and the Result.
5. **The story** (section 8's items: Said, Thought, Work lines, the cursor's detail inline): unchanged in structure; Work lines now read "Built the project, Ran the tests ✓" with fixed errors in amber words ("fixed an error at step 8") instead of red.
6. **Result** (settled turns): what came of it, from the transcript's own facts: files changed (path, +N -M, a press sets the cursor on that step), checks (the commands classified as build, test or lint, each with its verdict and "after 1 retry" where it was fixed), anything unfixed (the failures that stayed failed, each with its first error line), then "Then it answered" and the first line of the answer. Nothing is summarised by guessing: a check appears only for a command that is recognisably a build or test, and its mark is the tool's own status.
7. **Live (while running)**: the Now line (the plain title of the step in flight, its argument, the last 2 lines of output with a caret, "last output 4 s ago", "silent for 40 s" in attention when nothing has arrived for a while) sits under the header and above the story; the header's pill says WORKING; the story follows its newest item as before.

The card (collapsed turn) says the same in short: headline with the verdict clause ("Done, fixed 1 error"), the agent's first words, the zone chips; its edge and rings follow the turn verdict. The step list marks: failed = danger mark, fixed = amber "fixed" mark with "-> 12" to the passing step, nothing for done.

### Language for the retry story

A failed step that was fixed reads, in its detail: "Fixed on retry. It failed here ('switch must be exhaustive') and passed at step 12." with the passing step a chip. A turn whose only errors were fixed never shows a danger tone anywhere except the failed step's raw output lines.

### Core

`NeuralVerdict` (step and turn verdicts with words, tones and the rules above, one derivation), `NeuralHuman` (titles, classification of shell commands, retry titles), `NeuralAccount` gains `.plan` (parsed from the task-tracking step's input: content and status per todo, tolerant of both shapes the tools use), `.result` (changed files, checks, unfixed failures, answer) and the header vitals; `NeuralReading` words for every verdict and clause; `NeuralBrainCard` follows the turn verdict; `NeuralGlyph`/`NeuralGlyphWire` follow it (a failed bit only for an unfixed failure, as today); readout chips use the verdict; the step list's marks use it.

## 10. Sixth pass: closed by default, a card that is alive, and the move both ways (from Marcus's fifth review)

Marcus: "The robot shouldn't start expanded and the transition should be great from both states. Neat and snappy but cool." Reading: nothing opens by itself. Every turn is a card, the latest one included, and the person opens one when they want the entity's whole window. Because the running turn is the one a person most wants to watch and it no longer opens, its card must itself be the place to observe it. And the move between the card and the stage has to feel crafted in both directions and from both card states (idle and live), at every width.

### Closed by default

`NeuralOpenPolicy`: no turn is open until the person opens it (click, Enter or Space on a card, a zone chip, Find landing on a step, `brain=open` in drive hooks); opening one closes the one that was open (the two moves cross); a person's choice is kept in memory for the conversation, so scrolling away and back does not close what they opened; a new turn arriving never opens itself and never closes what the person opened (an open older turn stays open until they close it or open another); a relaunch starts all closed. There is no "open the latest" rule and no setting for it. The Lines style and every fallback are unchanged.

### The live card

The running turn's card keeps the settled card's size (112 / 84, no layout shift when it settles) and says what is happening now, in the reader's words:

- the picture is the live head: the active zone's light breathes (the activity's own swell at the 30 fps activity tempo, only while the card is on screen and the turn runs; one shared tick for every visible live card, none for settled cards), the eye wears the live tone, a zone that is waiting knocks;
- the headline reads the verdict ("Working", "Waiting for you", "Stuck for 40 s", "Hit an error: trying again") at 16/24 (14/20 Compact) with the counts beside it in 12 mono, tabular ("12 steps · 3 said · 4m 05s"), and the tone edge pulses at the same swell (a waiting turn knocks twice in amber);
- the third line is the NOW line: the plain title of the step in flight ("Running the tests") with its argument in the mono role and the last line of its output sliding in under it as it arrives; "silent for 40 s" replaces the output in attention when nothing has come for a while; when the agent speaks, its words replace the line for a moment (a note arrives as a quote line that holds for 4 s) so a person watching the card sees what it says as it says it;
- Open and Replay stay; the whole card is still one button.

When the turn ends the card settles in one 400 ms move: the lights ease to their final strengths, the eye takes the model's colour, the verdict text cross-fades to its settled words (a short slide of 6 px), the output line fades out and the quote line (or digest) fades in, and the edge stops pulsing. A card that settles while the person is looking at it should feel like the robot finished its sentence; one that settles off screen simply is settled when it arrives.

### The move, both ways, from both card states

One choreography family (`NeuralTransition`, section 3's timeline and curves) with these refinements, all of which a person feels before they can name them:

1. Open from a settled card and from a live card are the same move; from a live card the traveller is the live head: the breathing zone keeps breathing through the whole move (no freeze, no restart), the NOW line becomes the account's Now item by cross-fade in place, and the card's counts become the header's counts without a jump.
2. Close from the stage returns to whichever card state the turn is in (live card for a running turn, settled card otherwise), and the head lands exactly on the card's picture rect.
3. The move is one interruptible object: a press (or Esc, or another card's open) at any moment reverses from the current frame, never restarts, never queues; two moves (one closing, one opening) run together and share the row-height animation without fighting the scroll anchor.
4. Curves: geometry on easeOutCubic over 320 ms (open) and easeInOutCubic over 220 ms (close, a touch softer start so the head leaves the stage with intent), one progress value g drives everything, content reads the open timeline time that g corresponds to (te = 320 x (1 - (1 - g)^(1/3))) so closing is the opening played back faster and a reversal is just g changing direction; content on short staggered fades (account 24 px slide from 130 ms, filter chips and list header from 90 ms, list rows 6 px slide from 100 ms, 12 ms apart, nodes in step order from 120 ms across 150 ms with the 6 percent overshoot, footer from 240 ms; the sweep at 42 percent strength between 40 and 200 ms), the traveller 1.5 percent overscale at 80 percent of the open then settle, never a bounce; reduced motion is the 120 ms crossfade.
5. The chrome follows the move: the card's tone edge travels with the picture's left edge for the first 90 ms then fades; hairlines are drawn after the geometry settles; no element ever draws outside the row; the row clips and the transcript below moves with the row's height, eased by the same curve, so nothing underneath jumps.
6. Cost: display rate for the duration only, one traveller surface, no per-frame compositor render except the sweep's few frames; at most one dropped frame in the move on the 60 Hz harness; a strained or critical governor level shortens it to 160 ms without sweep or stagger but still moves.

Both directions are reviewed as frame sheets (8 frames each) and a live page with Open and Close buttons and a scrub slider, from the settled card, the live card and the mid-move reversal, in four themes.

### Core

`NeuralOpenPolicy` (closed by default, the rules above), `NeuralLiveCard` (the live card's content: verdict words, counts, the NOW line with its argument and output line, silent-since, the quote hold, the swell phase for the active zone, the settle animation's parameters), `NeuralBrainCard` gets `live: NeuralLiveCard?` and `settle(at:)` progress, `NeuralTransition` gets `fromLive` (the traveller carries the live swell) and the refined curves, `NeuralBrainModel` publishes `needsLiveCardClock` (running turn with a card on screen) distinct from `needsClock` (open stage).

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

## Design review 3

Fourth pass rendered on 2026-10-18 from the compositor's own pictures in Rosé Pine, Dawn, Tokyo Night and Phosphor (the account is drawn in Rosé Pine and Tokyo Night). Boards (`docs/neural-trace-mocks/`): `T-account-1280` (T), `T2-account-widths`, `T3-card-said`, `T4-list-said-rows`, `T5-account-narrow`, `T6-reply-and-keys`, `T7-account-live`; live page `.tailscode/design/neural-trace/T-live.html` (s S a [ ] j k 1 ! / ? Esc, click and hover all work). The earlier readout boards (L to L7, M, N, O, O2, P, Q, R, S) are marked superseded in their captions, the readout content they show stands inside the account's detail card. New sources: `account.js`, `brain4.js`, `page4.js`, `fixtures.js` (the `T_ACC` family: the build-fix turn with the agent's notes).

What the looking changed in section 8 (edited above):

1. **The right side reads as the agent talking.** With notes in prose at 15/24 behind a 3 px accent rule, a name and a clock above, and work folded to one 36 px line, a glance down the account is: voice, voice, one grey line, voice. The step inspector survives as a card nested under the cursor row, so the evidence never competes with the words. The first version drew work marks as runs ("1 1 1 1 1 1 1") and was noise: marks are now totals per zone, in order of first use, with words ("3 searches, 1 edit") while there are three zones or fewer and glyph and count beyond that.
2. **The left column is the head, the filter chips and the list; the filter panel is gone.** At Lw = 346 the panel and the head cannot share the column, and the panel's job (count by zone, toggle) is the chips'. Seven chips overflowed 346 px and wrapped over the search row, so the failed toggle moved into the list header and only SAID keeps its label (an accent border, an accent word): the voice is the one chip a person looks for. Chips 28 high, 5 px glyph padding, 4 px gap, 8 px right padding.
3. **Left column 320 to 360 at 0.27 W; head as wide as the column.** 346 at 1280 (252 high), 320 at 1100, 360 at 1440 and 1920. A map that is 346 wide still shows every zone and node shape, and the leader stays 24 px long.
4. **Split from an account of 924 px, a window of about 1310 px (not 1100).** Story min 440 plus the 24 px gap plus detail min 460 is 924; at 1100 the account is 756 and at 1280 it is 910, so both stay single-column with the card in place (T, T2). At 1440 (a 1056 account) the split is earned: the story is 444 and the card 588, and the card has room for 80 characters of output without wrapping. Story = clamp(0.42 A, 440, 680); at 1920 it is 645 and the card 867.
5. **Prose measure 36 em (540 px at 15 px), not 78 ch.** `ch` is the width of a zero, and 78 ch gave 86 characters a line. At 1280 the story column beside it holds a 230 px quiet margin that reads as intended because everything else (work lines, cards, the answer) stays inside the same 720 px band; the account is capped there (`storyMax 760`) in the single-column layout.
6. **Said row 40 px in the list, 2 lines, quote glyph in the accent, ink text** (T4); Thought rows stay 28 px and muted; tool rows stay 28 px. The Said rows are findable by scanning for the quote glyph alone. Under 400 px of left column the status text drops to marks (failed cross, ring with an arrow and the retry number) because arguments need the 100 px.
7. **Item numbers.** Said item: padding 2 56 2 16, the 56 is the right gutter for the step chip (11 px mono) and the Copy and Reply buttons, which show on hover and on the cursor; name line 16 high with a 4 px gap; 6 lines clamp (144 px) then Show all; items 20 px apart, consecutive notes 12 px (they are one speech). Thought: 24 px. Work line: 36 px, 8 px radius, raised surface, 1 px rule, 12 px right padding, 14 px between marks, glyph 18. Unfolded work: the list's own 28 px rows with a 1 px frame; the card under the cursor row: 36 px header, 14 px side padding, 3 px zone edge, 36 px left margin so it hangs off the row. Needs-you: 14 px padding, 3 px warn edge, 1 px warn border at 55 percent, 9 percent wash, sticky at the top with a soft shadow, the agent's words at the answer's size, the command in a recessed box, Go to approval as the only filled button. It is the loudest thing on the page by colour and position alone: no motion beyond the 1.6 s knock on its dot. Answer: 12 px padding, top rule, "Then it answered".
8. **Live (T7).** The running step's card is compact (no WHY, no relations: the note above it already says why) so the newest note and the work line fit in one view; a note arrives 12 px low at 55 percent and says "just now". The list shows a short pill ("Following paused, latest End"); the account's is the long form.
9. **The card's third line (T3).** The quote glyph and the name in the accent and the ink 2, the words in italic ink, cut at a whole word. The zone chips tighten (5 px padding, 4 px gap) and SAID leads and wears the accent so the line and the chip belong together; at Compact the line replaces nothing, it sits under the chips in the same 84 px.
10. **Keys.** `1` is SAID and `2` to `6` the other zones (it was `1` PLAN in section 7); `s` and `S` jump between notes, `a` to the ask; the legend names them and Esc's four steps. Space unfolds the work line under the cursor.

Final numbers (W is the row width): left column 346, 320, 360, 360 at 1280, 1100, 1440, 1920; account 910, 756, 1056, 1536; split at 1440 and 1920 (444 and 588, 645 and 867); open brain height 610, 591, 620, 620 (head + 8 + chips 34 + list header 36 + 9 rows 252 + 4 + hint 24); prose 15/24 at 36 em; Said row 40, Thought 28, work line 36, work-line gap 20, Said gap 12.

Open, not settled by looking: Reply and Copy have no key (only `c` for the command), a binding for Reply on a note is worth deciding; in the split layout a cursor on a note shows the turn's digest in the right column, a better answer might be the note's own context (the step before and after); more than one ask at once (two approvals) is untested; the head's SAID zone is read as a bubble pair at this size and might want a glow count; and whether the account should centre at 1280 instead of leaving 230 px at the right.

## Design review 4

Fifth pass rendered on 2026-10-18 (Rosé Pine for the window, all four themes and the two system looks for the head). Boards (`docs/neural-trace-mocks/`): `U-entity-window`, `U2-verdicts`, `U3-entity-live`, `U4-result-block`, `U5-plain-words`, `U6-entity-narrow`, `U7-phone-and-mac`. Sources: `verdict.js` (NV: step and turn verdicts, plain titles, plan, result), `account5.js`, `page5.js`. The T boards and everything before them are marked superseded in their captions.

1. **A turn that fixed an error says DONE, quietly.** The first version made the pill amber for "Done after retries" and the whole header read as a warning on a success. Now the pill is the same quiet DONE as a clean turn and the amber is one clause, "fixed 1 error on the way", with the retry arrow. The card's clause is "Done, fixed 1 error", the ring is dashed amber, and the head's eye does not change. Nothing outside the failed step's own output lines is red in a fixed turn (U, U2).
2. **Amber and danger are separated by glyph and word, not colour.** Fixed: the circular retry arrow plus "Fixed on retry" / "fixed an error at step 8" / "-> 12" in the list. Failed: the cross plus "Failed". Hit an error: the triangle. Stuck: a dashed clock. Waiting: pause bars. Stopped: a square. A colour-blind reader can tell all eight chips apart with the colour removed (U2 lower half). Amber is `warn` and red `danger` from each corrected palette.
3. **Header anatomy**, 28 px high, one row wrapping to two under 560 px: family dot 10, name 14/20 semibold, effort bars (five, 3 px wide, 4 to 12 px tall), the verdict pill (24 high, 11 px caps, tracked .06), the sentence (13/20 ink 2: "in 6m 29s · fixed 1 error on the way", "Working on: Ran ffmpeg", "Waiting for you", "Stuck for 40 s"), and at the right the counts in 11.5 mono ("3 said · 18 steps · 1 error fixed"). It sits above a 1 px rule and never scrolls with the account.
4. **Asked** is one label and two lines of 13.5 in ink 2, 36 em wide. **Plan** is a raised block, 10 px radius, 14 px side padding, header 24 high with the count and a 4 px bar capped at 160 px, items 24 high at 13.5/20: done in ink 2 with an accent check, in progress in ink semibold with the pulse, to do with an open dot. It folds when finished and, in the live window, compacts to segments plus the current item once the Now line is up (U3 bottom).
5. **Work lines read as clauses**: one glyph per zone, then "Searched for case .compaction · Read 2 files · Edited TranscriptRows.swift +6 -1", at most four clauses and "+N more"; a build or test that eventually passed gets a check, a fixed error is an amber clause, an unfixed one a red clause with the cross. Repeats collapse by title ("Pushed (4x)").
6. **Result anatomy**: a raised block under the story, 12 px padding, groups ruled at 1 px. CHANGED (path with the last two directories dimmed, a 64 px +/- bar, "+8 -3", the step numbers), CHECKS (a build or test command only: glyph, "Build" or "Tests", the raw command, the verdict in words: "passed", "passed after 1 retry" in amber, "failed" in danger, the step numbers), STILL FAILING (only when something stayed failed, naming the step and its first error line), THEN IT ANSWERED (cut at a whole word). No edits: "It changed no files."; only reads: "It only looked: read 4 files, changed nothing."; answerless: "It ended without an answer." (U4)
7. **Plain titles** (U5): list rows read "Built the project  swift build -c release ...", titles 12.5 semibold capped at 168 px, the raw argument 11.5 mono beside it; fixed errors show the retry arrow and the passing step ("-> 12") at the right. Retries read "Ran the build again". `rg`, `grep` and `find` read "Searched the files"; a Grep tool "Searched for <pattern>".
8. **Live window** (U3): Now line padded 6 12, a pulse and NOW in accent, the plain title, the mono command on one line, two output lines and a caret, "last output 4 s ago" at the right; silent turns swap to attention ink and "silent for 40 s" with the dashed clock and the head's eye in attention. The story below follows its newest item; the running step's card is compact (no WHY or relations).
9. **Port notes** (U7). iPhone: the card and the account stay inline in the transcript as an accordion, because a bottom sheet makes a modal of something read in passing and hides the chat; touch rows are 32 px (Said rows 44), chips 36, buttons 36 high with 44 pt hit areas, work lines 44. The sheet is shown beside it for argument; only the step detail card could earn one, for a long output. Mac: sidebar, toolbar, composer capsule and status capsule are glass; the head, list and account are content on the opaque canvas in system colours (the named palettes are Linux's); under System the amber is `systemOrange` and the red `systemRed`.

Open, not settled by looking: the Plan block when the agent never wrote a task list (omitted; an empty line would be less honest?), a header that wraps at 380 px puts the sentence on its own line (a little tall), "Hit an error" for a running turn shows only until the next step starts (a flash on fast retries), and whether Result should count a `git push` as a check.

## Design review 5

Sixth pass rendered on 2026-10-18. Boards (`docs/neural-trace-mocks/`): `V-live-card` (six live states at both densities and 380 px, in four themes), `V2-settle` (eight frames over 400 ms, both densities), `W-move-sheets` (six frame sheets: open from a settled card, open from a live card, close to settled, close to live, a reversal, two cards crossing; ten frames each with the numeric strip); live page `.tailscode/design/neural-trace/M-live.html` (Open, Close, Live card, Crossing, quarter speed, scrub; a press mid-move reverses from where it is). Sources: `live6.js` (LC), `page6.js`, plus two new compositor renders per live state (a low and a high breath frame) so the card's head really breathes.

1. **The live head is two real frames cross-faded.** The activity swell is a raised cosine of 1.9 s with a floor of 0.34: the compositor's frame at the floor and at the peak, the peak laid over the floor with a CSS opacity keyframe (`breathe`, 1.9 s, ease-in-out), is indistinguishable from the shader's own and costs nothing per frame. Every live card and the stage's traveller share one phase by a negative animation-delay taken from the clock, so no two breathing heads ever beat apart and a head that travels keeps its beat.
2. **Live card line anatomy** (V): line 1, the verdict in 16/24 semibold with its glyph (pulse, pause bars, dashed clock, triangle) and the counts in 12 mono tabular; line 2, the zone chips with SAID first and counted (dropped under 460 px); line 3, NOW: the plain title in 13/20 semibold, the argument in 12 mono ink 2 taking whatever width is left, the last output line right-aligned in 12 mono (maximum 42 percent of the line) sliding up 6 px as it arrives (220 ms ease-out); "silent for 40 s" replaces the output in amber with the dashed-clock glyph; an error's output stays amber; a note replaces line 3 with a quote glyph, the speaker and the words in italic, held 4 s. The buttons keep the top right and the headline pads 170 px so nothing ever runs under them. At Compact the output moves out and the line is title plus argument only.
3. **The first headline was too loud.** At 20/28 the verdict collided with the counts and the buttons on "Hit an error: trying again" and read as the card's title rather than its state; 16/24 reads as a status that belongs to the line below.
4. **Settle = 400 ms, not a cut** (V2): lights and the head cross-fade over easeOutCubic(t/400); the live headline leaves in 170 ms with a 6 px lift while the settled one arrives from 130 ms to 360 ms with a 6 px rise; the NOW line is gone by 140 ms; the first-words line fades in from 170 ms; the edge stops pulsing at once and holds at full. At 200 ms the card has already said everything it will say; the rest is the picture catching up, which is what makes it read as the end of a sentence rather than a state swap.
5. **The move**. One progress g; open `g = easeOutCubic(t/320)`, close `g = g0 x (1 - easeInOutCubic(t/max(110, 220 g0)))`, so a reversal from g0 takes proportionally less time and never jumps. The overscale is 1.5 percent, a half sine over g from 0.6 to 1.0 (peak at 0.8), applied about the traveller's centre so it grows outward rather than drifting right; the tone edge rides the picture's left edge (12 px left of it) for 90 ms of te and fades by 150; the card surface and text are gone by 90 ms. The row clips (`overflow:hidden`) and its height is the same g, so the transcript below rides the row without a second animation; in the crossing sheet two rows with different g sum their heights and nothing below jumps.
6. **What the frames showed and the numbers changed**: the sweep at 70 percent washed the head to cyan at 105 ms (42 percent now); the account and the list began at 150 and 120 ms, which left an empty 400 px row for 100 ms (130 and 90 now); and an unsynchronised breath made the traveller flicker for one beat after the hand-off (shared phase). The head never swaps images in the live open: the stage carries the same two frames the card did; in the settled open it carries the rest picture and its lights, which fade into the settled frame between 40 and 200 ms.
7. **Closed by default** (section 10, first part) is unchanged and was not drawn: it is the absence of the open row, which every board above shows as the card.

Final numbers: open 320 ms easeOutCubic; close 220 ms easeInOutCubic (min 110 on a reversal); settle 400 ms; overscale 1.5 percent at g 0.8; edge ride 90 ms then 60 ms fade; card text out 90 ms with an 8 px slide; sweep 40 to 200 ms at 42 percent; nodes from 120 ms across 150 ms with 6 percent overshoot; list header and chips from 90 ms; rows from 100 ms, 12 ms apart, 6 px; account from 130 ms over 170 ms, 24 px (12 px up when stacked); footer from 240 ms over 80 ms; live breath 1.9 s, heartbeat 1.6 s; output slide 220 ms; quote hold 4 s; silence threshold 40 s.

Open, not settled by looking: the move at 520 px and 380 px (the stacked layout is built and plays, but its sheet is not drawn); a real display's frame pacing (frame sheets cannot show whether 320 ms feels snappy, the live page can); the Compact live card has no output line at all, which may leave "Ran the tests" without evidence of life beyond the pulse; whether a quote that holds for 4 s should be dismissed by a press.


## Design review 6: the phone

Sixth review, 2026-10-23, from the owner's two complaints: on iOS Megatron takes too much of the screen, and the page is hard to scroll past. Measured on a 402 pt iPhone (row 386 wide) with the demo's 29-step turn: the open row was 716 to 780 pt (head 280 x 204, zone chips, search header, the whole account as an inner scroller grown to 62 percent of the viewport, footer), nearly a screen, and a finger that landed on that scroller scrolled it and not the page.

1. **A phone's open Megatron is a fixed, short column** (`NeuralStageMetrics.make(phone: true)`; the client passes it for a touch row under 860): head 208 x 152 centred, 4, one 40 bar, five 32 rows, 4, a 36 footer: 388 pt, whatever the viewport, and it scales with Dynamic Type up to 1.5 (`textScale`: rows, bar and footer grow, the head does not). The collapsed card stays 84: its picture is 72 and the three text lines and the button row fill it, so a 72 card would clip the buttons.
2. **Nothing in it scrolls.** The bar is the zone chips (a horizontal scroller that fades where it is cut), a search icon and the count, which opens the account. The list is `NeuralStepList.compactWindow`: the head of the list; the newest steps while a turn runs and is followed; the window around the cursor otherwise, so the step being read is always on the stage; a step waiting on the person takes the first slot and its tap goes to the approval. The slots at the ends say "N earlier steps" and "N more steps". A note is one line here (48 pt rows would make the height depend on the turn).
3. **"N more steps" opens in place up to 12 steps and in a sheet above.** Looked at both: twelve rows is 400 pt of page, a screen the person scrolls the transcript past, and "Show fewer steps" gives it back; forty rows in place is a second page nobody wanted inside the first. The sheet is the account itself (`BrainAccountView`: asked, plan, notes, work lines that unfold into the step cards, result) in a `UISheetPresentationController` with medium and large detents and a grabber, so the reading scroller is a page of its own that a swipe puts away. The account is not built until the sheet is asked for. Pressing the step that is already selected opens the sheet at it.
4. **Opened turns keep the person's choice** (`NeuralOpenPolicy` unchanged). Collapsing an older Megatron when the next message is sent would move content above the viewport while the sent prompt rises to the top (`FreshCanvas`), needs the same rule on the Mac and Linux, and with 388 pt instead of 716 a forgotten open Megatron is no longer most of a screen.
5. **The stage's swipe never competes with the back swipe.** It exists only while a dive into a zone is open (it leaves the dive), and never begins within 40 pt of either screen edge. The zone labels on the head are drawn smaller on a head this small (the ring a label sits over would clip them) and are 44 pt targets, below a node's own hit.
6. **Cost.** Nothing in the open stage runs while its chat is out of the window: the one-second clock of a live open Megatron used to keep ticking behind a pushed-away chat. The first open no longer pays the first `AttributedString(NSAttributedString)` of the process (13 ms, now made once off the main thread), the desktop step list and the account are not built on a phone, a hidden card is not rebuilt for every token, and the head pictures a conversation's cards ask for are made one per turn of the run loop. Numbers are in the commit message.
