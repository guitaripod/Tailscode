import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Answerless turn")
struct AnswerlessTurnTests {
    private func assistant(
        parts: [MessagePart] = [], completed: Bool = true, error: String? = nil,
        finish: String? = "unknown", model: String? = "grok-4.5"
    ) -> ChatMessage {
        ChatMessage(
            id: "m1", role: .assistant, agentType: .openCode, parts: parts, createdAt: Date(),
            completedAt: completed ? Date() : nil, isStreaming: !completed, error: error,
            modelID: model, finishReason: finish)
    }

    private func prompt(_ text: String, pictures: Int = 0) -> ChatMessage {
        var parts: [MessagePart] = [MessagePart(id: "text", kind: .text(text))]
        for index in 0..<pictures {
            parts.append(
                MessagePart(
                    id: "file-\(index)",
                    kind: .file(FileReference(mime: "image/png", filename: "shot.png"))))
        }
        return ChatMessage(
            id: "u1", role: .user, agentType: .openCode, parts: parts, createdAt: Date(),
            completedAt: Date())
    }

    @Test("A turn made only of step markers is answerless")
    func stepMarkersOnly() {
        let message = assistant(parts: [
            MessagePart(id: "p1", kind: .unknown(type: "step-start")),
            MessagePart(id: "p2", kind: .unknown(type: "step-finish")),
        ])
        #expect(message.isAnswerless)
        let reading = AnswerlessTurnReading.read(message, prompt: prompt("explain this"))
        #expect(reading?.title == "Nothing came back")
        #expect(reading?.remedy == .askAgain)
        #expect(reading?.action == "Ask again")
        #expect(reading?.prompt == "explain this")
        #expect(reading?.detail.contains("grok-4.5") == true)
        #expect(reading?.detail.contains("“unknown”") == true)
    }

    @Test("A picture in the question changes what is offered")
    func pictureInTheQuestion() {
        let reading = AnswerlessTurnReading.read(
            assistant(parts: [MessagePart(id: "p1", kind: .unknown(type: "step-start"))]),
            prompt: prompt("what is this?", pictures: 1))
        #expect(reading?.remedy == .askWithoutPictures)
        #expect(reading?.action == "Ask again without the picture")
        #expect(reading?.detail.contains("carried a picture") == true)
    }

    @Test("Two pictures are counted rather than pluralised by guess")
    func twoPictures() {
        let reading = AnswerlessTurnReading.read(
            assistant(), prompt: prompt("compare these", pictures: 2))
        #expect(reading?.action == "Ask again without the pictures")
        #expect(reading?.detail.contains("carried 2 pictures") == true)
    }

    @Test("A turn that said anything at all is not answerless")
    func saidSomething() {
        #expect(!assistant(parts: [MessagePart(id: "p1", kind: .text("hello"))]).isAnswerless)
        #expect(
            !assistant(parts: [
                MessagePart(id: "p1", kind: .reasoning("thinking"))
            ]).isAnswerless)
        #expect(
            !assistant(parts: [
                MessagePart(
                    id: "p1", kind: .tool(ToolCall(id: "t", name: "bash", status: .completed)))
            ]).isAnswerless)
        #expect(
            !assistant(parts: [
                MessagePart(id: "p1", kind: .file(FileReference(mime: "image/png")))
            ]).isAnswerless)
    }

    @Test("Whitespace is not an answer")
    func whitespaceIsNotAnAnswer() {
        #expect(assistant(parts: [MessagePart(id: "p1", kind: .text("  \n "))]).isAnswerless)
    }

    @Test("A turn still running has not ended in anything")
    func stillRunning() {
        #expect(!assistant(completed: false).isAnswerless)
    }

    @Test("A turn with an error already has a face")
    func errorHasItsOwnFace() {
        #expect(!assistant(error: "Connection refused").isAnswerless)
    }

    @Test("A turn stopped by hand is empty for a reason the person already knows")
    func stoppedByHand() {
        #expect(!assistant(finish: "abort").isAnswerless)
        #expect(!assistant(finish: "Cancelled").isAnswerless)
    }

    @Test("A user message is never read as an answerless turn")
    func userMessage() {
        var message = assistant()
        message.role = .user
        #expect(!message.isAnswerless)
        #expect(AnswerlessTurnReading.read(message, prompt: nil) == nil)
    }

    @Test("A model the server never named still gets a sentence")
    func unnamedModel() {
        let reading = AnswerlessTurnReading.read(assistant(model: nil), prompt: prompt("hi"))
        #expect(reading?.detail.hasPrefix("The turn ended without a word") == true)
    }

    @Test("A plain stop is not worth quoting back")
    func plainStopIsNotQuoted() {
        let reading = AnswerlessTurnReading.read(assistant(finish: "stop"), prompt: prompt("hi"))
        #expect(reading?.detail.contains("calls the ending") == false)
    }

    @Test("A question that was only a picture offers no words to send again")
    func nothingToSendAgain() {
        var picture = prompt("", pictures: 1)
        picture.parts.removeAll { if case .text = $0.kind { return true } else { return false } }
        let reading = AnswerlessTurnReading.read(assistant(), prompt: picture)
        #expect(reading?.prompt.isEmpty == true)
        #expect(reading?.offersRemedy == false)
    }
}

@Suite("A turn the machine cut off")
struct InterruptedTurnTests {
    @Test("Self-check of the interrupted-turn card stays clean")
    func selfCheck() {
        let issues = InterruptedTurnCheck.run()
        #expect(issues.isEmpty, "InterruptedTurnCheck: \(issues)")
    }
}
