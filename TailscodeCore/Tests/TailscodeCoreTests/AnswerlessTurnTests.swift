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
    private let started = Date(timeIntervalSince1970: 1_000_000)

    private func cutOff(queued: [String] = ["and then the mac"], resumed: Bool = false)
        -> TurnInterruption
    {
        let detected = started.addingTimeInterval(340)
        return TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started, detectedAt: detected,
            progress: TurnInterruption.Progress(toolCount: 2),
            queued: queued, resumedAt: resumed ? detected.addingTimeInterval(10) : nil)
    }

    private func card(queued: [String] = ["and then the mac"], resumed: Bool = false)
        -> InterruptedTurn
    {
        InterruptedTurnReading.read(
            cutOff(queued: queued, resumed: resumed),
            now: started.addingTimeInterval(460))!
    }

    @Test("Self-check of the interrupted-turn card stays clean")
    func selfCheck() {
        let issues = InterruptedTurnCheck.run()
        #expect(issues.isEmpty, "InterruptedTurnCheck: \(issues)")
    }

    @Test("The card says what leaving it undecided costs, in these words")
    func costOfStanding() {
        #expect(
            card().cost
                == "Until this is answered, the server will not carry this session on by itself — picking it up or letting it go both end that."
        )
        #expect(card(resumed: true).cost == nil)
        #expect(InterruptedTurnReading.pressed(card(), .pickUp).cost == nil)
    }

    @Test("What never ran is one sentence, owned here")
    func queuedLine() {
        #expect(card().queuedLine == "One prompt was waiting behind it and never ran.")
        #expect(
            card(queued: ["a", "b", "c"]).queuedLine
                == "3 prompts were waiting behind it and never ran.")
        #expect(card(queued: []).queuedLine == nil)
    }

    @Test("A press changes the card at once, in these words")
    func pressInFlight() {
        let pickingUp = InterruptedTurnReading.pressed(card(), .pickUp)
        #expect(InterruptedTurn.pickingUpTitle == "Picking it back up…")
        #expect(InterruptedTurn.lettingGoTitle == "Letting it go…")
        #expect(pickingUp.resumeTitle == "Picking it back up…")
        #expect(pickingUp.title == "Picking the turn back up")
        #expect(
            pickingUp.detail == "Asked the server to pick this back up — waiting for it to say it has."
        )
        #expect(!pickingUp.acceptsPress)
        #expect(!pickingUp.isResumed)

        let lettingGo = InterruptedTurnReading.pressed(card(), .letGo)
        #expect(lettingGo.dismissTitle == "Letting it go…")
        #expect(lettingGo.title == "Letting the turn go")
        #expect(
            lettingGo.detail == "Asked the server to set this aside — waiting for it to say it has.")
        #expect(!lettingGo.acceptsPress)
    }

    @Test("A refused press shows the server's own sentence and promises a corrected card")
    func refusalKeepsTheServersWords() {
        let body =
            "{\"error\":\"Nothing to pick up — no turn in this session was interrupted.\",\"reason\":\"nothing_interrupted\",\"interruption\":null}"
        #expect(
            InterruptedTurnReading.refusal(body: body)
                == "Nothing to pick up — no turn in this session was interrupted. The card has been refreshed to what the server actually has."
        )
        #expect(
            InterruptedTurnReading.refreshedNote
                == "The card has been refreshed to what the server actually has.")
        #expect(InterruptedTurnReading.conflict(body: body) == .nothingInterrupted)
    }

    @Test("A silent server gets one sentence per reason, never a paraphrase")
    func refusalFallbacks() {
        #expect(
            InterruptedTurnReading.refusal(said: nil, reason: .nothingInterrupted)
                .hasPrefix("The server has no interrupted turn in this session any more."))
        #expect(
            InterruptedTurnReading.refusal(said: "   ", reason: .alreadyResumed)
                .hasPrefix("That turn is already being picked back up."))
        #expect(
            InterruptedTurnReading.refusal(said: nil, reason: .unknownSession)
                .hasPrefix("The server does not know this session any more."))
        #expect(
            InterruptedTurnReading.refusal(said: nil, reason: .unstated)
                .hasPrefix("The server would not pick that turn back up, and did not say why."))
    }

    @Test("The reason codes are the ones the bridge writes")
    func conflictCodes() {
        #expect(InterruptedTurnConflict.key == "reason")
        #expect(InterruptedTurnConflict.nothingInterrupted.code == "nothing_interrupted")
        #expect(InterruptedTurnConflict.alreadyResumed.code == "already_resumed")
        #expect(InterruptedTurnConflict.unknownSession.code == "unknown_session")
        #expect(InterruptedTurnConflict.unstated.code == nil)
        #expect(InterruptedTurnConflict(code: "already_resumed") == .alreadyResumed)
        #expect(InterruptedTurnConflict(code: "something new") == .unstated)
        #expect(InterruptedTurnConflict(code: nil) == .unstated)
    }

    @Test("Everything the card says, a screen reader hears")
    func spokenCarriesTheNewLines() {
        let reading = card()
        #expect(reading.spoken.contains(reading.queuedLine ?? "—"))
        #expect(reading.spoken.contains(reading.cost ?? "—"))
    }
}
