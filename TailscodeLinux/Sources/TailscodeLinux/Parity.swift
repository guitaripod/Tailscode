import TailscodeCore

/// The GTK client's answer to every capability in `CapabilityRegistry`. The switch is exhaustive
/// on purpose: a capability added to the registry refuses to compile this client until someone
/// decides what Linux does about it. One case per line, no `default` — `scripts/parity.sh`
/// parses this file and greps every anchor against `TailscodeLinux/Sources/TailscodeLinux/`.
enum ParityManifest {
    static let client = ParityClient.linux

    static func evidence(for capability: AppCapability) -> ParityEvidence {
        switch capability {
        case .sessionSections: return .implemented("groupIntoSections")
        case .sessionRowStatus: return .implemented("SessionRowModel")
        case .unreadTracking: return .implemented("toggleUnreadSelected")
        case .savedChats: return .implemented("SavedChatStore")
        case .archivedChats: return .implemented("ArchivedChatStore")
        case .deleteSession: return .implemented("deleteSession")
        case .renameSession: return .implemented("renameSession")
        case .forkSession: return .implemented("forkSession")
        case .listFilter: return .implemented("searchEntry")
        case .autoOpenLastSession: return .implemented("lastSession")
        case .liveListUpdates: return .implemented("SessionListStreaming")
        case .rowContextActions: return .implemented("rowMenuRows")
        case .usageGauges: return .implemented("usage-footer")
        case .markdownRendering: return .implemented("PangoMarkdown")
        case .streamingGrowth: return .implemented("applyRows")
        case .toolRows: return .implemented("ToolRowView")
        case .toolDiffs: return .implemented("ToolDiff")
        case .imageParts: return .implemented("ImageCache")
        case .imageViewer: return .implemented("ImageGallery")
        case .subagentCards: return .implemented("subagentRows")
        case .questionCells: return .implemented("asksUserQuestion")
        case .compactionSeam: return .implemented("compaction")
        case .permissionCards: return .implemented("PendingCards")
        case .failureSurface: return .implemented("StatusBand")
        case .authBanner: return .implemented("authBanner")
        case .followBottom: return .implemented("jumpToBottom")
        case .transcriptFind: return .implemented("findEntry")
        case .userEcho: return .implemented("echoedPrompt")
        case .vimComposer: return .implemented("VimEngine")
        case .slashCompletion: return .implemented("SlashCompletion")
        case .attachments: return .implemented("AttachmentIntake")
        case .drafts: return .implemented("restoreDraft")
        case .sendQueue: return .implemented("sendButton")
        case .modelEffortPicker: return .implemented("modelRows")
        case .modelEffortDisplay: return .implemented("ModelBadge")
        case .ultracodeAura: return .implemented("ultracodeAura")
        case .stopTurn: return .implemented("cancelCurrentTurn")
        case .statusBand: return .implemented("StatusBand")
        case .usagePanel: return .implemented("UsagePanel")
        case .toasts: return .implemented("toastOverlay")
        case .serverManagement: return .implemented("ServerManager")
        case .connectDiagnosis: return .implemented("diagnose")
        case .serverSignIn: return .implemented("SignInDialog")
        case .serverSelfUpdate: return .implemented("renderSoftware")
        case .newChat: return .implemented("presentNewChat")
        case .keyboardShortcuts: return .implemented("installKeymap")
        case .shortcutCheatsheet: return .implemented("helpOverlay")
        case .fileBrowser: return .implemented("FileTree")
        case .terminalPane: return .implemented("TerminalPane")
        case .splitPanes: return .implemented("SplitHost")
        case .uiScale: return .implemented("UIScale")
        case .settingsSurface: return .implemented("Preferences")
        case .goalControl: return .implemented("goal-line")
        case .firstRunSetup: return .implemented("FirstRunDialog")
        case .demoMode: return .gap("No demo world; first run can only point at a real server")
        case .activityNotifications: return .implemented("Notifier")
        }
    }
}
