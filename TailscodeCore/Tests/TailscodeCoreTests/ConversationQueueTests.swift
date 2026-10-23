import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A server that keeps the queue the way the bridges do, with its failures told by hand: it can
/// be unreachable for a number of enqueues, can refuse commands the way opencode 2 does, and can
/// hold an enqueue open so a test can act while a request is out.
private final class QueueServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false,
        supportsAbort: true, supportsServerQueue: true, supportsQueueEdit: true)

    private let lock = NSLock()
    private var served = QueueSnapshot()
    private var running = true
    private var failuresOwed = 0
    private var refusesCommands = false
    private var delay: Duration = .zero
    private var cancelDelay: Duration = .zero
    private var calls: [EnqueuePrompt] = []
    private var cancels: [String] = []
    private var resumes = 0
    private var startedIDs: Set<String> = []

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s", createdAt: Date(),
            updatedAt: Date())
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }

    var enqueueCalls: [EnqueuePrompt] { lock.withLock { calls } }
    var cancelledIDs: [String] { lock.withLock { cancels } }
    var resumeCount: Int { lock.withLock { resumes } }
    var held: QueueSnapshot { lock.withLock { served } }

    func setRunning(_ value: Bool) { lock.withLock { running = value } }
    func failEnqueues(_ count: Int) { lock.withLock { failuresOwed = count } }
    func refuseCommands() { lock.withLock { refusesCommands = true } }
    func delayEnqueues(by value: Duration) { lock.withLock { delay = value } }
    func delayCancels(by value: Duration) { lock.withLock { cancelDelay = value } }
    func hold(_ snapshot: QueueSnapshot) { lock.withLock { served = snapshot } }
    func markStarted(_ id: String) {
        lock.withLock {
            served.items.removeAll { $0.id == id }
            startedIDs.insert(id)
        }
    }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        let (status, queue) = lock.withLock { (running, served) }
        return TranscriptSnapshot(messages: [], status: status ? .running : .idle, queue: queue)
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in continuation.yield(.attached) }
    }

    func enqueue(sessionID: String, prompt: EnqueuePrompt) async throws -> EnqueueResult {
        let (pause, fails, refuses) = lock.withLock {
            calls.append(prompt)
            let fails = failuresOwed > 0
            if fails { failuresOwed -= 1 }
            return (delay, fails, refusesCommands && prompt.kind == .command)
        }
        if pause > .zero { try await Task.sleep(for: pause) }
        if fails { throw AgentError.connection("unreachable") }
        if refuses { throw AgentError.unsupported("queued command") }
        return lock.withLock {
            if !running, served.items.isEmpty {
                return EnqueueResult(started: true, queue: served)
            }
            if !served.items.contains(where: { $0.id == prompt.id }) {
                served.items.append(
                    QueuedPrompt(
                        id: prompt.id, text: prompt.prompt.text, kind: prompt.kind,
                        createdAt: Date()))
            }
            return EnqueueResult(started: false, queue: served)
        }
    }

    func cancelQueued(sessionID: String, id: String) async throws -> QueueSnapshot {
        let pause = lock.withLock { cancelDelay }
        if pause > .zero { try await Task.sleep(for: pause) }
        return try lock.withLock {
            cancels.append(id)
            if startedIDs.contains(id) { throw QueueError.alreadyStarted }
            served.items.removeAll { $0.id == id }
            return served
        }
    }

    func editQueued(sessionID: String, id: String, edit: QueuedPromptEdit) async throws
        -> QueueSnapshot
    {
        try lock.withLock {
            guard let index = served.items.firstIndex(where: { $0.id == id }) else {
                throw QueueError.alreadyStarted
            }
            if let text = edit.text { served.items[index].text = text }
            return served
        }
    }

    func resumeQueue(sessionID: String) async throws -> QueueSnapshot {
        lock.withLock {
            resumes += 1
            served.paused = false
            return served
        }
    }
}

private final class SettledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private let routingToServer = QueueRouting(serverQueue: true, canEdit: true)

private func fresh(_ profile: String) -> ConversationQueue {
    SendQueueStore.clear(profileID: profile)
    QueueMemory.reset()
    return ConversationQueue(profileID: profile, sessionID: "s")
}

private func conversation(_ server: QueueServer) -> AgentConversation {
    AgentConversation(backend: server, sessionID: "s")
}

private func later() -> Date { Date().addingTimeInterval(ConversationQueue.retryDelay + 1) }

extension SendQueueStoreTests {
    @Test("A message written behind a running turn is handed to the server under its own id")
    func handedOverUnderItsOwnId() async {
        let queue = fresh("hand")
        defer { SendQueueStore.clear(profileID: "hand") }
        let server = QueueServer()
        let send = QueuedSend(text: "after this", model: nil, effort: "high")

        let changed = await queue.submit(send, through: conversation(server), routing: routingToServer)

        #expect(changed)
        #expect(queue.isEmpty)
        #expect(server.enqueueCalls.map(\.id) == [send.id.uuidString])
        #expect(server.enqueueCalls.first?.prompt.reasoningEffort == "high")
        #expect(server.held.items.map(\.text) == ["after this"])
        #expect(SendQueueStore.queue(profileID: "hand", sessionID: "s").isEmpty)
    }

    @Test("A command goes as its slash form and kind")
    func commandGoesAsSlashForm() async {
        let queue = fresh("cmd")
        defer { SendQueueStore.clear(profileID: "cmd") }
        let server = QueueServer()
        let send = QueuedSend(text: "keep the plan", kind: .command(name: "compact", arguments: "keep the plan"))

        await queue.submit(send, through: conversation(server), routing: routingToServer)

        #expect(server.enqueueCalls.first?.prompt.text == "/compact keep the plan")
        #expect(server.enqueueCalls.first?.kind == .command)
    }

    @Test("An unreachable server leaves the message unsent, and it goes at the tail when the server answers")
    func offlineThenReconnect() async {
        let queue = fresh("offline")
        defer { SendQueueStore.clear(profileID: "offline") }
        let server = QueueServer()
        server.failEnqueues(1)
        let first = QueuedSend(text: "first")
        let second = QueuedSend(text: "second")
        let talking = conversation(server)

        await queue.submit(first, through: talking, routing: routingToServer)

        #expect(queue.local.items.map(\.id) == [first.id])
        let display = queue.display(nil, routing: routingToServer)
        #expect(display.rows.map(\.holder) == [.unsent])
        #expect(display.rows.first?.id == first.id.uuidString)

        await queue.submit(second, through: talking, routing: routingToServer)
        #expect(queue.local.items.map(\.id) == [first.id, second.id])

        await queue.flush(through: talking, routing: routingToServer, now: later())

        #expect(queue.isEmpty)
        #expect(server.held.items.map(\.text) == ["first", "second"])
    }

    @Test("A message the server did not take is offered again on its own, without waiting for a state")
    func retriesByItself() async {
        let queue = fresh("retry")
        defer { SendQueueStore.clear(profileID: "retry") }
        let server = QueueServer()
        server.failEnqueues(1)

        await queue.submit(QueuedSend(text: "later"), through: conversation(server), routing: routingToServer)
        #expect(!queue.isEmpty)

        let deadline = Date().addingTimeInterval(ConversationQueue.retryDelay + 3)
        while !queue.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }

        #expect(queue.isEmpty)
        #expect(server.held.items.map(\.text) == ["later"])
    }

    @Test("Messages left in the store are handed over oldest first on the first connection")
    func leftInTheStore() async {
        let queue = fresh("left")
        defer { SendQueueStore.clear(profileID: "left") }
        let server = QueueServer()
        let sends = (1...3).map { QueuedSend(text: "m\($0)") }
        queue.append(sends[0])
        queue.append(sends[1])
        queue.append(sends[2])

        let changed = await queue.flush(
            through: conversation(server), routing: routingToServer)

        #expect(changed)
        #expect(server.enqueueCalls.map(\.prompt.text) == ["m1", "m2", "m3"])
        #expect(server.enqueueCalls.map(\.id) == sends.map { $0.id.uuidString })
        #expect(SendQueueStore.queue(profileID: "left", sessionID: "s").isEmpty)
    }

    @Test("A failure stops the hand-over where it is, so nothing goes out of order")
    func failureKeepsOrder() async {
        let queue = fresh("order")
        defer { SendQueueStore.clear(profileID: "order") }
        let server = QueueServer()
        server.failEnqueues(1)
        queue.append(QueuedSend(text: "a"))
        queue.append(QueuedSend(text: "b"))

        await queue.flush(through: conversation(server), routing: routingToServer)

        #expect(server.enqueueCalls.count == 1)
        #expect(queue.local.items.map(\.text) == ["a", "b"])
    }

    @Test("Without a server queue the device keeps everything and drains its own head")
    func deviceRoute() {
        let queue = fresh("device")
        defer { SendQueueStore.clear(profileID: "device") }
        queue.append(QueuedSend(text: "one"))
        queue.append(QueuedSend(text: "two"))

        let display = queue.display(ConversationState(status: .running), routing: .device)

        #expect(display.rows.map(\.holder) == [.device, .device])
        #expect(display.rows.map(\.title) == ["one", "two"])
        #expect(!queue.holdsServerBound(routing: .device))
        #expect(queue.takeDeviceHead(routing: .device)?.text == "one")
        #expect(queue.local.items.map(\.text) == ["two"])
    }

    @Test("The device never drains a head that belongs to the server's queue")
    func deviceLeavesServerBoundAlone() {
        let queue = fresh("leave")
        defer { SendQueueStore.clear(profileID: "leave") }
        queue.append(QueuedSend(text: "for the server"))

        #expect(queue.takeDeviceHead(routing: routingToServer) == nil)
        #expect(queue.local.count == 1)
    }

    @Test("A server that cannot queue a command leaves it on the device, labelled as held there")
    func commandsStayOnTheDeviceOnOpencodeTwo() async {
        let queue = fresh("oc2")
        defer { SendQueueStore.clear(profileID: "oc2") }
        let server = QueueServer()
        server.refuseCommands()
        let command = QueuedSend(text: "", kind: .command(name: "compact", arguments: ""))
        let prompt = QueuedSend(text: "words")
        let talking = conversation(server)

        await queue.submit(command, through: talking, routing: routingToServer)
        await queue.submit(prompt, through: talking, routing: routingToServer)

        let routing = QueueRouting(
            capabilities: server.capabilities, profileID: "oc2")
        #expect(routing.commandsRefused)
        #expect(queue.local.items.map(\.id) == [command.id])
        #expect(server.held.items.map(\.text) == ["words"])
        let display = queue.display(nil, routing: routing)
        #expect(display.rows.map(\.holder) == [.device])
        #expect(queue.takeDeviceHead(routing: routing)?.id == command.id)
    }

    @Test("What the server lists is drawn once, as the server's, followed by what is still here")
    func displayMergesWithoutDuplicates() {
        let mine = QueuedSend(text: "mine")
        let other = QueuedPrompt(id: "from-the-mac", text: "from another client", createdAt: Date())
        let duplicate = QueuedPrompt(id: mine.id.uuidString.lowercased(), text: "mine", createdAt: Date())
        let waiting = QueuedSend(text: "not there yet")
        var state = ConversationState(status: .running)
        state.queue = [other, duplicate]

        let display = QueueDisplay.make(
            state: state, local: SendQueue(items: [mine, waiting]), routing: routingToServer)

        #expect(display.rows.map(\.id) == ["from-the-mac", mine.id.uuidString.lowercased(), waiting.id.uuidString])
        #expect(display.rows.map(\.holder) == [.server, .server, .server])
        #expect(display.rows[0].canEdit)
    }

    @Test("A server that cannot edit offers no edit on its rows")
    func noEditWithoutTheCapability() {
        var state = ConversationState(status: .running)
        state.queue = [QueuedPrompt(id: "a", text: "x", createdAt: Date())]

        let display = QueueDisplay.make(
            state: state, local: SendQueue(),
            routing: QueueRouting(serverQueue: true, canEdit: false))

        #expect(display.rows.map(\.canEdit) == [false])
    }

    @Test("A message on its way to the server does not read as unsent")
    func inFlightIsNotUnsent() {
        let send = QueuedSend(text: "going")
        let display = QueueDisplay.make(
            state: nil, local: SendQueue(items: [send]), routing: routingToServer,
            sending: [send.id.uuidString], failing: true)

        #expect(display.rows.map(\.holder) == [.server])
        #expect(display.rows.map(\.canEdit) == [false])
        let stuck = QueueDisplay.make(
            state: nil, local: SendQueue(items: [send]), routing: routingToServer, failing: true)
        #expect(stuck.rows.map(\.holder) == [.unsent])
        let waiting = QueueDisplay.make(
            state: nil, local: SendQueue(items: [send]), routing: routingToServer)
        #expect(waiting.rows.map(\.holder) == [.server])
    }

    @Test("A paused queue shows only when it has something in it")
    func pausedOnlyWhenNotEmpty() {
        var state = ConversationState(status: .idle)
        state.queuePaused = true
        #expect(!QueueDisplay.make(state: state, local: SendQueue(), routing: routingToServer).paused)

        state.queue = [QueuedPrompt(id: "a", text: "x", createdAt: Date())]
        #expect(QueueDisplay.make(state: state, local: SendQueue(), routing: routingToServer).paused)
        #expect(!QueueDisplay.make(state: state, local: SendQueue(), routing: .device).paused)
    }

    @Test("Cancelling a row the server holds asks the server, and a message it already started says so")
    func cancelServerRow() async {
        let queue = fresh("cancel")
        defer { SendQueueStore.clear(profileID: "cancel") }
        let server = QueueServer()
        server.hold(
            QueueSnapshot(items: [QueuedPrompt(id: "a", text: "x", createdAt: Date())]))
        let row = QueueRow(
            id: "a", text: "x", isCommand: false, attachmentCount: 0, holder: .server, canEdit: true)

        #expect(await queue.cancel(row, through: conversation(server)) == .done)
        #expect(server.held.isEmpty)

        server.markStarted("b")
        let started = QueueRow(
            id: "b", text: "y", isCommand: false, attachmentCount: 0, holder: .server, canEdit: true)
        let outcome = await queue.cancel(started, through: conversation(server))
        #expect(outcome == .alreadyStarted)
        #expect(outcome.message == QueueReading.alreadySent)
    }

    @Test("Editing a row the server holds changes its words there; clearing it cancels it")
    func editServerRow() async {
        let queue = fresh("edit")
        defer { SendQueueStore.clear(profileID: "edit") }
        let server = QueueServer()
        server.hold(
            QueueSnapshot(items: [QueuedPrompt(id: "a", text: "old", createdAt: Date())]))
        let row = QueueRow(
            id: "a", text: "old", isCommand: false, attachmentCount: 0, holder: .server, canEdit: true)
        let talking = conversation(server)

        #expect(await queue.edit(row, text: "new", attachments: [], through: talking) == .done)
        #expect(server.held.items.map(\.text) == ["new"])

        #expect(await queue.edit(row, text: "  ", attachments: [], through: talking) == .done)
        #expect(server.held.isEmpty)
    }

    @Test("A message the person withdraws while it is on its way is cancelled once the server has it")
    func cancelWhileInFlight() async {
        let queue = fresh("flight")
        defer { SendQueueStore.clear(profileID: "flight") }
        let server = QueueServer()
        server.delayEnqueues(by: .milliseconds(150))
        let send = QueuedSend(text: "changed my mind")
        let talking = conversation(server)

        let handing = Task { await queue.submit(send, through: talking, routing: routingToServer) }
        while server.enqueueCalls.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let row = queue.display(nil, routing: routingToServer).rows[0]
        #expect(row.holder == .server)
        _ = await queue.cancel(row, through: talking)
        _ = await handing.value

        #expect(server.cancelledIDs == [send.id.uuidString])
        #expect(server.held.isEmpty)
        #expect(queue.isEmpty)
    }

    @Test("A row is gone from this device before the server has answered anything")
    func rowGoesBeforeTheServerAnswers() async {
        let queue = fresh("sync")
        defer { SendQueueStore.clear(profileID: "sync") }
        let server = QueueServer()
        server.failEnqueues(1)
        server.delayCancels(by: .milliseconds(200))
        let talking = conversation(server)
        let send = QueuedSend(text: "never mind")
        let rewritten = QueuedSend(text: "reword me")
        await queue.submit(send, through: talking, routing: routingToServer)
        queue.append(rewritten)
        let display = queue.display(nil, routing: routingToServer)

        let answered = SettledFlag()
        queue.cancel(display.rows[0], through: talking) { _ in answered.set() }

        #expect(queue.local.items.map(\.id) == [rewritten.id])
        #expect(!answered.isSet)

        let done = SettledFlag()
        queue.edit(display.rows[1], text: "reworded", attachments: [], through: talking) { _ in
            done.set()
        }
        #expect(queue.local.items.map(\.text) == ["reworded"])
        #expect(done.isSet)
        while !answered.isSet { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Resume lifts the pause on the server")
    func resume() async {
        let queue = fresh("resume")
        defer { SendQueueStore.clear(profileID: "resume") }
        let server = QueueServer()

        #expect(await queue.resume(through: conversation(server)) == .done)
        #expect(server.resumeCount == 1)
    }

    @Test("What the device drains waits for the server's queue to be empty")
    func deviceWaitsForTheServerQueue() {
        var state = ConversationState(status: .idle)
        #expect(SendQueueDrain.mayDrain(state))
        state.queue = [QueuedPrompt(id: "a", text: "x", createdAt: Date())]
        #expect(!SendQueueDrain.mayDrain(state))
    }

    @Test("A row speaks where it is held when that is not the server")
    func spokenRows() {
        let device = QueueRow(
            id: "a", text: "go", isCommand: false, attachmentCount: 0, holder: .device, canEdit: true)
        let server = QueueRow(
            id: "b", text: "go", isCommand: false, attachmentCount: 0, holder: .server, canEdit: true)
        #expect(QueueReading.spoken(device, position: 1, of: 2).contains(QueueReading.badge(device)))
        #expect(!QueueReading.spoken(server, position: 1, of: 2).contains(QueueReading.badge(device)))
        #expect(QueueReading.hint(device) != QueueReading.hint(server))
    }
}
