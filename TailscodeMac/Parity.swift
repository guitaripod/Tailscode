import TailscodeCore

/// The Mac's answer to every capability in `CapabilityRegistry`. The switch is exhaustive on
/// purpose: a capability added to the registry refuses to compile this client until someone
/// decides what the Mac does about it. One case per line, no `default` — `scripts/parity.sh`
/// parses this file and greps every anchor against `TailscodeMac/`.
///
/// This client ships two ways, so it answers twice. `declared(for:)` is always compiled whole and
/// states both truths side by side; `evidence(for:)` is the one this copy happens to be. The `#if`
/// deciding which copy is running lives in exactly one place in this file — put one inside a case
/// body and the manifest would state only the half that was compiled, which is precisely the half
/// no reader of the file, and no static reader of the matrix, could ever see.
enum ParityManifest {
    static let client = ParityClient.mac

    #if TAILSCODE_MAS
        static let distribution = ParityDistribution.appStore
    #else
        static let distribution = ParityDistribution.direct
    #endif

    static func evidence(for capability: AppCapability) -> ParityEvidence {
        declared(for: capability).resolved(for: distribution)
    }

    static func declared(for capability: AppCapability) -> ParityEvidence {
        switch capability {
        case .sessionSections: return .implemented("groupIntoSections")
        case .sessionRowStatus: return .implemented("observedPresence")
        case .activityIconography: return .implemented("ActivityBadgeView")
        case .sessionPinning: return .implemented("menuTogglePinned")
        case .unreadTracking: return .implemented("markUnread")
        case .savedChats: return .implemented("SavedChatStore")
        case .archivedChats: return .implemented("ArchivedChatStore")
        case .deleteSession: return .implemented("deleteSession")
        case .bulkSelection: return .implemented("SidebarBulkBar")
        case .bulkRangeSelection: return .implemented("rangeSelect")
        case .bulkSplit: return .implemented("openMarkedSplit")
        case .splitTabs: return .implemented("goToSplitMember")
        case .renameSession: return .implemented("renameSession")
        case .forkSession: return .implemented("forkSession")
        case .transcriptSearch: return .implemented("runTranscriptSearch")
        case .listFilter: return .implemented("searchField")
        case .autoOpenLastSession: return .implemented("lastSession")
        case .liveListUpdates: return .implemented("SessionListStreaming")
        case .rowContextActions: return .implemented("rowMenu")
        case .rowSnippet: return .implemented("if let snippet = model.snippet")
        case .rowFacets: return .implemented("detailText")
        case .modelIdentityTint: return .implemented("chipText")
        case .usageGauges: return .implemented("usageFooter")
        case .quotaExhaustion: return .implemented("quotaNotice")
        case .quotaScoping: return .implemented("quotasForModels")
        case .markdownRendering: return .implemented("MacMarkdown")
        case .transcriptLinks: return .implemented("extractBareLinks")
        case .syntaxHighlighting: return .implemented("RowKit.code")
        case .streamingGrowth: return .implemented("applyRows")
        case .streamCascade: return .implemented("CascadePainter")
        case .toolRows: return .implemented("ToolRowView")
        case .toolDiffs: return .implemented("ToolDiff")
        case .compactActivity: return .implemented("ToolRowView.makeRun")
        case .imageParts: return .implemented("ImageStore")
        case .imageViewer: return .implemented("ImageViewer")
        case .subagentCards: return .implemented("SubagentRowView")
        case .workflowCard: return .implemented("WorkflowCardView")
        case .taskBoard: return .implemented("TaskBoardView")
        case .questionCells: return .implemented("PendingCards")
        case .compactionSeam: return .implemented("Compaction")
        case .permissionCards: return .implemented("PendingCards")
        case .failureSurface: return .implemented("StatusBandView")
        case .answerlessTurn: return .implemented("answerless")
        case .interruptedTurn: return .implemented("interruptedTurn")
        case .authBanner: return .implemented("authBanner")
        case .followBottom: return .implemented("jumpButton")
        case .transcriptFind: return .implemented("FindBar")
        case .userEcho: return .implemented("PendingSendLedger")
        case .vimComposer: return .implemented("VimEngine")
        case .slashCompletion: return .implemented("renderCompletion")
        case .slashDispatch: return .implemented("SlashDispatch.decide")
        case .commandCatalog: return .implemented("CommandCatalogWindow")
        case .attachments: return .implemented("AttachmentIntake")
        case .drafts: return .implemented("DraftStore")
        case .sendQueue: return .implemented("editQueued")
        case .modelEffortPicker: return .implemented("PillsRow")
        case .unifiedModelChooser: return .implemented("ModelChooserSheet")
        case .modelEffortDisplay: return .implemented("ModelBadge")
        case .modelCapabilitySurfacing: return .implemented("dropUnsendableAttachments")
        case .responseStats: return .implemented("responseStats")
        case .ultracodeAura: return .implemented("UltracodeAura")
        case .stopTurn: return .implemented("cancelCurrentTurn")
        case .statusBand: return .implemented("StatusBandView")
        case .usagePanel: return .implemented("UsagePanel")
        case .usageAnalytics: return .implemented("AnalyticsCardRenderer")
        case .deepseekBalance:
            return .partial(
                "DeepSeekBalance",
                missing:
                    "The key is held in the same Keychain the profiles use, the fetch is local and throttled, and the balance is drawn as money — no bar, no invented cap — in the sidebar strip, the quota panel and the settings row. What it does not yet reach is the model chooser's walls: those read the quota list MainWindowController.collectQuotas gathers from the servers, which no DeepSeek reading is folded into, so an empty balance greys no DeepSeek row.")
        case .sessionSpend: return .implemented("SpendPanelViewController")
        case .toasts: return .implemented("ToastPresenter")
        case .serverManagement: return .implemented("ServersWindow")
        case .tailnetDiscovery:
            return .varies(
                direct: .implemented("DiscoveryPanel"),
                appStore: .gap(
                    "the panel is still compiled but nothing opens it and nothing would fill it — Find my machines is absent from the servers window and the survey answers sandboxed with no peers at all — so setting a machine up in this copy is the typed address and nothing else"),
                because:
                    "The scan is the tailnet asked for its own peers by running the Tailscale command line, and a container may neither spawn that binary nor reach the socket behind it. What the store copy owes is another road to the peer list, not a scan rewritten to always come back empty.")
        case .connectDiagnosis: return .implemented("diagnose")
        case .serverSignIn: return .implemented("SignInSheet")
        case .serverSelfUpdate: return .implemented("updateStatus")
        case .serverRestart: return .implemented("restartTapped")
        case .serverAutoUpdate: return .implemented("AutoUpdateRow")
        case .newChat: return .implemented("NewChatSheet")
        case .newChatPathCompletion: return .implemented("NewChatSheet")
        case .newChatDefaults: return .implemented("renderDefaults")
        case .newChatFailure: return .implemented("NewChatStatusView")
        case .keyboardShortcuts:
            return .varies(
                direct: .implemented("ShortcutSet"),
                appStore: .implemented(
                    "keepShortcutsWhereTheContainerCanReachThem"),
                because:
                    "Every key resolves through the same registry either way, but the file they are rebound in is not the same file: ~/.config/tailscode is outside the container, so the store copy keeps keybindings.json in the Application Support folder it does hold, and reveals it in Finder rather than opening it in whatever a person edits text with — a door the container does not have.")
        case .shortcutCheatsheet: return .implemented("cheatsheet")
        case .gitState:
            return .varies(
                direct: .implemented("GitPanelViewController"),
                appStore: .partial(
                    "GitPanelViewController", missing: "a claude-bridge conversation reads its repository exactly as it always did, over GET /git; an opencode one does not, because that road runs git on this Mac through LocalGit.Shell and a container may not spawn it — so on those chats the chip and the panel go quiet, which the git doctrine already reads as this server cannot say rather than as a clean tree"),
                because:
                    "The Kit is a package and cannot be told which copy of the app it was linked into, so the local shell is compiled either way; inside the sandbox it simply comes back with nothing, which is the one degradation this surface was written to survive.")
        case .fileBrowser:
            return .notApplicable(
                "the inspector is gone: a tree of the server's files beside a conversation is a second way to say something the composer already says better with @, and nobody reached for it on either desk")
        case .terminalPane:
            return .varies(
                direct: .implemented("TerminalPane"),
                appStore: .notApplicable(
                    "there is no pane, no Terminal menu item and no toolbar button — this copy is not a build that hides its shell, it is a build that has none"),
                because:
                    "The pane runs a login shell against this Mac's own directories, and a copy the App Store installs is sealed in a container that may neither spawn that process nor see the folder it would run in. A shell that could only reach the app's own container is not a shell beside the conversation, and offering one would be worth less than saying so.")
        case .splitPanes: return .implemented("SplitPaneHost")
        case .videoSlot:
            return .varies(
                direct: .implemented("VideoSlotView"),
                appStore: .notApplicable(
                    "the slot type is not compiled at all, so no pane can become one and a layout snapshot that held a stream restores an empty pane — though the pane chooser still draws Core's Watch something… row, which in this copy opens nothing and owes a hide"),
                because:
                    "Playing a page means resolving it to a stream with yt-dlp first, another program on this Mac the container has no way to reach, so the store copy cannot get as far as the frames AVKit would draw.")
        case .watchDirectory:
            return .varies(
                direct: .implemented("WatchBoardView"),
                appStore: .gap(
                    "the board is not compiled, and the one part of it that lived outside a slot — the chooser row's summary of who is live — is never fetched here, so that row is left saying what it always said"),
                because:
                    "The board only ever appears inside an empty video slot, so it went out with the slot it lives in. Its own sources are plain requests a container is free to make, which is what makes this work owed rather than work refused.")
        case .watchAccounts:
            return .varies(
                direct: .implemented("WatchSignInSheet"),
                appStore: .gap(
                    "the sheet is not compiled and the settings section that states each site as a fact is absent, so there is nowhere in this copy to sign in, to sign out, or to read that an account is held"),
                because:
                    "Nothing in the device flow needs a subprocess — it is a request, a short code confirmed in the person's own browser, and the Keychain — so signing in left with the board it feeds rather than with anything the sandbox forbids.")
        case .browserSlot:
            return .varies(
                direct: .implemented("WebSlotView"),
                appStore: .notApplicable(
                    "no chooser row offers a page, no layout restores one, and there is no other way in, so this copy holds no browser at all"),
                because:
                    "WebTarget takes any address, a bare host, or words to look up, which is the whole of what the age rating means by unrestricted web access — and the person who asked for this build says he has never opened a page in a pane on either desktop. A feature nobody uses is not worth re-rating a shared record over, so the store copy simply does not have one.")
        case .newPaneChooser: return .implemented("showChooser")
        case .chatDragToPane: return .implemented("onChatDropped")
        case .clickToActivate: return .implemented("pressLanded")
        case .uiScale: return .implemented("UIScale")
        case .typeRamp: return .implemented("MacTheme.Ramp")
        case .themePicker: return .implemented("MacTheme.Chrome")
        case .settingsSurface: return .implemented("PreferencesWindow")
        case .goalControl: return .implemented("setGoal")
        case .firstRunSetup:
            return .varies(
                direct: .implemented("FirstRunWindow"),
                appStore: .partial(
                    "FirstRunWindow", missing: "the half of the checklist that proves the typed address still runs whole — probeCandidates is a request and this copy has the network — but the half that proves this Mac is on a tailnet cannot run at all, so that step states that it cannot see instead of ticking or failing"),
                because:
                    "A checklist proves what it is allowed to run, and an address is a request while a machine's own tailnet presence is a program.")
        case .tailscaleReadiness:
            return .varies(
                direct: .implemented("TailnetRemedyView"),
                appStore: .partial(
                    "TailnetRemedyView", missing: "the reading is always the sandboxed one, which the doctrine counts as an honest state rather than a hole — but this copy cannot tell up from signed out from not installed, and the door it offers is the Tailscale app or the download page rather than tailscale up run where the person is already looking"),
                because:
                    "All four of the other states are read out of the command line's own JSON, which a container may not run, so the store copy has exactly the one state that was written for it and none of the ones that need a subprocess.")
        case .demoMode: return .implemented("enterDemoMode")
        case .activityNotifications: return .implemented("MacNotifier")
        case .hapticFeedback: return .partial("MacHaptics", missing: "the trackpad cannot compose: three canned patterns stand in for the recipes, so strength gates which beats survive but never how hard one lands, and a cue is felt only while a hand is on the trackpad")
        case .missedActivity: return .implemented("ActivityInbox.ordered")
        case .usageWidgets:
            return .varies(
                direct: .partial(
                    "publishWidgetSnapshot", missing: "the snapshot is written to the shared container on every quota refresh and the widget draws WidgetGlance from it, but the theme mirror is never written on this desk — ThemeSelection.mirrorSuiteName is assigned only in the phone's own AppPreferences — so a Mac widget wears the fallback palette rather than the theme the app it opens is wearing"),
                appStore: .gap(
                    "this target carries no widget extension and no app group, so there is nothing outside the app to read at all: publishWidgetSnapshot compiles to a no-op and the quotas are readable only by opening the window"),
                because:
                    "A widget is a second bundle and a container both copies would have to share, and the store target ships neither yet. The missing theme mirror is the older debt of the two and belongs to both.")
        case .homeQuickActions: return .notApplicable("macOS has no Home screen to long-press; the Dock is the OS's own launcher, and the destinations the phone's quick actions reach are one click inside the app's window")
        case .presenceOrb: return .implemented("PresenceOrbView")
        case .auroraStream: return .gap("the Mac has the same Metal and the same CADisplayLink and wants this; what it does not have is the glyph geometry, which the transcript reads out of its own NSLayoutManager per row — the iOS mapper is written against UITextView's stack and the port is real work rather than a recompile. Until then every answer on this desk is written by the settled renderer, which is the whole product's floor and loses no meaning")
        case .gameCenter:
            return .partial(
                "MacGameCenter",
                missing:
                    "the trophy case renders and reports through the same coordinator as iOS, but neither copy of this app can authenticate GKLocalPlayer: the dogfood build is ad-hoc signed without the com.apple.developer.game-center entitlement, and the store target leaves that entitlement deliberately out of the first submission; the surface states the unavailability instead of hiding")
        case .projectBoard: return .implemented("toggleProjectScope")
        case .quickAsk: return .implemented("QuickAskPanel")
        case .summonAnywhere: return .implemented("MacSummon")
        case .updateCenter:
            return .varies(
                direct: .partial(
                    "UpdateWindowController", missing: "every server is asked, classified by Core and installed end to end through its own restart, and the app's own row reads the checkout it was built from — but nothing here installs the app itself: rebuilding the .app takes xcodegen and a multi-minute xcodebuild whose product is the very bundle the process is executing out of, so the row states that obstacle and hands over the exact build command instead, and Update everything covers the servers only"),
                appStore: .implemented("UpdateWindowController"),
                because:
                    "The whole of the debt on a self-built copy is that nothing here can replace the app. A copy the App Store installed is a copy the App Store replaces, so that job is not this window's to owe: the servers are handled identically, and the app's own row states what this copy is rather than a version it has no store record to check.")
        case .designBoards: return .implemented("DesignBoardWindowController")
        case .linkEmbeds: return .gap("transcript links render as touchable text; the preview card owes an AppKit cell and a metadata fetcher, which the iOS LinkEmbedCell already carries and Core can share once it exists")
        case .proUnlock:
            return .varies(
                direct: .notApplicable(
                    "a build somebody installed themselves has no receipt and never will, so this copy sells nothing and gates nothing"),
                appStore: .implemented("MacProStore"),
                because:
                    "The unlock is a purchase, and a purchase is a receipt from the App Store — only one of the two Mac builds has any relationship with it. The store copy asks for the same product the phone does, so a supporter is already a supporter here; the direct copy is simply open.")
        case .videoForge: return .implemented("ForgeSlotView")
        case .forgeEntry: return .implemented("ForgeSheet")
        case .forgeSetup: return .implemented("ForgeSetupSheet")
        case .autoResume: return .implemented("armResume")
        case .forgeHistory: return .implemented("presentClipMenu")
        case .videoLane:
            return .notApplicable(
                "a Mac has no swipe to give a composer and no front-door prompt box to give lanes — its chat composer lives in each pane, and video is already one press away as the toolbar's own first-class control (forgeEntry) and its chord, which is this desk's button-shaped road to the same surface")
        case .reviewPrompt: return .gap("the policy is Core's and already shared, and macOS has the same SKStoreReviewController to ask with — what this client owes is a MacReviewPrompt coordinator wired to its own turn-completion and MacGameCenter trophy paths, the two signals iOS now hooks")
        }
    }
}

/// What a two-answer manifest can get wrong that the compiler cannot catch. A `varies` that says
/// why nothing, that hides another `varies` inside a half, or whose two halves are the same answer
/// is not two truths — it is one truth wearing the shape of two, which is worse than the single
/// answer it replaced, because a reader would stop looking for the difference.
enum MacParity {
    static func audit() -> [String] {
        var problems: [String] = []
        for capability in AppCapability.allCases {
            guard
                case .varies(let direct, let appStore, let because) =
                    ParityManifest.declared(for: capability)
            else { continue }
            let name = ".\(capability.rawValue)"
            if because.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(name) varies but says nothing about why")
            }
            if !direct.isSingular {
                problems.append("\(name) nests a varies inside its direct half")
            }
            if !appStore.isSingular {
                problems.append("\(name) nests a varies inside its appStore half")
            }
            if signature(direct) == signature(appStore) {
                problems.append("\(name) varies into two answers that are the same answer")
            }
        }
        return problems
    }

    /// An answer flattened to the text a reader would compare, so two halves that differ only in
    /// how they were written still count as differing, and two that read identically do not.
    private static func signature(_ evidence: ParityEvidence) -> String {
        switch evidence {
        case .implemented(let anchor): return "implemented:\(anchor)"
        case .partial(let anchor, let missing): return "partial:\(anchor):\(missing)"
        case .gap(let reason): return "gap:\(reason)"
        case .notApplicable(let reason): return "notApplicable:\(reason)"
        case .varies(let direct, let appStore, let because):
            return "varies:\(signature(direct)):\(signature(appStore)):\(because)"
        }
    }
}
