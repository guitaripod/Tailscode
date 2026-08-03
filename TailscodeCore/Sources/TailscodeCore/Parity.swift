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
    case markdownRendering
    case streamingGrowth
    case toolRows
    case toolDiffs
    case imageParts
    case imageViewer
    case subagentCards
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
    case attachments
    case drafts
    case sendQueue
    case modelEffortPicker
    case modelEffortDisplay
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
    case uiScale
    case settingsSurface
    case goalControl
    case firstRunSetup
    case activityNotifications
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
            id: .markdownRendering, area: "transcript", title: "Markdown prose",
            spec:
                "Assistant prose renders headings, emphasis, lists, links, inline code and fenced code from the shared grammar; never raw markdown source."),
        CapabilityDefinition(
            id: .streamingGrowth, area: "transcript", title: "Parts grow in place",
            spec:
                "A streaming part updates its existing row (reconfigure/diff), never tearing down the transcript or losing scroll position."),
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
                "Typing / offers the backend's availableCommands through the shared SlashCompletion pipeline, keyboard-navigable."),
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
                "The next turn's model and reasoning effort are pickable from availableModels; the choice rides send(model:reasoningEffort:)."),
        CapabilityDefinition(
            id: .modelEffortDisplay, area: "composer", title: "The chip tells the truth",
            spec:
                "The model/effort chip shows what will actually answer: the explicit pick, else the model observed on the last assistant turn, else the session's own record."),
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
            id: .uiScale, area: "app", title: "Type scale",
            spec: "Reading size is adjustable and persists under tailscode.uiScale (or the platform's own type system)."),
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
            id: .activityNotifications, area: "app", title: "The app taps your shoulder",
            spec:
                "A turn ending or a needs-you state in an unfocused session raises a system notification that deep-links back to it."),
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
