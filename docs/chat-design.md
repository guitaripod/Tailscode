# The chat screen — design contract

Three clients draw one conversation. This is what they agree on, written once. Words, readings and
numbers live in `TailscodeCore` (`ChatChrome`, `SubagentPresence`, `FailedTurnReading`,
`JumpReading`, `ChatSuggestion`, `StatusFacts`); a client decides only how a thing is drawn. The
master sheet (the Design artifact "Tailscode Chat Master Sheet") shows every rule below as a
picture.

## Principles

1. **One fact, one place.** A state that is told in the nav, the band, a card and a button is
   told four times. A state is *named* once, in the status line, and *acted on* once, in the zone
   that can act: the header says "Needs you", the dock holds the card, and neither is repeated
   by a banner or the band. What is *happening* is the status line, what is *waiting for you* is
   the dock, what is *true of the conversation* is the facts row, what you can *choose* is the
   controls row.
2. **A chip is a control or a reading, never both looks.** Facts are flat and quiet; controls
   are outlined; the live ones carry their meaning on a dot, never on a tinted capsule.
3. **Stillness is how a settled chat reads.** An idle band says nothing; a finished agent is
   history; a failed turn is a card that holds still.
4. **History belongs at its call.** A subagent is drawn where it was spawned. Only an agent that
   is out now may ask for room under the last message.
5. **What blocks the turn is nearest the composer, and the jump control says so.**
6. **Meaning never lives in a tint alone.** Glyph, word or shape carries it first.
7. **Nothing fixes what a window or a setting can change.** A window is any width a person
   drags it to, and type is any size they set. A height is a minimum that grows with the type;
   a width is whatever the pane has — answers and cards fill it, with no reading measure and no
   maximum line. Where room runs out the least important thing yields first (a band segment, a
   lane, a hint), and what is live or blocks the turn never does.

## Anatomy, top to bottom

| Zone | Holds | Rule |
|---|---|---|
| Header | the conversation's title; under it the one status line (phase, tool, clock) | The title stays during a turn. Status is a second line, never a replacement. |
| Notice | at most one banner | Priority: signed out → offline → quota wall → failed; reconnecting is status only. The desktops' slot is the signed-out banner; their offline and quota states read in the band, where the action to take is. |
| Transcript | rows | Prompt is the heavy voice; answers fill the pane; a turn costs the same gap on every client. |
| Dock | what the end of the transcript holds | Order, top to bottom: pending sends → queued → turn-state cards (revert, interrupted, retry, compaction, thinking) → needs-you (question, permission). |
| Facts row | context, spend, branch, goal, agents out, background work, attachments | One row; what is live leads, so scrolling sideways never hides it. Hidden when it has nothing to say, and appearing or leaving never moves the transcript a reader is reading. |
| Call strip | a live call: face and word, clock, what was said, the agent's account, mute, hang up, the beta mark | Docked directly above the composer, below the facts row; the transcript above it stays fully visible. Only while a call is up or has just ended (6 s). Its entry is one outlined chip in the controls row beside attach, hidden for a server with no gateway. |
| Composer | the field, send/stop | Exactly one Stop control per client: on iOS the send button becomes it, on the desktops it is the button beside the composer (Send reads Queue meanwhile). The band never carries one. |
| Controls | model + effort, lane, attach, commands | Same height and shape as a chip. |

## Chips (`ChatChrome`)

- Height 30 pt (touch, hit area 44 by outsetting) / 24 (pointer): a minimum — a chip grows with
  the chrome type size and never clips. Capsule. Horizontal padding
  11 / 9, icon 12, icon gap 5, chip spacing 6. One type role: `chip`.
- Radii: control 10, card 14, composer 20, sheet 24. Nothing else.
- Fills are opaque (ink mixed into the canvas, 7 % facts and live, 4 % controls) — a translucent
  fill lets the transcript print through a chip. Controls are outlined; facts and live are not.
- Tone is on the glyph or dot only. Ink is the theme's ordinary ink.
- A fade scrim sits behind the facts row where the transcript passes under it.

## The band (desktops)

The band is the facts row on a desktop: the same segments, in `StatusFacts.segments` order,
read-only text that opens an account when it is acted on. At idle it has no phase segment (no
"ready"); with nothing to say it is not drawn. The working phase is plain text — Stop is the
button beside the composer, never a segment.

## Subagents (`SubagentPresence`)

A server lists every agent a session ever started and keeps calling one active for up to half an
hour. The turn that holds an agent is the witness: under a turn that is over, nothing is out.
Live = open turn ∧ active ∧ not reported finished. Docked under the last message: live agents
with no spawn call in the loaded transcript, and nothing else. The chip, the overflow list and
the band count live agents, plus the band keeps the agents of the turn on screen
(`presence.current`) until the next prompt. More than three siblings collapse behind one
`SubagentGroup` row on every client.

## Outcomes that end a turn badly

Answerless (`AnswerlessTurnReading`) and failed (`FailedTurnReading`) are relatives: a card
with what happened, the server's own words quoted (a cut is marked), and one action that sends
the prompt again. Both hold perfectly still. The failed card is inline after the turn's rows on
all three clients.

## The jump control (`JumpReading`)

An arrow when the reader is up the page; **Needs you** (attention tone) when a permission or a
question waits at the end; **New below** when anything arrived while they were away. No number:
what arrives is counted in rows, a unit nobody reads in, and a streaming answer makes dozens.
Same control, same words, three clients.

## The empty chat (`ChatSuggestion`)

The headline "What should your agent do?" and four starters, drawn on every client; picking one
fills the composer (and does not send).

## Accessibility floor

- Every control has a name from Core's reading strings, never from a glyph. Pending cards are
  groups with a spoken label; question options carry selected state; a disclosure carries
  expanded state.
- A turn that ends, a question and an approval are **announced** (iOS announcement, AppKit
  announcement, GTK `accessible_announce`), one Core string each.
- Touch targets ≥ 44 pt; pointer targets ≥ 24 px; focus is visible on every actionable chip.
- `reduce motion` governs every spring, slide and sweep; nothing animates without a guard.
- Keyboard: previous prompt `[`, next prompt `]`, copy the last answer `Y`, approve/deny with
  the chords the user has bound, and the hint on the button is read from the live shortcut set.
- Dimmed rows (queued, placeholders) use an ink that passes AA, not an opacity.

## State matrix

| State | Header status | Notice | Dock | Facts row | Composer |
|---|---|---|---|---|---|
| New chat | — | — | empty chat (starters) | — | ready |
| Streaming | Writing · 0:12 | — | — | context, spend… | Stop |
| Tool running | Running Bash · 0:30 | — | — | + agents out | Stop |
| Needs approval | Needs you | — | permission (last) | — | Stop |
| Question | Needs you | — | question (last) | — | Stop |
| Failed | — | — | failed card (inline) | — | ready |
| Answerless | — | — | answerless card (inline) | — | ready |
| Interrupted | — | — | interrupted card | — | ready |
| Compacting | Compacting · 1:20 | — | compaction card | — | Queue |
| Queued | Writing · N queued | — | queued rows | — | Queue |
| Offline | Offline | iOS: banner, tap to retry · desktops: the band's phase, click to reconnect | — | — | ready |
| Reconnecting | Reconnecting · 4s | — | — | — | ready |
| Signed out | — | signed-out banner | — | — | ready |
| Background work | In the background · 2 | — | — | iOS: background chip · desktops: the band's phase | ready |
| Idle | — | — | — | context, spend, branch | ready |
