# Delegate's first run: a packet climbing, then the price

Asked for (2026-11-28): make Delegate's first run pretty, neat, useful, easy to complete and educative, and get revenue up, because many people use the app without paying. Shots are in `docs/delegate-first-run-shots/`, taken on the iPhone 17 Pro simulator with made-up machine names: `1-rehearsal-and-lesson.png` (the rehearsal board, then the practice run on the local rung, one rung up, and waiting for review) and `2-ask-price-setup.png` (applied with the way on, the Pro sheet, a machine with no dispatcher, the request written for its agent).

## 1. What was wrong

- **The price came first.** A copy without Pro that pressed Delegate, from the server row, Home or a chat, met the Pro sheet (the second frame of the second strip) before anything else. The sheet describes a ladder in a paragraph. Nobody had seen a packet climb before being asked for $14.99.
- **Setup was a dead end for anyone without Rust.** A Pro copy whose machine had no dispatcher met two shell commands, the first of which needs `cargo`. The agent sitting on that very machine could do it, and the app never asked it to.
- **The numbers** (`midgar brief --app tailscode`, 28 days to 2026-11-28): 131 new installs, about 82 active a week, 56 Pro sheet views since 6 November, 2 sales. The lever is how few people see what Pro does before the sheet, the same finding as D42.

## 2. What it is now

One rule: the first thing anyone learns about the dispatcher is the dispatcher working.

1. **Every road in leads a free copy to the rehearsal** (`DelegateRehearsal.road`). That is the scripted machine's board, which already plays the whole feature with no network. It opens with three lines that say what a packet is and one bold button, Send the practice packet. It is the only primary action there, so New packet steps back.
2. **The practice run is the lesson.** One sentence under the headline says what is happening as it happens (`DelegateRunReading.teaching`): the cheapest rung goes first; the proof failed, so the next rung is handed the verifier's words; it passed before the frontier was asked and waits for review; applied. The run stays at its top so the sentence is not scrolled away. A real machine's run is never lectured.
3. **Then the price, twice and never in the way.** "Use Delegate on <their machine>" sits under the practice button and again on the settled practice run, the moment the loop has just closed. It opens the Pro sheet with the delegate lead and the free Pro week; once Pro is open the rehearsal is replaced by that machine's own board.
4. **Setup is a request, not a chore.** A machine with no dispatcher offers, in order: ask the agent already on it (a new chat there with the request written out and unsent: install, write the config, fit the tiers to the models that machine has, start the service, prove it answers), watch a packet climb first, then the two commands by hand.

The practice packet is the translation job this work was born from: three new strings into Finnish, verified by `scripts/l10n-check.py --strict`, failing once on the local model and passing one rung up.

## 3. Where each client stands

| | iPhone and iPad | Mac | Linux |
|---|---|---|---|
| Rehearsal card and practice button | `DelegateBoardViewController` | `rebuildRehearsal` in the Delegate window | `rehearsalBlock` |
| Lesson sentence on a run | a row under the headline | under the facts | under the facts |
| The way on to Pro | row on the board and on the settled run | button in the rehearsal column (store build) | none: nothing is sold |
| Ask the agent to install | row, opens Home's box aimed at the server | button, opens a new chat | button, opens a new chat |

## 4. How it is judged

`MidgarSignals` marks `delegate-rehearsal` when a free copy lands on the rehearsal and `delegate-practice` when the practice packet is sent; the Pro sheet opened from it is `paywall.view` with placement `feature`, as before. So the funnel is door, practice sent, sheet seen, purchase, read with `midgar brief --app tailscode` once a release carries it. With about 130 installs a month the purchase count will move slowly; the first thing to read is whether practice packets are sent at all.

## 5. Not done

- Walked end to end on the iPhone 17 Pro and iPad Pro 11 simulators and in the Linux headless harness. The Mac window compiles and has not been looked at (a shot run opens a window on the desk in use), and no real device has run it.
- The first *real* packet is still a blank form. Starter packets (write the missing tests, translate the new strings, fix what the linter reports) are the next step after setup.
- Nothing invites a person to Delegate who never presses it. The Pro invitation after ten turns names it; the usage page, where the month's spend is, does not.
