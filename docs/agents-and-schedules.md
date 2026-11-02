# Any agent, any hour

Asked for: support connections like Hermes's (any agent that speaks ACP, the Agent Client Protocol) and move "ask later" off the desktop so the machine keeps the clock; research how everyone else onboards and runs these, design something better, give every client an entry point, and put it in the marketing and on the landing page. Same order as the other design docs: **look** (§1), **think** (§2), **design** (§3–§7, mocks in `docs/agents-and-schedules-mocks/`), **implement** (§9).

## 1. What I looked at

**Other products, onboarding and daily use** (sources at the end).

| Product | Getting an agent in | Daily use | The good idea | The pain |
| --- | --- | --- | --- | --- |
| Zed | 3 steps: open the ACP registry, install, pick it from the new-thread menu | each agent is a thread type | one searchable registry, threads imported from the agent | every agent brings its own model picker and its own sign-in; a remote project needs credentials per agent |
| JetBrains | "Install from ACP Registry…" in the agent picker | same | registry in the picker | per-IDE install |
| CodeCompanion, Vibe Kanban | install and sign the agent in on the host first | an adapter per agent | worktree per attempt | nothing works until the host is ready by hand |
| Happy, Omnara | run a wrapper instead of `claude`, scan its QR | phone mirrors one CLI | push for approvals | one wrapper per agent; the QR is unreadable in some terminals |
| Codex in ChatGPT, Claude Remote Control | QR from the desktop app, same account | machine as a device card | device cards | the account is the trust, the process must stay alive |
| Hermes | `hermes setup` wizard: provider, model, platforms; DM pairing codes for chat apps | Telegram/Discord/… or `hermes acp` in an editor | `hermes doctor`; one gateway runs cron | a terminal wizard before anything works; an editor only sees it after the wizard |

| Product | Making a schedule | Living with it | The good idea | The pain |
| --- | --- | --- | --- | --- |
| Claude Desktop tasks | a form, or ask in chat | app open and machine awake; one catch-up within 7 days | skipped runs listed with the reason | a 9:00 task may run at 23:00; needs the app open |
| Claude cloud `/schedule` | natural language, **absolute time confirmed** before saving | succeeded/failed/cancelled | "why did my nightly run do nothing" explains the history | an hour minimum; cloud, not your machine |
| ChatGPT Tasks, Gemini, Perplexity | ask in chat, confirm an editable summary | a Scheduled page; pause, edit, delete | results land as a thread plus a push | caps (3–15) that appear only when you hit them |
| Manus | from inside the task | calendar of runs | **a run can continue the same context** | — |
| Devin, Cursor, Codex automations | "Schedule" beside the input, presets or cron | inbox of runs | each run is a real session | a worktree per run piles up |
| Hermes cron | "every monday 9am", `in 30m`, cron | delivered to a chat app | **`[SILENT]`: a run with nothing to say delivers nothing, failures always do**; one catch-up after downtime, "missed ×N" | the gateway process has to be running |

**Tailscode today.** A machine is added once (QR or link, tailnet trust) and its bridge is the only thing installed on it. The model pill already spans every machine: models are grouped by house, a pick on another machine carries the conversation (`CarryPlan`), the party holds six model-and-level slots. "Later" exists only on the desktops (`QuickAskLater`): five phrases, kept in a JSON file on the computer that was told and asked by it while Tailscode runs; the phone does not offer it, because it is not running at the hour.

**Measured on arch, 2026-11-02.** `uvx --from 'hermes-agent[acp]' hermes acp` answers `initialize` in ~10 s with `loadSession`, `sessionCapabilities {fork, list, resume}`, image prompts and one auth method of type `terminal` (`--setup`, a curses wizard). Unconfigured, `session/new` fails with "No LLM provider configured". With three `hermes config set` lines pointing `model.provider custom` at llama-swap (`127.0.0.1:8081/v1`), `session/new` returns every llama-swap model as `models.availableModels` (`custom:<id>`), a slash-command list and `usage_update {used, size}`, and a prompt streams `agent_thought_chunk`, a `tool_call` (`kind: execute`, "terminal: uname -s") with its `tool_call_update`, then `agent_message_chunk`s and `stopReason: end_turn` — a real turn on the local Bolt. The ACP registry (`cdn.agentclientprotocol.com/registry/v1/latest/registry.json`) lists 44 agents (Gemini CLI, Codex, GitHub Copilot, goose, Kimi, Qwen Code, Cursor, Junie, Kiro, Mistral Vibe, Factory Droid…) as `npx`, `uvx` or per-platform `binary` archives with a sha256; Hermes is not in it. arch has `node`, `npx`, `uv`, `uvx` and `opencode acp`; the macbook has the same.

## 2. What everyone gets wrong, and the principles

Ranked by what it costs a person:

1. **The host has to be ready by hand before the client is any use** — install the agent, run its wizard, sign it in, in a terminal, per agent, per machine. Every product above except the cloud ones.
2. **Every agent brings its own model picker and its own vocabulary**, so the second agent is a second app.
3. **"Connected" is claimed before a prompt has ever worked.** A binary on PATH is not an agent that answers.
4. **Schedules live where the app is open**, so they run late, run twice or not at all, and the phone cannot make one.
5. **Schedules talk when they have nothing to say**, so the notification is learned to be ignored; and a run that stalls on an approval nobody sees is a silent failure.
6. **History hides the misses.** A run the machine slept through is just absent.

Principles:

- **A machine you already have grows agents.** The bridge is the only thing a machine ever gets; it hosts any ACP agent itself. No second install, no second pairing, no second port.
- **An agent is a family in the model pill**, not a new place. Party, presets, carry and the dial work across agents unchanged.
- **Ready means it answered.** The machine proves an agent by opening a real session in it; every state short of that is a checklist row the machine can prove, with the one press that fixes it.
- **The machine keeps the clock.** A schedule lives on the bridge, runs with every client closed, and is made from any client, the phone first.
- **Quiet unless there is news; failures always speak; misses are said.**
- **Words on the device, facts on the wire** (as everywhere): the bridge sends states and numbers, Core writes every sentence.

## 3. Agents

### 3.1 What the person sees

- **On the machine's screen** (iPhone: server detail; Mac and Linux: the server sheet), a new **Agents** section. Claude Code is the first row, *built in*. Then every agent the bridge knows, each one line: its mark, its name, and a state in words — *Ready · thinks with Bolt on this machine*, *Needs a brain*, *Needs a key*, *Needs sign-in*, *Found on arch · Add*, *Installing…*, *Needs Node.js on arch*. A row opens the agent's card. The foot of the section is **More agents…**, the official ACP registry as a list, each row *Install on arch*.
- **The agent's card** is a checklist the machine proves, in this order: *On arch* (found or installed, its version), *A brain* (only for an agent that needs one), *Signed in* (only for one that asks), *Answered* (a real session opened, with the models it offered). Each row that is not yet true carries its one press. The last row turning green is the moment the agent is in the pill; the card says so and offers *Start a chat with Hermes*.
- **Give it a brain.** An agent with no model of its own (Hermes's "No LLM provider configured") is offered the brains the machine already has, first: every OpenAI-compatible server the bridge finds on the machine (llama-swap, ollama, LM Studio, vLLM — asked on their usual ports) with its models, then the keys it could take (OpenRouter, Anthropic, OpenAI). A local model is one tap — *Think with Bolt on this GPU*; a key is pasted once and stays on the machine (mode 0600), never on the device. The bridge writes the agent's own config the way its own wizard would (`hermes config set model.provider custom …`).
- **A key** (Gemini CLI's `GEMINI_API_KEY`, Kimi's, Qwen's): one field, a link to where the key is made, kept on the machine and handed to the agent as an environment variable when it starts.
- **Sign in across two screens.** An agent whose sign-in is a terminal command (ACP `authMethods` of type `terminal`, or a recipe's login command) is run by the bridge on a pseudo-terminal; the card shows its last lines, any link becomes a button that opens on this device, any code is copyable, and a field answers what it asks. Exit 0 is signed in, and the machine proves it by opening a session. This is the Claude sign-in the app already has, made general.
- **The pill.** A ready agent is a section of the model chooser on every client, titled with the agent's name and its machine (*Hermes · arch*), listing the models it offered, at the levels it offered (`thought_level`). Picking one starts a conversation with that agent; the pill wears the agent's name before the model (*Hermes · Bolt*). The party takes agents like models — six slots can be Claude Code, Hermes and Codex side by side. A pick of a different agent from inside a conversation carries the conversation, exactly as a pick on another machine does, because an agent cannot take over another agent's session.
- **Found, not forced.** An agent found on the machine is listed, not started: the bridge runs other programs only after somebody added them. Home says it once, the first time a machine reports agents nobody has looked at: *arch has Gemini CLI and goose — add them to the model pill?* with *Add* (both) and *Not now*.
- **Never stalls on an approval.** A permission request from an agent is answered by the bridge with its allow option, as claude-bridge runs Claude with full permissions, so a phone in a pocket never holds a turn hostage. The card says so in one line.

### 3.2 On the wire (claude-bridge)

- `/status` gains `agents: 1`.
- `GET /agents` → `{"agents": [Agent], "brains": [Brain]}`. `Agent`: `id`, `name`, `version?`, `description?`, `icon?` (url), `source` (`builtin` · `found` · `registry` · `custom`), `added` (bool), `state` (`ready` · `checking` · `installing` · `notAdded` · `needsBrain` · `needsKey` · `needsSignIn` · `missingRuntime` · `failed`), `runtime?` (`node` · `uv` for `missingRuntime`), `failure?` (the agent's own error text, shown as a fact), `models` (`[{id, name, description?}]`), `efforts?`, `keys` (`[{env, name, url?, set}]`), `signIn` (`[{id, name, description?, kind}]`), `brain?` (`{kind: local|key, name, model?}`), `checkedAt?`. `Brain`: `id`, `name` (`llama-swap`, `ollama`, …), `baseURL`, `models [{id, name}]`.
- `GET /agents/registry` → the registry's agents with `installable` per this machine's platform and runtimes.
- `POST /agents/:id/add`, `POST /agents/:id/remove`, `POST /agents/:id/check` (run the proof again), `POST /agents/install {"id"}` (from the registry: `binary` downloads to `~/.claude-bridge/agents/<id>/` and checks the sha256; `npx`/`uvx` warm the cache), `POST /agents/:id/brain {"kind":"local","brain":"llama-swap","model":"…"}` or `{"kind":"key","provider":"openrouter","key":"…","model":"…"}`, `POST /agents/:id/key {"env","value"}`, `POST /agents/:id/signin {"method"}`, `GET /agents/:id/signin` → `{state, lines, links, codes, needsInput, exitCode?}`, `POST /agents/:id/signin/input {"text"}`, `POST /agents/:id/signin/cancel`.
- `GET /models` → Claude's models plus each ready agent's, as `{id, name, provider, providerName, agent: true, variants?, contextWindow?}`; an agent's model is `provider = <agent id>`, so the wire's model string is `hermes/custom:bolt` and the existing `provider/model` split reads it.
- A session is bound to an agent by the first turn that names an agent model (`model` with an agent id before the first slash) and keeps it: `SessionSummary.agent {id, name}`. A turn on a bound session naming another agent or a Claude model answers 409 with the sentence; the clients never send one, because the chooser carries instead.
- An agent session's transcript is the bridge's own store (there is no CLI transcript to read). Fork, compact, goal, subagents and spend answer 409/404 with a sentence for an agent session; rename, delete, marks, queue, abort, search, wait and the stream work as for Claude.

### 3.3 Inside the bridge

- `AgentCatalog`: built-in recipes (Hermes via `uvx`; detection of `gemini`, `goose`, `kimi`, `qwen`, `copilot`, `opencode`, `codex-acp`… on PATH, mapped to their registry ids so a found copy is the person's own already-signed-in one), the registry (fetched daily, cached), `~/.claude-bridge/agents.json` for custom commands. `claude-acp` is not offered: Claude Code is native here.
- `AcpConnection` (actor): one agent process per conversation, JSON-RPC 2.0 over stdio, request correlation, `initialize` with no `fs`/`terminal` client capabilities (the agent uses its own tools), `session/new` · `session/resume` (else `session/load` with the replay swallowed) · `session/prompt` · `session/cancel` · `session/set_config_option` / `session/set_model`, and the agent's requests answered: `session/request_permission` → its allow option (`allow_once`, else `allow_always`), anything else → method-not-found. Reaped when idle like Claude's processes, re-attached by `resume`/`load` on the next turn; an agent that can do neither gets a fresh session and a brief of the stored conversation (the `CarryMark` brief, built on the bridge).
- `AcpTranslator`: ACP `session/update`s become the Claude stream-json objects the bridge's `Assembler` already folds, so the turn machinery — journal, queue, live mirror, wait, Live Activity, push, titles — is the one Claude turns use. `agent_message_chunk` → text deltas; `agent_thought_chunk` → thinking; `tool_call` → a tool block named for its kind (`execute` → Bash with `command`, `read` → Read with `file_path`, `edit` → Edit with the diff, `search` → Grep, `fetch` → WebFetch, else the title) so `ToolCallSummary` draws it like any other; `tool_call_update` completed/failed → its result; `plan` → a `TodoWrite` call, so the plan is the task board card that already exists; `session_info_update` → the title unless the person named it; `usage_update` → the context fill; the prompt's `stopReason` → the turn's `result` (`refusal` is a failure in words).
- The proof (`AgentProbe`): spawn, `initialize`, `session/new` in `~/.claude-bridge/agents/probe`, read its models and levels, close. Its failure text is classified into `needsBrain` / `needsKey` / `needsSignIn` (`auth_required`, "No LLM provider configured", "API key"), else `failed` with the text. Run on add, on `check`, after a brain, key or sign-in, and once a day for added agents; never at every start.

## 4. Schedules

### 4.1 What the person sees

- **Ask later, from any composer.** On the phone a long press on Send (and *Ask later…* in the composer's menu) opens one sheet; on the desktops ⌥⏎ / *Ask later…* in the composer menu, and the quick ask's Later lane, open the same content. Five chips said the way people say them — *In an hour*, *Tonight 21:00*, *Tomorrow 08:00*, *Every morning 08:00*, *Every Monday 08:00* — and a field, *Or say when…*, that reads *weekdays 7:30*, *every 2 hours*, *fri 17:00*, *in 20 min*, *every morning at 6*. Under the field, always, what was understood as a date: **Next: Tue 4 Nov 07:30 · then every weekday · asked by arch** — the absolute time is confirmed before anything is saved, and an unreadable phrase says so rather than guessing.
- **One conversation that remembers** (on by default for repeats): every run goes into the same chat, so the agent sees what it said yesterday and can say what changed. Off, each run is a new chat.
- **Quiet when nothing changed** (on by default for repeats): the run is told, out of the transcript, to answer *nothing new* if nothing changed since its last answer; such a run is drawn as one muted line, is not unread anywhere and pushes nothing. A failure always speaks.
- **From anything you asked.** Your own message in any chat has *Ask this again…* in its menu: the same sheet, prefilled with those words, that chat's machine and model, and *One conversation* pointing at that chat.
- **Any agent, any model.** A schedule carries the model and level it was made with — Opus, Qwen on the GPU, Hermes · Bolt.
- **Coming up on Home.** When anything is scheduled, Home's status line gains *Next: "AI news" 07:00 on arch*; it opens **Scheduled**: every machine's schedules, soonest first, each row its words, when it asks next, the machine and model, and its last outcome. The desktops have *Scheduled* in the sidebar's places beside Usage.
- **A schedule's page**: its words (editable), when (the same chips and field), the toggles, *Run now*, *Pause*, *Delete* (the conversations stay), and its history: *Answered 07:00*, *Quiet 07:00 · nothing new*, *Failed 07:00 · the machine said: …*, *Caught up 09:12 · missed 07:00 while arch was off*, *Missed ×3 · arch was off*. A row opens that run's conversation.
- **The chat list** marks a schedule's conversation with a clock beside its title.
- **The desktop's own "later"** (`QuickAskLater`) hands a question to its machine when the machine keeps schedules, and keeps it on the computer, as today and saying so, only for a machine that cannot (opencode).

### 4.2 On the wire (claude-bridge and omp-bridge, the same shape)

- `/status` gains `schedules: 1`.
- `GET /schedules` → `[Schedule]`. `Schedule`: `id`, `text`, `title`, `model?`, `effort?`, `directory?`, `rule` (`{"kind":"once","at":ISO}` · `{"kind":"daily","hour","minute"}` · `{"kind":"weekdays","hour","minute"}` · `{"kind":"weekly","weekday","hour","minute"}` (1 = Sunday) · `{"kind":"hours","every","minute"}`), `timeZone` (the maker's), `next?`, `paused`, `thread` (`continue` · `fresh`), `quiet`, `sessionID?` (the continuing chat), `createdAt`, `createdBy?` (the device's name), `runs` (newest first, at most 30: `{id, scheduledFor, startedAt?, endedAt?, sessionID?, outcome: running|answered|quiet|failed|missed|caughtUp, missed, failure?}`).
- `POST /schedules` (`text`, `model`, `effort`, `directory`, `rule`, `timeZone`, `thread`, `quiet`, `sessionID?`, `createdBy?`) → `Schedule`; `PATCH /schedules/:id` (any of `text`, `rule`, `timeZone`, `model`, `effort`, `paused`, `thread`, `quiet`); `DELETE /schedules/:id`; `POST /schedules/:id/run`.
- A change goes out on `/stream` as `schedules` so an open list refreshes.

### 4.3 Inside the bridges

- `Scheduler` (actor): `~/.claude-bridge/schedules.json` (omp: its state dir), a tick every 20 s, next times computed in the maker's time zone. A due schedule sends through the store's own `send` — so it queues behind a live turn rather than racing it — into its continuing chat (made on the first run, titled by the schedule; a deleted chat is made again) or a new one. The quiet instruction rides only in the runner's prompt, never in the stored message, like attachment paths.
- The run's end is read at the store's turn end: `answered`, `quiet` (the answer is the sentinel; the stored answer becomes "Nothing new since the last check.", the chat is marked read on the bridge's clock, no push), or `failed` with the turn's error.
- **Missed runs**: at start, a schedule whose next time passed while the bridge was down runs once if the latest missed time is within 12 hours (`caughtUp`, with `missed` = how many it slept through) and otherwise records `missed ×N` and moves on; a one-off older than that is recorded missed and finished. Never more than one catch-up.
- A schedule never runs twice at once: a run still going when the next is due records that one as missed (*still running*).
- Minimum interval one hour; at most 50 schedules per machine, said at creation, not discovered.

## 5. Entry points, per client

| | iPhone / iPad | Mac | Linux |
| --- | --- | --- | --- |
| Agents | Server detail › Agents section › card; Home nudge; chooser sections | Server sheet › Agents; Home nudge (welcome/sidebar toast); chooser | same as Mac |
| More agents | Agents › More agents… | same | same |
| Ask later | long press Send; composer menu; message menu *Ask this again…* | ⌥⏎; composer menu; message menu; quick ask Later lane | same as Mac |
| Scheduled | Home status line › Scheduled; iPad sidebar place; server detail › Scheduled | sidebar place *Scheduled*; server sheet | same as Mac |

## 6. Words (Core owns every one)

`MachineAgentReading` (rows, card steps, presses, the nudge), `AgentBrainReading`, `ScheduleSpeech` (the phrase reader, English plus the device's own weekday names and 24- or 12-hour clock), `ScheduleWords` (when, next, run outcomes, limits), `ScheduleBoard` (every machine's schedules merged and sorted, Home's line). Nothing in a client invents a sentence.

## 7. Mocks, and what looking at them changed

`agents.png` / `agents-light.png` (the machine's Agents section, Hermes's card, the pill, More agents) and `schedules.png` / `schedules-light.png` (Ask later, Home and Scheduled, a schedule's page, one conversation); `render.sh` redraws them from the HTML.

- A chip stayed selected while a phrase was typed, so the sheet showed two answers to "when". Typing now clears the chips; the understood line is the only answer.
- Scheduled rows carried when, machine, model and last outcome in one subtitle and every one truncated. The subtitle is when and machine; the last outcome is a small mark at the trailing edge; the model lives on the schedule's page.
- The conversation mock drew a dated seam above every scheduled prompt — a renderer change on three clients for something the bubbles already say. Dropped: a scheduled run is an ordinary turn, and a quiet run's answer is one plain line ("Nothing new since the last check.") that leaves the chat read.
- The permission line read as a riddle; it now says what happens: agents say yes to their own permission questions, as Claude Code does on that machine.

## 8. Not in this

Importing an agent's own past sessions (`session/list` exists on Hermes; v2), routing an agent's permission requests to the approval cards instead of allowing them, an agent's own slash commands in the completion list (typed ones are sent and work), schedules triggered by anything but time (GitHub, webhooks), delivering a run to a chat app, a cron field (the phrases cover hours, days, weekdays and weeks).

## 9. Implement

1. claude-bridge: `AgentCatalog`, `AcpConnection`, `AcpTranslator`, `AgentProbe`, `AgentSignIn`, `BrainFinder`, store binding, `/agents*`, `/models`, `Scheduler`, `/schedules*`, tests (a fixture ACP agent in Python drives the translator and the store end to end; Hermes on llama-swap verified live).
2. omp-bridge: `Scheduler` and `/schedules*` in the same shape.
3. CodingAgentKit: wire types and backend calls for agents and schedules, `/models` merge for claude-bridge, `AgentSession.agent`, tag.
4. TailscodeCore: capabilities `machineAgents`, `machineSchedules` (and `quickAskLater` updated), readings, `ScheduleSpeech`, chooser agent sections and carry across agents, tests.
5. iOS, Mac, Linux: §5, parity answers, selftests.
6. Landing page and store captions; release notes.

Sources: agentclientprotocol.com (overview, session-setup, initialization, prompt-turn, tool-calls, authentication, session-config-options, session-list, agent-plan, slash-commands, registry); zed.dev/docs/ai/external-agents; zed.dev/blog/acp-registry; blog.jetbrains.com/ai/2026/01/acp-agent-registry; github.com/agentclientprotocol/claude-agent-acp; hermes-agent.nousresearch.com (acp, cron, messaging, quickstart); code.claude.com/docs (remote-control, desktop-scheduled-tasks, routines); help.openai.com scheduled tasks; Gemini scheduled actions; Perplexity Tasks; manus.im/en/blog/manus-schedules; docs.devin.ai scheduled sessions; Cursor automations; vibekanban.com; codecompanion.olimorris.dev; github.github.io/gh-aw schedule syntax.
