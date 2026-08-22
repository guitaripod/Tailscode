import Foundation

/// The three clients that must agree. The raw value is the directory the client's own code lives
/// in, because an anchor only counts as evidence when it is found inside the client that claims
/// it — shared code existing in the Kit proves nothing about who wired it.
public enum ParityClient: String, CaseIterable, Sendable {
    case iOS = "Tailscode"
    case linux = "TailscodeLinux/Sources/TailscodeLinux"
    case mac = "TailscodeMac"

    /// The ways this client's code actually reaches somebody. A client can ship more than one, and
    /// the ways do not agree: a copy the App Store installs is sealed in a container that may not
    /// run the machine's own programs, and a copy built here is not. So a distribution is part of
    /// the question a capability is asked rather than a footnote on the answer, and a client that
    /// ships two ways owes two answers wherever they part.
    public var distributions: [ParityDistribution] {
        switch self {
        case .iOS: return [.appStore]
        case .linux: return [.direct]
        case .mac: return [.direct, .appStore]
        }
    }
}

/// How a copy of a client got onto the machine running it, which is the only thing that decides
/// what it is allowed to do. `direct` is a build somebody installed themselves — ad-hoc signed,
/// unsandboxed, holding whatever rights the person holding the machine holds. `appStore` is a copy
/// the store installed and the store replaces, inside a sandbox.
public enum ParityDistribution: String, CaseIterable, Sendable {
    case direct
    case appStore
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
    case bulkRangeSelection
    case bulkSplit
    case splitTabs
    case renameSession
    case forkSession
    case listFilter
    case transcriptSearch
    case autoOpenLastSession
    case liveListUpdates
    case rowContextActions
    case rowSnippet
    case rowFacets
    case modelIdentityTint
    case usageGauges
    case quotaExhaustion
    case quotaScoping
    case markdownRendering
    case transcriptLinks
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
    case taskBoard
    case questionCells
    case compactionSeam
    case permissionCards
    case failureSurface
    case answerlessTurn
    case interruptedTurn
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
    case modelCapabilitySurfacing
    case responseStats
    case ultracodeAura
    case stopTurn
    case statusBand
    case usagePanel
    case usageAnalytics
    case deepseekBalance
    case sessionSpend
    case toasts
    case serverManagement
    case tailnetDiscovery
    case connectDiagnosis
    case serverSignIn
    case serverSelfUpdate
    case serverAutoUpdate
    case serverRestart
    case newChat
    case newChatDefaults
    case newChatFailure
    case newChatPathCompletion
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
    case typeRamp
    case themePicker
    case settingsSurface
    case goalControl
    case firstRunSetup
    case tailscaleReadiness
    case demoMode
    case activityNotifications
    case missedActivity
    case videoSlot
    case watchDirectory
    case watchAccounts
    case browserSlot
    case hapticFeedback
    case homeQuickActions
    case usageWidgets
    case presenceOrb
    case auroraStream
    case gameCenter
    case projectBoard
    case quickAsk
    case summonAnywhere
    case updateCenter
    case designBoards
    case linkEmbeds
    case reviewPrompt
    case proUnlock
    case videoForge
    case forgeHistory
}

/// What one client says about one capability. `implemented` names the wiring point — the type or
/// function in that client's own tree a reader should open first; `scripts/parity.sh` greps for
/// it, so a stale anchor is a build-gate failure, not a quiet lie. `partial` is wired but owes
/// named work; `gap` is work the client owes whole; `notApplicable` is a considered decision that
/// the platform makes the capability meaningless there — never a euphemism for "later".
/// `varies` is the answer a client that ships two ways owes when the two ways part. It carries
/// both halves whole rather than one half with a caveat, because the store copy is not always the
/// poorer one — it is the copy the store keeps current, so the update surface owes it *less* — and
/// because a `#if` inside a case body would state only the truth of whichever copy was compiled,
/// which is exactly the half a static reader of this file could never see.
public enum ParityEvidence: Sendable {
    case implemented(String)
    case partial(String, missing: String)
    case gap(String)
    case notApplicable(String)
    indirect case varies(direct: ParityEvidence, appStore: ParityEvidence, because: String)

    /// What one copy of the client actually answers. A singular answer is every copy's answer, so
    /// it is handed back untouched.
    public func resolved(for distribution: ParityDistribution) -> ParityEvidence {
        guard case .varies(let direct, let appStore, _) = self else { return self }
        switch distribution {
        case .direct: return direct.resolved(for: distribution)
        case .appStore: return appStore.resolved(for: distribution)
        }
    }

    /// Whether this is one answer rather than two — what a reader needs before quoting it as the
    /// client's answer, and what a half of a `varies` must be so no answer nests inside another.
    public var isSingular: Bool {
        if case .varies = self { return false }
        return true
    }
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
                "The list groups rows into PINNED / LIVE NOW / SAVED / RECENT via groupIntoSections, dropping empty sections so no heading ever sits over nothing. A conversation with a turn in flight — running, or stopped to ask something — leads the list in LIVE NOW rather than being findable only by sorting on recency; membership is decided on the (profile, session) pair, never a bare session id. Inside LIVE NOW the order is when each conversation began, newest first, and never recency of activity: a working chat's updatedAt is a clock rather than an identity, so ordering on it makes two working chats trade places several times a second under a reader trying to click one. The section already says a row is working; where it sits must hold still for as long as it is there."),
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
            id: .modelIdentityTint, area: "chat list", title: "A model wears its colour",
            spec:
                "Everywhere a session's model is named — the chat list row, the composer's model chip, the effort control — the family name wears its authored hue (ModelTint, corrected in OKLab against the canvas it sits on, the same walk the palettes take) and the effort word wears its heat: cold slate for low, teal, amber, orange, vermilion for max, with ultracode outside the scale in per-letter rainbow held to the contrast floor. Both facts stay printed words — the colour is on top, never instead — and a model outside the known families keeps the quiet register rather than being issued an identity. One catalog answers every client; a family's hue may never differ between desks."),
        CapabilityDefinition(
            id: .usageGauges, area: "chat list", title: "Usage quota gauges",
            spec:
                "Account quota (usageQuota + additionalUsageQuotas) is visible at a glance from the list surface and refreshes on a slow poll. The numbers are the account's, never a machine's: every connected server's report is folded by QuotaRollup into one heading per provider — the strictest reading of each window, a provider-stated reset over a guessed one, windows only one server knows kept — ordered tightest-first, and no gauge wears a hostname. A machine is named only where it is not redundant: the details surface names the servers behind a provider's numbers when more than one answered, and says nothing about hosts when one did."),
        CapabilityDefinition(
            id: .quotaExhaustion, area: "sessions", title: "Used-up quota is a clear state",
            spec:
                "When a provider window is at or past full, or a turn fails because of a rate limit / quota wall: a clear surface names the provider and window, says when it resets when known, and tells the person to switch model or wait — never a raw rate-limit string alone. Live gauges at full read as \"Used up\". A one-shot notification fires the first time a window hits full. Pre-emptive notice rides the conversation chrome while the wall is up, not only after a failed send, and speaks only for the chat's own provider family — a wall on another provider stays in the gauges. Copy and classification live in QuotaSurface so every client says the same thing."),
        CapabilityDefinition(
            id: .quotaScoping, area: "sessions", title: "A wall speaks to the model it holds",
            spec:
                "A used-up window is worn where it applies and nowhere else. QuotaBinding reads each gauge's own label for the model it was scoped to (\"Weekly · Opus\" is Opus's; \"5-hour session\" is the account's), so the chat's standing notice speaks only when the wall is in front of the model that chat would send with — a scoped wall on a model this chat is not using is not news, and a chat whose model nobody can name hears the account-wide walls only. A wall also speaks only to the models its provider actually bills (QuotaBinding.bills): Claude's weekly holds Claude models, Grok's holds Grok's, a prepaid DeepSeek balance holds DeepSeek's, and a reseller whose caps are account-wide dollars across its whole catalog (opencode go) holds every hosted model whose *door a pick would take* is Go — a dual-door Grok row that would send through xAI OAuth does not wear Go's spent window, and a DeepSeek row under a Claude wall is the one notice nobody can act on and never appears. Nested alternates bill their own door. What the notice stops saying, the chooser says instead: every model in the picker carries the wall in front of the door a pick would take (ModelChooserRow.wall), drawn spent — dimmed, wearing what ran out and when it returns (QuotaSurface.rowNote) — sunk under the models in its family that can still answer, counted in the chooser's summary, and echoed on the composer's own shortlist so the quick menu and the full list never disagree. A spent model stays pickable: a window resets, and refusing someone the model they came for is not the app's call. The reading is Core's; a client decides only how spent looks."),
        CapabilityDefinition(
            id: .markdownRendering, area: "transcript", title: "Markdown prose",
            spec:
                "Assistant prose renders headings (a `#` only with the space the grammar demands), emphasis, lists — numbered with `.` or `)`, task items as boxes (`- [ ]`/`- [x]` → ☐/☑) — links, inline code and fenced code from the shared grammar; never raw markdown source. A pipe table is read once in Core (MarkdownTable, lifted out of prose by MessageSegment.split alongside fences) and rendered as real columns with a bold header over a hairline and each column keeping its declared alignment; the client owns only the grid widget, and a copy or export writes the pipes back (MarkdownTable.markdown). Prose never carries more than one blank line in a row — extra emptiness is the model exhaling, not paragraph structure."),
        CapabilityDefinition(
            id: .transcriptLinks, area: "transcript", title: "An address is touchable",
            spec:
                "Every address in the transcript opens, whether it was written as a markdown link or pasted bare into a sentence — Autolink finds the bare ones in Core (a scheme or a `www.` host, a dot inside the host, trailing sentence punctuation handed back, a closing bracket kept only when the address opened one) so all three clients agree on where a link starts and stops. A link is drawn in the theme's accent and underlined, never as prose the reader has to retype off a screen. Activating one hands it to the browser the person is already signed in to — never a webview with an empty cookie jar, because the pages worth opening from a transcript are behind an account. A page Claude published for the conversation is recognised as such (ArtifactLink) and says so where it is shown, since its address is the only evidence in the transcript that the deliverable exists."),
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
                "Tool results that gave the model an image become file parts docked at the tool call, fetched over /files/raw and rendered inline with a filename caption. Direction is size: a picture the agent hands over is content and fills the row's preview, while one you sent is a receipt and renders at ImagePreview's share of that box — same shape, same tap to open it full size, no caption. A client decides only what units the rule is applied in."),
        CapabilityDefinition(
            id: .imageViewer, area: "transcript", title: "Image viewer over the conversation",
            spec:
                "Tapping a picture opens a gallery over every image in the conversation — paged, zoomable to 1:1 — and any save/share hands over the server's original bytes, never a re-encode."),
        CapabilityDefinition(
            id: .subagentCards, area: "transcript", title: "Subagents inline",
            spec:
                "A subagent renders as a card docked at its spawning tool call, expanding in place; a wide fan-out collapses behind one group row; never a separate chat."),
        CapabilityDefinition(
            id: .taskBoard, area: "transcript", title: "The agent's plan is one live board",
            spec:
                "Claude keeps its to-do list by tool call — TodoWrite rewrites the whole list, TaskCreate/TaskUpdate grow it a task at a time with the number only in the result string — and TaskBoard (Core) folds every such call in transcript order into one list. The transcript shows the board once: the LAST board-moving call renders as a checklist card — done struck through, the in-progress task wearing its activeForm and the accent, pending dim, headed by \"N of M done · what is happening now\" — and every earlier board call stays the one-line tool row it was, so a long run reads as one plan updating rather than twenty snapshots. TaskList/TaskGet read the server's list and change nothing, so they stay ordinary rows. The card is the fold of the transcript the device already holds — no server route, works on saved chats."),
        CapabilityDefinition(
            id: .workflowCard, area: "transcript", title: "A workflow run is one card",
            spec:
                "A Workflow call renders as the run it started, not the receipt it returned: the workflow's name and description, the phase plan its script declares, live agent rows (what each is doing, for how long), a progress reading over the fan-out in hand, elapsed, and — when the run's task reports back — the answer folded into the same card. Phase attribution is only claimed once the finished run records it; a live card shows the plan and the agents, never a guessed position between them."),
        CapabilityDefinition(
            id: .questionCells, area: "transcript", title: "Questions, not tool rows",
            spec:
                "An AskUserQuestion call docks as a question card at the end of the transcript and the answer goes out through the normal send path, never a direct backend call. The options an agent offers are a shortlist, not the whole of what can be said, so every card carries a line to type an answer of your own on — present on the card beside the options rather than behind a sheet or a menu, because an alternative you have to go looking for reads as absent, and the answer the agent needs is often the one it did not think to offer. On a question that takes one answer, typing takes the ticks off and the return key sends it; on one that takes several, what is typed stands beside them. It is a prompt box like any other: what is half-written into it is kept by DraftStore against the ask itself, so it survives the app being closed on the question it answers."),
        CapabilityDefinition(
            id: .designBoards, area: "transcript", title: "A design is looked at, not described",
            spec:
                "A change to a surface is argued about in pictures, so /design opens a preflight (DesignPreflight) that composes one brief — what to design, where it is now, what it must respect, how many alternatives — and sends it as an ordinary turn: the agent writes one self-contained HTML mock per alternative into .tailscode/design/<slug>/ plus a board.json naming each one, and changes no source. The brief states the convention rather than a command name, so it works on every agent this app talks to, and the word is answered by the app rather than by the server's catalog (SlashDispatch.designPreflight, CommandCatalogStore.designCommand) because what comes back is a surface this client renders. The board announces itself by that manifest being written — DesignReading watches the path, not the tool's name, since every agent calls its writer something different — and docks as a card at the call that wrote it, never a line of blue text. Opening it reads the manifest and each mock over the file route and renders them in the platform's own engine (WKWebView, WebKitGTK): one artboard at a time, full-bleed, its letter and name over it, its rationale and the annotations the agent stuck on it beside it, arrows or 1-9 to switch. Three verbs and no more: change this one (rewrites that mock in place), one more (appends an artboard), build this (the implement prompt, which says outright that the mock is a picture of the result rather than code to paste, and carries any last instruction). Every word is DesignBoardState's and every prompt is DesignFollowUp's, so a client decides only how a mock is framed. A board whose manifest cannot be read says so and offers the reread; a design skill that published to a link instead of to files is surfaced as that link rather than swallowed."),
        CapabilityDefinition(
            id: .linkEmbeds, area: "transcript", title: "An address wears its face",
            spec:
                "A link in the transcript is more than blue text: it gets a small preview card right below the prose that wrote it, one per address, capped, so a list of references reads as a shelf of cards rather than a paragraph of URLs. The card is a promise kept small — an icon slot, one line of title, one line of host — and states itself honestly at every stage: a quiet placeholder while the page's title is still unknown, the page's own title and favicon once they are fetched, and the host alone when the fetch fails, never a spinner forever. It is metadata only: the fetch reads the page's head for a title and an icon, never the conversation's context, and it is debounced and cached so a link re-rendered on every streamed arrival costs one request, not one per arrival, and a streamed address still growing never fires one at all. Tapping the card opens the address exactly the way the link itself opens — the reader's own browser, never an embed of the page — and long-press offers to copy the address. Failure of the fetch is not failure of the link: the card stays tappable with the host as its face, because what the transcript promised is the address, not the page. The card is on by default and the reader can turn it off: LinkEmbedsSetting (Core) is the one answer every client asks, off means plain links and nothing else, and flipping the switch rebuilds an open transcript at once rather than on its next turn."),
        CapabilityDefinition(
            id: .compactionSeam, area: "transcript", title: "Compaction is a seam",
            spec:
                "A Compaction part renders as a divider stating what was traded for what, with the machine-facing summary behind a reader; /compact always passes through a preflight that warns, and takes an instruction for what the summary must keep where the server's compaction accepts one (Claude Code) — a server whose summarize takes none (opencode) gets the same preflight without the field, because a sentence the server would drop is a promise it cannot keep. opencode's wire shape for a compaction is three pieces — a marker part on an empty user message, then an assistant message whose text is the summary — and the backend folds them into the same seam every client renders: the marker drives the running activity from the event stream, and the completed summary is carried inside the Compaction part."),
        CapabilityDefinition(
            id: .permissionCards, area: "transcript", title: "Permission requests",
            spec:
                "pendingPermissions render as approval cards with the tool's ask spelled out and approve/deny (and remember, where the backend offers it)."),
        CapabilityDefinition(
            id: .failureSurface, area: "transcript", title: "Failures say so",
            spec: "lastFailure surfaces as a visible banner/row with the message, never a silent stall."),
        CapabilityDefinition(
            id: .answerlessTurn, area: "transcript", title: "A turn that said nothing says so",
            spec:
                "A turn can finish having produced nothing at all — no words, no tool call, no picture, and no error, which is what a provider refusing a request mid-stream leaves behind. Every part of the transcript is built from what a turn produced, so that outcome draws nothing anywhere: the spinner stops, the transcript sits exactly as it was, and the question reads as ignored. ChatMessage.isAnswerless names it from the message itself — assistant, completed, no error, and not one part carrying content — excluding a turn somebody stopped by hand, whose emptiness they already understand. AnswerlessTurnReading turns it into the row's words, and no client writes its own: what happened, the server's own finish word quoted when it adds anything, and — when the question carried pictures, which is the commonest thing a model is refused for holding — that fact and the remedy that follows from it. Nothing claims a cause the transcript cannot show. The row is settled, so it holds perfectly still, and it offers exactly one action: send the same words again, without the pictures where they were there, which every client wires to the ordinary send so the retry is a message like any other. The words come from the prompt in the transcript rather than from a send this device happens to remember, so the row works on a conversation opened from another machine."),
        CapabilityDefinition(
            id: .interruptedTurn, area: "transcript",
            title: "A turn the machine cut off is not a turn that was ignored",
            spec:
                "A server that stops mid-answer — updated, killed, slept, powered off — leaves a conversation indistinguishable from one where the model had nothing to say: the prompt is there, no answer follows, the spinner is gone. It is the one failure that must never render as silence, because the agent may have been three files into an edit. The server names it (TurnInterruption on ConversationState, fetched on every refetch and delivered live on the stream, so a client that was not connected when it happened still finds out), InterruptedTurnReading writes the words once in Core, and all three clients draw the same card docked at the end of the transcript: what was asked, how long the turn had run, when the stop was noticed — never why, because nobody knows — and the account of what the work had actually done, read off the agent's own transcript rather than off anything it claimed: tools counted, the one it was inside, the files it wrote to named without their paths, the commands it ran, how far the answer had got, and the prompts that were queued behind it and never ran. A turn that had done nothing says exactly that, because 'nothing on the machine changed' is the fact that decides whether starting over is safe. It is a settled state and holds perfectly still. Two actions and no more: pick it back up, which continues the work on the server that holds it, and let it go, which drops the record and touches no transcript. The card comes down on the server's answer rather than on the press, and a turn already resumed keeps the card, saying so, rather than vanishing into another silence. A backend that cannot answer the question is not a backend that answered 'nothing was interrupted' — an unsupported route leaves the question unanswered and the surface absent, never a false all-clear."),
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
            id: .userEcho, area: "transcript", title: "Sent words appear at once, and say what became of them",
            spec:
                "A sent message renders immediately as a pending row built from what is in memory — never from a rebuild of the transcript, which is what made a long conversation swallow a send — and the row carries its phase from PendingSend: sending, sent, or not sent with the reason and the words still in it, offering send-again/edit/discard. Retired only when the server's account grows the message it stood in for."),
        CapabilityDefinition(
            id: .vimComposer, area: "composer", title: "Modal composer",
            spec:
                "The composer runs VimEngine: normal mode hides the caret and doubles as the app's normal key context, visual modes work, half-typed commands are protected, unbound keys fall back to vim."),
        CapabilityDefinition(
            id: .slashCompletion, area: "composer", title: "Slash command completion",
            spec:
                "Typing / offers the backend's availableCommands through the shared SlashCompletion ranking: the whole word typed out first, then a prefix, then a namespace:name segment matched on its bare half (/planner reaching project:planner), then letters found inside, then letters found in order but apart (/gm reaching git:merge) — and inside a tier, the commands this device reached for most recently (SlashRecents). Every row states what it is: the letters that matched tinted inside the name, the server's own argumentHint as a trailing chip, and the plugin or project that contributed it. The list is keyboard-navigable — arrows or tab to walk, enter or tab to accept, escape to dismiss — without taking those keys from an ordinary draft. Past the command's name the list gives way to that one command's signature and description, held on screen while the argument is written, and a word the catalog does not have says so rather than vanishing under the caret. Every composer the app has answers this, the quick ask included: it is the same prompt box, so / means the same thing in it — offered from the machine's own catalog (fetched with no project, cached per server through CommandCatalogStore so the first keystroke is never blank) minus the commands that read a transcript, since the conversation it mints has none, and a word missing because there is no project says that rather than only that it is missing."),
        CapabilityDefinition(
            id: .slashDispatch, area: "composer", title: "A typed command runs",
            spec:
                "A slash command typed out and sent goes exactly where picking it from the list would have sent it, through the shared SlashDispatch.decide: /compact always through its preflight carrying whatever instruction was typed after it, a command the server knows through the command route with its arguments and the model and effort the composer is wearing, and anything the server has never heard of out as the plain words that were written — the server is the authority on its own grammar, and an agent that resolves its own slash grammar from prompt text gets the prompt untouched. A quick ask decides the same way and carries the decision through the mint (QuickAskSend), so a command typed into it runs as a command in the conversation it minted rather than reaching the model as the word it was typed as."),
        CapabilityDefinition(
            id: .commandCatalog, area: "composer", title: "Browse every command",
            spec:
                "The whole catalog is browsable, not just completable: grouped by where each command came from (built in, this project, yours, plugins, skills, MCP servers) with its description, scope and argument hint, searchable over names and descriptions through the same shared ranking, and recently used first. Picking one hands it to the composer half-typed when it takes arguments, and runs it when it does not. A completion list cannot teach a name nobody has seen."),
        CapabilityDefinition(
            id: .attachments, area: "composer", title: "Attachments",
            spec:
                "Files and images attach via the shared AttachmentIntake (size-capped), show as removable chips, and ride out with send. One trip through the picker takes as many as the send can carry — a question with pictures usually has more than one, and going back through the sheet, the menu and the library for each is the same decision made four times — kept in the order they were picked, capped by count as well as by size because the whole selection rides inside one message, and answered with one line saying how many landed rather than a toast per file. A paste is an attach as much as a paste: the clipboard is read into one shape (ClipboardOffer) and PasteIntake decides what it means, so all three clients agree without deciding anything themselves — files copied in a file manager become chips under their own names, a picture becomes a chip rather than nothing at all, an overlong paste becomes the file it already is, and only words go in as words, at the caret. What the aim cannot be handed is refused by name rather than dropped silently, and the ordinary word paste is handed back to the platform untouched so undo, selection and the system's own behaviour keep working. A phone has no file manager to copy from, so its clipboard offers pictures and words and the surface says so."),
        CapabilityDefinition(
            id: .drafts, area: "composer", title: "Nothing typed is ever lost",
            spec:
                "Every prompt box persists what is in it as it is typed, and hands it back on return — not only the chat composer but Home's, the /compact instruction, the goal condition and a free-typed answer to a question. The shared DraftStore keys each box by what it is writing to (DraftScope: a chat by profile and session, Home by the compose target it would start in) so a draft follows its conversation across panes, clients and restarts rather than the window it was typed in. Recording is per keystroke and the write is coalesced onto a quiet moment (DraftStore.quietSeconds), off the caller's thread and into the store's own file — a burst of typing costs one write, and the last word still lands without anyone remembering to save. Clients flush by hand where the process is about to stop being asked (resign, terminate, window or pane close), sending clears the draft immediately so a crash cannot hand a sent prompt back, and the store is bounded by recency so a device that has typed into hundreds of chats never carries a write proportional to all of them."),
        CapabilityDefinition(
            id: .sendQueue, area: "composer", title: "A queued message is still yours",
            spec:
                "Sending while a turn runs is allowed and visibly queued (Send becomes Queue), and the message goes the moment the turn yields. It is held on the device rather than handed to the server, because that is the only version of queueing where the message is still yours: the next thing you type is the thing you most often want to reword, reorder or take back once you have read another paragraph of the answer, and a queue entry on the far side of a wire is one nobody can reach. Every waiting message is therefore a row in the transcript — dimmed, marked, and never drawn as though it had been sent — and it opens: a press on it, or ↑ from an empty composer for the most recent one, puts it back in the box (SendQueueReading.upArrowTakesBack; only from an empty box, because in a half-typed paragraph that key is moving the caret). The entry keeps its place in the order while it is being rewritten and sending replaces it there rather than appending a new one, which is the difference between editing and deleting-and-re-adding; clearing it to nothing is how it is taken back. Nothing drains while a message is open for editing — sending it out from under the person editing it is the one thing the queue exists to prevent — and a send that fails goes back to the head of the queue rather than the tail, so a blip on the connection cannot silently reorder what somebody wrote. The whole model is SendQueue/QueuedSend in Core and no client invents a word of it."),
        CapabilityDefinition(
            id: .modelEffortPicker, area: "composer", title: "Model and effort choice",
            spec:
                "The next turn's model and reasoning effort are pickable from availableModels, and the choice rides every road a turn starts on — send(model:reasoningEffort:) for a typed prompt, run(_:arguments:model:reasoningEffort:) for a slash command, a compaction and a goal — because a command is a turn and a server asked for nothing answers on its own default, which is how a chat ends up wearing the name of a model that never answered it. A pick is recorded per session and as the server's last-used default (ModelPreferenceStore/EffortPreferenceStore.recordPick), and a chat opens on initialModel/initialEffort — never a hardcoded default. When the server's session record names a door for its model (AgentSession.modelProviderID — opencode reports one), that door settles how the bare model string resolves against the catalog, so a session on the direct DeepSeek key reopens on the key rather than on the plan's copy of the same model — and a pick with no door at all still resolves its model by id, so a reopened conversation keeps the model's own levels instead of a list that stopped matching. The effort menu lists only what the picked model can run (ModelEffort.options): a level the model cannot take is absent, not dimmed, and a model with no levels has no effort control. A command that pins its own model still wins on the server: the pick is what the client asks for, not what it orders. Claude Code's effort menu includes ultracode, which the server maps to xhigh plus standing workflow orchestration; typing the word in a prompt opts that turn in the same way."),
        CapabilityDefinition(
            id: .unifiedModelChooser, area: "composer", title: "One selector over every provider",
            spec:
                "Every model the server lists, from every provider, is chosen from one searchable surface built on the shared ModelChooser — never a flat menu of the raw catalog. The same model offered by two providers folds into one row that says so and opens onto its alternates (⌃→ / the chevron); sections are model families, not provider keys. The list leads with Current — what this chat runs, named rather than implied by a tick somewhere down the page, with the server's own default beside it — so Recent stops repeating the row above it. Every row is one shape on all three desks: the tick, the name over what settles which model it is, and against the right edge everything the row wears, so the marks form a column instead of an edge that moves with the length of each name. What a row wears is what would change the pick, and nothing else: the machine when it is not this one, local, effort levels, the doors it has, and the wall in front of it — with capabilities in the quieter register behind them, and any capability the whole catalog shares dropped outright by ModelFactPolicy, because a label two hundred rows all wear distinguishes none of them. The second line is dropped the same way: a house that runs every model under a heading does not name itself under every row, and an id that only respells the name is not a line. A narrow screen keeps the name and drops the marks it cannot fit, and says all of them to a screen reader anyway. Standing filters (ModelChooser.scopes — the whole catalog, this server, local) are always on screen with their own keys (⌃1–9) and are offered only where they would change what is listed; an empty answer names the filter as well as the query and hands back the one press that clears it. Past ModelChooser.foldFrom models the families fold: the list arrives open only where the model in use lives, each heading is a press (⌃→/⌃←, ⌃⇧ for all of them) that says how many it holds, and one control at the top opens everything or shuts it again, naming the number it would show. A query is never answered from behind a shut heading. A wall is the account's rather than the machine's, so a window every one of your servers spends from marks that model on all of them — two machines on one plan never disagree about what is used up. The door a collapsed row picks is deliberate: the door the chat is already on wins (a re-pick never silently moves the billing), then the model's own house over a reseller fronting it — a model offered both by its own keyed provider and by opencode go picks the key, because someone who configured one wants it. One query searches names, ids, providers and families through ModelChooser.search with the matched letters weighted in the row; recents float; the row already chosen is where the chooser opens. The pill's quick menu shows ModelChooser.shortlist and hands the rest to this surface, so the two are one list at two lengths."),
        CapabilityDefinition(
            id: .modelCapabilitySurfacing, area: "composer",
            title: "What a model cannot do is never offered",
            spec:
                "A capability is the model's far more often than the server's — one opencode machine fronts a hundred models and half of them cannot see a picture, most take no effort level at all — so every affordance follows the *pick* rather than the connection, and the reading is Core's so three clients cannot disagree about one model. ModelAbilities.resolve narrows the backend's word by the picked model's own and is what decides whether an attach affordance is drawn at all, whether pictures are among what it offers, and whether a drop or a paste is accepted; a model the catalog cannot describe is trusted rather than assumed blind, because a server that never published per-model capabilities must not lose its attach affordance over a fact nobody stated, and a pick carrying no door still finds its model by id, which is the shape a conversation reopened on another device holds. ModelEffort.options decides the levels the same way — the model's own variants where the catalog names them, the agent's list only where the model itself is unknown, and an empty variants list is an answer rather than a gap. What a model cannot do is never offered and never explained: the effort control is absent, not a pill reading \"no effort control\", and the chip names no effort word left over from the model that answered last. What is already in hand when the pick changes is dropped out loud (ModelAbilities.dropped) rather than left to fail on the other machine, and where the whole affordance is missing the menu says which of the two refused it (ModelAbilities.unavailableReason) so its absence is a stated fact rather than a control somebody assumes they failed to find. Every composer answers this — the chat's, the quick ask's — on all three clients."),
        CapabilityDefinition(
            id: .responseStats, area: "transcript", title: "An answer says what it took",
            spec:
                "A person reading an answer asks three things about it: was that slow, was that expensive, what wrote it. ResponseStats answers them under the turn itself as one quiet strip — output speed, elapsed, tokens written, tokens read, estimated cost, and the model with its effort — off by default (ResponseStatsSetting) because a transcript is for reading and a rail of figures under every answer is a tax on the reading it exists to inform. It is deterministic and never measured here: every figure is the server's own arithmetic or a division of two of the server's own numbers, so two devices watching one conversation report the same answer identically and nothing drifts with the network or this process's own scheduling. The rate divides MessageUsage.written and never a total — a turn that read a hundred thousand cached tokens and wrote two hundred did not run fast — and needs enough clock under it to mean anything. What cannot be derived is left out rather than guessed: a turn whose server said nothing about tokens shows its clock and no rate, a turn that said nothing at all draws no strip, and a turn still being written or one that failed draws nothing, because a rate over a partial answer moves under the reader's eye and everything settled in this app holds perfectly still. Money follows the spend doctrine — API-equivalent value, marked an estimate, never a bill. Each client decides only the layout: the same facts, the same order, the platform's symbol or the text glyph, the detail sentence as a tooltip and the whole strip spelled out for a screen reader."),
        CapabilityDefinition(
            id: .modelEffortDisplay, area: "composer", title: "The chip tells the truth",
            spec:
                "The model/effort chip shows what will actually answer: the explicit pick, else the model observed on the last assistant turn, else the session's own record."),
        CapabilityDefinition(
            id: .ultracodeAura, area: "composer", title: "Ultracode looks unlocked",
            spec:
                "Picking the ultracode tier, typing the word into the draft, or a turn in flight that was sent with it wraps the composer in the shared animated rainbow aura, and a turn in flight is read from the conversation rather than from having been the client that sent it: Ultracode.turnInvoked finds the word in the running turn's own prompt, which is the same text the server decided on, so a turn summoned on one desk wears the aura on every desk watching it (Ultracode.auraActive over Ultracode.rainbowStops) — special powers visibly on before the prompt is sent — and the effort menu presents ultracode as a power (Ultracode.menuTitle/menuSubtitle), not another level. The rainbow travels around the edge and the glow breathes under it, both on the shared periods (Ultracode.auraTurnSeconds/auraBreathSeconds/auraBreathFloor, or Ultracode.aura(at:) where the client paints its own frames), off a clock rather than a counter so a dropped frame costs a frame and not the rhythm. Reduced motion keeps the aura lit and stops it moving: a power being on is a fact, not a flourish."),
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
                "A dedicated analytics surface aggregates the whole account: every connected Claude server reports the ledger its machine already holds (GET /analytics — every transcript priced turn by turn), and Core's UsageAnalytics merges the servers and generates every word. The sections are fixed: the window's total with its per-day rate and week-over-week trend, a bar per day with the empty days present, the week's rhythm Monday-first, the day's 24-hour clock, models, projects, tools, where the money went across the four token tiers with what caching saved, the records (busiest day, priciest conversation and turn, longest turn, streak, subagent runs, compactions), per-machine shares when more than one server answered, and two or three insights. A client decides only how tall a bar is. Money is an estimate and says so; a server too old for the route is named in the surface, never a silent hole in the numbers. The surface shares: AnalyticsShare is one package every client reads — plain text and markdown for a paste, a stable filename, and a card laid out in pure geometry (blocks, fixed metrics, the active theme's palette falling back to Rosé Pine so a share never wears System's invisible colours). The card is a brag poster, not a dump of the screen: the total, the window, the day chart, the week, the top meters, the records and the insights, with the estimate provenance at the foot. A client paints that geometry at 2× or 3× into a PNG and hands the picture with the words to the platform's own share sheet (UIActivityViewController, NSSharingServicePicker, the desktop clipboard and a Save as… on Linux). Share is offered only once the ledger has something to say; an empty or still-loading surface has no share control."),
        CapabilityDefinition(
            id: .deepseekBalance, area: "status", title: "DeepSeek API balance",
            spec:
                "DeepSeek models reached through a direct API key are metered by that key's prepaid balance, not by any plan's windows, and the usage surfaces say so in the key's own voice: an optional API key stored with the platform's secret store, read once per refresh from api.deepseek.com/user/balance, and rendered as a balance rather than as quota bars — the total available, split into what was topped up and what was granted, with no invented cap and no reset countdown. An empty balance reads as the wall it is: the provider's card says used up and the chooser marks only DeepSeek models (the billing rule in QuotaBinding.bills), never a neighbour's. No key means no card rather than an error — the surface stays what it was, and the settings row states the key's presence or absence as a fact. The fetch is best-effort on every existing usage path so the widgets and the panel move together."),

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
                "The server screen reads /update through BridgeUpdater, offers the commits it would bring, and follows the restart; a refused connection mid-update is the restart, not a failure. A restart is never taken out from under a running turn: the machine reports what it is doing, the press says beforehand what stopping it would cost, and the bridge holds the restart behind its own quiet barrier rather than exiting on a check it made minutes earlier. A build that landed and was never started is one press rather than a terminal instruction (UpdateInvitation.restartHere), and only where something would start the bridge again — a machine with no supervisor is handed the command instead, because a bridge that exits with nothing to bring it back is a machine no client can reach. The obstacle in the way of an update is named rather than summarised: the files that are dirty, the commits that cannot be fast-forwarded, the toolchain that would do the building."),
        CapabilityDefinition(
            id: .serverRestart, area: "servers", title: "The app can start a server over",
            spec:
                "Where a server is explained, it can be asked to start over (ServerRestart, RestartableBackend). It is the only way back to anything a long-lived process reads once and never again — the model list opencode resolved at startup, a config edited since, a plugin installed after it began — from the device that is present, on a machine whose terminal is not. The press states what it costs before it is taken, counting the turns this device knows are running there, because a restart stops them where they stand; the restart itself is one command on the machine, left there by the setup script. A server set up by hand is not left with a refusal: the failed restart offers the setup in the same breath (ServerRestart.setup*, ServeManagerBackend.installServeManager) — one press that installs the supervisor, the restart command and the catalog refresher on the machine, idempotently and without a terminal — and the machine that takes the offer restarts when the setup lands. A setup that did not take says so and hands over the command, never a press that pretends. Nothing waits on a reply: the connection dies with the process it was asked over, and the ordinary reconnect is what says the machine is back."),
        CapabilityDefinition(
            id: .serverAutoUpdate, area: "servers", title: "A machine can keep itself current",
            spec:
                "A machine can be trusted to keep itself current, and the trust is the server's rather than this device's: the policy lives on the bridge, off until somebody turns it on, so every client that asks sees the same answer and a phone nobody opens again does not stop the machine updating. A client offers the switch where that server is explained, states in the same breath what the machine will do with it — take an update only when it can finish the job end to end and nothing is running on it, because a restart stops a turn where it stands — and reads back the machine's own account: when it last took one, when it will look again, and what it is holding off for right now (UpdateAutomation, written once in Core). The waiting is a state and not a silence: a build that has landed while a turn is running says so and holds, and a commit that refused to build is not tried again until a newer one exists or the backoff runs out. A server whose policy is on is still shown as behind while it is behind, because it is; it stops holding the standing mark up, since a mark is a request that somebody act and nobody has to, and its offer expires on that machine's own next look rather than standing all morning over a version installed at two. The switch renders from what the machine last answered and says when that was, never from what this device last sent; a bridge too old for the policy has no switch rather than one that does nothing."),
        CapabilityDefinition(
            id: .updateCenter, area: "servers", title: "An update is a standing fact",
            spec:
                "Every machine in the picture — this app and each server it talks to — reports what it runs and what it could run, and the answer is one mark the app wears until the update is taken. The mark is chrome, never content: it covers nothing, steals no focus, and has no dismiss gesture; setting an offer aside (UpdateLedger.acknowledge) collapses the card that explains it and is recorded against that exact offer, so a newer release, a different obstacle or an obstacle that clears speaks again. It renders from UpdateLedger before any check of the launch completes and survives relaunches, and it holds perfectly still unless something is actually being installed, because an available update is a settled fact rather than work in progress. The words are Core's and no client invents one: UpdateReadings maps what a machine actually said into a verdict, and the whole point is what it refuses to say — a server that never reached the project, one too old for the route, one that answered nothing, one that built but never restarted, and a store record that has not propagated are five different states and none of them may read as 'up to date'. Every number is shown with its provenance and the moment it was read; 'current' expires, 'behind' does not. One press does exactly what it promises and says when it cannot finish the job itself: a bridge that can update itself is installed end to end and followed through its own restart, a machine that cannot is handed the one command, and a phone hands its own update to the App Store outright. Update everything walks the servers one at a time and never includes this app, which would replace the process doing the watching, and never a machine whose whole remaining job is loading a build it already has — rebuilding a machine that only needed starting is minutes of work for nothing, so the walk is derived from the invitation rather than from whether an offer could be installed."),
        CapabilityDefinition(
            id: .newChat, area: "servers", title: "New conversation",
            spec:
                "Starting a chat picks server and working directory in one modal built on NewChatChooser: the folders this device already knows for that server — starred, recent, and the ones its own chats work in — ranked against what is being typed by FuzzyRank, each row saying where it came from, with the typed path always offered as a row of its own so a folder nobody has used yet needs no special gesture. The server last used is pre-chosen, not re-asked. Keyboard-first in two modes: while typing, ⌃n/⌃p walk, tab completes, ⌃s switches server and esc reaches the verbs; in normal mode j/k walk, g/G jump, 1–9 pick outright, i types, f stars, enter starts and esc closes — the grammar written on screen, never a form with unranked buttons under a text field."),
        CapabilityDefinition(
            id: .newChatDefaults, area: "servers", title: "A new chat says what it will start with",
            spec:
                "The new-chat surface states, before Start is pressed, which server will host the conversation and which model it will open with. The server is named outright — NewChatChooser.heading carries the machine and agent even when only one is configured — and the model is NewChatDefaults: resolved exactly the way the composer resolves a first turn (the pick this device recorded for that server, else the server's own default, with the effort beside it), re-read every time the server choice changes so switching machines re-labels the chat before it exists. The model wears its family colour and the effort its heat wherever the client already colours chips, a device with no pick says the server decides rather than guessing a name, and the whole fact reads as one sentence for a screen reader. Never a chat whose model is discovered on the first answer."),
        CapabilityDefinition(
            id: .newChatPathCompletion, area: "servers",
            title: "The path field is a shell",
            spec:
                "A path typed into the new-chat modal completes against the server's real disk, not this device's memory: the moment the query looks like a path, the chooser names the folder it sits in (NewChatChooser.wantedListing — asked once per folder, because the parent only changes at slash boundaries) and the client answers it over the /files route the file browser already rides, offering every subdirectory whose name the letters find, case-blind, ranked and highlighted by the same FuzzyRank as everything else (PathCompletion.matches). Tab at the top of the list is the shell's tab: the longest continuation every candidate shares, spelled the way the disk spells it, a lone candidate completing whole with its trailing slash so the walk continues without another keystroke (PathCompletion.completed); a cursor deliberately walked onto a row keeps the old meaning and adopts that row. A listing that comes back for a query the person has already left, or from a server no longer chosen, is dropped rather than rendered stale; a folder the server refused is neither offered nor asked for again; and a bridge too old to list says nothing, so the modal degrades to exactly what it was. The rows read live off the disk wear no badge — the remembered ones keep theirs — and Enter on any of them starts the chat there like Enter always did."),
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
            id: .bulkRangeSelection, area: "chat list", title: "Shift-mark selects the span between",
            spec:
                "A mark placed with the shift modifier does not join the set — it re-writes it as the contiguous span the list is drawing between the anchored row and the pressed one, inclusive, the way a file manager reads shift-click. The anchor is the row the last plain mark landed on (ChatSelection.anchorKey, the listed item's lead chat so a split row anchors whole); shift-marking again re-measures the span from that same anchor rather than crawling, and anything that ends the gesture — clearing the set, selecting all, a bulk verb spending it — also forgets the anchor, while a listing change that removes the anchor degrades the next shift-mark to a plain mark. A platform whose pointer cannot express a shift modifier answers notApplicable rather than inventing a second tap gesture nobody asked for."),
        CapabilityDefinition(
            id: .bulkSplit, area: "chat list", title: "Marked chats open as one even split",
            spec:
                "A selection can also be spent on the window itself: while several chats are marked, the selection surface offers to open all of them at once as one tiling — side by side, stacked, or as a grid — with every pane an equal share of the window. SplitEven owns the whole gesture: which arrangements a count earns (two chats get the two lines, a third earns the grid, past SplitEven.limit the verbs simply do not appear), the words and glyphs every client names them by, and the equalized tree itself, with panes landing in the order the list was drawing the marked rows. The gesture spends the marks like every other bulk verb and the arrangement persists like any hand-built layout. A platform without tiling answers notApplicable rather than inventing a stack of modal chats."),
        CapabilityDefinition(
            id: .splitTabs, area: "chat list", title: "A split is one row, and unsplitting separates it",
            spec:
                "While a window holds several conversations, the chat list draws them as the one thing they are: a single row standing for the whole arrangement, and the moment the window unsplits the rows separate again. The row is a pure function of the window's live layout (SplitTab over the same snapshot the window persists), never a memory of one — a merged row standing for an arrangement that no longer exists would be the list describing a window nobody is looking at, so the row and the panes can never disagree. SplitTabGrouping folds it into the sections every client already builds: the row takes the place of the first of its members, which puts it in the highest section any of its chats earns, and the state it wears is the loudest pane's — a split with a question waiting in one pane is a split that needs you. It is only drawn whole: a listing missing a member cannot honestly say what the window holds, so its surviving chats are drawn plain. Pressing the row goes to the split — it is already on screen, and rebuilding it would tear down the very streams it stands for; pressing a member's own line jumps to the pane showing it; the row's menu offers each chat alone (unsplit down to that one pane) and Unsplit outright (collapse to the focused pane in one gesture, not a close per pane); marking the row holds every chat in it. A platform with no tiling answers notApplicable — there is no window arrangement for a row to stand for."),
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
            id: .typeRamp, area: "app", title: "Type ramp",
            spec:
                "Every place the app sets type names a TypeRole from Core's shared ramp (Typography.spec) and no client invents a size, a weight, a tracking or a leading of its own. A role carries the axis it scales with (chrome, prose, mono), the face it is set in — prose, mono, or canvas, which is the client's own voice for the two things a person types — and the four values a client would otherwise guess. The ramp exists to make type say what an accent rule was saying alone: the prompt is the heavier voice and the answer the lighter one with the leading, because the question is a heading over its own answer; a name outweighs its detail inside a row (a tool's name is semibold, its arguments are not); tracking is spent only on small labels that would clot and display numbers that would sprawl; and anything that changes while a person watches it is set in tabular figures, so a settled number never reads as motion. TypographyTests proves the claims, so a client that drifts fails the build rather than the eye."),
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
            id: .tailscaleReadiness, area: "app",
            title: "Not on the tailnet is four states, each with its own fix",
            spec:
                "Whether this device is on a tailnet is a TailscaleReading rather than an address or nothing: up, signed out, service not running, not installed, or — inside a sandbox — unable to see. Each carries what is true, why it matters and the one action that fixes it, and the client wires that action to its own door: the download page, a sign-in that surfaces the login URL where the person is already looking, or the platform's own Tailscale. Nobody is told to open a terminal, and 'this app cannot see' is never drawn as 'you are not connected'."),
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
                "A notification is a thing that appears for seconds and is then gone whether or not anybody saw it, so every alert the client raises is also written down in ActivityInbox and listed until it is looked at: what happened, in which chat, on which server, how long ago, with the ones still blocking a turn first. Opening the chat clears its own entries — a glance at the list is not looking, or the list would empty itself as it was drawn — and an approval or question answered on the server leaves the list by the same withdrawal that takes the notification back, so it can never send someone to a chat that is waiting on nothing. The list offers to clear itself whole, and says nothing at all when there is nothing to say. A notice names its chat by the name a person would recognise: the first turn is the news and the server has not named it yet, so MissedActivity.name falls back to the words that started it, and ActivityInbox.reconcile holds the standing list against every fresh listing — adopting the name the server has since written, dropping a chat that was deleted on a server that answered, and dropping finished-news for a session that is working again, while a server that said nothing is never read as having deleted anything."),
        CapabilityDefinition(
            id: .homeQuickActions, area: "app", title: "Home screen quick actions",
            spec:
                "Long-pressing the app icon offers a jump list: New Chat focuses the composer, Saved chats opens the device-local bookmarks, Usage opens the quota panel, Quick Ask summons the question composer, and a dynamic Resume item tracks the most recent session and opens it. The jump list is for what someone reaches for daily rather than what they did once — adding a server is setup, and setup belongs inside the app. Every action lands on the same destination as its in-app tap, and one that arrives before the main UI exists (a cold launch, or before any server is set up) is parked and delivered the moment Home appears."),
        CapabilityDefinition(
            id: .usageWidgets, area: "app", title: "The quotas without opening the app",
            spec:
                "Where the platform lets an app put a reading outside itself, the account's quotas are readable without launching anything: every widget family, the Lock Screen accessories, and a Control Center button, all rendered from the shared snapshot by one reading (WidgetGlance) so a phone, a lock screen and a control can never disagree. The reading is the whole contract and no client invents a word of it: windows ranked with the walls first and the tightest next, a full window drawn as the state it is rather than as 100%, money with no ceiling drawn as a balance rather than as a bar at zero, an empty balance ranked as the wall it is, and a snapshot nobody could refresh saying so before it says anything else — a percentage presented as current is the one lie this surface can tell. Each size is given only the rows it can hold and states what it left out rather than truncating silently, and every row carries its own sentence for a reader who gets no columns. It is configurable in the platform's own editor rather than by a rebuild: which providers (read from the snapshot, so a provider the account actually has is offered and one that stopped answering is not silently unpicked), how the rows are chosen, how much each row says, where the colour comes from, and whether the reset clock is shown. The colour follows the app's own theme through a mirror in the shared container — an extension cannot see the app's defaults, and a Home Screen wearing a different palette than the app it opens reads as two apps — while meaning always outranks branding: a wall is the failure colour whatever else was picked, and a tinted or Lock Screen rendering flattens to one ink without losing a fact. The extension refreshes itself inside its own budget rather than waiting for the app to be opened, and a fetch that fails serves the stored snapshot rather than an error."),
        CapabilityDefinition(
            id: .presenceOrb, area: "app", title: "A presence with a body (alpha)",
            spec:
                "The aggregate of everything this device watches, worn as one small GPU-rendered creature on the app's main surface — off by default, opt-in from settings under the shared tailscode.presenceOrb key (PresenceOrbSetting), and labeled alpha wherever it is offered. The whole behaviour is the shared simulation: PresenceSignal.aggregate distils every conversation's ActivityKind to one tone, one motion and a count, and PresenceField turns that into the frame a client rasterises with a shader and adds nothing to — a breathing core, one satellite per open turn emerging onto its own slow orbit, colour from the palette's own tone slots (the platform's colours under System). The mapping is the meaning and it obeys the activity doctrine: work breathes on the shared swell, a turn waiting on the person knocks twice on the attention tone, a failure holds the danger colour perfectly still — a broken thing is never animated into looking busy, or cute — and idle is a dim body at rest. Ultracode rims it with the shared rainbow on the shared aura clock. Every parameter approaches its target on a short time constant, from absolute time, so a state may change in a frame but the body always arrives. When a frame reports itself settled the client stops its clock and the GPU goes quiet; reduced motion shows each state's resting arrangement and loses nothing else. Touching the orb opens the conversation that most needs the person, and a screen reader gets the whole state in words (PresenceSignal.spoken)."),
        CapabilityDefinition(
            id: .auroraStream, area: "chat", title: "The answer written by the GPU (alpha)",
            spec:
                "The cascade is one effect with two rasterisers, and which one writes is a choice under the shared tailscode.streamRenderer key (StreamRendererSetting) — classic by default, labeled alpha wherever it is offered, and chosen on a screen that runs both hands side by side on the same sentence rather than describing them, because a reveal cannot be judged from a percentage any more than a haptic can. Nothing about the meaning changes between them: StreamCascade still decides every glyph's heat, the band over it and how far it has entered, the pacer still plays out of the same buffer at the same speed, and the gate still holds the renderer at the last position where no inline token is half-open. What the alpha renderer adds is what an attributed string cannot hold — AuroraField, the same distance-behind-the-edge arithmetic spent as geometry: ink that lands rather than appears, each glyph settling the last fraction of its own height with its own seeded tilt, colour channels pulled apart at the edge and closing behind it, light spilling off a hot letterform onto the page, embers that die well inside the wave because nothing may still be moving where the text has settled, and a nib riding the leading edge that burns with the pacer's own rate and rests rather than goes out when a turn stops to run something. The per-frame cost is the point: geometry is rebuilt when text arrives, and between arrivals a frame is one uniform buffer and one draw call however long the answer is, on the display's own clock at up to 120Hz. Every constant is Core's and asserted by AuroraTests, so a shader that drifts fails a test rather than merely looking different; the client resolves the theme's inks, reads the display's clock, and adds nothing. It degrades rather than breaks: no GPU, reduced motion, a row the geometry cannot be read from, or a burst past the tuning all fall back to the settled renderer for that row, and the settled renderer remains the whole product's floor."),
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
        CapabilityDefinition(
            id: .gameCenter, area: "status", title: "The ledger is also a game",
            spec:
                "The month the analytics already fold is scored against a fixed trophy catalog, and Apple's Game Center wears the result. The catalog and every word are Core's (TrophyRoom): each trophy is an identifier shared with App Store Connect, a target, a progress line and Game Center's own 0–100 percent, all read from the same UsageAnalytics merge as the charts — the in-app card and Apple's dashboard can never disagree. The analytics surface carries the trophy case: earned count, the nearest unearned marks as progress bars (the chase, not the shelf), and the road into Apple's own dashboard. Signing in is lazy and never a wall — the card renders whole from Core with no account, states plainly when Game Center is unavailable, and the sign-in sheet appears only when the person goes toward the dashboard. Reporting rides the fetches the app already makes: whenever a haul lands, changed percentages go to GKAchievement and the window's scores to the leaderboards (longest streak, and the month's turns, tokens and tool calls), deduplicated so a refresh costs nothing. Game Center is Apple's account system, so only the Apple clients can answer it; the trophies themselves stay toolkit-free in Core."),
        CapabilityDefinition(
            id: .projectBoard, area: "chat list", title: "A project opens as its own board",
            spec:
                "A project names a place work happens — a directory on one machine — and choosing it opens a container, never a composer: the board is that project's chats and nothing else, decided on the exact (profile, directory) pair (ProjectScope.matches), never a path substring, wearing the same rows, sections, live updates and row verbs the whole list wears, and leading with the project's own name. The one thing a launch pad owed — a new chat in that project, pre-aimed at its directory — rides the board's chrome as an offer, so starting work there costs one tap but stays a choice; creation never happens on open. Where the container appears is the client's idiom: the phone's project cards open it, a desktop sidebar scopes itself from a row's own menu or the p key and wears a clearable banner naming the scope (ProjectScope.banner — project and server both, because two machines can hold a checkout spelled the same) rather than a hidden mode. Leaving the scope restores the whole list unchanged, and conversations that never had a directory form a real scope of their own rather than being unreachable."),
        CapabilityDefinition(
            id: .quickAsk, area: "composer", title: "A question skips the setup",
            spec:
                "Some prompts are questions, not work, and a question owes no form: the surface is only a composer and sending is the whole ceremony, but how that composer is reached is the platform's own. A desktop takes a chord from the whole machine, and a window arrives with it over whatever was in front. A phone has no key to take and no window to arrive in — and it already has a prompt box on its front door, which differs from a question in exactly one way: it has a project. So the phone's quick ask is not a sheet summoned over that box but the box's other lane (QuickAskLane), thrown with one small switch inside it: nothing about composing is learned twice, each lane keeps its own draft so the flip loses no words, and what is in hand rides whichever lane is sending. Whichever shape it takes, the lane in force is stated rather than implied — the switch wears the accent when the ask lane is on, the destination chip drops the project a question cannot have, and the empty box says what it is for. A lookup competes with the browser already in the person's hand, so the gesture is also offered outside the app wherever the platform has a place for one — on the phone, the icon's jump list and a Control Center tile, both landing on that same box with the lane already thrown and the keyboard already up, and a press that arrives before the app is standing is parked rather than dropped. The aim is one control naming both halves — which machine answers and which model it answers on — and one action changes either: which server is QuickAskDefaults.target (the machine the last quick ask used while it is still among the servers offered, else the caller's own fallback), and which model is that server's quick-ask memory (QuickAskDefaults.model/effort, filed under an ask context beside the server's own, never inside it). How hard the machine is asked to think is the other half of that memory and is set beside the model on every client: the levels are the picked model's own where the catalog names them and the agent's otherwise (ModelEffort.options), a control with nothing to offer says so rather than reading as a default (ModelEffort.label), and a level the aim can no longer run is handed back to the machine rather than kept as a word the send would not carry. Until a model is picked by hand the aim follows the server, so the first question runs on what a new chat there would have; after one it is the quick ask's own and stays put — pointing lookups at something cheap may never re-aim the project chats, and being asked twice for the same aim is the thing the surface exists to avoid. A model picked on another machine re-aims the whole question there. A send records the server, and the minted conversation is stamped with the aim so it opens on the model the question was asked with. Sending mints an ordinary conversation there with no project directory and the words already on their way, then opens it where conversations open on that client. Afterwards a quick ask is any other chat: it lists, resumes, saves and deletes normally, and its row simply has no project to name rather than pretending one. With no servers the surface says so and offers setup instead of a dead text box. Owing no form is not the same as being able to do nothing, and the surface has three states rather than one. Composing is the chat's own composer, not a smaller one — literally the same prompt box the chat is written in (PromptEditor on the desktops, the front door's own HomeComposerBar on the phone, which answers everything ComposerView does), so it is as tall as what is in it up to the same ceiling the settings set and then scrolls, Enter sends and shift+enter writes the line break under the same preference, a desktop's modal editing is the same engine wearing the same modes on the same border, and the ultracode aura lights around it the same way; a question that needs a paragraph is typed the way a prompt is: whatever the aim can be handed rides with the question — pictures, files, the clipboard's picture, a large paste that becomes the file it already is — each read fully at pick time into a removable chip, capped at 8 MB, and a picture with no words is a send like any other (QuickAskComposition.canSend). What the aim cannot take is never offered: ModelAbilities.resolve narrows the backend's word by the picked model's own, a model the catalog cannot describe is trusted rather than assumed blind, and something already in hand that a model switch makes unreadable is dropped out loud instead of failing on the other machine. The empty state argues for itself rather than showing a placeholder — QuickAskStarters, filtered to what this aim and this device can do, most recently used first, each row the first half of a sentence left in the composer with the caret at its end and never a question the app sent on somebody's behalf — and with them the last few questions asked on that machine (QuickAskRecents), which reopen rather than ask again. How they are laid out is the surface's own — rows down a panel that has a screen to spend, a strip of chips above a bar that has none — but the order never is: what the agent can do first, what was already asked behind it. The starters get out of the way the moment there is a question, or something in hand, or a command being named, and come back if it is emptied. Waiting locks the box so nothing is typed into a send already in flight, and a surface with room for a sentence names the machine being waited on; failing shows the diagnosis where the asking happened with the one action that fixes it (NewChatAttempt/NewChatFailure.fix, applied and retried in place, never an alert on whatever a dismissal revealed), and the words, the attachments and the aim all survive it. What is typed survives the surface closing, the lane being thrown, and the aim moving (DraftStore.quickAsk, per server). Every affordance stays the platform's own idiom: a phone offers its camera and takes a drop anywhere on the screen, a desktop takes a drop on the panel and answers chords, and no client invents a wording Core does not carry."),
        CapabilityDefinition(
            id: .summonAnywhere, area: "composer", title: "The question is asked from anywhere",
            spec:
                "A lookup competes with the window already in front of the person, so on a desktop the quick ask is not a shortcut inside this app but a key taken from the whole machine: one chord, pressed in any program, opens the question box (SummonSettings.chord, default SummonChord.standard — Ctrl+Alt+A, inside the two-modifier space a desktop leaves to whatever wants a key from the whole session). It is the only gesture: a chord that already works from every program owes nothing to a second one inside the app, and the bare letter it used to spend there is worth more back in the composer, where a vim hand presses A to append at the end of the line.. The chord is the person's to change and is recorded by pressing it rather than by naming a key, because what a person wants is what their hand already does. Taking a key from the machine can break a program that is not this one, so the chord is judged before it is claimed and the refusal names the thing that would be taken, never a rule: an arrow with shift extends the selection by word in every editor and text field on the machine, an arrow alone moves the caret or the workspace, Tab belongs to the window switcher, a lone editing chord is copy or save everywhere, and a key with no modifier at all belongs to whatever is being typed into. What the machine then did with the chord is a state rather than a boolean, and none of its faces may read as bound: asked for and not yet granted, granted as a different key than the one requested, already answered by something else, and a session with nothing to ask are four different facts (SummonState), and a claimed key states how far it reaches — a desktop that holds the key only while this app runs says so (SummonReach), because a summon that quietly needs the thing it is summoning is worth saying once rather than discovering on the morning it is pressed first. A press reaching a process that is not standing is a launch rather than a dropped keystroke: the app is single-instance, so the summon arrives as an action on the process that already holds the bus name and raises its window before opening the field — a field that opened behind another app's window would take the keystrokes meant for the question with it. Where the platform cannot grant a key at all the surface says which desktop refused and hands over the one line that desktop's own config would need (SummonRecipe, in that desktop's language), which is also the road to a Tailscode that is not running. A phone has no such gesture to give: its share of this is the icon's jump list and the Control Center tile, which quickAsk already carries."),
        CapabilityDefinition(
            id: .reviewPrompt, area: "settings", title: "An App Store review is asked for, never nagged",
            spec:
                "The only moment the app asks for a review is the moment value just landed, and the policy that decides whether to ask is Core's, not a client's: ReviewPromptPolicy counts successful turns, anchors an install date on first use, and answers due only past both gates — enough completed turns and enough days since install — with one ask per cooldown window so a review is never nagged for. What counts as a successful turn is the ordinary reading: the turn finished, produced content, and failed at nothing. A trophy earned waives the turn count, because that moment is the deepest signal the person already has, but never the age gate. The ask itself is the platform's own store-review call (SKStoreReviewController) — nothing renders a custom prompt, so a dismissal the system never reports back is not something the policy pretends to know; the system's own annual cap is the last word on how often anyone is asked. A platform without a store to review answers notApplicable, and the policy is never told to ask there. The ask is debounced behind the turn's end so it lands on the person reading the answer, not on the frame the answer arrived."),
        CapabilityDefinition(
            id: .proUnlock, area: "settings", title: "The unlock, and the one gate it answers",
            spec:
                "Tailscode is GPL-3.0 and every screen is in the free app, so the purchase is a convenience and a way to fund the work rather than a wall: ProOffer in Core holds the whole policy and every word of it — the product identifiers, what the free copy holds (one server, ProOffer.freeServerLimit), what Pro adds, the sentence said at the gate, and the tip jar that unlocks nothing at all. The store record is shared across the Apple clients and so are the product ids, so one purchase covers iPhone and Mac on the same Apple Account and each client only has to ask StoreKit what it already knows. The gate is on ADDING a server past the free limit, never on keeping one already configured, and it never refuses without opening the window that answers it. Nothing asks on launch, nothing asks on a timer, and no surface is hidden behind the unlock. A client with no store to buy from, or a build with no receipt to verify, is simply unlocked rather than pretending to sell something it cannot deliver."),
        CapabilityDefinition(
            id: .videoForge, area: "splits", title: "A video is asked for and watched being made",
            spec:
                "A person describes a video on any client and watches it be made on the machine with the card. Everything but the drawing is Core's. Where the renderer lives is a ForgeEndpoint — a host and ComfyUI's own 8188 read through the same HostAddress parser the agent connection uses, kept in ForgeStore, and probed with PortReachability rather than an HTTP request so \"nothing is listening\" is told apart from \"that machine is asleep\" and \"that name does not resolve\" (ForgeEndpoint.sentence names each). What is rendered is a ForgeRecipe — prompt, negative, a frame size that is a multiple of 32, seconds, frame rate, seed and which of the two LTX-2.5 transformers, each model bringing its own sigma schedule — and ForgeGraph turns it into the twenty-eight-node two-pass graph verified on the box, encoding the invariants as code rather than as comments: length is seconds times rate plus one, the first pass samples at half the asked-for size and the latent upsampler doubles it back, and ForgeGraph.problems refuses to post a graph whose links do not resolve. ForgeClient runs it: one client id shared by the POST and the websocket or the frames land on somebody else's socket, a 45-second budget on the first request because the box is socket-activated and takes about twelve seconds to answer cold, every frame type parsed by ForgeEvent including the null-node executing frame that is how a finished render announces itself, /interrupt to cancel, and the file resolved out of history to a /view URL — with a salvage loop so a phone that locked its screen mid-render still gets its clip. Progress is the node census from progress_state (finished over total), never the sampler's step counter, which restarts between the two passes and would fill, empty and fill again. ForgeJob is the state machine (drafting, submitting, queued, running, done, failed, cancelled) and owns every word on screen — title, subtitle, detail, badge, elapsed, which pass is working — and ForgeBoard lays it out as four sections every client draws identically: the renderer and whether it answered, the render in hand with its bar, the settings as walkable rows, and the clips already made. A failure is never silent: ForgeFailure carries a sentence naming the machine and, where it can, the fix, and ForgeClient.reason normalises anything foreign so no client ever prints an error object. What each client owes is the drawing — rows, a text field, a video player for ForgeAsset.url(on:) — and nothing else."),
        CapabilityDefinition(
            id: .forgeHistory, area: "splits", title: "Every clip made is still findable",
            spec:
                "A render costs minutes of another machine's card and the file it wrote lives on that machine, so what this device keeps is the receipt: ForgeStore.history holds a capped list of ForgeEntry — the prompt, the settings, the seed and the three fields that fetch the file back — filed the moment a job stops, whether it produced a clip or a reason it did not. That is enough to list what was made, play any of it again through ForgeAsset.url(on:) with whatever endpoint is current rather than a URL that went stale when the address changed, and — the whole point of showing a seed — ask for the same clip again or the same clip slightly different: ForgeBoard.reuse puts an old recipe back in the draft. The list is device-local like the archive and the watchlist, compacts to four rows behind one expander that says how many it is holding, and an empty one says it is empty rather than vanishing. A client owes the rows and a way to remove one; the order, the wording, the badge and the cap are Core's."),
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
