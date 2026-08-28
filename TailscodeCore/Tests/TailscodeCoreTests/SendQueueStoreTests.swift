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
        var state = ConversationState()
        #expect(SendQueueDrain.mayDrain(state))
        #expect(!SendQueueDrain.mayDrain(state, editing: true))
        state.status = .running
        #expect(!SendQueueDrain.mayDrain(state))
    }
}
