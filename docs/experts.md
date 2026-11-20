# Experts

Asked for (2026-11-19): is it a good idea to keep one session dedicated to iPadOS work, always the same one? Research what the best system is. If a dedicated specialist is worth having, it goes beyond a skill and should be considered as a Tailscode feature: "an expert bot, like what many others do with bots, but better". Same order as the other design docs: **look** (§1), **think** (§2), **design** (§3–§7, mocks in `docs/experts-mocks/`), **implement** (§10).

## 1. What I looked at

### The session that asked

The iPadOS session ran from 17 to 20 November over three apps (layout, iPad mini, performance, how posts open), with about a dozen helper agents. Its context was compacted at least four times. What carried from one task to the next was never the thread. It was the files: the `ipados` skill (devices, window sizes, the design contract, the verification loop), the device lines in the global instructions, and three memory files. What the thread lost: after the last compaction, the performance results the person had not yet been told had to be dug back out of the session's own transcript file with a script, and each task began by reading the same files again. The thread was a liability carrying files that would have loaded into any new session.

### Research (sources at the end)

- **Long contexts get worse.** Anthropic names it context rot: recall falls as the window fills, on every model, because attention is spent across n² pairs of tokens. Compaction has to choose what to keep, and "cutting too aggressively can remove details that matter later". The recommendation is notes kept outside the window and sub-agents with clean context that hand back a summary (Anthropic, 2025-09-29). The degradation numbers come from retrieval benchmarks, not from coding sessions, so applying them to Claude Code is an inference, and this session is one observation that agrees.
- **Long-running work is handed over in files.** Anthropic's harness for multi-session work passes state through a progress file, git history and a feature list whose items only change status, and starts every session fresh (2025-11-26).
- **Specialist knowledge helps only when it is specific and tested.** SkillsBench measures curated skills raising the average pass rate from 33.9% to 50.5% across 87 tasks (2026-02). SWE-Skills-Bench measures almost nothing on real software-engineering work: 76.6% to 76.9%, 92 of 98 skills not significant, and some skills hurt by imposing their own templates (2026-03-16). Anthropic's skill-creator adds evals and blind A/B runs so a skill change can be shown to help, and flags skills a newer model has absorbed (2026-03-03).
- **Evals.** Regression evals should sit near 100%, capability evals start low. Graders are checked by reading transcripts, and grading the outcome usually beats grading the path (Anthropic, 2026-01-09).
- **Memory decays.** 2026 papers find that the usefulness of accumulated memory rises and then falls as it is consolidated again and again, sometimes below having no memory at all. Superseded facts keep being retrieved, and agents rarely notice that a memory is no longer true. The proposed fix keeps old records with provenance and invalidates them, rather than deleting or silently rewriting them (arXiv 2609.33013, 2610.05732). Practice is converging on memory that is dated, edited and deleted as files, with consolidation done offline.

### Other products

| Product | Kept across tasks | Fresh per task | The good idea | The pain |
| --- | --- | --- | --- | --- |
| Claude Code | `CLAUDE.md`, skills, subagent definitions (a subagent may keep a memory directory), auto memory | every session and subagent | skills load only when needed | memory is written by the model with no review; nothing says when a skill stopped helping |
| Codex | `AGENTS.md`, skills | every task | a short `AGENTS.md` as a map, not a manual | nothing learns |
| GitHub Copilot | custom agents in `.github/agents`: instructions plus a tool allowlist | every run | an agent is a file in the repo | no memory |
| Devin | Knowledge (now deprecated in favour of Skills), Playbooks | every session | playbooks as reusable procedures | suggested knowledge piles up |
| Cursor | `.cursor/rules` (third-party reports say Memories was removed in 2.1; not confirmed) | every chat and background agent | rules scoped to paths | automatic memories reportedly dropped |
| Factory | droid definitions | every droid run | a role with its own tools | no memory beyond the definition |
| Letta | memory blocks in a database, rewritten by the agent; sleep-time agents consolidate offline | the context window | consolidation away from the conversation | the memory edits itself and nobody sees a diff |
| Claude and ChatGPT Projects | project files and project-scoped memory | each chat | knowledge attached to a place | invites one endless chat per project; no tools of your own machine |

Across all of them the durable part is a standing-instructions file or a skill, and the worker's context is fresh each time. Few keep memory beyond those files, and none of them asks the person before memory changes, tests whether the specialist got better or worse, or knows anything about the devices and tools it works with.

### Tailscode today

- claude-bridge starts every Claude conversation with `claude -p --resume`, `--add-dir <directory>` and the client note through `--append-system-prompt` (`ClaudeProcess.arguments`, `ClientNote`). That note is how a standing brief reaches a session without ever entering its transcript.
- Schedules (`Scheduler`) already run fixed words with a fixed model on the machine, quiet unless there is news. Their "one conversation that remembers" mode is the endless-thread pattern: right for a daily digest, wrong for work.
- A carry (`ConversationBrief`, `CarryMark`) turns a conversation into prose a fresh session can start from, built on the device.
- The delegate ladder hands out packets with a verify command, which is an eval in all but name.
- `SetupChecklist` is the one vocabulary for a capability the machine proves.
- Marks live on the bridge, so a decision follows the person to every client.
- The Agents board (`AgentTower`) watches up to six running sessions.

## 2. What goes wrong, and the principles

Ranked by what it costs a person:

1. **The thread is the memory.** People keep one chat per subject because it is the only place the agent's knowledge lives, and it rots, compacts and forgets in ways nobody sees.
2. **Memory writes itself.** Automatic memory adds and rewrites facts with no review, stale facts come back for months, and there is never a diff to read.
3. **Nothing says whether the specialist is any good.** Instructions and skills change without a test, and most skills measurably do nothing for software work.
4. **The specialist has no hands.** Its instructions mention an iPad; nothing knows whether the iPad is connected, unlocked, or held by another task.
5. **Its work is scattered.** Results sit in chat scrollback, so the next task cannot see what the last one measured.

Principles:

- **A task is a fresh session; the expert is what carries over.** Every task opens a new chat that starts with the expert's brief. Nothing depends on a thread surviving.
- **The notebook changes only by your hand.** Each fact is a file with a date and the task it came from. At the end of a task the expert proposes changes, and you accept or skip each one. An outdated fact is retired with its reason, never silently rewritten or deleted.
- **The journal is the memory of work; the notebook is the memory of truth.** Every task leaves one journal entry: what was asked, what changed, what was measured, and the commits. The next task reads the latest few.
- **Its bench is proven, not described.** The devices and tools an expert works with are rows the machine proves (connected, unlocked, who holds it), in the setup checklist's vocabulary.
- **Guards say when its world breaks.** An expert owns commands that must keep passing: tests, and benches with a threshold. A failure reaches the next task as its first fact, and the expert's card says so.
- **It lives on the machine**, like marks and schedules, so every client shows the same expert. Words on the device, facts on the wire.
- **Files you already have.** An expert adopts an existing skill and memory directory (`~/.claude/skills/ipados`, `~/claudememory/tailscode`) instead of copying them, so the terminal and Tailscode share one truth.

## 3. What the person sees

### 3.1 The shelf

Home gains an **Experts** section when a machine has one. The iPad and the desktops get a sidebar place, *Experts*, with the experts listed under it; on the iPad they sit at the sidebar's foot, under the left thumb. Each row: the expert's mark, its name, and one state line: *Working on "Unrager posts" · 14 min*, *Idle · 23 notes · guards passing*, *2 notes to review*, *Guard failing · PadLayoutTests since 03:00*. A row opens the expert. *New expert* sits at the foot.

### 3.2 An expert's page

- **Head**: mark, name, one sentence of purpose, the machine, the folder, the model and effort it starts with, and **New task**. On an iPad held sideways the page is two columns (bench, guards and watches; notebook and journal), and New task becomes a composer along the page's foot, with Send under the right thumb.
- **Bench**: one row per device or tool, proven by the machine: *iPad Pro M1 · connected · free*, *iPad mini · on arch over USB*, *iPhone Air · locked*, *iPad Pro M1 · held by "Flaccy perf" since 14:02*. A row that is not ready says what is missing, never what command to run.
- **Guards**: *12 of 12 passing · checked 03:00*, each guard a row with its last result, its measured number against its line where it has one (*46 ms · at most 100 ms*), and how long it took. *Check now*. A failing guard offers *Hand the failure to iPadOS*: a new task that starts with the failing output.
- **Notebook**: *23 notes · 2 not confirmed since September*. Opens the notes, each a title, its first line, when it was written or last confirmed, and the task it came from. Retired notes sit folded at the foot with their reasons.
- **Journal**: the latest tasks, each its title, when, and its outcome line (*Posts zoom from their card · 280 tests · installed on 3 devices*). A row opens that task's chat.
- **Watches**: the schedules the expert owns, such as *Every morning 08:00 · pull the iPad's Tailscode logs, say only new stalls*. They are ordinary schedules and report quietly unless there is news. A watch never starts work on its own.
- **Charter** and **Skills** last: the standing instructions (short, a map rather than a manual) and the skills it loads first, *Adopted from arch: ipados, ios-dev*.

### 3.3 Starting a task

- **New task** on the shelf or the page opens a new chat whose pill wears the expert before the model: *iPadOS · Opus 5.5*. The model chooser gains an **Experts** section above the families, so any composer can start one.
- Above an empty composer, one line says what the session starts with: *Starts with its charter, the ipados skill, 23 notes, the last 5 tasks, iPad Pro free · 3.1k tokens*. It is a fact, not a setting.
- **Hand to an expert…** in any chat's menu starts a task with that conversation carried as a brief (`CarryMark`), the way a pick of another machine does.
- The brief rides in the runner's prompt, beside the client note, and never in the transcript. A carry never takes it along.

### 3.4 Ending a task: the debrief

- A task is finished by *Finish task* in the chat's menu, or by starting the expert's next task: an unfinished task is debriefed first, so a journal entry is never missing and no turn is spent on a chat that is still going.
- The debrief is one extra turn on a fork of the task, so the task's own transcript stays as it was. It returns the journal entry and the proposed notebook changes.
- The chat ends with a **debrief card**: *iPadOS learned 2 things and wants to retire 1*. Each proposal is a row (*New*, *Changed*, *Retire*) with its reason and its own action beside *Skip*: **Add**, **Change** or **Retire**. *Accept all* is one press, and *Later* leaves the debrief waiting (the shelf's *3 notes to review*). The journal entry is shown above them and is kept as written. Nothing reaches the notebook until it is accepted.
- When the person is not looking, one notification: *iPadOS finished "Unrager posts" · 3 notes to review*.

### 3.5 Making an expert

- **From a chat**: *Make an expert from this chat…* drafts a name, a charter of at most 300 words, the first notes, the bench (the devices the chat used) and the skills it loaded, as a review sheet. A note that was only true that day (a port another agent held) is offered unticked. Nothing is saved until *Create*.
- **From a skill**: *New expert › From a skill on arch* lists the machine's skills; picking one adopts it and drafts the charter from its description.
- **The notebook** is either new (on the machine, beside the expert) or an existing memory folder adopted as it is, one fact per file with a front matter and an index. Notes accepted in Tailscode land in that folder, so the terminal sees them on its next session.

## 4. On the wire (claude-bridge)

- `/status` gains `experts: 1`.
- `GET /experts` → `[Expert]`. `Expert`: `id`, `name`, `glyph`, `hue`, `purpose`, `directory`, `model`, `effort`, `charter`, `skills [String]`, `notebook {path, adopted, notes, stale, retired}`, `bench [BenchItem]`, `guards [Guard]`, `watches [String]` (schedule ids), `journal` (latest five `JournalEntry`), `task? {sessionID, title, since}`, `pending` (notes waiting for review), `briefTokens`.
- `BenchItem`: `id`, `name`, `kind` (`appleDevice` · `lock` · `port` · `command`), `state` (`ready` · `absent` · `locked` · `held` · `unknown`), `holder? {sessionID, title}`, `facts` (name, model, OS, connection). `Guard`: `id`, `name`, `command`, `directory`, `pass` (`exit` · `{metric, atMost|atLeast}`), `last? {at, passed, seconds, value?, failure?}`.
- `GET /experts/:id/notebook` → `[Note]`: `id` (the file name), `title`, `summary`, `body`, `written`, `confirmed?`, `source?` (session id), `retired? {at, reason}`.
- `POST /experts`, `PATCH /experts/:id`, `DELETE /experts/:id` (the notebook and the journal stay on disk, and the sheet says so). `POST /experts/draft {session? | skill?}` → an unsaved `Expert` with draft notes.
- `POST /experts/:id/tasks {text, model?, effort?, carry?, directory?}` → a session; `SessionSummary.expert {id, name}` thereafter.
- `POST /sessions/:id/debrief` → `Debrief {journal {title, outcome, measured [String], commits [String]}, proposals [{id, op: add|change|retire, note?, title, body, reason}]}`; `GET` returns the stored one. `POST /experts/:id/notebook/accept {accepted [id], edits?}` writes the accepted changes and closes the debrief; a debrief left for later stays in `Expert.pending`.
- `POST /experts/:id/guards/run`; `GET /experts/:id/bench` proves the bench on demand.
- A change goes out on `/stream` as `experts`.

## 5. Inside the bridge

- `ExpertStore` (actor): `~/.claude-bridge/experts/<id>/expert.json`, `journal.jsonl`, and `notebook/` unless one is adopted. Writes are atomic, files are mode 0600, and a retired note moves to `notebook/retired/` with `retired` and `reason` in its front matter. An adopted folder gets the same files and its index line, and the bridge never commits in it (a folder synced by its own job, as `~/claudememory` is, keeps its own history).
- `ExpertBrief`: the charter; the adopted skills, named so the session loads them first; the notebook's index (each note's title and summary, plus the folder to read the rest from); the last five journal entries; the bench as facts; failing guards. It has a budget of 4,000 tokens: over it, the oldest journal entries go first, then the notes' summaries (titles stay). It is appended through `--append-system-prompt` beside the client note, so it is part of the launch and never of the transcript.
- `ClaudeLaunch` gains `expert`, and `serves(_:)` compares it, so a conversation never continues on a process started with another brief.
- The debrief runs `--resume <task> --fork-session` with an out-of-transcript prompt that asks for JSON in a fixed shape, parses it, and deletes the fork's transcript. If the JSON does not parse, it is asked once more, then the card says the debrief could not be read and offers *Try again*.
- Guards run through `Scheduler` as a command run instead of a prompt run, keep their last 30 results, and follow schedules' quiet rule: a guard that keeps passing says nothing, and a change from passing to failing is news.
- Bench provers per kind: `appleDevice` reads `xcrun devicectl list devices --json-output` on a Mac and `pymobiledevice3 usbmux list` on Linux; `lock` asks who holds the lock file and maps that process to the session whose process tree it belongs to; `port` connects; `command` runs a probe with a timeout. They run when a page asks and every five minutes while a client watches, never in the background otherwise.

## 6. Entry points, per client

| | iPhone / iPad | Mac | Linux |
| --- | --- | --- | --- |
| Shelf | Home section; iPad sidebar place *Experts* | sidebar place *Experts* | same as Mac |
| New task | shelf row; expert page; chooser's Experts section | same, plus *New task with…* in the File menu | same as Mac |
| Hand over | chat menu *Hand to an expert…* | chat menu; ⌥⌘E | same as Mac |
| Make | chat menu *Make an expert from this chat…*; shelf *New expert* | same | same |
| Debrief | the card at the end of the chat; chat menu *Finish task* | same | same |
| Notebook, bench, guards | the expert's page | the expert's page, notebook beside it | same as Mac |

## 7. Words (Core owns every one)

`ExpertReading` (shelf rows and state lines), `NotebookReading` (notes, confirmed and stale, retired), `DebriefReading` (the card's headline and its rows), `BenchReading` (through `SetupReading`'s vocabulary), `GuardWords`, and `ExpertBoard` (every machine's experts merged and sorted). One `AppCapability`, `experts`, answered by every client manifest.

## 8. Mocks, and what looking at them changed

`experts.png` / `experts-light.png` (the shelf, an expert's page, a new task, the debrief), `experts-more.png` / `experts-more-light.png` (the notebook, guards, making an expert from a chat, the chooser handing a chat over) and `experts-ipad.png` / `experts-ipad-light.png` (the iPad Pro held sideways, with both thumbs' reach drawn). `render.sh page.html…` redraws both themes at 2×.

- The debrief first gave every row a filled *Keep* beside a filled *Keep all*, so the card looked as if everything had been kept before anything was pressed, and *Keep* on a retirement could mean keeping the note. Each row now names its own action (*Add*, *Change*, *Retire*) beside *Skip*, as plain buttons; the one filled control is *Accept all*, with *Later* beside it.
- The iPad page's head repeated *Working on "Unrager posts"*, beside the sidebar's *working* and the journal's live first row. It is gone from the head: the journal is where the running task lives.
- On the iPad, *New task* at the top of the page sat outside both thumbs' reach. It became the composer along the foot, and the experts moved to the sidebar's foot, so starting a task never means letting go of the iPad.
- Drafting an expert from this session's own chat turned up "port 8795 is taken by another agent" as a note: true that afternoon, false the next day. The draft offers such notes unticked rather than adding them.

## 9. Not in this

- **Drills**: frozen tasks with a verify command, run on a fixed commit in a scratch worktree, to show whether a change to the charter or the notebook made the expert better or worse. They are the delegate packet's shape, and they cost real turns, so they are never automatic. This is the second version.
- Experts on opencode or on ACP agents (the first version is Claude Code on claude-bridge, the one that takes an appended brief).
- An expert shared across machines (an expert lives on one machine; another machine gets a copy).
- Experts handing work to each other, or starting work on their own: a watch reports, and a person starts tasks.

## 10. Implement

1. claude-bridge: `ExpertStore`, `ExpertBrief`, the launch and `serves`, `/experts*`, the debrief on a fork, notebook writes (new and adopted), bench provers, the guard runner in `Scheduler`, tests (a fixture expert, the brief's budget, the debrief's parse and its retry, writes into an adopted folder).
2. CodingAgentKit: wire types and backend calls, `AgentSession.expert`, a tag.
3. TailscodeCore: the `experts` capability, the readings, `ExpertBoard`, the debrief model, tests.
4. iOS, Mac, Linux: §6, parity answers, selftests.
5. The first expert, made from this session: *iPadOS* on the macbook, adopting the `ipados` skill and `~/claudememory/tailscode`, its bench (iPad Pro M1, iPad mini, iPhone XS, iPhone Air) and its guards (Unrager's `PadLayoutTests`, Tailscode's `WorkspaceColumns` and `HandReach` tests, Flaccy's `AdaptiveLayoutTests`).

Sources: anthropic.com/research/effective-context-engineering-for-ai-agents (2025-09-29); anthropic.com/engineering/effective-harnesses-for-long-running-agents (2025-11-26); anthropic.com/engineering/demystifying-evals-for-ai-agents (2026-01-09); claude.com/blog/improving-skill-creator-test-measure-and-refine-agent-skills (2026-03-03); arxiv.org/html/2602.12670v4 (SkillsBench); arxiv.org/pdf/2603.15401 (SWE-Skills-Bench); arxiv.org/abs/2609.33013; arxiv.org/pdf/2610.05732; code.claude.com/docs (memory, skills, subagents); docs.devin.ai (knowledge, playbooks); docs.github.com (custom agents); developers.openai.com/codex (AGENTS.md, skills); docs.letta.com (memory blocks, sleep-time agents).
