import TailscodeCore

/// The Mac's answer to every capability in `CapabilityRegistry`. The switch is exhaustive on
/// purpose: a capability added to the registry refuses to compile this client until someone
/// decides what the Mac does about it. One case per line, no `default` — `scripts/parity.sh`
/// parses this file and greps every anchor against `TailscodeMac/`.
enum ParityManifest {
    static let client = ParityClient.mac

    static func evidence(for capability: AppCapability) -> ParityEvidence {
        switch capability {
        case .sessionSections: return .implemented("groupIntoSections")
        case .sessionRowStatus: return .implemented("SessionRowModel")
        case .unreadTracking: return .implemented("markUnread")
        case .savedChats: return .implemented("SavedChatStore")
        case .archivedChats: return .implemented("ArchivedChatStore")
        case .deleteSession: return .implemented("deleteSession")
        case .renameSession: return .implemented("renameSession")
        case .forkSession: return .implemented("forkSession")
        case .listFilter: return .implemented("searchField")
        case .autoOpenLastSession: return .implemented("lastSession")
        case .liveListUpdates: return .implemented("SessionListStreaming")
        case .rowContextActions: return .implemented("rowMenu")
        case .usageGauges: return .implemented("usageFooter")
        case .markdownRendering: return .implemented("MacMarkdown")
        case .streamingGrowth: return .implemented("applyRows")
        case .toolRows: return .implemented("ToolRowView")
        case .toolDiffs: return .implemented("ToolDiff")
        case .imageParts: return .implemented("ImageStore")
        case .imageViewer: return .implemented("ImageViewer")
        case .subagentCards: return .implemented("SubagentRowView")
        case .questionCells: return .implemented("PendingCards")
        case .compactionSeam: return .implemented("Compaction")
        case .permissionCards: return .implemented("PendingCards")
        case .failureSurface: return .implemented("StatusBandView")
        case .authBanner: return .implemented("authBanner")
        case .followBottom: return .implemented("jumpButton")
        case .transcriptFind: return .implemented("FindBar")
        case .userEcho: return .implemented("echoed")
        case .vimComposer: return .implemented("VimEngine")
        case .slashCompletion: return .implemented("CompletionPopover")
        case .attachments: return .implemented("AttachmentIntake")
        case .drafts: return .implemented("tailscode.draft")
        case .sendQueue: return .implemented("Queue")
        case .modelEffortPicker: return .implemented("PillsRow")
        case .modelEffortDisplay: return .implemented("ModelBadge")
        case .stopTurn: return .implemented("cancelCurrentTurn")
        case .statusBand: return .implemented("StatusBandView")
        case .usagePanel: return .implemented("UsagePanel")
        case .toasts: return .implemented("ToastPresenter")
        case .serverManagement: return .implemented("ServersWindow")
        case .connectDiagnosis: return .implemented("diagnose")
        case .serverSignIn: return .implemented("SignInSheet")
        case .serverSelfUpdate: return .implemented("updateStatus")
        case .newChat: return .implemented("NewChatSheet")
        case .keyboardShortcuts: return .implemented("ShortcutSet")
        case .shortcutCheatsheet: return .implemented("cheatsheet")
        case .fileBrowser: return .implemented("FileTreePane")
        case .terminalPane: return .implemented("TerminalPane")
        case .uiScale: return .implemented("UIScale")
        case .settingsSurface: return .implemented("PreferencesWindow")
        case .goalControl: return .implemented("setGoal")
        case .firstRunSetup: return .implemented("FirstRunWindow")
        case .activityNotifications: return .implemented("MacNotifier")
        }
    }
}
