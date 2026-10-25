# Agents Watch — the board you leave up on a monitor

Asked for: the Agents window as "a cool screensaver you just leave up on a monitor to monitor the situation", where every state has meaning. The window also grew taller than the Tailscode window it came from. Same order as the other design docs: **why** (§1), **language** (§2–§3), **layout and ambience** (§4–§5), **controls and honesty** (§6–§7), **where it lives** (§8).

## 1. Why the board is not that yet

The board (Now, Hour) is a *work surface*: it is read from a foot away, scrolls, and has a sidebar of detail. A monitor wall is read from three metres, never scrolled, never touched, and left on for days. Different job, different design:

- **It must never scroll or overflow.** Whatever the agents are doing, the whole situation fits one screen, so the layout is chosen from the count and the window's aspect, not from the content's natural height. (The window that outgrew its parent was sized by its content; it is now sized by the monitor and remembered.)
- **Glance first.** One sentence in huge type says the situation; colour and motion say the rest; detail is one tap away and goes back by itself.
- **Quiet is a state, not an absence.** An empty wall says "all quiet" and shows the last hour, so a person can tell *calm* from *broken*.
- **It must be safe unattended**: no popups, no focus grabbing, no one-tap approvals, no burn-in, no CPU burn.

## 2. The state language

One vocabulary, from Core (`AgentWall`). A tile wears exactly one state, and the state is never told by colour alone: shape of the glyph, the motion and one plain word say it too.

| State | Means | Look | Motion | Word |
|---|---|---|---|---|
| **Working** | a turn is running and events arrive | green orb, context ring around it, scrolling heartbeat | slow breathing; the heartbeat moves with real activity | what it is doing ("Editing Backoff.swift") |
| **Thinking** | running, no tool out | soft violet orb | slower breath, no tool tick | "Thinking" |
| **Needs you** | an approval or a question | amber tile, the command or question word for word | knocks twice every few seconds; waiting time counts up | "waiting 2m" |
| **Overdue** | needs you for more than 5 minutes | the amber deepens to a hot orange-red border and the screen's edge breathes | the edge vignette breathes slowly; never flashes | "waiting 12m" |
| **Retrying** | the provider failed, the agent is trying again | amber dashed ring | the dashes crawl | "Waiting on the provider · try 2" |
| **Quiet** | running but nothing has moved for 45 s | cold slate orb, flat heartbeat | still, one slow ripple a minute | "quiet for 3m" — a stall you can see |
| **Background** | the turn ended while a task still runs | hollow ring with one orbiting dot | the dot orbits | the task and its age ("swift test · 22m") |
| **Stuck** | background work that stopped reporting | the hollow ring turns amber, dot stops | still | "stuck" |
| **Finished** | a turn ended well | cyan check, tile cools | the tile fades out over 60 s, then lives in the Recent strip | "Done in 6m · 14 tools" |
| **Failed** | a turn ended in failure | red cross, tile stays | none | the reason; stays until the board is closed or 15 minutes pass |
| **Stopped** | the person ended it | grey square | none | "Stopped" |
| **Away** | the machine stopped answering | the tile is hatched and dim | none | "studio not answering · last seen 4m ago" |
| **Listed** | running, but past the watch cap of six | a compact chip in the rail | none | "listed" |

Wall-level mood, which drives the ambience: **calm** (nothing running), **busy** (something working), **attention** (something needs you), **alarm** (overdue, or a failure not yet seen). Mood changes headline colour, the speed of the ambient motes and the edge vignette — never anything flashing.

## 3. What the numbers are

- Context ring: the share of the model's context window in use (`ContextFill`); it turns amber past 85 % (compaction is near), never a bill.
- Heartbeat: the last minute of events this device saw (`AgentBeat`), drawn from counters; flat means nothing arrived, not that the machine is down.
- Elapsed and waiting times count from absolute timestamps, ticking once a second, never from the number of frames.
- The money line, where shown, is an API-equivalent estimate and says so.
- "Watching 4 of 6" and "listed" say what is read live and what is only listed.

## 4. Layout

The wall is a grid of **tiles, at most six** (the watch cap) plus two rails.

- Columns and rows come from the tile count and the window's aspect: 1 → one hero tile; 2 → two across (landscape) or stacked (portrait); 3 → three across or one hero + two; 4 → 2×2; 5–6 → 3×2 (landscape) or 2×3 (portrait).
- Order is by urgency: needs-you (longest wait first), failed, retrying, quiet, then working, thinking, background, finished. A tile keeps its place until its state's rank changes, so the wall does not reshuffle on every event.
- A needs-you tile spans two columns when the grid has at least two tiles; it carries the command in large monospaced type, wrapped, never cut.
- **Top band:** the headline sentence in the largest type on the screen ("2 working · 1 needs you"), the watch line under it, the clock and date at the right, large.
- **Bottom band:** the Hour strip (the last hour of every lane, compressed to a single thin ribbon with the now line, hatched where not seen) and under it the **Recent** rail: the last five endings as chips (✓ Deploy check · 12m ago) and **Also running**: listed sessions as chips.
- Every size derives from the window height (`unit = height / 100`); text is never smaller than 1.6 units, so a 4K monitor and a 1080p one read the same from across a room. Nothing scrolls; if the situation is huge the extra goes to the rails as counts ("+3 listed").
- When nothing runs: the calm screen — a large slow orb in the centre, "All quiet", the last hour's summary in one line ("6 done · 1 failed · 2 stopped in the last hour, seen by this Mac"), the Hour strip full width.

## 5. Ambience

- A very dark ground in the theme's own palette (the theme's dark variant when the current appearance is light), a faint grid, and **motes**: a few dozen tiny drifting points whose speed follows the busyness (calm: almost still; busy: a gentle current; attention: they drift toward the needs-you tile). Pre-allocated, no per-frame allocation.
- Tiles are glass cards with a soft inner glow in the state's colour; the glow breathes on the absolute clock.
- **Burn-in care:** the static chrome (headline, clock, rails) drifts by up to ±6 px on a ten-minute loop; after ten minutes of calm the whole wall dims to 40 % and the motes slow; any event brings it back over a second.
- **Cost:** one frame clock, capped at 30 fps while anything animates, 1 fps when calm and dimmed, none while the window is hidden or minimised; reduced motion makes every breath a still frame and keeps only the heartbeat's movement.

## 6. Controls

- Header: **Watch · Now · Hour** (Watch is the default and what fullscreen shows), fullscreen, keep-awake.
- `F11` or double-click the headline: fullscreen. `Esc` leaves it. In fullscreen the header and the pointer fade out after 3 s and return on movement.
- `d` dims or undims, `k` toggles keep-awake (on by default in fullscreen: the compositor's idle inhibit is held while the wall is up and released when it leaves).
- `1`–`6` or a click on a tile: the **peek overlay** (doing now, steps, agents, meters, Open chat, Stop, Nudge) over the wall; it goes back to the wall by itself after 20 s without input.
- **Approve on the wall is hold-to-approve**: press and hold 0.8 s while a ring fills; a tap does nothing but shows "hold to approve". Deny is a tap. A wall left on a shared monitor must not be approvable by a stray touch. Answers go through the same paths as the board (`.needsChat` opens the chat).
- Nothing on the wall ever opens a dialog by itself.

## 7. Honesty

- It draws only what the tower saw; "quiet" means *no events seen*, never *dead*; a machine that stopped answering is shown as away, with when it was last seen, not as failed.
- A failure stays until seen; a finish fades; a calm wall says so.
- The hour strip says "seen by this Mac" and hatches what it did not see.

## 8. Where it lives

- Core, toolkit-free and tested: `AgentWall.read(board:hour:now:aspect:)` turns the board into the wall — mood, headline, tiles (state, urgency level, span, words, heartbeat, context ring, children), grid shape, rails, calm summary — and `AgentRow` carries the last steps, the object and the context share the tiles need. `AgentDemo.wall(now:)` is the fictional wall with every state in it, for screenshots and self-tests.
- Linux first: `AgentsWatchView` is the window's default lens; the window is sized from the monitor (never taller than its work area, remembered), fullscreen and keep-awake wired to the compositor. Mac and iOS answer `agentsWatch` as a declared gap until their own wall exists (the iPhone's is the obvious StandBy screen); the reading is shared.
- Parity: `agentsWatch`.
