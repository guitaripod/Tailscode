# Agents — what they are doing

Asked for: a great UX to view what agents are doing. Same order as the other design docs: **look** (§1), **think** (§2–§3), **design** (§4–§5, mocks in `docs/agents-board-mocks/`), then **implement** (§8). The canvas version is a private Claude artifact: https://claude.ai/artifact/8eL2EZbKiuF3saJBMWHgHm.

## 1. What I looked at

The Linux client in its headless harness (a Working band of sessions, a workflow card with its agents in the transcript), the source of every surface that mentions agents on the three clients, and the Kit's data model for them.

| Surface | Says | Only when |
|---|---|---|
| Working band, sidebar rows | which sessions run, model, elapsed | always (list level) |
| Status band, nav badge | state, live agents, background tasks | that chat is open |
| Subagent and workflow cards | each agent's tool, todos, progress | that chat is open |
| Neural trace (Megatron) | one turn's steps | that chat is open |
| Sparx orb, Live Activity | one aggregate mood, one turn | glance only |
| Delegate board | delegate runs | delegate only |

There is **no surface that shows all running agents across all machines**. `SessionActivity.presence(for:)` answers only for sessions this device drives, and the Linux orb and sidebar presence cover only the panes of the current window.

## 2. What is wrong, ranked by cost

1. **The Working band lists sessions, not agents.** Subagents, background tasks and workflow runs exist only inside the chat that started them.
2. **Needs-you is a badge, not a place.** Approving one command means opening its chat; with three running, that is three chats to find the one.
3. **Detail exists only where you are looking.** Every session this device is not driving is a dot and an elapsed time, however busy it is.
4. **The feed is thin by design.** For a session nobody opened the list stream carries `isActive`, `activeAgents` (a count), `agentTask`, `backgroundWork`. No current tool, no pending approval, no steps.

## 3. Principles

- **Agents, not sessions.** One row per thing doing work (a session's turn, a subagent, a background task, a workflow run), nested under its session.
- **State first, words second.** The activity vocabulary leads (`ActivityKind`: tone and motion, stillness meaning settled); one plain line says what it is doing, never a raw tool name.
- **Needs-you is a place, and it acts in place.** It leads the board with the command or the question word for word.
- **Peek, don't open.** A peek is a read-only monitor; opening the chat is its own verb.
- **Unknown is a word, never a spinner.** The board says which rows it is only listing.
- **Costs a line at rest.** Furniture is flat; only what is live moves, by absolute time.

## 4. Design

Three views, one board.

**Now** (every desk). A sentence leads: *2 working · 1 needs you*, and under it how much is watched. Then sections, a session appearing once, in its most urgent one:
- **Needs you.** A card per ask: what it wants (an approval's command, a question), which chat and machine, how long it has waited, and the answer in place: Deny / Approve (Face ID, as notifications already do) or the question's options.
- **Working.** A row per session: the glyph, the title, the elapsed time, the line of words (*Editing Backoff.swift*), a heartbeat strip (the last minute of tool activity; a flat strip is a stall you can see) and the machine. Its agents hang under it as a tree: an agent with its todos (`4/6`), a background task with its age. A session with agents folded says *2 agents*.
- **In the background.** Sessions whose turn ended while a task still runs.
- **Finished.** The last hour, unread first: how long it took, the tools it ran, what it changed, or why it failed.

**Peek** (every desk; a sheet on the phone, an inspector on the desktops). Title, machine, model and level, elapsed. **Doing now** in large type with the file or command under it. **Last steps**, newest first, each with its age. **Agents in this chat**, the files touched, and three meters: context fill, tokens this turn, an API-equivalent estimate marked as one. Open chat, Stop (confirmed), Nudge (queues a message).

**Hour** (Mac, Linux, iPad). Lanes over the last hour, one per session with its agents beneath, bars in the activity tones, a *now* line, an amber bar while it waits on you, a mark where it ended. Spans this device did not see are hatched. Selecting a lane fills the inspector with its Peek.

Entry points: Home's Working band header and the orb on the phone; the sidebar's Agents entry, its orb and ⌘⇧A / Ctrl+Shift+A on the desktops; a Live Activity tap opens that agent's Peek. The orb, the Live Activity and the band stay as the glance; this is the read.

## 5. Data, and what the board can honestly say

| Fact | Listed | Watched (up to six) |
|---|---|---|
| Running or idle | yes | yes, and for how long |
| Live agents | a count | each: name, current tool, todos |
| Background work | a count | the task and how it ended |
| Waiting on you | not in the feed | the command or question |
| Doing now | no | the latest tool call, in words |
| Heartbeat, last steps | no | from the events this device saw |

- **Watching is the cost, so it is capped.** The board attaches up to six running sessions (needs-you first, then the most recent) and releases them when it closes; past six a row says *listed* and offers to swap it in. A conversation the app already holds is reused.
- **Time is only what the server stamped.** A tool call carries no duration, so a step's age is when this device first saw it, and Hour hatches what it did not.
- **A machine that stops answering keeps its rows**, dimmed, with when they were last seen.
- **Backends differ and the board says so.** claude-bridge and omp-bridge report agents, background work and interruptions; opencode 2.x agents and interruptions; opencode 1.x agents as child sessions and nothing else. A section a backend cannot fill is never drawn for it.
- **Answers keep their paths.** A Claude `AskUserQuestion` goes through `ChatViewModel.send`, an approval asks Face ID, and a subagent is read inline, never opened as a chat of its own.
- **Money is an estimate.** API-equivalent, marked as such, never a bill.

## 6. Where it lives

Core, toolkit-free, so three clients agree:
- `AgentRoster.read(sessions:watched:now:)` → `AgentBoard` (needs-you cards, working trees, background, finished, the footer's watch count).
- `AgentLine.words(for:)`: a tool call to its line (*Editing Backoff.swift*, *Running swift test*, *Searching “jitter”*, *Reading 12 files* for a run of reads), built on `ToolCallSummary.Kind`, never on `summary` in a loop.
- `AgentWatch.plan(running:watching:cap:)`: which sessions to attach and which to release.
- `AgentBeat`: the heartbeat as bucketed counters of observed events.
- `AgentHour`: lane spans from `PresenceLedger` and turn stamps, unseen spans marked.
- `AgentAction`: approve, deny, answer, stop, nudge, each routed through the chat's own path.

Per client: a board view, a Peek, and on the wide desks the Hour lanes. Parity: `agentsBoard`, `agentPeek` and `agentsHour`; the iPhone answers `agentsHour` as not applicable (lanes need width) and the iPad implements it.

Cost rules: the board rebuilds on state changes, coalesced to one a second, never per streamed token; the heartbeat is counters; motion is arithmetic on absolute time.

## 7. Not in this

A menu-bar extra, a watch face, starting or steering agents beyond Stop and Nudge, history the device did not see, money per agent, a cross-machine timeline merged server-side.

## 8. Mocks, and what looking at them changed

`phone-now.png`, `phone-peek.png`, `mac-hour.png`; the hero is one Blender render, `hero/`, shaped like the carry one (`docs/model-carry-mocks/hero/finish.py` finishes it).

- The headline said *3 working* over two rows; the count is sessions, so it reads *2 working* and the agents are in the tree.
- The Peek's files-touched row wrapped its `+1` onto a line of its own; the word became a glyph.
- The Hour mock disagreed with itself on how many were running (5, 3, 4); the sidebar, header and phone now agree on four, two working, one waiting, one in the background.
- The heartbeat strip was added after the first Now mock read as a list of sessions with nothing to say about *how* they were running.

## 9. Implement

1. **Core**: `AgentLine`, `AgentBeat`, `AgentWatch`, `AgentRoster`, with tests built from `MockBackend` transcripts (a stalled turn, an approval, two agents, a background task, a failed turn).
2. **Now**, with the needs-you actions, on the three clients in parallel; parity cases added first.
3. **Peek**, then **Hour** (`AgentHour`) on the desktops and iPad.

Shipping per CLAUDE.md: Linux installs on arch only when Marcus says, the Mac through its release path (the macbook's `/Applications/Tailscode.app` is the store build), iOS from his machine.
