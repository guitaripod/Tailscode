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
- **Nothing moves a tile.** A session takes a slot when it first appears and keeps it until it leaves the wall, whatever its state does: a turn that flips between working and thinking on every tool, going quiet, retrying, or an ask arriving reshuffles nothing. A newcomer joins the end; only the very first read puts the most urgent first (needs-you with the longest wait, then failed, retrying, quiet, working, thinking, background, finished). Urgency is told by the tile's own glow, mark and word, never by where it sits. When there is no room for six, what goes is what matters least and latest (a cooled ending, then background work, then what runs), never an ask.
- No tile spans. A needs-you tile is one cell like any other and carries the command in large monospaced type, wrapped, never cut; when a command is too long for the cell it says so and a press opens the whole of it in the peek.
- **Top band:** the headline sentence in the largest type on the screen ("2 working · 1 needs you"), the watch line under it, the clock and date at the right, large.
- **Bottom band:** the Hour strip (the last hour of every lane, compressed to a single thin ribbon with the now line, hatched where not seen) and under it the **Recent** rail: the last five endings as chips (✓ Deploy check · 12m ago) and **Also running**: listed sessions as chips.
- Every size derives from the window height (`unit = height / 100`); text is never smaller than 1.6 units, so a 4K monitor and a 1080p one read the same from across a room. Nothing scrolls; if the situation is huge the extra goes to the rails as counts ("+3 listed").
- When nothing runs: the calm screen — a large slow orb in the centre, "All quiet", the last hour's summary in one line ("6 done · 1 failed · 2 stopped in the last hour, seen by this Mac"), the Hour strip full width.

## 4a. Sub-agents get tiles of their own

Asked for: "sub-agents in that watch mode with their own tiles, so you have a full bird's eye view over the workers." A session's workers were four dots in its footer; they are now tiles, so the wall answers *who is doing what under each session* at a glance.

- **One cell per session, shared.** The grid does not change: still at most six sessions. Each cell is cut between the session's own tile and a small tile for each of its workers (`WallSquad`, cut from the cell's real shape — `AgentWall.read(gridAspect:)` is the shape of the area the tiles fill, not of the screen). A wide cell puts the session left and the workers right; a tall one puts the session on top and the workers under it. A faint plate in the session's colour runs round the whole cell, so the group reads as one.
- **How many fit.** The fewer sessions share the wall the more each cell affords: 6 workers for one session, 5 for two, 4 for three, 3 for four to six. When there are more, the last slot is a `+N` tile that counts them, and says *some need a look* when the first one it hides is stuck or quiet. A tile is never smaller than the text floor, so the cut is by count, never by shrinking.
- **Four states, each with its own mark and word** (`WorkerState`): *working* (the agent's own orb, what it is doing in its todo's or its tool's words, its todo list as a bar with `4/6`, how long it has run); *quiet* (the listing has seen no movement for 90 s, counted from when it last moved: the slate orb, "quiet for 3m" — it says nothing was seen, never that the agent is dead); *background* (a shell task the session carries: the hollow ring with one orbiting dot, or amber and still when the machine found it stuck); *finished* (it left the roster while the session runs: a ring of unknown ending, cooling over half a minute, never a check — the listing does not say how it ended).
- **Order.** Workers keep their places like tiles do: a newcomer joins the end (the longest-running first when several arrive together) and a worker that goes quiet or stuck stays where it was. The `+N` tile says *some need a look* when any worker it hides is stuck or quiet.
- **Honest silence.** Quiet is not read behind an ask or for a machine that stopped answering: the silence has a known reason and the session's own tile already says it. Sessions nobody watches first-hand have no workers to draw, only the listing's count, which their chip in *Also running* carries ("2 sub-agents").
- **Cost.** Worker marks turn at 15 fps, their glass at 6; nothing about them wakes a dimmed wall except a worker appearing, leaving, going quiet or getting stuck.
- **Press.** A press on a worker, or on the `+N`, opens its session's peek (which lists every agent). A worker is never approvable and never its own chat: a subagent is not a chat.

## 4b. Plain words

Asked for: "the text output in the tiles should be natural decoded language that anyone can read and understand easily."

- **Rules first, for everyone** (`AgentPlain`, Core, offline, instant, the same on every client). A tool call or shell command is said as what it does, in the tense of what it is doing: *Running the tests*, *Ran the tests*, *Looking at Backoff.swift*, *Changing Backoff.swift*, *Searching the code for “jitter”*, *Clearing the build folder → Building the project*. Never a command's own text or a tool's name. The shell is read the way a person would read it: wrappers (`sudo`, `time`, `FOO=1`, `cd x &&`) are taken off, `bash -c '…'` is read through, a pipe is described by its first stage, a line of commands is said in order and never names more than two. About a hundred common commands are known (tests, builds, installs, git, files, search, network, services, containers, lint and format).
- **Nothing dangerous is said softly.** A forced push, a hard reset or `git clean -f` are *Force-uploading the changes* and *Throwing away local changes*; a script piped into a shell is *Downloading a script and running it*; `sudo` adds *as administrator*. An approval keeps its whole command beside the rules' own lead (*Wants to run*), never a paraphrase of it.
- **The raw words stay where they help.** A tile no longer prints the path or the command under a line the rules understood (the line already says it, and a press opens the peek for the rest). When no rule could read a command the line is the honest *Running a command* and the raw command is shown under it, so the tile still says something real.
- **Workers and background work** say the same way: a sub-agent's tool is *Searching the code* and not `Grep`, a background task is *Running the tests* and not `swift test --parallel`; a retry says *The AI service is busy, trying again*, not that it waits on a provider.

### Opt-in: a model you run says the rest

For the commands no rule knows, a person may switch on a model they run themselves (`agentsLocalWords`, Linux first). It is **off by default** and decided this way because the rules already read the great majority, the long tail is the one place a model beats them, and a monitor wall is the wrong place to send anything anywhere without being asked:

- Only an OpenAI-compatible address on this machine or a private network is accepted (`PlainModel.endpoint`: loopback, private ranges, tailnet addresses, `.ts.net`, `.local`, `.localhost`; never credentials in the address, never the internet), checked when it is saved and again at every request.
- Only the raw words of an unreadable running command or tool are sent, capped at 400 characters and with secrets taken out first (`PlainModel.redact`). Never a conversation, a file or an approval.
- One fixed, readable prompt asks for one line of 3 to 9 words; a reply is shown only if it is one short plain line with no code or paths (`PlainModel.reply`). Anything else keeps the rules' line.
- Its lines carry a ✦ and say *written by a model* to a screen reader. Answers live in memory only, one request runs at a time, a failure is not retried for a minute, and with the switch off nothing is ever sent.
- It is never the only thing standing between a person and a decision: approvals are rules-only.

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

- Core, toolkit-free and tested: `AgentWall.read(board:hour:now:aspect:gridAspect:previous:)` turns the board into the wall — mood, headline, tiles (state, urgency level, span, words, heartbeat, context ring, workers and the squad that shares the cell with them), grid shape, rails, calm summary; `reflowed(aspect:gridAspect:)` fits a read wall to another window (a demo scene) — and `AgentRow` carries the last steps, the object and the context share the tiles need. `AgentDemo.wall(now:)` is the fictional wall with every state in it, for screenshots and self-tests.
- Linux first: `AgentsWatchView` is the window's default lens; the window is sized from the monitor (never taller than its work area, remembered), fullscreen and keep-awake wired to the compositor. Mac and iOS answer `agentsWatch` as a declared gap until their own wall exists (the iPhone's is the obvious StandBy screen); the reading is shared.
- Parity: `agentsWatch`.
