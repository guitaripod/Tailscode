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
    case unreadTracking
    case savedChats
    case archivedChats
    case deleteSession
    case renameSession
    case forkSession
    case listFilter
    case autoOpenLastSession
    case liveListUpdates
    case rowContextActions
    case usageGauges
    case quotaExhaustion
    case markdownRendering
    case streamingGrowth
    case streamCascade
    case toolRows
    case toolDiffs
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
    case toasts
    case serverManagement
    case connectDiagnosis
    case serverSignIn
    case serverSelfUpdate
    case newChat
    case keyboardShortcuts
    case shortcutCheatsheet
    case fileBrowser
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
    case videoSlot
    case browserSlot
    case hapticFeedback
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
                "The list groups rows into LIVE NOW / SAVED / RECENT via groupIntoSections, dropping empty sections so no heading ever sits over nothing."),
        CapabilityDefinition(
            id: .sessionRowStatus, area: "chat list", title: "Row state pill and glyph",
            spec:
                "Every row states what it is doing via SessionRowState: live, needs-you, offline, failed each get a pill/glyph; silence is reserved for idle."),
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
            id: .usageGauges, area: "chat list", title: "Usage quota gauges",
            spec:
                "Account quota (usageQuota + additionalUsageQuotas) is visible at a glance from the list surface and refreshes on a slow poll."),
        CapabilityDefinition(
            id: .quotaExhaustion, area: "sessions", title: "Used-up quota is a clear state",
            spec:
                "When a provider window is at or past full, or a turn fails because of a rate limit / quota wall: a clear surface names the provider and window, says when it resets when known, and tells the person to switch model or wait — never a raw rate-limit string alone. Live gauges at full read as \"Used up\". A one-shot notification fires the first time a window hits full. Pre-emptive notice rides the conversation chrome while the wall is up, not only after a failed send. Copy and classification live in QuotaSurface so every client says the same thing."),
        CapabilityDefinition(
            id: .markdownRendering, area: "transcript", title: "Markdown prose",
            spec:
                "Assistant prose renders headings, emphasis, lists, links, inline code and fenced code from the shared grammar; never raw markdown source."),
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
            spec: "Edit/write tool calls show an added/removed line diff (ToolDiff), not raw JSON."),
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
            id: .drafts, area: "composer", title: "Per-session drafts",
            spec: "Unsent composer text persists per session under tailscode.draft.<id> and restores on return."),
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
                "Picking the ultracode tier, typing the word into the draft, or a turn in flight that was sent with it wraps the composer in the shared animated rainbow aura (Ultracode.auraActive over Ultracode.rainbowStops) — special powers visibly on before the prompt is sent — and the effort menu presents ultracode as a power (Ultracode.menuTitle/menuSubtitle), not another level."),
        CapabilityDefinition(
            id: .stopTurn, area: "composer", title: "Stop the turn",
            spec: "A visible control cancels the current turn via cancelCurrentTurn."),
        CapabilityDefinition(
            id: .statusBand, area: "status", title: "Status band",
            spec:
                "A persistent strip states phase, token estimate, and clock from the shared StatusFacts — the same facts on every platform."),
        CapabilityDefinition(
            id: .usagePanel, area: "status", title: "Usage details",
            spec: "A dedicated surface breaks down quota windows beyond the glanceable gauges."),
        CapabilityDefinition(
            id: .toasts, area: "status", title: "Transient notices",
            spec: "Short-lived confirmations/errors appear as toasts that never steal focus."),
        CapabilityDefinition(
            id: .serverManagement, area: "servers", title: "Server profiles",
            spec:
                "Add, probe, edit and remove server profiles; HostAddress normalizes anything typed; a password is asked for only once a server says it wants one."),
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
            spec: "Starting a chat picks server, working directory, and agent in one flow."),
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
            spec: "Where the client owns its chrome (Linux GTK), a named theme is chosen and persists under tailscode.theme; each theme carries its own light and dark appearance and follows the desktop between them unless pinned, and every colour a label draws from clears WCAG contrast on its own canvas. Where the OS owns the materials (iOS Liquid Glass, macOS system glass), the app follows the system appearance and accent rather than painting a parallel palette that would fight the chrome."),
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
            id: .browserSlot, area: "splits", title: "Browser slot in the split grid",
            spec:
                "A pane can hold a web page. WebTarget reads an address, a bare host, a port on this machine or words to look up; the page renders inside the grid with the platform's own engine, and every split verb treats it like any other pane. The slot asks for an address when it is empty, wears the page's own title in its identity strip, and claims only the chords a browser owns (ctrl+l, ctrl+r, alt+←→, ctrl+±/0, esc) so every other key belongs to the page."),
        CapabilityDefinition(
            id: .videoSlot, area: "splits", title: "Video slot in the split grid",
            spec:
                "A pane can hold a stream instead of a chat. VideoTarget reads a channel, a link or words; the slot plays it inside the grid, and every split verb treats it like any other pane — it splits, the dividers resize it, zoom hides its siblings, closing it hands the space back, and the layout snapshot restores what it was watching. An empty slot asks what to watch, a playing one states the stream's own title in its identity strip, and VideoCommand answers space/m/e/arrows without taking keys from the chat panes. What it costs the grid is stated rather than discovered: VideoNotice's line rides the chooser row that offers a stream and the empty slot's own body, and a playing slot keeps the short of it at the end of its identity strip until it is paused."),
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
