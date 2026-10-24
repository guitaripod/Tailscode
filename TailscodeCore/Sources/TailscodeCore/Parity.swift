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
    case homeBoard
    case sessionRowStatus
    case activityIconography
    case backgroundWork
    case backgroundStop
    case sessionPinning
    case unreadTracking
    case savedChats
    case savedChatSync
    case sessionMarks
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
    case tableRendering
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
    case transcriptNotes
    case providerRetry
    case conversationRevert
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
    case sharedQueue
    case modelEffortPicker
    case modelEffortDial
    case modelPresets
    case unifiedModelChooser
    case modelEffortDisplay
    case modelCapabilitySurfacing
    case modelParty
    case agentsBoard
    case agentPeek
    case agentsHour
    case modelSeam
    case carryChat
    case responseStats
    case ultracodeAura
    case stopTurn
    case statusBand
    case usagePanel
    case usageAnalytics
    case deepseekBalance
    case ollamaCloudUsage
    case sessionSpend
    case contextWindow
    case range
    case toasts
    case serverManagement
    case tailnetDiscovery
    case ompServer
    case openCodeTwoServer
    case connectDiagnosis
    case serverAccess
    case firstRunPlan
    case pairingLink
    case pairingScan
    case serverSignIn
    case machinePermissions
    case serverSelfUpdate
    case serverAutoUpdate
    case serverRestart
    case newChat
    case newChatDefaults
    case newChatFailure
    case newChatPathCompletion
    case serverFolderBrowser
    case keyboardShortcuts
    case shortcutCheatsheet
    case fileBrowser
    case gitState
    case terminalPane
    case splitFromTerminal
    case listBesideConversation
    case splitPanes
    case newPaneChooser
    case chatDragToPane
    case clickToActivate
    case paneDensity
    case paneArrangements
    case paneOverflow
    case paneResizeByKey
    case paneRearrange
    case safeRestore
    case flightRecorder
    case resourceGuard
    case pointerFeedback
    case uiScale
    case typeRamp
    case themePicker
    case settingsSurface
    case goalControl
    case firstRunSetup
    case emptyWelcome
    case addAnotherMachine
    case tailscaleReadiness
    case demoMode
    case activityNotifications
    case missedActivity
    case liveActivity
    case turnEndWhileAway
    case videoSlot
    case watchDirectory
    case watchAccounts
    case browserSlot
    case imageGenSlot
    case livePreview
    case previewLenses
    case previewTouch
    case imageLane
    case imageLibrary
    case imagePromptHelper
    case imageLivePreview
    case studioSheet
    case hapticFeedback
    case homeQuickActions
    case usageWidgets
    case presenceOrb
    case auroraStream
    case gameCenter
    case projectBoard
    case quickAsk
    case quickAskClipboard
    case summonAnywhere
    case updateCenter
    case designBoards
    case linkEmbeds
    case chatDensity
    case neuralTrace
    case reviewPrompt
    case proUnlock
    case supporterInvitation
    case videoForge
    case forgeEntry
    case forgeSetup
    case mediaReadiness
    case forgeHistory
    case videoLane
    case videoPromptHelper
    case videoLivePreview
    case videoFirstFrame
    case videoSound
    case videoEstimate
    case videoLight
    case voiceCall
    case setupChecklist
    case serverCapabilities
    case autoResume
    case freshCanvas
    case chooserBriefing
    case delegateBoard
    case delegateComposer
    case delegateRun
    case delegateApproval
    case delegateProGate
    case betaMark
    case delegateClassDefaults
    case delegateNextSteps
    case delegateSetup
    case delegateNotices
    case delegateReview
    case delegateHandoff
    case rateAndShare
    case midgarPortal
    case worldClock
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
    /// The registry's chunks in the order the matrix prints them; each lives in its own
    /// `CapabilityRegistry+` file so no one file holds the whole table.
    public static let all: [CapabilityDefinition] =
        chatAndTranscript + composerAndServers + appAndSplits

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
