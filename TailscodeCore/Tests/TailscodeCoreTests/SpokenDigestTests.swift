import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Spoken digest")
struct SpokenDigestTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func user(_ text: String, at offset: TimeInterval = -600) -> ChatMessage {
        ChatMessage(
            id: "u\(text.count)\(offset)", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text(text))], createdAt: now.addingTimeInterval(offset))
    }

    private func assistant(
        _ parts: [MessagePart.Kind], error: String? = nil, streaming: Bool = false, id: String = "a"
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode,
            parts: parts.enumerated().map { MessagePart(id: "\(id)\($0.offset)", kind: $0.element) },
            createdAt: now.addingTimeInterval(-300),
            completedAt: streaming ? nil : now.addingTimeInterval(-290), isStreaming: streaming, error: error)
    }

    private func tool(_ name: String, status: ToolStatus = .running) -> MessagePart.Kind {
        .tool(ToolCall(id: "t-\(name)", name: name, status: status))
    }

    private func state(
        _ messages: [ChatMessage], status: BackendStatus = .idle, questions: [QuestionRequest] = [],
        permissions: [PermissionRequest] = [], failure: BackendFailure? = nil,
        background: BackgroundWork? = nil, connection: ConnectionPhase = .live
    ) -> ConversationState {
        ConversationState(
            messages: messages, status: status, pendingPermissions: permissions,
            pendingQuestions: questions, lastFailure: failure, connection: connection,
            hasLoadedTranscript: true, backgroundWork: background)
    }

    private func read(_ state: ConversationState) -> (busy: Bool, digest: String) {
        SpokenDigest.read(state, now: now)
    }

    @Test("A conversation with nothing in it is idle")
    func idle() {
        let reading = read(state([]))
        #expect(!reading.busy)
        #expect(reading.digest == "The agent is idle.")
        #expect(SpokenDigest.idle == VoiceAgentSnapshot.idle.digest)
    }

    @Test("A turn in flight says Working and names the tool that is out")
    func working() {
        let cases: [(String, String)] = [
            ("Bash", "Running a command."), ("Read", "Reading files."), ("Edit", "Editing files."),
            ("Write", "Editing files."), ("Grep", "Searching the code."), ("WebSearch", "Searching the web."),
            ("WebFetch", "Reading a web page."), ("TodoWrite", "Updating its plan."),
            ("Task", "Running helper agents."), ("Skill", "Using a skill."), ("Mystery", "Using a tool."),
        ]
        for (name, phrase) in cases {
            let reading = read(state([user("go"), assistant([tool(name)], streaming: true)], status: .running))
            #expect(reading.busy)
            #expect(reading.digest == "Working. \(phrase)", "\(name)")
        }
    }

    @Test("A turn with no tool is thinking, and one that has started writing says so")
    func thinkingAndWriting() {
        let thinking = read(state([user("go")], status: .running))
        #expect(thinking.busy)
        #expect(thinking.digest == "Working. Thinking.")
        let writing = read(
            state([user("go"), assistant([.text("Here is")], streaming: true)], status: .running))
        #expect(writing.digest == "Working. Writing the answer.")
    }

    @Test("A compaction, a retry and background work are all work")
    func otherWork() {
        let compaction = ConversationState(
            messages: [user("go")], status: .idle, connection: .live, hasLoadedTranscript: true,
            compaction: CompactionActivity(startedAt: now))
        #expect(read(compaction).digest == "Working. Compacting the conversation.")
        let retrying = ConversationState(
            messages: [user("go")], status: .running, connection: .live, hasLoadedTranscript: true,
            retry: TurnRetry(attempt: 2, reason: "overloaded"))
        #expect(read(retrying).digest == "Working. Waiting on the model provider, which is retrying.")
        let background = read(state([user("go"), assistant([.text("Started it.")])], background: BackgroundWork(tasks: 2)))
        #expect(background.busy)
        #expect(background.digest == "Working. 2 background tasks are running.")
        let stuck = read(state([], background: BackgroundWork(tasks: 1, stalled: true)))
        #expect(stuck.digest == "Working. A background task looks stuck.")
    }

    @Test("A question waiting for the person is not the agent working, and its first sentence is read out")
    func waitingOnAQuestion() {
        let question = QuestionRequest(
            id: "q", sessionID: "s",
            questions: [
                .init(
                    question: "Which database should I migrate first? The old one or the new one?",
                    header: "DB", options: [])
            ])
        let reading = read(state([user("go")], status: .running, questions: [question]))
        #expect(!reading.busy)
        #expect(reading.digest == "Waiting for you. Which database should I migrate first?")
    }

    @Test("A permission waiting for the person says what it wants")
    func waitingOnApproval() {
        let titled = PermissionRequest(id: "p", sessionID: "s", title: "Run rm -rf build", toolName: "Bash")
        #expect(
            read(state([user("go")], status: .running, permissions: [titled])).digest
                == "Waiting for you. It needs your approval: Run rm -rf build.")
        let bare = PermissionRequest(id: "p", sessionID: "s", toolName: "Bash")
        #expect(
            read(state([user("go")], status: .running, permissions: [bare])).digest
                == "Waiting for you. It needs your approval to use Bash.")
        #expect(read(state([], permissions: [PermissionRequest(id: "p", sessionID: "s")])).busy == false)
    }

    @Test("A failed turn says that it failed and the first sentence of why")
    func failed() {
        let failure = BackendFailure(message: "Rate limit reached for this key. Try again in 20 minutes.")
        let reading = read(state([user("go")], failure: failure))
        #expect(!reading.busy)
        #expect(reading.digest == "That failed. Rate limit reached for this key.")
        let onTheMessage = read(state([user("go"), assistant([], error: "Context window exceeded")]))
        #expect(onTheMessage.digest == "That failed. Context window exceeded.")
        #expect(read(state([user("go")], failure: BackendFailure(message: ""))).digest == "That failed. The turn stopped with an error.")
    }

    @Test("Work outranks an old failure that has not been cleared")
    func workBeatsFailure() {
        let failure = BackendFailure(message: "boom")
        #expect(read(state([user("go")], status: .running, failure: failure)).digest == "Working. Thinking.")
    }

    @Test("A finished turn says Done and the first sentences of the last answer, without code or markup")
    func finished() {
        let answer = """
            ## Summary

            I fixed the **parser** bug in [the lexer](https://example.com/docs/lexer). It was reading past the end.

            ```swift
            let x = lexer.next()
            ```

            Tests pass now. Nothing else changed.
            """
        let reading = read(state([user("fix it"), assistant([tool("Edit", status: .completed), .text(answer)])]))
        #expect(!reading.busy)
        #expect(reading.digest == "Done. I fixed the parser bug in the lexer. It was reading past the end.")
    }

    @Test("Lists, long paths, addresses and tables are not read aloud")
    func cleaned() {
        let answer = """
            Changed the following:

            - `Sources/TailscodeCore/Voice/VoiceCallSession.swift` now redials
            - See https://github.com/guitaripod/Tailscode/pull/42 for details

            | file | lines |
            | a | 3 |
            """
        let digest = read(state([user("go"), assistant([.text(answer)])])).digest
        #expect(digest == "Done. Changed the following. now redials.")
        #expect(!digest.contains("/"))
        #expect(!digest.contains("http"))
    }

    @Test("Abbreviations and version numbers do not end a sentence early")
    func sentences() {
        #expect(
            SpokenDigest.firstSentences(of: "Use e.g. the parser from v1.2.3 for it. Then stop. Then rest.", count: 1, limit: 200)
                == "Use e.g. the parser from v1.2.3 for it.")
        #expect(SpokenDigest.firstSentences(of: "", count: 2, limit: 100) == "")
        #expect(SpokenDigest.firstSentences(of: "```\ncode only\n```", count: 2, limit: 100) == "")
    }

    @Test("A long first sentence is cut at a word, and the digest never passes the wire limit")
    func limits() {
        let long = String(repeating: "word ", count: 200)
        let digest = read(state([user("go"), assistant([.text(long)])])).digest
        #expect(digest.count <= VoiceWire.digestLimit)
        #expect(digest.hasPrefix("Done. word word"))
        let sentence = SpokenDigest.firstSentences(of: long, count: 2, limit: 50)
        #expect(sentence.count <= 50)
    }

    @Test("The digest is ASCII whatever the agent wrote")
    func ascii() {
        let digest = read(state([user("go"), assistant([.text("Réglé — l’erreur était dans le fichier. 完了。")])])).digest
        #expect(digest.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(digest.hasPrefix("Done. Regle"))
    }

    @Test("A finished turn that wrote nothing is said plainly, and the answer is the last one after the last prompt")
    func answerless() {
        let nothing = read(state([user("go"), assistant([tool("Bash", status: .completed)])]))
        #expect(nothing.digest == "Done. It finished without a written answer.")
        let older = read(state([user("one"), assistant([.text("Old answer.")], id: "a1"), user("two"), assistant([], id: "a2")]))
        #expect(older.digest == "Done. It finished without a written answer.")
    }

    @Test("A prompt that has just gone out and not yet started is work, an old unanswered one is not")
    func freshPrompt() {
        let fresh = read(state([user("go", at: -3)]))
        #expect(fresh.busy)
        #expect(fresh.digest == "Working. Starting on it.")
        let stale = read(state([user("go", at: -300)]))
        #expect(!stale.busy)
        #expect(stale.digest == "The agent is idle.")
    }

    @Test("A server that is not answering is said so")
    func offline() {
        #expect(read(state([user("go")], status: .running, connection: .offline)).digest == "The agent is not reachable right now.")
    }

    @Test("The turn rises when what the digest means changes and holds when it does not")
    func turns() {
        let thinking = state([user("go")], status: .running)
        let reading = state([user("go"), assistant([tool("Read")], streaming: true)], status: .running)
        let first = SpokenDigest.snapshot(from: thinking, after: nil, now: now)
        #expect(first.turn == 1)
        let again = SpokenDigest.snapshot(from: thinking, after: first, now: now)
        #expect(again.turn == 1)
        let next = SpokenDigest.snapshot(from: reading, after: again, now: now)
        #expect(next.turn == 2)
        let done = SpokenDigest.snapshot(
            from: state([user("go"), assistant([.text("All set.")])]), after: next, now: now)
        #expect(done.turn == 3)
        #expect(done.busy == false)
        let sameAgain = SpokenDigest.snapshot(
            from: state([user("go"), assistant([.text("All set.")])]), after: done, now: now)
        #expect(sameAgain.turn == 3)
        let newAnswer = SpokenDigest.snapshot(
            from: state([user("go"), assistant([.text("All set. Really.")])]), after: sameAgain, now: now)
        #expect(newAnswer.turn == 4)
        #expect(done.wire == VoiceClientMessage.AgentState(busy: false, digest: "Done. All set.", turn: 3))
    }

    @Test("A prompt handed over and not yet echoed is Starting on it, unless the agent is waiting for the person")
    func sendingBeforeTheEcho() {
        let idleState = state([])
        let plain = SpokenDigest.snapshot(from: idleState, after: nil, now: now)
        #expect(!plain.busy)
        let sending = SpokenDigest.snapshot(from: idleState, sending: true, after: plain, now: now)
        #expect(sending.busy)
        #expect(sending.digest == SpokenDigest.starting)
        #expect(sending.turn == plain.turn + 1)
        let again = SpokenDigest.snapshot(from: idleState, sending: true, after: sending, now: now)
        #expect(again.turn == sending.turn)
        let notSending = SpokenDigest.snapshot(from: idleState, sending: false, after: plain, now: now)
        #expect(notSending == plain)
        let question = QuestionRequest(
            id: "q", sessionID: "s", questions: [.init(question: "Which branch?", header: "B", options: [])])
        let waiting = SpokenDigest.snapshot(from: state([user("hi")], questions: [question]), sending: true, now: now)
        #expect(waiting.digest.hasPrefix("Waiting for you."))
        #expect(!waiting.busy)
    }
}
