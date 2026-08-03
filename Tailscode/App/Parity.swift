import TailscodeCore

/// The phone's answer to every capability in `CapabilityRegistry`. The switch is exhaustive on
/// purpose: a capability added to the registry refuses to compile this client until someone
/// decides what iOS does about it. One case per line, no `default` — `scripts/parity.sh`
/// parses this file and greps every anchor against `Tailscode/`.
enum ParityManifest {
    static let client = ParityClient.iOS

    static func evidence(for capability: AppCapability) -> ParityEvidence {
        switch capability {
        case .sessionSections: return .implemented("HomeSection")
        case .sessionRowStatus: return .implemented("statusPill")
        case .unreadTracking: return .implemented("markUnread")
        case .savedChats: return .implemented("SavedChatsViewController")
        case .archivedChats: return .implemented("ArchivedChatsViewController")
        case .deleteSession: return .implemented("confirmDelete")
        case .renameSession: return .implemented("promptRename")
        case .forkSession: return .implemented("forkConversation")
        case .listFilter: return .implemented("filteredEntries")
        case .autoOpenLastSession: return .notApplicable("the phone launches to the Home board by design; Live cards and deep links reopen work")
        case .liveListUpdates: return .implemented("startStreams")
        case .rowContextActions: return .implemented("sessionMenu")
        case .usageGauges: return .implemented("QuotaCard")
        case .markdownRendering: return .implemented("TextBubbleCell")
        case .streamingGrowth: return .implemented("reconfigureItems")
        case .toolRows: return .implemented("ToolStepRenderer")
        case .toolDiffs: return .implemented("editDiff")
        case .imageParts: return .implemented("ImageBubbleCell")
        case .imageViewer: return .implemented("ImageViewerViewController")
        case .subagentCards: return .implemented("SubagentCardCell")
        case .questionCells: return .implemented("QuestionCell")
        case .compactionSeam: return .implemented("CompactionCell")
        case .permissionCards: return .implemented("PermissionCell")
        case .failureSurface: return .implemented("updateBanner")
        case .authBanner: return .implemented("presentSignIn")
        case .followBottom: return .implemented("syncFAB")
        case .transcriptFind: return .implemented("runFind")
        case .userEcho: return .implemented("LocalEcho")
        case .vimComposer: return .notApplicable("a touch composer; modal editing presumes a hardware keyboard")
        case .slashCompletion: return .implemented("SlashCommandPalette")
        case .attachments: return .implemented("pendingAttachments")
        case .drafts: return .implemented("saveDraft")
        case .sendQueue: return .implemented("flushQueue")
        case .modelEffortPicker: return .implemented("modelBarButton")
        case .modelEffortDisplay: return .implemented("displayedModel")
        case .stopTurn: return .implemented("composerDidTapStop")
        case .statusBand: return .implemented("StatusFacts.from")
        case .usagePanel: return .implemented("UsageViewController")
        case .toasts: return .implemented("presentToast")
        case .serverManagement: return .implemented("ConnectionController")
        case .connectDiagnosis: return .implemented("ConnectDiagnosis")
        case .serverSignIn: return .implemented("ServerSignInViewController")
        case .serverSelfUpdate: return .implemented("BridgeUpdater")
        case .newChat: return .implemented("NewChatFlow")
        case .keyboardShortcuts: return .implemented("KeyBridge")
        case .shortcutCheatsheet: return .implemented("ShortcutCheatsheetViewController")
        case .fileBrowser: return .implemented("FileBrowserViewController")
        case .terminalPane: return .notApplicable("iOS has no shell; the pane presumes the app shares a filesystem with the agent")
        case .uiScale: return .implemented("Theme")
        case .settingsSurface: return .implemented("SettingsViewController")
        case .goalControl: return .implemented("updateGoalChip")
        case .firstRunSetup: return .implemented("ServerSetupViewController")
        case .activityNotifications: return .implemented("NotificationManager")
        }
    }
}
