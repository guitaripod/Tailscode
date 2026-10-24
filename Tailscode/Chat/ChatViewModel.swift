import MidgarCore
import TailscodeCore
import CodingAgentKit
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class ChatViewModel {
    let backend: any CodingAgentBackend
    let session: AgentSession

    let contextID: String
    let conversation: AgentConversation
    let persistKey: String
    var streamTask: Task<Void, Never>?

    var state = ConversationState()
    var selectedModel: ModelSelection?
    var currentEffort: String?
    /// A summoned turn is still running: the aura stays lit after the draft
    /// that lit it has been sent.
    var ultracodeInFlight = false

    var isBound = true
    var onState: ((ConversationState) -> Void)?
    /// A change to what this device is holding — a message sent, taken, failed or queued — and
    /// nothing at all to the server's account of the conversation.
    ///
    /// It is a separate signal because it has a separate cost. Redrawing from a state means
    /// rebuilding every row of the transcript from every message in it, which in a conversation
    /// of a few thousand rows is most of a second of main thread — and the one moment that must
    /// never cost most of a second is the one right after somebody presses Send. A client
    /// answering this redraws only what it is itself holding.
    var onPending: (() -> Void)?
    var onModelChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onQuestionFailed: ((String) -> Void)?
    /// A press on the cut-off card began or ended. It changes only that one row, and it changes it
    /// on this device's news rather than the server's, so it is its own signal.
    var onInterruptionChange: (() -> Void)?
    /// What the server said when it would not take a press on the cut-off card.
    ///
    /// Separate from `onError` because it is not an error to hold somebody up with: the card has
    /// already corrected itself to what the server really has, and this is the sentence saying
    /// why — a report, not a wall.
    var onInterruptionRefused: ((String) -> Void)?
    /// A press this device has made on the cut-off card and has no answer to yet.
    var interruptionPress: InterruptedTurnPress?
    /// A press on Restore began or ended. Separate from `onState` because the revert banner has no
    /// identity of its own to carry the press across a redraw the way the interrupted-turn card's
    /// record does: this device's own news is the only place it can live.
    var onRevertChange: (() -> Void)?
    /// A press on Restore just landed. The banner itself comes down once the server's own account
    /// says the revert is gone, which arrives through the ordinary state stream; this is only the
    /// composer's cue to take back the words it lent the reader, when they are still untouched.
    var onRevertRestored: (() -> Void)?
    /// A press on Undo from here this device has made and has no answer to yet, so a second press
    /// on another message before the first lands cannot race it.
    var isReverting = false
    var isRestoringRevert = false

    init(
        backend: any CodingAgentBackend, session: AgentSession, contextID: String = "default",
        serverName: String = ""
    ) {
        self.backend = backend
        self.session = session
        self.contextID = contextID
        self.persistKey = "\(contextID)/\(session.id)"
        self.conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
        self.serverName = serverName
        self.queue = ConversationQueue(profileID: contextID, sessionID: session.id)
    }

    let serverName: String

    private(set) lazy var displayTitle: String = session.title
    var title: String { displayTitle }

    /// What a notice about this chat calls it. A turn that ends is news before the server has
    /// named the conversation it happened in, so the notification and the row it leaves behind
    /// would both read "New chat" — the words that started it are the name a person recognises.
    var alertTitle: String {
        MissedActivity.name(
            title: displayTitle,
            latestPrompt: state.messages.last { $0.role == .user }?
                .parts.compactMap(\.text).joined(separator: "\n"))
    }

    /// The session as this chat now understands it: the server usually auto-titles
    /// a conversation after its first turn, long after the list that opened it.
    var sessionSnapshot: AgentSession {
        var snapshot = session
        snapshot.title = displayTitle
        snapshot.updatedAt = max(session.updatedAt, state.messages.last?.createdAt ?? .distantPast)
        return snapshot
    }
    var canRename: Bool { backend.capabilities.supportsRenaming }

    /// Whether the machine's Claude is signed out.
    ///
    /// A signed-out CLI does not fail a turn — it answers it, with "Not logged in · Please run
    /// /login" — so the reply is the only hint, and the server's own account state is the proof.
    /// The hint is cheap and wrong sometimes; the proof costs a round trip, so it is only asked for
    /// when the hint appears, and at most twice a minute.
    private(set) var isSignedOut = false
    var onSignInStateChanged: (() -> Void)?
    private var lastAuthCheck = Date.distantPast

    var authenticator: (any AuthenticatingBackend)? { backend as? any AuthenticatingBackend }

    func noteSignedOutIfHinted(_ state: ConversationState) {
        guard authenticator != nil, state.status != .running else { return }
        guard Self.looksSignedOut(state) else { return }
        guard Date().timeIntervalSince(lastAuthCheck) > 30 else { return }
        lastAuthCheck = Date()
        Task { await checkSignIn() }
    }

    func checkSignIn() async {
        guard let authenticator else { return }
        guard let status = try? await authenticator.authStatus() else { return }
        guard isSignedOut != !status.loggedIn else { return }
        isSignedOut = !status.loggedIn
        MidgarLog.info("server signed \(self.isSignedOut ? "out" : "in")", category: .connection)
        onSignInStateChanged?()
    }

    func clearSignedOut() {
        guard isSignedOut else { return }
        isSignedOut = false
        onSignInStateChanged?()
    }

    private static func looksSignedOut(_ state: ConversationState) -> Bool {
        if let failure = state.lastFailure, failure.message.contains("/login") { return true }
        guard let last = state.messages.last, last.role == .assistant else { return false }
        return last.parts.contains { part in
            guard case .text(let text) = part.kind else { return false }
            return text.contains("Please run /login") || text.contains("Not logged in")
        }
    }

    private var manuallyRenamed = false

    func rename(to title: String) async throws {
        try await backend.renameSession(session.id, title: title)
        displayTitle = title
        manuallyRenamed = true
    }

    var onTitleChange: (() -> Void)?

    /// Servers auto-title a conversation after its first turn (the bridge
    /// writes an LLM title shortly after); pick the new name up when the turn
    /// settles so the list, nav bar, and Live Activity all read well.
    func refreshTitleFromServer(delay: Duration = .zero) {
        guard !manuallyRenamed else { return }
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !manuallyRenamed,
                let fresh = try? await backend.listAllSessions(
                    knownDirectories: session.directory.map { [$0] } ?? []
                ).first(where: { $0.id == session.id }),
                !fresh.hasPlaceholderTitle, fresh.title != displayTitle
            else { return }
            displayTitle = fresh.title
            AppActivityController.shared.retitle(sessionID: session.id, title: fresh.title)
            onTitleChange?()
        }
    }

    var supportsModelSelection: Bool { backend.capabilities.supportsModelSelection }
    var supportsReasoningEffort: Bool { backend.capabilities.supportsReasoningEffort }

    /// The model in play, in the shape a catalog lookup wants: the explicit pick, else the model
    /// the transcript or the session record names, wearing a "server" door when no real one is
    /// known. `ModelEffort`/`ModelAbilities` resolve a doorless pick by id.
    private var effectiveSelection: ModelSelection? {
        displayedModel
    }

    /// Effort is a property of the model where the catalog says so (opencode's variants differ
    /// per model); the backend-wide list serves agents whose models all take the same levels. The
    /// rule is Core's, so what this chat offers and what the desktops offer for the same model can
    /// never differ.
    var reasoningEffortOptions: [String] {
        ModelEffort.options(
            models: knownModels, selection: effectiveSelection,
            agentOptions: backend.reasoningEffortOptions)
    }

    private var lastAssistantEffort: String? {
        for message in state.messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// What the chat is actually being answered by, which is not always what
    /// the session record says: a `/model` typed into the CLI changes the model
    /// for every later turn without the server's stored session ever hearing
    /// about it. An explicit pick wins, then the transcript — the last
    /// assistant message names the model that wrote it — and the session record
    /// is the fallback for a chat that has no answer in it yet.
    var displayedModel: ModelSelection? {
        ActiveModel.selection(
            picked: selectedModel, messages: state.messages, session: session,
            catalog: knownModels)
    }

    /// The effort the chip names, and nothing at all where the model takes no effort: a word left
    /// over from the model that answered last is a claim about a control this model does not have.
    var displayedEffort: String? {
        let options = reasoningEffortOptions
        guard !options.isEmpty else { return nil }
        if let kept = ModelEffort.surviving(currentEffort, options: options) { return kept }
        if let stored = ModelEffort.surviving(session.reasoningEffort, options: options) {
            return stored
        }
        return ModelEffort.surviving(lastAssistantEffort, options: options)
    }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }

    /// What the model answering this chat can be handed. Resolved against the model actually in
    /// play rather than only an explicit pick, so a conversation reopened on another device — where
    /// the model comes from the server's own record — narrows its composer the same way.
    var abilities: ModelAbilities {
        ModelAbilities.resolve(
            supportsAttachments: supportsAttachments, models: knownModels,
            selection: effectiveSelection, camera: true)
    }

    /// Whether the current model can receive an image attachment.
    var canAttachImages: Bool { abilities.vision }

    /// Whether the current model can receive non-image file attachments
    /// (e.g. a large paste converted to a text file).
    var canAttachFiles: Bool { abilities.attachments }
    var canClear: Bool { backend.capabilities.supportsClearing }
    var canFork: Bool { backend.capabilities.supportsForking }
    var canAbort: Bool { backend.capabilities.supportsAbort }
    var supportsUsage: Bool { backend.capabilities.supportsSessionUsage }
    var supportsFileBrowsing: Bool { backend.capabilities.supportsFileBrowsing }
    /// A dead stream can't clear a stale `.running`, so busy requires a live
    /// subscription — once the stream terminates, the spinner never outlives it.
    var isBusy: Bool { (streamTask != nil && state.status == .running) || optimisticThinking }

    func fork() async throws -> AgentSession {
        try await backend.forkSession(session.id)
    }

    var trackedSubagents: [SubagentSummary] = []
    var subagentTranscripts: [String: [ChatMessage]] = [:]
    var expandedSubagents: Set<String> = []
    var loadingSubagents: Set<String> = []
    var onSubagentsChange: (() -> Void)?
    var subagentTask: Task<Void, Never>?

    var serverCommands: [AgentCommand] = []
    var onCommandsChange: (() -> Void)?

    var streamGeneration = 0

    /// A stream that ended while someone is still looking at the chat is a terminal failure, not
    /// a request to stop watching — left alone, the transcript freezes on whatever rendered last
    /// until the screen is reopened, which reads as an answer that just stopped arriving. So a
    /// bound chat dials again after a beat; an unbound one stays released, exactly as before.
    var streamRestarts = 0

    /// What this device has written and the server has not echoed back yet, with what became of
    /// each — the row a person sees the instant they press Send, and the only place a send that
    /// never went still holds its words. The ledger and its wording are Core's; this owns the
    /// clock and the network.
    var pending = PendingSendLedger()

    /// Messages a spent provider window stopped, and the moment each goes again. The policy and
    /// every word are Core's; this owns the one clock that fires them and the copy on disk, so a
    /// window that opens while the phone is in a pocket is still explained rather than lost.
    var resume = ResumeLedger()
    var resumeClock: Task<Void, Never>?
    /// How many times this conversation has already been sent into the wall and bounced. A plan
    /// that fires and dies produces a *fresh* failure, and reading each fresh failure as a first
    /// attempt is how a bounded retry becomes an unbounded one — so the count lives here, beside
    /// the conversation, and only a turn that is not in a failed state clears it.
    var resumeAttempts = 0

    /// A plan taken up or laid down, so the app around the chat can put a notification on the
    /// window's reopening and take it off again.
    var onResumeChange: ((ResumePlan?) -> Void)?

    var optimisticThinking = false
    var turnSawRunning = false
    /// Whether the turn this chat last watched has been put to rest on the Lock Screen already, so
    /// a conversation that sits idle is not settled again on every state it streams.
    var cardSettled = false

    /// The messages written while a turn was running. Held here rather than handed to the server
    /// precisely so they can still be changed: the next thing you type is the thing you most often
    /// want to reword once you have read another paragraph of the answer.
    let queue: ConversationQueue
    var lastSent: QueuedSend?

    var heldBaseline: Int?

    /// Why the queue stopped draining, when it has. A queue that quietly stopped looks exactly
    /// like one waiting its turn, and the difference is the only thing worth knowing.
    var queueHold: String?

    /// Gates auto-flush after a failure without depending on
    /// `ConversationState.lastFailure`, which the Kit only clears on a new
    /// send, a `.live` transition, or a successful refresh — a failure while
    /// the connection never left `.live` would leave it set and wedge the
    /// queue forever. This clears the moment a turn is genuinely running
    /// again, and any explicit user send clears it outright.
    var queueHeldAfterFailure = false

    /// Re-dials the event stream and re-fetches the transcript. Called on foregrounding: the
    /// socket may be half-open after suspension (reads hang, no error), so waiting for it to fail
    /// isn't enough — the reconnect has to be forced. The conversation reconnects underneath us
    /// rather than the stream being torn down and rebuilt, so no snapshot is lost in the gap and
    /// a second observer (another window, the session list) is not disturbed. A stream that ended
    /// on its own is started rather than reconnected — there is nothing to re-dial.
    var lastResync: Date = .distantPast

    var sendTask: Task<Void, Never>?
    var firstAnswer = FirstAnswerClock()

    /// Sends optimistically: the prompt echoes into the transcript, the
    /// thinking state engages, and the Live Activity starts immediately —
    /// ActivityKit only allows starting one while foregrounded, so waiting
    /// for the server's `.running` event breaks the send-and-background flow.
    /// The delivery itself is bounded to 15s (`prompt_async` returns
    /// immediately when reachable), so a dead tunnel fails fast instead of
    /// hanging in the thinking state for minutes.
    var sendGeneration = 0

    var knownModels: [ModelInfo] = []

    var cachedUsage: (value: AgentUsage?, at: Date)?

    /// One failed turn otherwise poisons the session: the Kit keeps
    /// `lastFailure` until reconnect, so the banner would resurface the old
    /// error after every later successful turn. A new send or an explicit
    /// banner tap acknowledges the current failure.
    var dismissedFailure: BackendFailure?
}
