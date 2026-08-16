import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Send queue")
struct SendQueueTests {
    private func queue(_ texts: String...) -> SendQueue {
        var queue = SendQueue()
        for text in texts { queue.append(QueuedSend(text: text)) }
        return queue
    }

    @Test("Editing keeps a message where it was in the order")
    func editInPlace() {
        var queue = self.queue("first", "second", "third")
        let middle = queue.items[1].id
        let replaced = queue.replace(id: middle, text: "rewritten", attachments: [])
        #expect(replaced)
        #expect(queue.items.map(\.text) == ["first", "rewritten", "third"])
    }

    @Test("Clearing a waiting message to nothing takes it back")
    func emptyEditIsADeletion() {
        var queue = self.queue("first", "second")
        let cleared = queue.replace(id: queue.items[0].id, text: "   ", attachments: [])
        #expect(cleared)
        #expect(queue.items.map(\.text) == ["second"])
    }

    @Test("Words can go once the pictures are gone, and the reverse")
    func attachmentsAloneAreEnough() {
        var queue = SendQueue()
        let only = queue.append(
            QueuedSend(text: "look", attachments: [PromptAttachment(mime: "image/png")]))
        let kept = queue.replace(id: only.id, text: "", attachments: only.attachments)
        #expect(kept)
        #expect(queue.count == 1)
        #expect(queue.items[0].text == "")
    }

    @Test("The last thing written is what an up-arrow takes back")
    func takeLast() {
        var queue = self.queue("first", "second")
        let taken = queue.takeLast()
        #expect(taken?.text == "second")
        #expect(queue.items.map(\.text) == ["first"])
    }

    @Test("A failed send goes back to the head, never the tail")
    func failureKeepsOrder() {
        var queue = self.queue("second", "third")
        queue.requeueAtHead(QueuedSend(text: "first"))
        #expect(queue.items.map(\.text) == ["first", "second", "third"])
        let next = queue.takeFirst()
        #expect(next?.text == "first")
    }

    @Test("The up-arrow is only claimed from an empty box")
    func upArrowOnlyWhenEmpty() {
        let waiting = queue("first")
        #expect(SendQueueReading.upArrowTakesBack(composerText: "", queue: waiting))
        #expect(!SendQueueReading.upArrowTakesBack(composerText: "half a thought", queue: waiting))
        #expect(!SendQueueReading.upArrowTakesBack(composerText: "", queue: SendQueue()))
    }

    @Test("A queued command reads as the command it will run")
    func commandRow() {
        let command = QueuedSend(text: "", kind: .command(name: "compact", arguments: "keep the api"))
        #expect(SendQueueReading.rowTitle(command) == "/compact keep the api")
        #expect(command.isCommand)
        let bare = QueuedSend(text: "", kind: .command(name: "clear", arguments: ""))
        #expect(SendQueueReading.rowTitle(bare) == "/clear")
    }

    @Test("Removing by id answers whether there was anything there")
    func removeByID() {
        var queue = self.queue("first")
        let id = queue.items[0].id
        let removed = queue.remove(id: id)
        #expect(removed?.text == "first")
        let again = queue.remove(id: id)
        #expect(again == nil)
        #expect(queue.isEmpty)
    }
}
