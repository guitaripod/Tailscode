import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Synchronization

/// A load fixture for the tiling soak: one scripted server with `panes` long conversations whose
/// every reply is a firehose of tiny text deltas, so a client can be measured with several panes
/// streaming at once and no network. It routes like the demo world (its profile id starts with
/// `demo-`) and exists only when a harness run asks for it.
public enum SoakWorld {
    public static let profilePrefix = "demo-soak"

    public struct Configuration: Sendable, Equatable {
        public var panes: Int
        public var tokensPerSecond: Double
        public var rows: Int
        public var turnSeconds: Int
        public var listedSessions: Int
        public var paragraphCharacters: Int

        public init(
            panes: Int = 5, tokensPerSecond: Double = 80, rows: Int = 600, turnSeconds: Int = 240,
            listedSessions: Int = 200, paragraphCharacters: Int = 0
        ) {
            self.panes = max(1, panes)
            self.tokensPerSecond = max(1, tokensPerSecond)
            self.rows = max(0, rows)
            self.turnSeconds = max(1, turnSeconds)
            self.listedSessions = max(self.panes, listedSessions)
            self.paragraphCharacters = max(0, paragraphCharacters)
        }

        /// `N:R:K[:T[:P]]` — panes, tokens per second, transcript messages, how long one reply
        /// streams for, and the length of the one unbroken paragraph each text segment of the
        /// reply is (zero keeps the mixed markdown segments). Anything unreadable is nil rather
        /// than a guess.
        public init?(parsing text: String) {
            let fields = text.split(separator: ":").map { String($0) }
            guard (3...5).contains(fields.count), let panes = Int(fields[0]),
                let rate = Double(fields[1]), let rows = Int(fields[2]), panes > 0, rate > 0,
                rows >= 0
            else { return nil }
            let seconds = fields.count >= 4 ? Int(fields[3]) : 240
            let paragraph = fields.count == 5 ? Int(fields[4]) : 0
            guard let seconds, seconds > 0, let paragraph, paragraph >= 0 else { return nil }
            self.init(
                panes: panes, tokensPerSecond: rate, rows: rows, turnSeconds: seconds,
                paragraphCharacters: paragraph)
        }

        public var tokenInterval: Duration {
            .microseconds(Int64((1_000_000 / tokensPerSecond).rounded()))
        }

        public var turnTokens: Int { Int(tokensPerSecond * Double(turnSeconds)) }
    }

    public static let profile = ConnectionProfile(
        id: profilePrefix, name: "soak", backend: .claudeCode,
        baseURL: URL(string: "http://soak.tailnet-demo.ts.net:4098")!)

    public static func sessionID(_ index: Int) -> String { "soak-\(index)" }

    private static let installed = Mutex<SoakServer?>(nil)

    /// Makes the soak server the one `backend(for:)` answers with. Installing again replaces it.
    @discardableResult
    public static func install(_ configuration: Configuration) -> MockBackend {
        let server = SoakServer(configuration: configuration)
        installed.withLock { $0 = server }
        return server.backend
    }

    public static var configuration: Configuration? {
        installed.withLock { $0?.configuration }
    }

    public static func backend(for profileID: String) -> MockBackend? {
        guard profileID == profile.id else { return nil }
        return installed.withLock { $0?.backend }
    }

    static func server(for backend: MockBackend) -> SoakServer? {
        installed.withLock { server in server.flatMap { $0.backend === backend ? $0 : nil } }
    }

    public static func backend(_ configuration: Configuration) -> MockBackend {
        let now = Date()
        var scripts: [String: [MockScriptStep]] = [:]
        var sessions: [AgentSession] = []
        for index in 1...configuration.panes {
            let id = sessionID(index)
            scripts[id] = transcript(index: index, rows: configuration.rows, now: now).map {
                MockScriptStep(.messageUpserted($0, replaceParts: true), delay: .zero)
            }
            sessions.append(
                AgentSession(
                    id: id, agentType: .claudeCode, title: "Soak \(index)",
                    directory: "/home/soak/project-\(index)",
                    createdAt: now.addingTimeInterval(-86_400),
                    updatedAt: now.addingTimeInterval(-Double(index)), model: model.id,
                    reasoningEffort: "high"))
        }
        if configuration.listedSessions > configuration.panes {
            for filler in 1...(configuration.listedSessions - configuration.panes) {
                let age = 3_600 + Double(filler) * 1_800
                sessions.append(
                    AgentSession(
                        id: "soak-idle-\(filler)", agentType: .claudeCode,
                        title: "Earlier chat \(filler)",
                        directory: "/home/soak/project-\(filler % 9)",
                        createdAt: now.addingTimeInterval(-age - 600),
                        updatedAt: now.addingTimeInterval(-age), model: model.id))
            }
        }
        return MockBackend(
            agentType: .claudeCode, scripts: scripts, replyTurns: [replyTurn(configuration)],
            interactive: true, sessions: sessions, models: [model], defaultModelID: model.id,
            reasoningEffortOptions: ["low", "medium", "high"],
            health: ServerHealth(healthy: true, version: "soak"),
            capabilities: BackendCapabilities(
                supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
                supportsMultipleSessions: true, supportsModelSelection: true,
                supportsAttachments: false, supportsReasoningEffort: true, supportsAbort: true,
                supportsSessionUsage: false, supportsQuestions: false),
            commands: [])
    }

    private static let model = ModelInfo(
        id: "claude-fable-5", name: "Fable 5", providerID: "anthropic",
        variants: ["low", "medium", "high"], contextWindow: 1_000_000)

    /// `rows` messages in the proportions a working conversation has: a prompt, then an answer
    /// that reads, runs and explains — reasoning, prose with a list, a code block, a tool call
    /// with real output, and a conclusion.
    public static func transcript(index: Int, rows: Int, now: Date = Date()) -> [ChatMessage] {
        (0..<rows).map { row in
            let date = now.addingTimeInterval(-Double(rows - row) * 40 - 3_600)
            let id = "s\(index)m\(row)"
            if row % 2 == 0 {
                return ChatMessage(
                    id: id, role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text(prompt(row)))], createdAt: date)
            }
            return ChatMessage(
                id: id, role: .assistant, agentType: .claudeCode, parts: answerParts(row),
                createdAt: date, completedAt: date.addingTimeInterval(30),
                providerID: "anthropic", modelID: model.id, totalTokens: 2_400 + row)
        }
    }

    /// One reply: an assistant message whose text arrives a token at a time, `tokensPerSecond`
    /// tokens a second, broken every few hundred tokens by a short tool call the way an agent's
    /// answer is, for `turnSeconds` in all.
    public static func replyTurn(_ configuration: Configuration) -> [MockScriptStep] {
        let interval = configuration.tokenInterval
        var steps: [MockScriptStep] = [
            MockScriptStep(
                .messageUpserted(
                    ChatMessage(
                        id: "soak-reply", role: .assistant, agentType: .claudeCode, parts: [],
                        createdAt: Date(), isStreaming: true, providerID: "anthropic",
                        modelID: model.id),
                    replaceParts: true), delay: .milliseconds(200))
        ]
        var remaining = configuration.turnTokens
        var segment = 0
        while remaining > 0 {
            let textID = "t\(segment)"
            steps.append(
                MockScriptStep(
                    .partUpserted(messageID: "soak-reply", MessagePart(id: textID, kind: .text(""))),
                    delay: interval))
            let text =
                configuration.paragraphCharacters > 0
                ? longParagraph(segment, characters: configuration.paragraphCharacters)
                : segmentText(segment)
            let tokens = tokenize(text).prefix(remaining)
            for token in tokens {
                steps.append(
                    MockScriptStep(
                        .partTextDelta(messageID: "soak-reply", partID: textID, delta: token),
                        delay: interval))
            }
            remaining -= tokens.count
            guard remaining > 0 else { break }
            let call = "soak-call-\(segment)"
            let command = "swift test --filter Soak\(segment) 2>&1 | tail -5"
            steps.append(
                MockScriptStep(
                    .partUpserted(
                        messageID: "soak-reply",
                        MessagePart(
                            id: "tool\(segment)",
                            kind: .tool(
                                ToolCall(
                                    id: call, name: "Bash", status: .running,
                                    input: .object(["command": .string(command)]), title: command)))),
                    delay: interval))
            steps.append(
                MockScriptStep(
                    .partUpserted(
                        messageID: "soak-reply",
                        MessagePart(
                            id: "tool\(segment)",
                            kind: .tool(
                                ToolCall(
                                    id: call, name: "Bash", status: .completed,
                                    input: .object(["command": .string(command)]),
                                    output: toolOutput(segment), title: command)))),
                    delay: .milliseconds(150)))
            segment += 1
        }
        return steps
    }

    /// Text cut into pieces the size a model streams: a word with the space after it, or a run
    /// of at most six characters inside a long word or a line of code.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" || current.count >= 6 {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func prompt(_ row: Int) -> String {
        let asks = [
            "The reconnect test still fails one run in five. Find the race and fix it without touching the scheduler's public API.",
            "Add pagination to the sessions endpoint. Keep the old shape working for clients that never send a cursor.",
            "Why does the cache miss on every cold launch? Read the key derivation and tell me before changing anything.",
            "Write a migration that splits the `events` table by month and backfills the last ninety days.",
            "Profile the list view: scrolling stutters with a few thousand rows. Measure first, then fix the worst offender.",
        ]
        return asks[(row / 2) % asks.count] + " (step \(row / 2 + 1))"
    }

    private static func answerParts(_ row: Int) -> [MessagePart] {
        let file = ["Sources/Pulse/Socket/Reconnect.swift", "Sources/Pulse/API/Sessions.swift",
            "Sources/Pulse/Cache/KeyDerivation.swift", "Migrations/0042_split_events.sql",
            "Sources/PulseUI/SessionList.swift"][row % 5]
        return [
            MessagePart(
                id: "r",
                kind: .reasoning(
                    "Reading \(file) before touching it. The smallest correct diff wins, and the test has to fail before the fix and pass after it.")),
            MessagePart(id: "t1", kind: .text(segmentText(row))),
            MessagePart(
                id: "tool",
                kind: .tool(
                    ToolCall(
                        id: "s-call-\(row)", name: row % 3 == 0 ? "Read" : "Bash",
                        status: .completed,
                        input: .object(["command": .string("swift test --filter Pulse 2>&1 | tail -20")]),
                        output: toolOutput(row), title: row % 3 == 0 ? "Read \(file)" : "swift test"))),
            MessagePart(
                id: "t2",
                kind: .text(
                    "All green after the change. The fix is contained to `\(file)` and the regression test pins the behaviour, so this is safe to ship. Want me to open the PR?")),
        ]
    }

    /// One paragraph with no blank line in it, so the transcript keeps it as a single label however
    /// long it runs.
    private static func longParagraph(_ index: Int, characters: Int) -> String {
        let sentences = [
            "The retry policy measures its deadline from the start of the request rather than from the attempt, so a slow first call leaves later attempts no time at all.",
            "Clamping the jitter factor inside the policy means a caller cannot widen it by accident, and the test can inject a fixed factor instead of sleeping.",
            "Nothing else reads the old rounding, which `rg` confirms across every caller in the tree, so the change stays inside one file.",
            "The flaky run was the third call site, whose test asserts on wall-clock time and fails whenever the machine is busy with something else.",
        ]
        var text = ""
        var next = index
        while text.count < characters {
            text += sentences[next % sentences.count] + " "
            next += 1
        }
        return String(text.prefix(characters))
    }

    private static func segmentText(_ index: Int) -> String {
        let topics = ["reconnect backoff", "session pagination", "cache key derivation",
            "monthly partitioning", "list virtualization", "token refresh"]
        let topic = topics[index % topics.count]
        return """
            ## \(index + 1). The \(topic)

            Reading the code before changing it: the **\(topic)** has three moving parts, and only one of them is actually wrong. The other two are doing exactly what they were written to do, which is why the bug survived review twice.

            - The first call site passes a deadline measured from the *start* of the request, not from the retry
            - The second rounds the jitter factor before multiplying, so the worst case is \(400 + index % 160) ms rather than the documented ceiling
            - The third is fine, but its test asserts on wall-clock time and fails under load

            Here is the smallest change that fixes the first two without moving any public API:

            ```swift
            struct RetryPolicy: Sendable {
                var base: Duration = .milliseconds(\(400 + index % 100))
                var jitter: ClosedRange<Double> = 0.8...1.2

                func delay(attempt: Int, factor: Double) -> Duration {
                    let scaled = base * Double(1 << min(attempt, 6))
                    return scaled * min(max(factor, jitter.lowerBound), jitter.upperBound)
                }
            }
            ```

            With the factor clamped inside the policy, the caller cannot widen it by accident, and the test can inject a fixed factor instead of sleeping. I checked every caller with `rg "RetryPolicy("` and none of them depends on the old rounding.

            | Case | Before | After |
            |---|---|---|
            | worst delay | \(560 + index % 40) ms | 480 ms |
            | flaky runs in 100 | \(18 + index % 7) | 0 |

            Running the suite next to prove it.


            """
    }

    private static func toolOutput(_ index: Int) -> String {
        (0..<12).map { line in
            "Test Case 'PulseTests.Soak\(index)Tests.case\(line)' passed (0.\(100 + line * 7) seconds)"
        }.joined(separator: "\n") + "\nExecuted 12 tests, with 0 failures (0 unexpected) in 1.\(index % 10)84 seconds"
    }
}

/// The installed soak server: the scripted backend plus the list pushes a real bridge makes while
/// its conversations are busy — one upsert per streaming session per second, each of which a
/// client folds into its whole session list.
final class SoakServer: Sendable {
    let configuration: SoakWorld.Configuration
    let backend: MockBackend

    init(configuration: SoakWorld.Configuration) {
        self.configuration = configuration
        backend = SoakWorld.backend(configuration)
    }

    func listChanges() -> AsyncStream<SessionListChange> {
        let backend = backend
        let configuration = configuration
        return AsyncStream { continuation in
            let task = Task {
                var seenPrompts = 0
                var liveUntil = Date.distantPast
                var wasLive = false
                let base = (try? await backend.listSessions()) ?? []
                let live = base.filter { $0.id.hasPrefix("soak-") && !$0.id.hasPrefix("soak-idle") }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let prompts = backend.recordedPrompts.count
                    if prompts > seenPrompts {
                        seenPrompts = prompts
                        liveUntil = Date().addingTimeInterval(Double(configuration.turnSeconds) + 2)
                    }
                    let isLive = Date() < liveUntil
                    guard isLive || wasLive else { continue }
                    wasLive = isLive
                    for session in live {
                        var pushed = session
                        pushed.updatedAt = Date()
                        pushed.isActive = isLive
                        continuation.yield(.upsert(pushed))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MockBackend: @retroactive SessionListStreaming {
    /// Only the soak server pushes list changes; every other scripted backend answers that it
    /// cannot, exactly as it did before this conformance existed.
    public func sessionListChanges() async -> AsyncStream<SessionListChange>? {
        SoakWorld.server(for: self)?.listChanges()
    }
}
