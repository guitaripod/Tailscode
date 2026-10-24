import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What was done to a rail: clicked, opened or closed from the keyboard, or walked into with the
/// down arrow.
enum RailAct: Sendable {
    case click
    case key
    case down
}

/// What a row needs from the window that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
final class TranscriptContext: @unchecked Sendable {
    var expanded = TranscriptExpansion()
    /// Whether the turn these rows belong to is still open. A tool call the record still says is
    /// running only moves while it is; once the turn has ended the same record is a stale mark.
    var turnOpen = false
    /// The pane's brains, which a brain row's widget reports to and asks the open question of.
    weak var brains: BrainHost?
    /// Opens the card a Task node stands for, by the step's own key.
    var openSubagent: (@Sendable (String) -> Void)?
    /// The newest text of a thought that is still being written. A reasoning row's header counts
    /// its words, so it changes on every arrival — and rebuilding the row for that is a flicker.
    /// The row is updated in place instead, and a body opened afterwards reads the current text
    /// from here rather than the one its closure was built with.
    var liveReasoning: [String: String] = [:]
    /// The decoded previews, which are the device's rather than this transcript's: one store
    /// serves every pane. A preview is downsampled to `bubbleMaxDimension` so a transcript full
    /// of agent screenshots stays small; the original bytes are the disk cache's, read when the
    /// gallery's 1:1 page or a save wants them.
    let pictures: PictureStore
    private var pictureObserver: Int?
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
    /// The workflow runs of this conversation, keyed by the Workflow call that started each. A run
    /// outlives its tool call by minutes, so the card reads its state from here rather than from a
    /// call that has said all it will say.
    var workflowRuns: [String: WorkflowRun] = [:]
    /// The one moment every live reading in this transcript is drawn against — a workflow card's
    /// spinners and elapsed, a subagent row's clock — stamped when a pass begins and moved by the
    /// pane's ticker. A draw whose clocks each read the wall separately is not a draw of one
    /// moment: two cards in the same frame would disagree about what time it is.
    var liveNow: Date = Date()
    var onToggle: (@Sendable (String, Bool) -> Void)?
    /// A press, or a key, on a link rail: the pane owns the one plate every rail's addresses open
    /// onto, so a rail only says which of them it is.
    var railAct: (@Sendable (Int, RailAct) -> Void)?
    /// A rail's widget was destroyed, so a plate that belongs to it must not outlive it.
    var railGone: (@Sendable (Int) -> Void)?
    /// Called with a just-opened disclosure's widget bits: the pane scrolls the minimum needed to
    /// show the opened body, never past the point where the clicked header would leave the top.
    var revealRow: (@Sendable (UInt) -> Void)?
    var requestImage: (@Sendable (FileReference, String) -> Void)?
    var requestSubagent: (@Sendable (ToolCall) -> Void)?
    /// A workflow agent is fetched by its own id: it has no spawning call to name it.
    var requestWorkflowAgent: (@Sendable (String) -> Void)?
    var openImage: (@Sendable (String, String) -> Void)?
    var presentText:
        (@Sendable (_ title: String, _ subtitle: String?, _ body: String, _ mono: Bool) -> Void)?
    /// A short confirmation the window floats over everything — "Command copied".
    var toast: (@Sendable (String) -> Void)?
    /// The words of a turn that said nothing, sent again — the pane's own send, so the retry is a
    /// message like any other rather than a second road into the backend.
    var askAgain: (@Sendable (String) -> Void)?
    /// A board of design alternatives, opened. The pane owns it because reading the mocks is the
    /// server's file route and building one is the pane's own send.
    var openDesign: (@Sendable (DesignSource) -> Void)?
    /// What each board in this transcript turned out to be, so its card can name it rather than
    /// its folder. Filled by the pane the first time a card asks.
    var designBoards: [String: DesignManifest] = [:]
    var requestDesignBoard: (@Sendable (String) -> Void)?
    /// A message still waiting behind the running turn, opened for rewriting. It is the one row in
    /// a transcript that has not happened yet, so it is the one row a press means something on.
    var editQueued: (@Sendable (String) -> Void)?
    /// Lifts the pause a Stop left on the queue, which is the queue's and not any one message's.
    var resumeQueue: (@Sendable () -> Void)?
    var pendingAct: (@Sendable (UUID, PendingSend.Act) -> Void)?
    /// A message being held for a provider's window: sent into it now anyway, opened for
    /// rewriting, or let out of the wait. The pane owns all three because only it knows what the
    /// conversation is sending with.
    var resumeAct: (@Sendable (UUID, ResumeReading.Act) -> Void)?
    /// A turn the server's machine cut off, picked back up or let go on that machine. Both go
    /// through the pane, which is the one place that knows which conversation is being looked at.
    var resumeInterrupted: (@Sendable () -> Void)?
    var dismissInterrupted: (@Sendable () -> Void)?
    /// A right-click on a user message's own row: its id, the row widget's bits and the point to
    /// anchor a popover at. The pane decides what the row may offer (today, only Undo from here,
    /// and only where the backend and the message qualify) because only it holds the backend's
    /// capabilities and the live conversation state.
    var presentMessageMenu: (@Sendable (String, UInt, Double, Double) -> Void)?
    /// The one press a standing revert's banner offers. The pane owns it because only it can tell
    /// whether this device is already mid-press and knows what to do with the composer once the
    /// server answers.
    var restoreRevert: (@Sendable () -> Void)?
    /// The gallery's ear while it is open: a page whose texture was still being fetched repaints
    /// the moment a preview lands, or the original behind it is back on disk.
    var onImageStored: (@Sendable (String) -> Void)?
    /// The pane's ear for a preview landing in the store, whoever asked for it: it gathers the
    /// keys and redraws the rows that show them once.
    var onPictureLanded: (@Sendable (String) -> Void)?

    init(pictures: PictureStore = .shared) {
        self.pictures = pictures
        pictureObserver = pictures.addObserver { [weak self] key, restored in
            guard let self else { return }
            self.onImageStored?(key)
            if !restored { self.onPictureLanded?(key) }
        }
    }

    deinit {
        if let pictureObserver { pictures.removeObserver(pictureObserver) }
    }

    /// A run reads as open when any step inside it is, so folding a step into a run carries the
    /// reader's decision in with it rather than collapsing it.
    func isExpanded(_ key: String) -> Bool { expanded.reads(key) }

    /// The longest side a transcript picture is kept at. A row never draws one larger than a
    /// strip thumbnail or a 340 × 300 poster, so twice that is all a transcript can use: a 4K
    /// screenshot downsampled to this side is ~1.3 MB of texture instead of ~33 MB, a transcript of
    /// two hundred agent screenshots fits the cap whole, and the 1:1 pixel view never touches the
    /// cache — the gallery decodes the original for the page it is showing, one at a time. At
    /// 1600 a long session needed more than the cap, every rebuild asked for every picture the
    /// cache had dropped, and the pictures on screen were evicted by the ones above them: the
    /// strip flickered between its pictures and a "loading…" line on every streamed arrival.
    static let bubbleMaxDimension: Int32 = 720

    /// The decoded preview for a picture, and a mark that a row is using it now. Zero when it is
    /// not decoded.
    func texture(forKey key: String) -> UInt { pictures.texture(forKey: key) }

    func dimensions(forKey key: String) -> (Int32, Int32)? { pictures.dimensions(forKey: key) }

    /// Decodes `data` here and now into the store, and files the original where the gallery reads
    /// it from. For pictures that are already on this machine — the demo's — so a decode on the
    /// main thread is the price of having no network to wait for.
    func storePreview(of data: Data, original reference: FileReference, forKey key: String) {
        ImageCache.save(data, for: reference)
        guard let preview = PictureDecode.preview(of: data) else { return }
        pictures.store(preview, forKey: key)
    }
}

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state was the
/// seconds-long silence between "Loading…" and the transcript. Only messages whose value actually
/// changed are re-folded; a palette change invalidates everything, because the markup carries the
/// palette's colors baked in, and so does the link-card switch, because the cards are rows.
final class TranscriptRowBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private let brains = BrainLedger()
    private let published = NSLock()
    private var brainSettings = BrainBuildSettings()
    private var publishedPolicy: NeuralOpenPolicy?
    private var seamTracker = ModelSeamTracker()
    private var catalog: [ModelInfo] = []

    /// How the brains are drawn this build: the style, which one the person opened and which one
    /// lists its rows. Set from the main loop whenever one changes. It has a lock of its own,
    /// never the build's, so the main loop does not wait for a build that may take its time.
    func setBrains(_ settings: BrainBuildSettings) {
        published.lock()
        brainSettings = settings
        published.unlock()
    }

    /// The models of the machine this pane's chat runs on, which is what turns an answer's model
    /// id into the word a seam compares. Same small lock as the brains' settings, so the main loop
    /// never waits for a build.
    func setCatalog(_ models: [ModelInfo]) {
        published.lock()
        catalog = models
        published.unlock()
    }

    private var currentCatalog: [ModelInfo] {
        published.lock()
        defer { published.unlock() }
        return catalog
    }

    /// The open policy the last build made, which is what a press on a head's chevron toggles.
    /// Published at the point a build makes it, under the same small lock as the settings.
    var brainPolicy: NeuralOpenPolicy? {
        published.lock()
        defer { published.unlock() }
        return publishedPolicy
    }

    private var currentBrainSettings: BrainBuildSettings {
        published.lock()
        defer { published.unlock() }
        return brainSettings
    }

    private func publish(policy: NeuralOpenPolicy?) {
        published.lock()
        publishedPolicy = policy
        published.unlock()
    }

    /// How many turns the brains have read from their messages, for the harness.
    var brainReadings: (partitions: Int, reuses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (brains.turnPartitions, brains.turnReuses)
    }

    /// How the rows are drawn at this moment, which is part of what a remembered row is: a theme,
    /// the link treatment and the density each change the rows themselves.
    private static var look: String {
        MatrixTheme.palette.name + (Preferences.linkEmbeds ? "" : ":plain-links") + ":"
            + Preferences.chatDensity.rawValue
    }

    /// One message's rows, from the process's memo when it holds them.
    ///
    /// The seal is part of what the rows are, so it is part of what the memo remembers: the message
    /// that stops being written is byte-identical to the one that was.
    private static func messageRows(
        _ message: ChatMessage, after prompt: ChatMessage?, writing: String?, turnOpen: Bool,
        look: String, carried: Bool, modelName: (ModelSelection) -> String?
    ) -> [TranscriptRow] {
        let sealed = MessageSegment.isSealed(
            streaming: message.isStreaming, isNewest: message.id == writing, turnOpen: turnOpen)
        let look = carried ? look + ":carried" : look
        if let hit = RowMemo.shared.rows(for: message, sealed: sealed, look: look) { return hit }
        let rows = TranscriptRow.rows(
            for: message, prompt: prompt, cacheMarkup: message.id != writing, sealed: sealed,
            carried: carried, modelName: modelName)
        RowMemo.shared.store(rows, for: message, sealed: sealed, look: look)
        return rows
    }

    /// Makes the rows of a transcript's messages without assembling them into a page, so a chat
    /// that is about to be opened finds each message already drawn. Holds no builder's lock: it
    /// writes only the memo, which every build reads.
    static func warm(
        _ messages: [ChatMessage], turnOpen: Bool, modelName: (ModelSelection) -> String?
    ) {
        let look = Self.look
        let writing = messages.last?.id
        var prompt: ChatMessage?
        var sawUser = false
        for message in messages {
            _ = messageRows(
                message, after: prompt, writing: writing, turnOpen: turnOpen, look: look,
                carried: message.role == .user && !sawUser, modelName: modelName)
            if message.role == .user {
                prompt = message
                sawUser = true
            }
        }
    }

    /// Rows for a state, with the conversation's own account of what it is waiting on.
    func rows(
        state: ConversationState, messages: [ChatMessage]? = nil,
        modelName: (ModelSelection) -> String? = { _ in nil }
    ) -> [TranscriptRow] {
        rows(
            for: messages ?? state.messages, turnOpen: state.status == .running,
            awaiting: BrainAwaiting.read(state), modelName: modelName)
    }

    /// - Parameter turnOpen: whether the conversation is mid-turn. The newest message of an open
    ///   turn is still being written even on a backend that stamps nothing on the record itself
    ///   (`MessageSegment.isSealed`), which is every message the Claude bridge serves.
    /// - Parameter modelName: threaded to ``TranscriptRow/rows(for:prompt:cacheMarkup:sealed:modelName:)``
    ///   for a note's own model naming; not part of the memo key; see that function's doc.
    func rows(
        for messages: [ChatMessage], turnOpen: Bool = false, awaiting: NeuralAwaiting = .none,
        modelName: (ModelSelection) -> String? = { _ in nil }
    ) -> [TranscriptRow] {
        lock.lock()
        defer { lock.unlock() }
        let look = Self.look
        let seams = seamTracker.update(messages, catalog: currentCatalog)
        var brain = brains.pass(
            messages: messages, running: turnOpen, awaiting: awaiting,
            settings: currentBrainSettings)
        publish(policy: brains.policy)
        var all: [TranscriptRow] = []
        let writing = messages.last?.id
        var prompt: ChatMessage?
        var sawUser = false
        for message in messages {
            var rows = Self.messageRows(
                message, after: prompt, writing: writing, turnOpen: turnOpen, look: look,
                carried: message.role == .user && !sawUser, modelName: modelName)
            if message.role == .user {
                prompt = message
                sawUser = true
            }
            if brain != nil { rows = brain!.apply(to: rows, of: message) }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            if let seam = seams[message.id] {
                all.append(TranscriptRow(key: "seam:\(message.id)", kind: .modelSeam(seam)))
            }
            all += rows
        }
        all = TranscriptRow.placeBoard(in: all)
        return TranscriptRow.gallery(Preferences.compactTools ? TranscriptRow.fuse(all) : all)
    }
}

/// One agent action in the order it happened — a thought or a tool call — folded together into a
/// run row the same way the iOS app groups them, so the three clients read the middle of a turn
/// alike.
enum ActivityStep: Hashable {
    case reasoning(key: String, String)
    case tool(key: String, ToolCall)

    /// The row's own durable key, carried in rather than re-derived from where the step ended up.
    /// A step's position inside a run moves whenever the run is re-split, and a key that moves is
    /// a reader's expansion thrown away.
    var key: String {
        switch self {
        case .reasoning(let key, _), .tool(let key, _): return key
        }
    }
}

extension TranscriptRow {
    /// Whether this row draws a call the record still says is running — the rows whose marks have
    /// to be redrawn the moment the turn ends, because nothing about their value changes when it
    /// does.
    var hasOpenWork: Bool {
        switch kind {
        case .tool(let call), .subagent(let call), .workflow(let call):
            return call.status == .running
        case .subagentGroup(let members):
            return members.contains { $0.call.status == .running }
        case .run(let steps):
            return steps.contains {
                if case .tool(_, let call) = $0 { return call.status == .running }
                return false
            }
        default:
            return false
        }
    }
}

/// One line of the transcript, in the CLIs' grammar: the prompt behind an accent rule, the
/// agent's answer as prose at full measure, code as blocks that copy byte-exactly, edits as
/// diffs, reasoning and tool output behind a disclosure, a compaction as a seam, a picture as
/// the picture. No bubbles — the material lives in the chrome around this.
struct TranscriptRow: Hashable {
    enum Kind: Hashable {
        case userText(String, messageID: String)
        case interruption
        /// The markup rides in the row, computed where the rows are computed — off the GLib main
        /// context — so painting a prose row is a label set, not a markdown parse. The palette's
        /// colors are baked into it, which is what makes a theme change a row change the diff sees.
        case agentProse(text: String, markup: String)
        case codeBlock(language: String?, body: String)
        /// The one line under a run of prose that holds every address the run mentioned. It exists
        /// only once the run has closed, so a streaming answer never carries a rail its own growth
        /// would keep pushing down, and its addresses are the whole of its identity.
        case linkRail(urls: [String])
        /// Pictures the agent made, consecutive ones sharing one square of tiles that opens the
        /// conversation's gallery.
        case pictures([GalleryPicture])
        case table(MarkdownTable)
        /// A table still being written: its card, its count, and none of its rows measured.
        case tableDraft(TableDraft)
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        case workflow(ToolCall)
        case file(FileReference, mine: Bool)
        /// A board of design alternatives the agent wrote, standing where the manifest that made it
        /// was written rather than as a line about a file.
        case designBoard(DesignSighting)
        case taskBoard(TaskBoard)
        case compaction(Compaction)
        case answerless(AnswerlessTurn)
        /// A turn that stopped with an error: what happened, the server's own words quoted, and the
        /// one action that asks again. Inline after the turn's own rows.
        case failed(FailedTurn)
        /// Too many sibling agents to read card by card: one line, and the cards behind it.
        case subagentGroup([AgentMember])
        /// What the answer above it took, drawn only where the reader asked for it.
        case responseStats(ResponseStats)
        /// Written, not sent: a prompt waiting behind the turn that is running.
        case queuedSend(QueueRow, position: Int, of: Int)
        /// The queue a Stop paused, with something in it: nothing goes until it is resumed.
        case queuePaused(count: Int)
        case pendingSend(PendingSend, ResumePlan?)
        /// Not ``interruption``, which is the escape key: this is the machine stopping mid-answer.
        case interruptedTurn(InterruptedTurn)
        /// A line the server wrote for the reader rather than the model: quiet, still, never a
        /// message. See ``TranscriptNoteReading``.
        case note(TranscriptNoteLine)
        /// The turn waiting on its provider between attempts. Docked at the end of the transcript
        /// in the same family as ``interruptedTurn``, and gone the moment an attempt answers.
        case providerRetry(ProviderRetryCard)
        /// A revert standing on the conversation, where the messages it set aside used to be.
        /// `restoring` is this device's own press, worn by the button until the server answers.
        case revertBanner(RevertBanner, restoring: Bool)
        /// Everything a turn did before it answered, as one head: the line and, while it is open,
        /// the stage. The member parts' own rows are not built unless the person asked for Rows.
        case brain(BrainRow)
        /// Where the answering model changed inside the conversation: one flat line before the
        /// first answer the new model wrote.
        case modelSeam(ModelSwitch)
        /// The first row of a carried conversation: where it came from, opening the brief it rode in.
        case carried(CarryReading)
        case turnBreak
    }

    /// One agent inside a group: the key its card is opened under, and the call that spawned it.
    struct AgentMember: Hashable {
        let key: String
        let call: ToolCall
    }

    /// More siblings than this from one turn collapse behind a single row.
    static let inlineAgentLimit = 3

    /// One picture of a gallery: the row key its pixels are cached under, and what to fetch.
    struct GalleryPicture: Hashable {
        let key: String
        let reference: FileReference
    }

    let key: String
    let kind: Kind

    /// Whether this row is part of what the person sent — the words, or a picture clipped to
    /// them — which is the block that rises to the top when a prompt goes.
    var isPromptBlock: Bool {
        switch kind {
        case .userText, .pendingSend: return true
        case .file(_, let mine): return mine
        default: return false
        }
    }
}

/// Holds a ``PendingSend`` on a GTK widget without asking the value type to be a class.
final class PendingSendBox: @unchecked Sendable {
    var send: PendingSend
    /// The wait this row is under, when it is under one — carried on the widget so the countdown
    /// ages in place rather than rebuilding a row every second for a clock.
    var plan: ResumePlan?
    init(_ send: PendingSend, plan: ResumePlan? = nil) {
        self.send = send
        self.plan = plan
    }
}
