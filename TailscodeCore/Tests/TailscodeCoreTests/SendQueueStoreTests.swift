import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Send queue store", .serialized)
struct SendQueueStoreTests {
    @Test("A queue is kept per conversation and read back whole, in order")
    func roundTrip() {
        SendQueueStore.removeAll()
        defer { SendQueueStore.removeAll() }
        var queue = SendQueue()
        queue.append(QueuedSend(text: "first", model: ModelSelection(providerID: "anthropic", modelID: "opus"), effort: "high"))
        queue.append(QueuedSend(text: "", kind: .command(name: "compact", arguments: "keep the plan")))
        queue.append(QueuedSend(text: "third", attachments: [PromptAttachment(mime: "image/png", filename: "a.png", data: Data([1, 2, 3]))]))
        SendQueueStore.save(queue, profileID: "p", sessionID: "s")
        SendQueueStore.save(SendQueue(items: [QueuedSend(text: "elsewhere")]), profileID: "p", sessionID: "other")
        let back = SendQueueStore.queue(profileID: "p", sessionID: "s")
        #expect(back == queue)
        #expect(SendQueueStore.queue(profileID: "p", sessionID: "other").items.map(\.text) == ["elsewhere"])
        #expect(SendQueueStore.queue(profileID: "q", sessionID: "s").isEmpty)
        #expect(SendQueueStore.all().count == 2)
        SendQueueStore.save(SendQueue(), profileID: "p", sessionID: "s")
        #expect(SendQueueStore.all().map(\.sessionID) == ["other"])
        SendQueueStore.clear(profileID: "p")
        #expect(SendQueueStore.all().isEmpty)
    }

    @Test("Draining waits for the turn, the compaction, the last failure and the editor")
    func drainRule() {
        var state = ConversationState(status: .idle)
        #expect(SendQueueDrain.mayDrain(state))
        #expect(!SendQueueDrain.mayDrain(state, editing: true))
        state.status = .running
        #expect(!SendQueueDrain.mayDrain(state))
    }

    @Test("A chat reopened before the server has said whether its turn ended does not drain")
    func unknownStatusHoldsTheQueue() {
        var state = ConversationState()
        #expect(state.status == .unknown)
        #expect(!SendQueueDrain.mayDrain(state))
        #expect(!SendQueueDrain.mayDrain(state, handoff: TurnHandoff()))
        state.status = .idle
        #expect(SendQueueDrain.mayDrain(state))
    }

    @Test("A send holds the queue until its turn is seen running")
    func handoffHoldsUntilRunning() {
        var state = ConversationState(status: .idle)
        var handoff = TurnHandoff()
        handoff.begin(after: state)
        #expect(!SendQueueDrain.mayDrain(state, handoff: handoff))

        state.messages.append(Self.message(.user))
        handoff.observe(state, sendsInFlight: false)
        #expect(!SendQueueDrain.mayDrain(state, handoff: handoff))

        state.status = .running
        handoff.observe(state, sendsInFlight: false)
        #expect(!handoff.isOpen)
        #expect(!SendQueueDrain.mayDrain(state, handoff: handoff))

        state.status = .idle
        #expect(SendQueueDrain.mayDrain(state, handoff: handoff))
    }

    @Test("A turn answered without ever being seen running releases the queue")
    func handoffReleasesOnAnswer() {
        var state = ConversationState()
        state.messages = [Self.message(.user), Self.message(.assistant)]
        var handoff = TurnHandoff()
        handoff.begin(after: state)

        handoff.observe(state, sendsInFlight: false)
        #expect(handoff.isOpen)

        state.messages.append(Self.message(.user))
        handoff.observe(state, sendsInFlight: true)
        #expect(handoff.isOpen)
        handoff.observe(state, sendsInFlight: false)
        #expect(handoff.isOpen)

        state.messages.append(Self.message(.assistant))
        handoff.observe(state, sendsInFlight: true)
        #expect(handoff.isOpen)
        handoff.observe(state, sendsInFlight: false)
        #expect(!handoff.isOpen)
    }

    @Test("A turn that never comes stops holding the queue, and a failed send ends the hold")
    func handoffGivesUp() {
        let state = ConversationState(status: .idle)
        let start = Date()
        var handoff = TurnHandoff()
        handoff.begin(after: state, now: start)
        handoff.observe(state, sendsInFlight: false, now: start.addingTimeInterval(TurnHandoff.patience - 1))
        #expect(handoff.isOpen)
        handoff.observe(state, sendsInFlight: false, now: start.addingTimeInterval(TurnHandoff.patience + 1))
        #expect(!handoff.isOpen)

        handoff.begin(after: state)
        handoff.end()
        #expect(SendQueueDrain.mayDrain(state, handoff: handoff))
    }

    @Test("takeFirst hands back the head and keeps the rest, and an emptied queue leaves no record")
    func takeFirstOrder() {
        SendQueueStore.removeAll()
        defer { SendQueueStore.removeAll() }
        SendQueueStore.save(
            SendQueue(items: [QueuedSend(text: "one"), QueuedSend(text: "two")]), profileID: "p", sessionID: "s")
        #expect(SendQueueStore.takeFirst(profileID: "p", sessionID: "s")?.text == "one")
        #expect(SendQueueStore.queue(profileID: "p", sessionID: "s").items.map(\.text) == ["two"])
        #expect(SendQueueStore.takeFirst(profileID: "p", sessionID: "s")?.text == "two")
        #expect(SendQueueStore.takeFirst(profileID: "p", sessionID: "s") == nil)
        #expect(SendQueueStore.all().isEmpty)
        #expect(SendQueueStore.takeFirst(profileID: "nobody", sessionID: "s") == nil)
    }

    @Test("Under many concurrent takers every queued message is taken exactly once")
    func takeFirstConcurrent() {
        SendQueueStore.removeAll()
        defer { SendQueueStore.removeAll() }
        let sent = (0..<120).map { QueuedSend(text: "m\($0)") }
        SendQueueStore.save(SendQueue(items: sent), profileID: "p", sessionID: "s")
        SendQueueStore.save(SendQueue(items: [QueuedSend(text: "other")]), profileID: "p", sessionID: "t")
        let lock = NSLock()
        nonisolated(unsafe) var taken: [QueuedSend] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            while let next = SendQueueStore.takeFirst(profileID: "p", sessionID: "s") {
                lock.lock()
                taken.append(next)
                lock.unlock()
            }
        }
        #expect(taken.count == sent.count)
        #expect(Set(taken.map(\.id)) == Set(sent.map(\.id)))
        #expect(SendQueueStore.queue(profileID: "p", sessionID: "t").items.map(\.text) == ["other"])
    }

    @Test("takeFirst reads what another process wrote rather than this process's memory")
    func takeFirstReadsDisk() throws {
        SendQueueStore.removeAll()
        defer { SendQueueStore.removeAll() }
        SendQueueStore.save(SendQueue(items: [QueuedSend(text: "stale")]), profileID: "p", sessionID: "s")
        let elsewhere = [SendQueueRecord(profileID: "p", sessionID: "s", items: [QueuedSend(text: "fresh"), QueuedSend(text: "later")])]
        try JSONEncoder().encode(elsewhere).write(to: SendQueueStore.url, options: .atomic)
        #expect(SendQueueStore.takeFirst(profileID: "p", sessionID: "s")?.text == "fresh")
        #expect(SendQueueStore.queue(profileID: "p", sessionID: "s").items.map(\.text) == ["later"])
    }

    private static func message(_ role: MessageRole) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString, role: role, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("words"))], createdAt: Date())
    }
}
