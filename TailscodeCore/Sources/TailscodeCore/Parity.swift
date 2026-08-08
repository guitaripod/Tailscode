import Foundation

/// The three clients that must agree. The raw value is the directory the client's own code lives
/// in, because an anchor only counts as evidence when it is found inside the client that claims
/// it — shared code existing in the Kit proves nothing about who wired it.
public enum ParityClient: String, CaseIterable, Sendable {
    case iOS = "Tailscode"
    case linux = "TailscodeLinux/Sources/TailscodeLinux"
    case mac = "TailscodeMac"
}

/// Every user-facing capability the product has, in one enum. This is the parity system's forcing
/// function: each client answers every case in its own `Parity.swift` with an exhaustive switch,
/// so adding a capability here refuses to compile any client that has not decided what it does
/// about it. A feature that never becomes a case here is a feature the other clients will lose.
public enum AppCapability: String, CaseIterable, Sendable {
    case sessionSections
    case sessionRowStatus
    case activityIconography
    case sessionPinning
    case unreadTracking
    case savedChats
    case archivedChats
    case deleteSession
    case bulkSelection
    case renameSession
    case forkSession
    case listFilter
    case transcriptSearch
    case autoOpenLastSession
    case liveListUpdates
    case rowContextActions
    case rowSnippet
    case rowFacets
    case usageGauges
    case quotaExhaustion
    case markdownRendering
    case syntaxHighlighting
    case streamingGrowth
    case streamCascade
    case toolRows
    case toolDiffs
    case compactActivity
    case imageParts
    case imageViewer
    case subagentCards
    case workflowCard
    case questionCells
    case compactionSeam
    case permissionCards
    case failureSurface
    case authBanner
    case followBottom
    case transcriptFind
    case userEcho
    case vimComposer
    case slashCompletion
    case slashDispatch
    case commandCatalog
    case attachments
    case drafts
    case sendQueue
    case modelEffortPicker
    case unifiedModelChooser
    case modelEffortDisplay
    case ultracodeAura
    case stopTurn
    case statusBand
    case usagePanel
    case usageAnalytics
    case sessionSpend
    case toasts
    case serverManagement
    case tailnetDiscovery
    case connectDiagnosis
    case serverSignIn
    case serverSelfUpdate
    case newChat
    case newChatFailure
    case keyboardShortcuts
    case shortcutCheatsheet
    case fileBrowser
    case gitState
    case terminalPane
    case splitPanes
    case newPaneChooser
    case chatDragToPane
    case clickToActivate
    case uiScale
    case themePicker
    case settingsSurface
    case goalControl
    case firstRunSetup
    case demoMode
    case activityNotifications
    case missedActivity
    case videoSlot
    case watchDirectory
    case watchAccounts
    case browserSlot
    case hapticFeedback
    case homeQuickActions
    case presenceOrb
}

/// What one client says about one capability. `implemented` names the wiring point — the type or
/// function in that client's own tree a reader should open first; `scripts/parity.sh` greps for
/// it, so a stale anchor is a build-gate failure, not a quiet lie. `partial` is wired but owes
/// named work; `gap` is work the client owes whole; `notApplicable` is a considered decision that
/// the platform makes the capability meaningless there — never a euphemism for "later".
public enum ParityEvidence: Sendable {
    case implemented(String)
    case partial(String, missing: String)
    case gap(String)
    case notApplicable(String)
}

/// What a capability means, stated toolkit-free so an agent porting it reads semantics, not one
/// platform's widget choices. The spec is the contract a port is judged against.
public struct CapabilityDefinition: Sendable {
    public let id: AppCapability
    public let area: String
    public let title: String
    public let spec: String

    public init(id: AppCapability, area: String, title: String, spec: String) {
        self.id = id
        self.area = area
        self.title = title
        self.spec = spec
    }
}

/// The single table behind the parity system, in the same spirit as `ShortcutRegistry`: one
/// declarative list, everything else derived. `scripts/parity.sh` prints the matrix from it,
/// the `/parity` skill works through it, and a capability missing from it does not exist.
public enum CapabilityRegistry {
    public static let all: [CapabilityDefinition] = [
        CapabilityDefinition(
            id: .sessionSections, area: "chat list", title: "Sessions grouped into sections",
            spec:
                "The list groups rows into PINNED / LIVE NOW / SAVED / RECENT via groupIntoSections, dropping empty sections so no heading ever sits over nothing. A conversation with a turn in flight — running, or stopped to ask something — leads the list in LIVE NOW rather than being findable only by sorting on recency; membership is decided on the (profile, session) pair, never a bare session id."),
        CapabilityDefinition(
            id: .sessionRowStatus, area: "chat list", title: "Row state pill and glyph",
            spec:
                "Every row states what it is doing via SessionRowState: live, needs-you, offline, failed each get a pill/glyph; silence is reserved for idle. The state is resolved once in SessionRowModel from the listing and from what this device is watching first-hand (SessionPresence) — a turn running here is live before the server's next sweep agrees, and a turn that stopped for an approval says so instead of reading as merely busy."),
        CapabilityDefinition(
            id: .activityIconography, area: "chat list", title: "A busy session looks busy",
            spec:
                "Every state that is not idle has one identity across all three clients, authored once in ActivityKind: a symbol (Apple) and a one-column glyph (text), a tone drawn from four meanings — live, attention, danger, quiet — a word, a sentence for a screen reader, and a motion. The motion is part of the meaning and comes from the shared clock maths in ActivityMotion/ActivityPulse: work breathes on one slow swell, a turn stopped for the person knocks twice and rests, something being turned over sweeps, and anything settled — failed, offline, queued, idle — holds perfectly still, because stillness is how a reader tells a stopped turn from a slow one. Everything animates off the display's own clock (CADisplayLink / gtk tick callback) read as absolute time, never a counter, so every badge on screen swells in unison and one that appears mid-turn arrives in time. A frame may change light, and a sweep's one glyph; it may never change a size layout depends on. Reduced motion drops the movement and nothing else — glyph, word and colour still carry the state. Surfaces that must wear it: the chat list row (which knows only that a turn is open, so it says exactly that), and the chat's own status surface, which reads the turn down to what it is doing — the tool that is out on the machine, with that tool's own symbol, whether the answer has started arriving, a fan-out counted as agents rather than named as a call."),
        CapabilityDefinition(
            id: .sessionPinning, area: "chat list", title: "Pinned chats lead the list",
            spec:
                "A chat pins to the top of the list on this device (SessionPinStore, ordered). Pinned rows lead in a PINNED section ahead of every other section, keep their state pill, and pin order is the order the pins were made; unpinning returns the row to recency order. A row action pins and unpins. Device-local by design, like the archive."),
        CapabilityDefinition(
            id: .unreadTracking, area: "chat list", title: "Unread markers",
            spec:
                "Background activity marks a session unread (SessionSeenStore); opening it clears the mark; a row action toggles read/unread by hand."),
        CapabilityDefinition(
            id: .savedChats, area: "chat list", title: "Saved chats with full snapshot",
            spec:
                "Bookmarks are device-local (SavedChatStore) and carry their own copy of everything needed to list and explain themselves when the server is unreachable or the session deleted."),
        CapabilityDefinition(
            id: .archivedChats, area: "chat list", title: "Device-local archive",
            spec:
                "Archiving hides a session from the main list without touching the server (ArchivedChatStore); an archived view lists, restores, and explains them."),
        CapabilityDefinition(
            id: .deleteSession, area: "chat list", title: "Delete with optimistic removal",
            spec:
                "Deleting removes the row immediately and tells the server after; a failure resurfaces the row honestly rather than pretending."),
        CapabilityDefinition(
            id: .renameSession, area: "chat list", title: "Rename a session",
            spec: "A row action renames the session on the server and updates the row in place."),
        CapabilityDefinition(
            id: .forkSession, area: "chat list", title: "Fork a session",
            spec: "A row action forks the conversation server-side and opens or reveals the copy."),
        CapabilityDefinition(
            id: .listFilter, area: "chat list", title: "Filter the list by text",
            spec: "Typing filters rows by title/project/server without losing section structure."),
        CapabilityDefinition(
            id: .transcriptSearch, area: "chat list", title: "Search inside every conversation",
            spec:
                "The filter matches titles; this searches what was actually said. Submitting the query runs TranscriptSearch.run across every connected server at once — the bridge reads the CLI's own transcripts on its own machine (GET /search), so prose, the model's reasoning, the command a tool ran and what it answered are all findable, and a conversation's subagents are searched as part of it rather than as chats of their own — and the answers merge into one ranked list rather than a pile per server: a title that says the words first, then a conversation with the words in it, then recency. Each row names the chat, its project and server, and quotes the places it matched with the register each was in (answer/you/thinking/output/tool name), and says how many more places matched. Coverage is stated, never implied: a backend that cannot search inside is matched on the titles this device holds and labelled as such, a server that stopped early or never answered is named in TranscriptSearch.caveat, and an empty result therefore means nothing was found rather than nothing was looked at. Opening a result opens that conversation on its own server; leaving the results returns the list exactly as it was."),
        CapabilityDefinition(
            id: .autoOpenLastSession, area: "chat list", title: "Reopen the last chat on launch",
            spec: "Launch restores the previously open conversation instead of an empty pane."),
        CapabilityDefinition(
            id: .liveListUpdates, area: "chat list", title: "List streams while visible",
            spec:
                "The listing refreshes from SessionListStreaming pushes while the list is on screen; no manual refresh is the only path."),
        CapabilityDefinition(
            id: .rowContextActions, area: "chat list", title: "Per-row action menu",
            spec:
                "Long-press/right-click on a row offers save, archive, rename, fork, delete, read/unread — the same verbs on every platform."),
        CapabilityDefinition(
            id: .rowSnippet, area: "chat list", title: "A busy row names the work",
            spec:
                "While a session is working, the row's second line carries agentTask (the task in flight) in place of the meta line, so the list says what the agent is doing rather than only that it is live; idle rows keep their meta. Filtering matches the snippet too."),
        CapabilityDefinition(
            id: .rowFacets, area: "chat list", title: "The row's second line is read, not parsed",
            spec:
                "A row's second line is three facts at three weights rather than four at one: the project it is in leads, the machine and agent follow a step quieter, and the age is pinned in a fixed column at the trailing edge in monospaced digits, so staleness can be compared straight down the list. What the whole listing already says is not repeated on every row — ChatListVocabulary, computed once from the full listing, drops the server name when one machine answered and the agent name when one backend did, and a row left with nothing to say falls back to naming its server. Every client reads SessionRowModel.facets(_:) and decides only how the two weights look."),
        CapabilityDefinition(
            id: .usageGauges, area: "chat list", title: "Usage quota gauges",
            spec:
                "Account quota (usageQuota + additionalUsageQuotas) is visible at a glance from the list surface and refreshes on a slow poll."),
        CapabilityDefinition(
            id: .quotaExhaustion, area: "sessions", title: "Used-up quota is a clear state",
            spec:
                "When a provider window is at or past full, or a turn fails because of a rate limit / quota wall: a clear surface names the provider and window, says when it resets when known, and tells the person to switch model or wait — never a raw rate-limit string alone. Live gauges at full read as \"Used up\". A one-shot notification fires the first time a window hits full. Pre-emptive notice rides the conversation chrome while the wall is up, not only after a failed send, and speaks only for the chat's own provider family — a wall on another provider stays in the gauges. Copy and classification live in QuotaSurface so every client says the same thing."),
        CapabilityDefinition(
            id: .markdownRendering, area: "transcript", title: "Markdown prose",
            spec:
                "Assistant prose renders headings, emphasis, lists, links, inline code and fenced code from the shared grammar; never raw markdown source."),
        CapabilityDefinition(
            id: .syntaxHighlighting, area: "transcript", title: "Code is coloured by what it is",
            spec:
                "A fenced block is lexed by SyntaxHighlighter — one shared, toolkit-free pass over ~60 language tags — and painted through SyntaxPalette, which derives every role from the theme's own slots on its own code background: keywords wear special, names wear info, strings wear warn, numbers wear accentDim, comments are textDim blended toward the canvas. A diff is read twice (DiffHighlight): its first column decides each line's ground — added and removed lines sit on a wash of the same accent and danger the diff's +N/−N labels wear (SyntaxPalette.diffLineBackground), with the marker glyph keeping the diff's full ink — and the language the patch's own headers name colours the code on every line, corrected against the wash it sits on; a patch that names no file keeps whole-line accent and danger, and a headed block's header wears both facts (`diff · swift`). Comments and strings are claimed before anything else, so a `//` inside a string is not a comment and a keyword inside a comment is not a keyword; an unterminated run claims the rest of the block, which is what a block still being streamed looks like. A block's header wears the canonical language name and an unknown fence tag keeps its own spelling and renders plain rather than being guessed at. Code scrolls horizontally and is never reflowed — code that rewraps is code you cannot read."),
        CapabilityDefinition(
            id: .streamingGrowth, area: "transcript", title: "Parts grow in place",
            spec:
                "A streaming part updates its existing row (reconfigure/diff), never tearing down the transcript or losing scroll position."),
        CapabilityDefinition(
            id: .streamCascade, area: "transcript", title: "The answer is written, not pasted",
            spec:
                "Streamed prose plays out of a buffer instead of appearing in whatever lumps the network delivered. LiveCascade renders the whole markdown-safe prefix once per arrival (CascadeGate holds the renderer at the last position where no inline token is half-open, so no answer ever flashes its asterisks) and then reveals through the *rendered* characters, which is what makes the speed even — punctuation the renderer ate never counts. StreamCadence plays at a rate that changes on a long time constant and may never drain the buffer faster than CadenceTuning.floorTime, so a model that pauses reads as a hand slowing rather than a frame dropping. RevealPlan reserves the rest of the word being written and lays it out invisibly, so a per-character reveal never rewraps a line — glyphs arrive in place. The last StreamCascade.span characters carry the wave: heat toward the theme's accent, a shimmer band travelling back on its own clock, and a per-glyph entry fade from StreamCascade.entryFloor. Ultracode paints the edge with the shared rainbow. Frames come from the display's own clock at up to 120Hz. New rows enter with the same easing and stagger; history, a chat switch or a burst past the tuning is adopted whole; reduced motion reveals at once; and the wave comes off by hand when it lets go of a row."),
        CapabilityDefinition(
            id: .toolRows, area: "transcript", title: "Tool call rows",
            spec:
                "Each tool call is a compact row stating tool, target and status, expandable to its payload; one row per MessagePart."),
        CapabilityDefinition(
            id: .toolDiffs, area: "transcript", title: "Edit tools render diffs",
            spec:
                "Edit/write tool calls show an added/removed line diff (ToolDiff), not raw JSON. The call's own file_path names the language (ToolDiff.language), so the lines get the same treatment as a fenced patch: the diff washes under them, the file's syntax on them."),
        CapabilityDefinition(
            id: .compactActivity, area: "transcript", title: "Agent steps collapse to a slim line",
            spec:
                "A run of thinking and tool calls collapses to a single slim line naming the run at a glance — status glyph, step count, the tools involved — instead of a full-width card, and expands in place to the same detail either way. Where the client exposes the choice, the compact collapsed form is the default."),
        CapabilityDefinition(
            id: .imageParts, area: "transcript", title: "Pictures the agent hands over",
            spec:
                "Tool results that gave the model an image become file parts docked at the tool call, fetched over /files/raw and rendered inline with a filename caption."),
        CapabilityDefinition(
            id: .imageViewer, area: "transcript", title: "Image viewer over the conversation",
            spec:
                "Tapping a picture opens a gallery over every image in the conversation — paged, zoomable to 1:1 — and any save/share hands over the server's original bytes, never a re-encode."),
        CapabilityDefinition(
            id: .subagentCards, area: "transcript", title: "Subagents inline",
            spec:
                "A subagent renders as a card docked at its spawning tool call, expanding in place; a wide fan-out collapses behind one group row; never a separate chat."),
        CapabilityDefinition(
            id: .workflowCard, area: "transcript", title: "A workflow run is one card",
            spec:
                "A Workflow call renders as the run it started, not the receipt it returned: the workflow's name and description, the phase plan its script declares, live agent rows (what each is doing, for how long), a progress reading over the fan-out in hand, elapsed, and — when the run's task reports back — the answer folded into the same card. Phase attribution is only claimed once the finished run records it; a live card shows the plan and the agents, never a guessed position between them."),
        CapabilityDefinition(
            id: .questionCells, area: "transcript", title: "Questions, not tool rows",
            spec:
                "An AskUserQuestion call docks as a question card at the end of the transcript and the answer goes out through the normal send path, never a direct backend call."),
        CapabilityDefinition(
            id: .compactionSeam, area: "transcript", title: "Compaction is a seam",
            spec:
                "A Compaction part renders as a divider stating what was traded for what, with the machine-facing summary behind a reader; /compact always passes through a preflight that warns and takes an instruction."),
        CapabilityDefinition(
            id: .permissionCards, area: "transcript", title: "Permission requests",
            spec:
                "pendingPermissions render as approval cards with the tool's ask spelled out and approve/deny (and remember, where the backend offers it)."),
        CapabilityDefinition(
            id: .failureSurface, area: "transcript", title: "Failures say so",
            spec: "lastFailure surfaces as a visible banner/row with the message, never a silent stall."),
        CapabilityDefinition(
            id: .authBanner, area: "transcript", title: "Signed-out Claude is a state",
            spec:
                "A signed-out CLI shows as a warning banner in chat that leads to the sign-in flow; never tell someone to open a terminal."),
        CapabilityDefinition(
            id: .followBottom, area: "transcript", title: "Follow the bottom deliberately",
            spec:
                "The transcript follows new content only while the reader is at the bottom; scrolled up, a jump pill appears and counts what arrived."),
        CapabilityDefinition(
            id: .transcriptFind, area: "transcript", title: "Find in conversation",
            spec: "Text search within the open conversation with match count and next/previous."),
        CapabilityDefinition(
            id: .userEcho, area: "transcript", title: "Sent words appear at once",
            spec: "A sent message renders immediately as a pending row, reconciled when the server echoes it."),
        CapabilityDefinition(
            id: .vimComposer, area: "composer", title: "Modal composer",
            spec:
                "The composer runs VimEngine: normal mode hides the caret and doubles as the app's normal key context, visual modes work, half-typed commands are protected, unbound keys fall back to vim."),
        CapabilityDefinition(
            id: .slashCompletion, area: "composer", title: "Slash command completion",
            spec:
                "Typing / offers the backend's availableCommands through the shared SlashCompletion ranking: the whole word typed out first, then a prefix, then a namespace:name segment matched on its bare half (/planner reaching project:planner), then letters found inside, then letters found in order but apart (/gm reaching git:merge) — and inside a tier, the commands this device reached for most recently (SlashRecents). Every row states what it is: the letters that matched tinted inside the name, the server's own argumentHint as a trailing chip, and the plugin or project that contributed it. The list is keyboard-navigable — arrows or tab to walk, enter or tab to accept, escape to dismiss — without taking those keys from an ordinary draft. Past the command's name the list gives way to that one command's signature and description, held on screen while the argument is written, and a word the catalog does not have says so rather than vanishing under the caret."),
        CapabilityDefinition(
            id: .slashDispatch, area: "composer", title: "A typed command runs",
            spec:
                "A slash command typed out and sent goes exactly where picking it from the list would have sent it, through the shared SlashDispatch.decide: /compact always through its preflight carrying whatever instruction was typed after it, a command the server knows through the command route with its arguments, and anything the server has never heard of out as the plain words that were written — the server is the authority on its own grammar, and an agent that resolves its own slash grammar from prompt text gets the prompt untouched."),
        CapabilityDefinition(
            id: .commandCatalog, area: "composer", title: "Browse every command",
            spec:
                "The whole catalog is browsable, not just completable: grouped by where each command came from (built in, this project, yours, plugins, skills, MCP servers) with its description, scope and argument hint, searchable over names and descriptions through the same shared ranking, and recently used first. Picking one hands it to the composer half-typed when it takes arguments, and runs it when it does not. A completion list cannot teach a name nobody has seen."),
        CapabilityDefinition(
            id: .attachments, area: "composer", title: "Attachments",
            spec:
                "Files and images attach via the shared AttachmentIntake (size-capped), show as removable chips, and ride out with send."),
        CapabilityDefinition(
            id: .drafts, area: "composer", title: "Nothing typed is ever lost",
            spec:
                "Every prompt box persists what is in it as it is typed, and hands it back on return — not only the chat composer but Home's, the /compact instruction, the goal condition and a free-typed answer to a question. The shared DraftStore keys each box by what it is writing to (DraftScope: a chat by profile and session, Home by the compose target it would start in) so a draft follows its conversation across panes, clients and restarts rather than the window it was typed in. Recording is per keystroke and the write is coalesced onto a quiet moment (DraftStore.quietSeconds), off the caller's thread and into the store's own file — a burst of typing costs one write, and the last word still lands without anyone remembering to save. Clients flush by hand where the process is about to stop being asked (resign, terminate, window or pane close), sending clears the draft immediately so a crash cannot hand a sent prompt back, and the store is bounded by recency so a device that has typed into hundreds of chats never carries a write proportional to all of them."),
        CapabilityDefinition(
            id: .sendQueue, area: "composer", title: "Send during a live turn queues",
            spec:
                "Sending while a turn runs is allowed and visibly queued (Send becomes Queue); the message goes when the turn yields."),
        CapabilityDefinition(
            id: .modelEffortPicker, area: "composer", title: "Model and effort choice",
            spec:
                "The next turn's model and reasoning effort are pickable from availableModels; the choice rides send(model:reasoningEffort:). A pick is recorded per session and as the server's last-used default (ModelPreferenceStore/EffortPreferenceStore.recordPick), and a chat opens on initialModel/initialEffort — never a hardcoded default. Claude Code's effort menu includes ultracode, which the server maps to xhigh plus standing workflow orchestration; typing the word in a prompt opts that turn in the same way."),
        CapabilityDefinition(
            id: .unifiedModelChooser, area: "composer", title: "One selector over every provider",
            spec:
                "Every model the server lists, from every provider, is chosen from one searchable surface built on the shared ModelChooser — never a flat menu of the raw catalog. The same model offered by two providers folds into one row that says so and opens onto its alternates (⌃→ / the chevron); sections are model families, not provider keys, with the provider a fact on the row beside the id, what it reads (vision/pdf/files), how many effort levels it takes, and whether it runs on the server's own machine. One query searches names, ids, providers and families through ModelChooser.search with the matched letters weighted in the row; recents float; the row already chosen is where the chooser opens. The pill's quick menu shows ModelChooser.shortlist and hands the rest to this surface, so the two are one list at two lengths."),
        CapabilityDefinition(
            id: .modelEffortDisplay, area: "composer", title: "The chip tells the truth",
            spec:
                "The model/effort chip shows what will actually answer: the explicit pick, else the model observed on the last assistant turn, else the session's own record."),
        CapabilityDefinition(
            id: .ultracodeAura, area: "composer", title: "Ultracode looks unlocked",
            spec:
                "Picking the ultracode tier, typing the word into the draft, or a turn in flight that was sent with it wraps the composer in the shared animated rainbow aura (Ultracode.auraActive over Ultracode.rainbowStops) — special powers visibly on before the prompt is sent — and the effort menu presents ultracode as a power (Ultracode.menuTitle/menuSubtitle), not another level. The rainbow travels around the edge and the glow breathes under it, both on the shared periods (Ultracode.auraTurnSeconds/auraBreathSeconds/auraBreathFloor, or Ultracode.aura(at:) where the client paints its own frames), off a clock rather than a counter so a dropped frame costs a frame and not the rhythm. Reduced motion keeps the aura lit and stops it moving: a power being on is a fact, not a flourish."),
        CapabilityDefinition(
            id: .stopTurn, area: "composer", title: "Stop the turn",
            spec: "A visible control cancels the current turn via cancelCurrentTurn."),
        CapabilityDefinition(
            id: .statusBand, area: "status", title: "Status band",
            spec:
                "A persistent strip states phase, token estimate, and clock from the shared StatusFacts — the same facts on every platform."),
        CapabilityDefinition(
            id: .sessionSpend, area: "sessions", title: "What this conversation cost",
            spec:
                "The price on the chat's own chrome is the whole conversation's, not the last turn's — a turn's cost is a curiosity, a session's is a fact you act on — and touching it opens the account behind it. The server reads the CLI's own transcript (GET /sessions/:id/spend) for per-turn tokens by tier and prices them; a backend that reports money per message is summed locally instead (SessionSpend(messages:)); a server too old for either leaves the last turn's price where it was. The money is always marked as an estimate with its provenance stated, because a subscription bills a flat fee and the figure is API-equivalent value, never a bill. The panel is the same five sections on every client: the total with turns/each/over/rate/tokens, a bar per turn against the priciest, where the money went across answer / cache written / cache read / fresh input, which model spent it, and the five most expensive turns named by the words that started them. Every number comes from SessionSpend; a client decides only how tall a bar is."),
        CapabilityDefinition(
            id: .usagePanel, area: "status", title: "Usage details",
            spec:
                "A dedicated surface breaks down quota windows beyond the glanceable gauges. It leads with the tightest window — the one that decides when the next send unlocks — as a hero gauge with its countdown, then every provider's windows as labelled bars with LIVE/CACHED provenance and plan details, and it is the road to the month in numbers."),
        CapabilityDefinition(
            id: .usageAnalytics, area: "status", title: "The month in numbers",
            spec:
                "A dedicated analytics surface aggregates the whole account: every connected Claude server reports the ledger its machine already holds (GET /analytics — every transcript priced turn by turn), and Core's UsageAnalytics merges the servers and generates every word. The sections are fixed: the window's total with its per-day rate and week-over-week trend, a bar per day with the empty days present, the week's rhythm Monday-first, the day's 24-hour clock, models, projects, tools, where the money went across the four token tiers with what caching saved, the records (busiest day, priciest conversation and turn, longest turn, streak, subagent runs, compactions), per-machine shares when more than one server answered, and two or three insights. A client decides only how tall a bar is. Money is an estimate and says so; a server too old for the route is named in the surface, never a silent hole in the numbers."),
        CapabilityDefinition(
            id: .toasts, area: "status", title: "Transient notices",
            spec: "Short-lived confirmations/errors appear as toasts that never steal focus."),
        CapabilityDefinition(
            id: .serverManagement, area: "servers", title: "Server profiles",
            spec:
                "Add, probe, edit and remove server profiles; HostAddress normalizes anything typed; a password is asked for only once a server says it wants one."),
        CapabilityDefinition(
            id: .tailnetDiscovery, area: "servers", title: "The app finds its own servers",
            spec:
                "Setting a machine up is a scan, not a form: the tailnet's own peers are asked on both agent ports through the shared TailnetScanner, and everything that answers is offered as a row that adds itself — the machine's name, what answers there, its version, and whether it will want a password. The wait is drawn rather than spun: TailnetRadar is the shared arithmetic of a sweep that laps at one speed on every desk, each found machine taking a fixed place on the dial from its own name so a rescan puts it back where the reader last saw it, brightest as the arm crosses it and never darker than its resting light. A machine already configured says so instead of offering itself twice, a scan that finds nothing says which peers it asked, and reduced motion draws the same dial at rest with everything on it. Where the tailnet can be read locally it costs nothing to run; where it cannot, the scan asks for the credential it needs and says why."),
        CapabilityDefinition(
            id: .connectDiagnosis, area: "servers", title: "Failed probes name their cause",
            spec:
                "A failed probe runs ConnectDiagnosis/PortReachability and offers the one fix; never a raw URLError."),
        CapabilityDefinition(
            id: .serverSignIn, area: "servers", title: "Split browser sign-in",
            spec:
                "claude auth login runs on the server's pseudo-terminal; this machine opens the URL and returns the code."),
        CapabilityDefinition(
            id: .serverSelfUpdate, area: "servers", title: "The app updates the server",
            spec:
                "The server screen reads /update through BridgeUpdater, offers the commits it would bring, and follows the restart; a refused connection mid-update is the restart, not a failure."),
        CapabilityDefinition(
            id: .newChat, area: "servers", title: "New conversation",
            spec:
                "Starting a chat picks server and working directory in one modal built on NewChatChooser: the folders this device already knows for that server — starred, recent, and the ones its own chats work in — ranked against what is being typed by FuzzyRank, each row saying where it came from, with the typed path always offered as a row of its own so a folder nobody has used yet needs no special gesture. The server last used is pre-chosen, not re-asked. Keyboard-first in two modes: while typing, ⌃n/⌃p walk, tab completes, ⌃s switches server and esc reaches the verbs; in normal mode j/k walk, g/G jump, 1–9 pick outright, i types, f stars, enter starts and esc closes — the grammar written on screen, never a form with unranked buttons under a text field."),
        CapabilityDefinition(
            id: .newChatFailure, area: "servers", title: "A chat that cannot start says why",
            spec:
                "Starting a chat never fails silently and never prints a raw error. The modal stays up through the mint — it is another machine over a tailnet — showing the working badge while it waits, and on refusal it replaces its own body with the diagnosis: NewChatDiagnosis turns what this device saw plus what the machine answered when asked directly (NewChatWitness.gather, which probes the profile's address and the other agent's default port) into a title, a sentence, and one action. The commonest mistake — a profile aimed at the other agent's port, which answers, refuses, and looks like a dead server — is repaired by the app itself: the fix rewrites the profile's address and retries the same folder on the spot, so the person lands in the chat they asked for. Every other cause names its own remedy (server settings, try again) and no path — no password on this device, no such server, an unreachable host, a healthy server refusing a folder — is allowed to end in a closed sheet with nothing said. The modal also states before the choice which servers did not answer the last listing.",
        ),
        CapabilityDefinition(
            id: .bulkSelection, area: "chat list", title: "Several chats at once",
            spec:
                "The chat list can hold a selection and act on all of it: mark rows (space, or the client's own editing mode), mark every row shown or none (⌃a), then delete, archive, save or mark read in one gesture. The set is ChatSelection, keyed on the (profile, session) pair and pruned as the listing moves under it, and the words come from BulkChatCopy so every client names the count the same way. A delete confirms first, naming what goes; rows leave immediately and a partial failure reports what survived — never a silent skip, and never a set that outlives the rows it points at."),
        CapabilityDefinition(
            id: .keyboardShortcuts, area: "app", title: "The shared shortcut registry",
            spec:
                "Keys resolve through ShortcutSet from ShortcutRegistry.all with ~/.config/tailscode/keybindings.json rebinding, normal/insert/terminal contexts, sequences and conflicts reported."),
        CapabilityDefinition(
            id: .shortcutCheatsheet, area: "app", title: "Shortcut cheatsheet",
            spec: "A help overlay derives its content from the effective bindings, config path included."),
        CapabilityDefinition(
            id: .fileBrowser, area: "app", title: "The server's files",
            spec:
                "Browse the conversation directory's tree via FileBrowsingBackend.listFiles; picking a file hands its path to the composer."),
        CapabilityDefinition(
            id: .gitState, area: "app", title: "What the repository is doing",
            spec:
                "The repository a conversation is working in, read and never operated: the server answers GET /git with branch, upstream drift, stash count, an operation left half-done, every path the working tree disagrees with the index or HEAD about, and the recent commits, and GitObservingBackend carries it to the client with nil meaning 'this server cannot say' rather than an error. GitState in Core is the whole arrangement — sections in triage order (conflicts, staged, changed, untracked), one row per path with git's own status letter, a symbol, a tone from five meanings and the lines it moved; a header that states the branch, what it owes its upstream and one alert line when a merge or rebase is unfinished; and the chip a chat's chrome wears, which spells the tree out in a prompt's shorthand rather than one lump — ↑↓ for the upstream, ✖ conflicted, + staged, ~ changed, ? untracked, and nothing at all for a mark that would read as zero. A file opens its own diff, read into numbered lines by GitPatchReader so all three clients colour the same gutter, and a commit opens what it changed. No client offers to stage, commit, pull or push: a change made from a phone is a change nobody reviewed on the machine that has to live with it. A tree with no repository says so; a bridge too old for the routes makes the surface disappear rather than fail."),
        CapabilityDefinition(
            id: .terminalPane, area: "app", title: "A shell beside the conversation",
            spec:
                "Run shell commands in the conversation's working directory with history, from the same window as the chat."),
        CapabilityDefinition(
            id: .splitPanes, area: "app", title: "Tiling split panes",
            spec:
                "The conversation surface is a binary tree of live panes (SplitLayout): any pane splits right or down to any depth, and each pane is a complete conversation — its own stream, composer, vim, find, status. The ctrl+w verbs work the tree (directional focus, close, zoom, swap, equalize) and a double click on any divider evens the whole tree out without touching the keyboard, the focused pane wears a visible accent and drives the window chrome, a chat-list row can open into a new split, and the tree with its ratios and sessions persists under tailscode.layout.tree and restores on launch — a pane whose session cannot be found says so instead of collapsing the arrangement."),
        CapabilityDefinition(
            id: .newPaneChooser, area: "app", title: "The new pane asks which server",
            spec:
                "A pane with no conversation in it is a chooser, not a caption (PaneChooser): it names every configured server with its address, chat count and whether it is answering, and once one is chosen it offers a new chat there plus that server's recent chats — so a split can land on another machine without touching the chat list. One configured server skips the question; two or more pre-focus the server the pane was already on. Keyboard-first everywhere: arrows or j/k walk, enter opens, 1-9 pick outright, esc steps back to the servers, and the rows are clickable. Choosing New chat here opens the new-chat flow with that server already selected, and the chat it mints opens in the pane that asked."),
        CapabilityDefinition(
            id: .chatDragToPane, area: "app", title: "Drag a chat into a pane",
            spec:
                "A chat-list row is a drag source carrying its profile and session under a private type (PaneDragPayload), never plain text, so a chat dropped on a prompt box cannot arrive as pasted words. Every pane is a drop target: the middle of a pane means open it here, and the outer 28% of any edge means split that pane and give the arriving chat that side (PaneDropTarget/PaneDropZone) — a pane with no room to halve, under 560pt on that axis, only offers to fill. While the pointer is over a pane the arrangement it would make is drawn on top of it, in exactly the region the chat would take, captioned with the verb and the chat's title; leaving the pane or the window takes the highlight with it. The drop opens the chat, focuses the pane it landed in, and persists the tree — an edge drop puts the new pane on the side the highlight promised (SplitLayout.split placingNewFirst), and a drop carrying a chat no listing knows changes nothing."),
        CapabilityDefinition(
            id: .clickToActivate, area: "app", title: "Pressing something activates it",
            spec:
                "Where the pointer goes down is what the keyboard is working in. A press anywhere inside a pane — transcript, prompt box, status band, pill, permission card, chooser, either button — makes that pane the focused one: the accent moves, the window chrome (title, file tree, terminal, remembered session) follows, and the ctrl+w verbs work from there. It happens before the widget under the pointer acts, so a control in a background pane commands its own conversation rather than whichever pane the eye had left behind, and the press keeps its ordinary meaning — nothing is swallowed and keyboard focus lands exactly where the click put it, never grabbed on its behalf. The same rule holds for the regions beside the tree: pressing in the chat list, the file tree or the terminal makes that the keyboard's region, so Tab cycles from where the hand is. A press on a divider, on chrome outside the tree, or in the pane that is already focused changes nothing."),
        CapabilityDefinition(
            id: .uiScale, area: "app", title: "Type scale",
            spec: "Reading size is adjustable and persists under tailscode.uiScale (or the platform's own type system)."),
        CapabilityDefinition(
            id: .themePicker, area: "app", title: "Theme",
            spec: "One catalog of named themes (AppTheme.all in Core), chosen on every client and persisted under tailscode.theme, with light or dark pinned separately under tailscode.appearance because picking Gruvbox should not also decide whether it is night. Each theme carries its own two appearances and follows the system between them unless pinned; every slot is published through Palette.corrected(), which walks lightness in OKLab until the colour clears WCAG on its own canvas, so a theme that cannot be made readable fails the build (ThemeTests). The slots are meanings, not decorations — accent is motion, warn is attention, danger is failure, info is what the agent touched, special is a standing mark — and no client may spend one on a second meaning. Where the client paints every pixel (Linux GTK) the palette is the whole window. Where the OS owns the materials (iOS and macOS Liquid Glass) the palette owns the content layer only and the glass is left alone to drink from it: no bar, sidebar or glass surface takes a palette background, ink that sits on glass stays a system colour so it flips with the material, and the palette reaches the chrome through the app tint and through the canvas the chrome floats over. Those two clients also offer System — the platform's own colours, and their default — because an app whose materials Apple drew has a real answer to give when someone wants no theme at all."),
        CapabilityDefinition(
            id: .settingsSurface, area: "app", title: "Settings",
            spec: "App preferences live on one discoverable surface, persisted under the shared tailscode.* keys."),
        CapabilityDefinition(
            id: .goalControl, area: "app", title: "Goals are visible and settable",
            spec:
                "ConversationState.goal is shown when set, and the user can set/clear it from the conversation surface."),
        CapabilityDefinition(
            id: .firstRunSetup, area: "app", title: "First run is a verified checklist",
            spec:
                "Setup states each requirement and proves what it can — this machine's tailnet presence, and which agent answers the typed address via probeCandidates — before asking for anything."),
        CapabilityDefinition(
            id: .demoMode, area: "app", title: "Try it without a server",
            spec:
                "First run offers a scripted demo world (MockBackend) so the product can make its argument before any machine is set up — a real conversation surface over fake servers, clearly labeled, exitable back to setup."),
        CapabilityDefinition(
            id: .hapticFeedback, area: "app", title: "Cues you feel, at a strength you choose",
            spec:
                "Every physical cue is a named HapticCue rather than an amplitude at the call site, played from HapticRecipe's composed pattern. The cues that carry a turn — sent, progress, needs-you, finished — are the point: waiting on another machine is what the app asks of someone, and the wait is reported to the hand. Every recipe is authored to be pleasant at full strength (rounded body, soft attack, at most one reinforcing beat, low sharpness), one setting scales all of them through HapticStrength.drive, reinforcement drops out below its floor, and repeats inside minimumGap are dropped so a burst of tool calls reads as progress rather than a rattle. Hardware that cannot compose falls back to canned feedback that keeps each cue's meaning. The setting is chosen by feel: the control plays every stop it passes at the strength under the finger."),
        CapabilityDefinition(
            id: .activityNotifications, area: "app", title: "The app taps your shoulder",
            spec:
                "A turn ending or a needs-you state in an unfocused session raises a system notification that deep-links back to it."),
        CapabilityDefinition(
            id: .missedActivity, area: "app", title: "What happened while you were away",
            spec:
                "A notification is a thing that appears for seconds and is then gone whether or not anybody saw it, so every alert the client raises is also written down in ActivityInbox and listed until it is looked at: what happened, in which chat, on which server, how long ago, with the ones still blocking a turn first. Opening the chat clears its own entries — a glance at the list is not looking, or the list would empty itself as it was drawn — and an approval or question answered on the server leaves the list by the same withdrawal that takes the notification back, so it can never send someone to a chat that is waiting on nothing. The list offers to clear itself whole, and says nothing at all when there is nothing to say."),
        CapabilityDefinition(
            id: .homeQuickActions, area: "app", title: "Home screen quick actions",
            spec:
                "Long-pressing the app icon offers a jump list: New Chat focuses the composer, Saved chats opens the device-local bookmarks, Usage opens the quota panel, Add Server starts the setup screen, and a dynamic Resume item tracks the most recent session and opens it. Every action lands on the same destination as its in-app tap, and one that arrives before the main UI exists (a cold launch, or before any server is set up) is parked and delivered the moment Home appears."),
        CapabilityDefinition(
            id: .presenceOrb, area: "app", title: "A presence with a body (alpha)",
            spec:
                "The aggregate of everything this device watches, worn as one small GPU-rendered creature on the app's main surface — off by default, opt-in from settings under the shared tailscode.presenceOrb key (PresenceOrbSetting), and labeled alpha wherever it is offered. The whole behaviour is the shared simulation: PresenceSignal.aggregate distils every conversation's ActivityKind to one tone, one motion and a count, and PresenceField turns that into the frame a client rasterises with a shader and adds nothing to — a breathing core, one satellite per open turn emerging onto its own slow orbit, colour from the palette's own tone slots (the platform's colours under System). The mapping is the meaning and it obeys the activity doctrine: work breathes on the shared swell, a turn waiting on the person knocks twice on the attention tone, a failure holds the danger colour perfectly still — a broken thing is never animated into looking busy, or cute — and idle is a dim body at rest. Ultracode rims it with the shared rainbow on the shared aura clock. Every parameter approaches its target on a short time constant, from absolute time, so a state may change in a frame but the body always arrives. When a frame reports itself settled the client stops its clock and the GPU goes quiet; reduced motion shows each state's resting arrangement and loses nothing else. Touching the orb opens the conversation that most needs the person, and a screen reader gets the whole state in words (PresenceSignal.spoken)."),
        CapabilityDefinition(
            id: .browserSlot, area: "splits", title: "Browser slot in the split grid",
            spec:
                "A pane can hold a web page. WebTarget reads an address, a bare host, a port on this machine or words to look up; the page renders inside the grid with the platform's own engine, and every split verb treats it like any other pane. The slot asks for an address when it is empty, wears the page's own title in its identity strip, and claims only the chords a browser owns (ctrl+l, ctrl+r, alt+←→, ctrl+±/0, esc) so every other key belongs to the page."),
        CapabilityDefinition(
            id: .videoSlot, area: "splits", title: "Video slot in the split grid",
            spec:
                "A pane can hold a stream instead of a chat. VideoTarget reads a channel, a link or words; the slot plays it inside the grid, and every split verb treats it like any other pane — it splits, the dividers resize it, zoom hides its siblings, closing it hands the space back, and the layout snapshot restores what it was watching. An empty slot asks what to watch, a playing one states the stream's own title in its identity strip, and VideoCommand answers space/m/e/arrows without taking keys from the chat panes. What it costs the grid is stated rather than discovered: VideoNotice's line rides the chooser row that offers a stream and the empty slot's own body, and a playing slot keeps the short of it at the end of its identity strip until it is paused."),
        CapabilityDefinition(
            id: .watchAccounts, area: "splits", title: "Signing in to Twitch and YouTube",
            spec:
                "Signing in is what lets the board list the channels somebody already follows, and it is never a condition of the board working. Both sites are entered through the OAuth device flow (WatchSignIn, toolkit-free): the app asks the site for a short code, the person confirms it in their own browser, and no password is ever typed into this app — the tokens land in whatever the platform gave the app for secrets (Keychain on Apple, the 0600 file store on Linux) as one blob per site, and the display name lands in ordinary settings so a row can draw itself without unlocking anything. Twitch needs no registered application because its own web client's device flow accepts the same client id the signed-out directory already reads with; YouTube will only answer a registered app, so a build given none says exactly what is missing and how to supply it rather than offering a button that fails. Signed in, Twitch answers every followed channel's live state in one request and YouTube answers who is subscribed while the free path still answers which of them are live — quota is never spent on a question the signed-out board already answers. A settings section (WatchAccounts.rows) states each site as a fact first: the account when there is one, what signing in would add when there is not. An account that expires past refreshing signs itself out and says so; the board keeps working on the signed-out paths."),
        CapabilityDefinition(
            id: .watchDirectory, area: "splits", title: "What's on, before anything is chosen",
            spec:
                "An empty video slot is a board of what is actually on, not a text box. WatchChooser holds it toolkit-free: the channels this device follows (WatchStore, device-local, listing itself with names and sources even when no source answers), what is live among them with audience and uptime, what is popular now, and the categories to browse — each section compact by default and expanding in place behind one row that says how many it is holding. Typing turns the board into an answer for those words: what they would open leads, and what the sources found live for them follows, while VideoTarget.classify keeps a typed channel behaving exactly as it always did. Both sources are read without an account (Twitch's public GraphQL, YouTube's own web JSON, yt-dlp for a single channel's live state), and an account only ever adds to that, every fetch is the client's to schedule, and a source that cannot answer says which one failed as a row rather than leaving a silent gap. The keys are the ones a text field cannot want — arrows, enter, tab to expand, ctrl+f to follow, esc to step back — because the same box is being typed into. The pane chooser's watch row reports the same fact in one line: WatchSummary names who is live instead of naming the two sites."),
    ]

    public static func definition(for id: AppCapability) -> CapabilityDefinition {
        all.first { $0.id == id }!
    }

    /// The registry and the enum must be the same set — a case without a spec is a capability
    /// nobody can port. Selftests assert this so the mistake cannot outlive a build.
    public static var missingDefinitions: [AppCapability] {
        let specified = Set(all.map(\.id))
        return AppCapability.allCases.filter { !specified.contains($0) }
    }
}
