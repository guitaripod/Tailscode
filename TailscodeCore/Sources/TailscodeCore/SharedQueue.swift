import CodingAgentKit
import Foundation
import Synchronization

/// Where a message written behind a running turn is held until it goes.
public enum QueueHolder: Sendable, Hashable {
    /// On the server, which every client of the conversation reads and which drains it.
    case server
    /// On this device, which drains it the moment the turn yields, as it always has.
    case device
}

/// How one conversation's backend takes a queued message, decided once for every client.
///
/// A backend that keeps a queue (``BackendCapabilities/supportsServerQueue``) holds the message
/// itself, so every client of the conversation shows the same queue. A backend that does not (an
/// older bridge, opencode 1) leaves queueing where it has always been, on the device. One more
/// case stays on the device: opencode 2's inbox has no place for a command to wait in, and the
/// first time a server says so the profile remembers it.
public struct QueueRouting: Sendable, Hashable {
    public var serverQueue: Bool
    public var canEdit: Bool
    public var commandsRefused: Bool

    public init(serverQueue: Bool, canEdit: Bool, commandsRefused: Bool = false) {
        self.serverQueue = serverQueue
        self.canEdit = canEdit
        self.commandsRefused = commandsRefused
    }

    public init(capabilities: BackendCapabilities, profileID: String) {
        self.init(
            serverQueue: capabilities.supportsServerQueue,
            canEdit: capabilities.supportsQueueEdit,
            commandsRefused: QueueMemory.refusesCommands(profileID: profileID))
    }

    /// The routing of a backend with no server queue: everything is held on this device.
    public static let device = QueueRouting(serverQueue: false, canEdit: false)

    public func holder(of send: QueuedSend) -> QueueHolder {
        guard serverQueue else { return .device }
        return send.isCommand && commandsRefused ? .device : .server
    }
}

extension QueuedSend {
    /// The words the server queues: a command is its slash form, which is what the bridges run.
    var serverText: String {
        guard case let .command(name, arguments) = kind else { return text }
        return arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)"
    }

    var serverKind: QueuedPrompt.Kind { isCommand ? .command : .prompt }
}

/// One line of the queue a conversation draws, whoever holds it. The server's queue and the
/// messages this device still holds are both drawn from this, so a client has one row to render.
public struct QueueRow: Sendable, Hashable, Identifiable {
    public enum Holder: Sendable, Hashable {
        /// On the server: it is in the queue every client of the conversation shows.
        case server
        /// Written here and not on the server yet: offline or refused, it goes when the server
        /// answers.
        case unsent
        /// Held on this device because the backend keeps no queue of its own for it.
        case device
    }

    public let id: String
    public var text: String
    public var isCommand: Bool
    public var attachmentCount: Int
    public var holder: Holder
    public var canEdit: Bool
    /// The message itself where this device holds it, with its attachments.
    public var local: QueuedSend?

    public init(
        id: String, text: String, isCommand: Bool, attachmentCount: Int, holder: Holder,
        canEdit: Bool, local: QueuedSend? = nil
    ) {
        self.id = id
        self.text = text
        self.isCommand = isCommand
        self.attachmentCount = attachmentCount
        self.holder = holder
        self.canEdit = canEdit
        self.local = local
    }

    /// The identity a transcript row wears, so a row survives the queue changing around it.
    public var key: String { "queued:\(id)" }

    public var title: String {
        guard text.isEmpty, attachmentCount > 0 else { return text }
        return QueueReading.attachmentsOnly(attachmentCount)
    }

    /// What the composer is handed to rewrite: the message as this device holds it, or the words
    /// of the one the server holds, whose attachments stay where they are.
    public var editable: QueuedSend {
        local ?? QueuedSend(id: UUID(uuidString: id) ?? UUID(), text: text)
    }
}

/// The queue a conversation draws: the server's items in the server's order, then whatever this
/// device still holds, in the order it was written.
public struct QueueDisplay: Sendable, Hashable {
    public var rows: [QueueRow]
    /// A Stop paused a queue that has something in it. An empty paused queue shows nothing.
    public var paused: Bool

    public init(rows: [QueueRow] = [], paused: Bool = false) {
        self.rows = rows
        self.paused = paused
    }

    public static let empty = QueueDisplay()

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
    public var last: QueueRow? { rows.last }

    public func row(id: String) -> QueueRow? {
        rows.first { $0.id == id }
    }

    public func row(key: String) -> QueueRow? {
        rows.first { $0.key == key }
    }

    /// Builds the display from the server's account, the messages this device holds, the ids of
    /// the ones a request is carrying to the server right now, and whether the last hand-over
    /// failed. A message bound for the server reads as unsent only once the server has failed to
    /// take it, so one that is simply on its way does not flash a warning. A message the server
    /// already lists is drawn once, as the server's.
    public static func make(
        state: ConversationState?, local: SendQueue, routing: QueueRouting,
        sending: Set<String> = [], failing: Bool = false
    ) -> QueueDisplay {
        var rows: [QueueRow] = []
        let items = routing.serverQueue ? (state?.queue ?? []) : []
        for item in items {
            rows.append(
                QueueRow(
                    id: item.id, text: item.text, isCommand: item.kind == .command,
                    attachmentCount: item.attachments.count, holder: .server,
                    canEdit: routing.canEdit && item.kind == .prompt))
        }
        let known = Set(items.map { $0.id.lowercased() })
        for send in local.items where !known.contains(send.id.uuidString.lowercased()) {
            let id = send.id.uuidString
            let carried = sending.contains(id)
            let holder: QueueRow.Holder
            switch routing.holder(of: send) {
            case .device: holder = .device
            case .server: holder = failing && !carried ? .unsent : .server
            }
            rows.append(
                QueueRow(
                    id: id, text: SendQueueReading.rowTitle(send), isCommand: send.isCommand,
                    attachmentCount: send.attachments.count, holder: holder,
                    canEdit: !send.isCommand && !carried, local: send))
        }
        let paused = routing.serverQueue && state?.queuePaused == true && !items.isEmpty
        return QueueDisplay(rows: rows, paused: paused)
    }
}

/// What came of a press on a queued row.
public enum QueueOutcome: Sendable, Equatable {
    case done
    /// The server had already started the message, so it can no longer be changed.
    case alreadyStarted
    case failed(String)

    /// The sentence to tell the person, when there is one.
    public var message: String? {
        switch self {
        case .done: return nil
        case .alreadyStarted: return QueueReading.alreadySent
        case let .failed(reason): return reason
        }
    }
}

/// What this process remembers about queues between calls, kept apart from the store because none
/// of it should survive a restart: a request in flight is gone with the process, and a profile's
/// refusal is cheap to learn again.
enum QueueMemory {
    struct State {
        var refusedCommands: Set<String> = []
        var flushing: Set<String> = []
        var again: Set<String> = []
        var sending: Set<String> = []
        var cancelled: Set<String> = []
        var failedAt: [String: Date] = [:]
        var failures: [String: Int] = [:]
        var retrying: Set<String> = []
    }

    static let state = Mutex(State())

    static func refusesCommands(profileID: String) -> Bool {
        state.withLock { $0.refusedCommands.contains(profileID) }
    }

    static func refuseCommands(profileID: String) {
        state.withLock { _ = $0.refusedCommands.insert(profileID) }
    }

    static func isFailing(conversation: String) -> Bool {
        state.withLock { $0.failedAt[conversation] != nil }
    }

    static func sendingIDs(conversation: String) -> Set<String> {
        let prefix = conversation + "#"
        return state.withLock { state in
            Set(state.sending.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }
}

/// One conversation's waiting messages as a client holds them, and the traffic that hands them to
/// the server.
///
/// A pane or a view model owns one of these instead of a queue of its own. It reads and changes
/// the device's part of the queue through ``SendQueueStore`` (so two panes and a background watch
/// cannot disagree about it), draws the whole queue with ``display(_:routing:)`` and speaks to the
/// server for the rest: handing over what was written here, editing and cancelling what the
/// server holds, and resuming a queue a Stop paused. Nothing here sends a message to a running
/// turn: where the server keeps the queue it drains it, and what the device drains is only what
/// ``QueueRouting/holder(of:)`` says is the device's.
public final class ConversationQueue: @unchecked Sendable {
    /// How long after a failed hand-over the next one waits, so a server that is down is not
    /// asked on every state the stream delivers.
    public static let retryDelay: TimeInterval = 3
    public static let maxRetryDelay: TimeInterval = 30

    public let profileID: String
    public let sessionID: String
    private let mirror: Mutex<SendQueue>

    public init(profileID: String, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.mirror = Mutex(SendQueueStore.queue(profileID: profileID, sessionID: sessionID))
    }

    private var conversationKey: String { "\(profileID)/\(sessionID)" }

    /// The messages this device holds, as this object last read them.
    public var local: SendQueue { mirror.withLock { $0 } }

    public var isEmpty: Bool { local.isEmpty }
    public var count: Int { local.count }

    /// Reads the store again: another pane, a background watch or a hand-over may have changed it.
    /// Whether this object's copy changed.
    @discardableResult
    public func adopt() -> Bool {
        let stored = SendQueueStore.queue(profileID: profileID, sessionID: sessionID)
        return mirror.withLock { held in
            guard held != stored else { return false }
            held = stored
            return true
        }
    }

    @discardableResult
    private func change<T>(_ body: (inout SendQueue) -> T) -> T {
        var result: T?
        let stored = SendQueueStore.update(profileID: profileID, sessionID: sessionID) { queue in
            result = body(&queue)
        }
        mirror.withLock { $0 = stored }
        return result!
    }

    public func append(_ send: QueuedSend) {
        change { _ = $0.append(send) }
    }

    /// A message that failed to go returns to the head, so a blip cannot reorder what was written.
    public func requeueAtHead(_ send: QueuedSend) {
        change { $0.requeueAtHead(send) }
    }

    @discardableResult
    public func remove(id: UUID) -> QueuedSend? {
        change { $0.remove(id: id) }
    }

    @discardableResult
    public func removeFirst() -> QueuedSend? {
        change { $0.takeFirst() }
    }

    /// Rewrites one message this device holds in place. Empty words with nothing attached is a
    /// deletion.
    @discardableResult
    public func replace(id: UUID, text: String, attachments: [PromptAttachment]) -> Bool {
        change { $0.replace(id: id, text: text, attachments: attachments) }
    }

    /// Takes the head the device itself drains, atomically; nil when the head belongs to the
    /// server's queue or nothing is waiting.
    public func takeDeviceHead(routing: QueueRouting) -> QueuedSend? {
        let taken = SendQueueStore.takeFirst(
            profileID: profileID, sessionID: sessionID, where: { routing.holder(of: $0) == .device })
        adopt()
        return taken
    }

    /// Whether anything the device drains is waiting.
    public func holdsDeviceHead(routing: QueueRouting) -> Bool {
        local.items.first.map { routing.holder(of: $0) == .device } ?? false
    }

    /// Whether anything is waiting to be handed to the server.
    public func holdsServerBound(routing: QueueRouting) -> Bool {
        routing.serverQueue && local.items.contains { routing.holder(of: $0) == .server }
    }

    public func display(_ state: ConversationState?, routing: QueueRouting) -> QueueDisplay {
        QueueDisplay.make(
            state: state, local: local, routing: routing,
            sending: QueueMemory.sendingIDs(conversation: conversationKey),
            failing: QueueMemory.isFailing(conversation: conversationKey))
    }

    /// Writes a message behind a running turn. Where the server keeps the queue it is handed over
    /// at once and held on this device only until the server has it; elsewhere it waits here.
    /// Whether the device's part of the queue changed by the end of the call.
    @discardableResult
    public func submit(
        _ send: QueuedSend, through conversation: AgentConversation, routing: QueueRouting
    ) async -> Bool {
        append(send)
        return await flush(through: conversation, routing: routing)
    }

    /// Hands the server every message this device holds for it, oldest first, each under its own
    /// id so asking again changes nothing. A failure leaves the message and everything behind it
    /// where they are, in order, to go when the server answers again. One flush runs at a time
    /// per conversation; a call made during one is picked up by it. Whether the device's part of
    /// the queue changed.
    @discardableResult
    public func flush(
        through conversation: AgentConversation, routing: QueueRouting, now: Date = Date()
    ) async -> Bool {
        guard routing.serverQueue, beginFlush(now: now) else { return false }
        var attempted: Set<UUID> = []
        var failed = false
        var changed = false
        repeat {
            while !failed, let next = nextForServer(routing: routing, skipping: attempted) {
                attempted.insert(next.id)
                switch await hand(next, to: conversation) {
                case .accepted: changed = true
                case .refused: break
                case .failed: failed = true
                }
            }
            if failed { noteFailure() }
        } while !endFlush(retry: !failed)
        if failed { scheduleRetry(through: conversation, routing: routing) }
        return adopt() || changed
    }

    private func noteFailure() {
        let key = conversationKey
        QueueMemory.state.withLock { state in
            state.failedAt[key] = Date()
            state.failures[key, default: 0] += 1
        }
    }

    /// Tries again on its own once the delay has passed, because a conversation nobody is
    /// touching may deliver no state to ask on. The delay doubles with each failure up to
    /// ``maxRetryDelay``, and the retry stops when this object goes or nothing is left to hand over.
    private func scheduleRetry(through conversation: AgentConversation, routing: QueueRouting) {
        let key = conversationKey
        let delay = QueueMemory.state.withLock { state -> TimeInterval? in
            guard state.retrying.insert(key).inserted else { return nil }
            let failures = max(state.failures[key] ?? 1, 1)
            return min(Self.retryDelay * pow(2, Double(failures - 1)), Self.maxRetryDelay)
        }
        guard let delay else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.1))
            QueueMemory.state.withLock { _ = $0.retrying.remove(key) }
            guard let self, self.holdsServerBound(routing: routing) else { return }
            await self.flush(through: conversation, routing: routing)
        }
    }

    private func beginFlush(now: Date) -> Bool {
        let key = conversationKey
        return QueueMemory.state.withLock { state in
            if state.flushing.contains(key) {
                state.again.insert(key)
                return false
            }
            if let failedAt = state.failedAt[key], now.timeIntervalSince(failedAt) < Self.retryDelay {
                return false
            }
            state.flushing.insert(key)
            return true
        }
    }

    /// Whether the flush is over: it is not when a call came in while it ran and it may go on.
    private func endFlush(retry: Bool) -> Bool {
        let key = conversationKey
        return QueueMemory.state.withLock { state in
            let asked = state.again.remove(key) != nil
            if asked, retry { return false }
            state.flushing.remove(key)
            return true
        }
    }

    private func nextForServer(routing: QueueRouting, skipping attempted: Set<UUID>) -> QueuedSend? {
        let stored = SendQueueStore.queue(profileID: profileID, sessionID: sessionID)
        let current = QueueRouting(
            serverQueue: routing.serverQueue, canEdit: routing.canEdit,
            commandsRefused: QueueMemory.refusesCommands(profileID: profileID))
        return stored.items.first { !attempted.contains($0.id) && current.holder(of: $0) == .server }
    }

    private enum HandOver { case accepted, refused, failed }

    private func itemKey(_ id: String) -> String { "\(conversationKey)#\(id)" }

    private func hand(_ send: QueuedSend, to conversation: AgentConversation) async -> HandOver {
        let id = send.id.uuidString
        let key = itemKey(id)
        QueueMemory.state.withLock { _ = $0.sending.insert(key) }
        defer { QueueMemory.state.withLock { _ = $0.sending.remove(key) } }
        do {
            try await conversation.enqueue(
                send.serverText, id: id, kind: send.serverKind, model: send.model,
                reasoningEffort: send.effort, attachments: send.attachments)
        } catch let error as AgentError {
            guard case .unsupported = error else { return .failed }
            if send.isCommand { QueueMemory.refuseCommands(profileID: profileID) }
            return .refused
        } catch {
            return .failed
        }
        remove(id: send.id)
        QueueMemory.state.withLock { state in
            state.failedAt[conversationKey] = nil
            state.failures[conversationKey] = nil
        }
        let withdrawn = QueueMemory.state.withLock { $0.cancelled.remove(key) != nil }
        if withdrawn { _ = try? await conversation.cancelQueued(id: id) }
        return .accepted
    }

    /// Takes a message out of this device's part of the queue at once, so the row is gone before
    /// anything is asked of the server. Whether the server may hold it too and so has to be asked
    /// to let it go (``cancelOnServer(_:through:)``): a message only this device held, or one still
    /// on its way, which is cancelled the moment the server has it, is settled here.
    public func withdraw(_ row: QueueRow) -> Bool {
        let wasHeldHere = UUID(uuidString: row.id).map { remove(id: $0) != nil } ?? false
        let key = itemKey(row.id)
        let carried = QueueMemory.state.withLock { state -> Bool in
            guard wasHeldHere, state.sending.contains(key) else { return false }
            state.cancelled.insert(key)
            return true
        }
        return !carried && row.holder != .device
    }

    /// Asks the server to drop a message it may hold. A message it already started answers
    /// ``QueueOutcome/alreadyStarted``. For one that never reached it the answer does not matter,
    /// so a server that cannot be reached is not an error there.
    public func cancelOnServer(
        _ row: QueueRow, through conversation: AgentConversation?
    ) async -> QueueOutcome {
        guard let conversation else { return .done }
        do {
            try await conversation.cancelQueued(id: row.id)
            return .done
        } catch QueueError.alreadyStarted {
            return .alreadyStarted
        } catch {
            return row.holder == .unsent ? .done : .failed(AgentErrorText.readable(error))
        }
    }

    /// Takes a message out of the queue, wherever it is held. The device's part is settled before
    /// this returns, so a row is gone the moment it is pressed; `settled` is told what became of
    /// the rest, once, from whichever thread finished it.
    public func cancel(
        _ row: QueueRow, through conversation: AgentConversation?,
        settled: @escaping @Sendable (QueueOutcome) -> Void
    ) {
        guard withdraw(row) else { return settled(.done) }
        Task { settled(await self.cancelOnServer(row, through: conversation)) }
    }

    public func cancel(_ row: QueueRow, through conversation: AgentConversation?) async -> QueueOutcome {
        await withCheckedContinuation { continuation in
            cancel(row, through: conversation) { continuation.resume(returning: $0) }
        }
    }

    /// Rewrites a message this device holds, in place and at once, keeping its turn; clearing it to
    /// nothing takes it out. False when the server holds the message, which has to be asked.
    private func rewrite(_ row: QueueRow, text: String, attachments: [PromptAttachment]) -> Bool {
        guard row.holder != .server else { return false }
        guard let id = UUID(uuidString: row.id) else { return true }
        replace(id: id, text: text, attachments: attachments)
        return true
    }

    /// Rewrites a queued message in place, keeping its turn; clearing it to nothing takes it out.
    /// As with ``cancel(_:through:settled:)`` the device's part is settled before this returns and
    /// `settled` is told what became of the server's.
    public func edit(
        _ row: QueueRow, text: String, attachments: [PromptAttachment],
        through conversation: AgentConversation?,
        settled: @escaping @Sendable (QueueOutcome) -> Void
    ) {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty && (attachments.isEmpty || row.holder == .server) {
            return cancel(row, through: conversation, settled: settled)
        }
        if rewrite(row, text: text, attachments: attachments) { return settled(.done) }
        guard let conversation else { return settled(.done) }
        Task {
            do {
                try await conversation.editQueued(id: row.id, text: text)
                settled(.done)
            } catch QueueError.alreadyStarted {
                settled(.alreadyStarted)
            } catch {
                settled(.failed(AgentErrorText.readable(error)))
            }
        }
    }

    public func edit(
        _ row: QueueRow, text: String, attachments: [PromptAttachment],
        through conversation: AgentConversation?
    ) async -> QueueOutcome {
        await withCheckedContinuation { continuation in
            edit(row, text: text, attachments: attachments, through: conversation) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Lifts the pause a Stop left on the server's queue.
    public func resume(through conversation: AgentConversation) async -> QueueOutcome {
        do {
            try await conversation.resumeQueue()
            return .done
        } catch {
            return .failed(AgentErrorText.readable(error))
        }
    }
}

/// Everything a client says about where a queued message is held, written once so three clients
/// say it the same.
public enum QueueReading {
    public static var alreadySent: String { Localized.text("Already sent.") }

    public static func attachmentsOnly(_ count: Int) -> String {
        count == 1
            ? Localized.text("1 attachment") : Localized.text("%d attachments", count)
    }

    /// The mark a row wears on the text clients: the hourglass for a message waiting its turn, a
    /// dotted circle for one that has not reached the server.
    public static func glyph(_ row: QueueRow) -> String {
        row.holder == .unsent ? "◌" : SendQueueReading.glyph
    }

    /// The symbol it wears on the Apple clients.
    public static func symbol(_ row: QueueRow) -> String {
        row.holder == .unsent ? "arrow.up.circle.dotted" : SendQueueReading.symbol
    }

    /// What the row says under the words: where the message is held, and what to do about it.
    public static func hint(_ row: QueueRow) -> String {
        switch (row.holder, row.canEdit) {
        case (.server, true):
            return Localized.text(
                "Waiting on the server for this turn, where every device sees it — click to edit, or press ↑ in an empty composer"
            )
        case (.server, false):
            return Localized.text("Waiting on the server for this turn, where every device sees it")
        case (.unsent, true):
            return Localized.text(
                "Not sent yet — it goes to the server when it answers. Click to edit")
        case (.unsent, false):
            return Localized.text("Not sent yet — it goes to the server when it answers")
        case (.device, true):
            return Localized.text(
                "Held on this device — it goes when this turn ends. Click to edit, or press ↑ in an empty composer"
            )
        case (.device, false):
            return Localized.text("Held on this device — it goes when this turn ends")
        }
    }

    /// The short form, for a row too narrow for the sentence.
    public static func badge(_ row: QueueRow) -> String {
        switch row.holder {
        case .server: return Localized.text("waiting")
        case .unsent: return Localized.text("not sent")
        case .device: return Localized.text("on this device")
        }
    }

    public static func spoken(_ row: QueueRow, position: Int, of total: Int) -> String {
        let place =
            total > 1
            ? Localized.text("%d of %d waiting", position, total)
            : Localized.text("waiting to send")
        guard row.holder != .server else { return "\(place). \(row.title)" }
        return "\(place). \(row.title). \(badge(row))"
    }

    public static func pausedLine(count: Int) -> String {
        count == 1
            ? Localized.text("Paused: 1 message waiting")
            : Localized.text("Paused: %d messages waiting", count)
    }

    public static var pausedHint: String {
        Localized.text("A stopped turn pauses the queue. Nothing in it goes until you resume")
    }

    public static var resume: String { Localized.text("Resume") }

    /// Whether an up-arrow in the composer should open the last queued message for rewriting:
    /// only from an empty box, because in a half-typed paragraph that key is moving the caret.
    public static func upArrowOpensLast(composerText: String, display: QueueDisplay) -> Bool {
        guard let last = display.last, last.canEdit else { return false }
        return composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
