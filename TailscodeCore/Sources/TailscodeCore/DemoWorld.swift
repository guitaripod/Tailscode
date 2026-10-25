import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// The self-contained demo world: two scripted servers that saturate every screen with
/// believable sessions, quotas, models, and file trees — no tailnet required. Ships in
/// Release so App Review and first-run users can explore the full app before owning a server.
public enum DemoWorld {
    public static let profilePrefix = "demo-"

    public static let claudeProfile = ConnectionProfile(
        id: "demo-claude", name: "studio", backend: .claudeCode,
        baseURL: URL(string: "http://studio.tailnet-demo.ts.net:4098")!)

    public static let openCodeProfile = ConnectionProfile(
        id: "demo-opencode", name: "homelab", backend: .openCode,
        baseURL: URL(string: "http://homelab.tailnet-demo.ts.net:4096")!)

    public static var profiles: [ConnectionProfile] { [claudeProfile, openCodeProfile] }

    public static func backend(for profileID: String) -> (any CodingAgentBackend)? {
        switch profileID {
        case claudeProfile.id: return claude
        case openCodeProfile.id: return openCode
        default: return nil
        }
    }

    static let now = Date()

    static let readsEverything = ModelCapabilities(
        attachment: true, imageInput: true, pdfInput: true)
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    static func hence(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    static func step(_ event: BackendEvent, ms: Int = 10) -> MockScriptStep {
        MockScriptStep(event, delay: .milliseconds(ms))
    }

    static func step(_ message: ChatMessage, ms: Int = 10) -> MockScriptStep {
        MockScriptStep(.messageUpserted(message, replaceParts: true), delay: .milliseconds(ms))
    }

    static func user(
        _ id: String, _ type: AgentType, _ text: String, at date: Date
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: type,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date)
    }

    static func note(_ id: String, _ subject: TranscriptNote.Subject, at date: Date)
        -> ChatMessage
    {
        ChatMessage(
            id: id, role: .system, agentType: .openCode,
            parts: [MessagePart(id: "\(id)/note", kind: .note(TranscriptNote(subject)))],
            createdAt: date, completedAt: date)
    }

    static func compaction(_ id: String, _ type: AgentType, at date: Date) -> ChatMessage {
        ChatMessage(
            id: id, role: .system, agentType: type,
            parts: [
                MessagePart(
                    id: "compaction",
                    kind: .compaction(
                        Compaction(
                            trigger: .manual, tokensBefore: 311_551, tokensAfter: 16_418,
                            duration: 114, preservedMessageCount: 9,
                            summary: demoCompactionSummary)))
            ],
            createdAt: date)
    }

    private static let demoCompactionSummary = """
        This session is being continued from a previous conversation that ran out of context. \
        The summary below covers the earlier portion of the conversation.

        **1. Primary request and intent**

        Walk through how token refresh works in `pulse-server`, with particular attention to where \
        it retries and what happens when a refresh fails outright.

        **2. Key technical concepts**

        - `TokenStore` owns the whole lifecycle: mint at boot, serve from memory, refresh ahead of \
        expiry. It is the only writer; readers never take a lock.
        - Refresh fires 90 seconds before the access token expires, with exponential backoff \
        (`1s, 2s, 4s…` capped at 60s) on transient failure.
        - A 401 on the refresh call is terminal — the refresh token itself is dead, so the store \
        moves to `.needsReauth` instead of retrying.

        **3. Files and code sections**

        - `Sources/Pulse/Auth/TokenStore.swift` — `bootstrap()`, the refresh task, and the \
        `.unauthorized` escalation path.
        - `Sources/Pulse/Auth/DeviceIdentity.swift` — supplies the credential the reauth hook signs \
        back in with.

        **4. Errors and fixes**

        None encountered; this portion of the conversation was explanatory.

        **5. Pending work**

        The user was asking what happens when the refresh call itself returns 401. The answer had \
        not yet been given when the context filled.
        """

    /// A working tree a demo can show: enough shapes to prove the surface — something staged,
    /// something only edited, something git has never seen — without pretending to be a repository
    /// anybody could act on. Nothing here is reachable, which is the point of a demo.
    static func demoGit(
        root: String, branch: String, upstream: String?, ahead: Int, behind: Int,
        changes: [GitChange], commits: [(String, String, TimeInterval)]
    ) -> GitSnapshot {
        GitSnapshot(
            root: root, repo: true, branch: branch, head: "9f3a21c8", upstream: upstream,
            ahead: ahead, behind: behind, stashes: 1, remote: "git@github.com:demo/pulse.git",
            fetchedAt: ago(2_400), changes: changes,
            commits: commits.enumerated().map { index, commit in
                GitCommitSummary(
                    hash: "demo-commit-\(index)", short: String(format: "%08x", 0x9f3a21c8 &- index &* 977),
                    subject: commit.0, author: commit.1, at: ago(commit.2),
                    refs: index == 0 ? ["HEAD -> \(branch)"] : [])
            }, changedTotal: changes.count)
    }

    static let demoReconnectPatch = """
        diff --git a/Sources/Pulse/Socket/Reconnect.swift b/Sources/Pulse/Socket/Reconnect.swift
        index 7c02e5d..b41f9a0 100644
        --- a/Sources/Pulse/Socket/Reconnect.swift
        +++ b/Sources/Pulse/Socket/Reconnect.swift
        @@ -4,13 +4,18 @@ import Foundation
         final class ReconnectScheduler {
             private let backoff: Backoff
        +    private let jitter: JitterSource
             private var failures = 0

        -    init(backoff: Backoff = Backoff(base: 0.4, ceiling: 30)) {
        +    init(
        +        backoff: Backoff = Backoff(base: 0.4, ceiling: 30),
        +        jitter: JitterSource = SystemJitter()
        +    ) {
                 self.backoff = backoff
        +        self.jitter = jitter
             }

             func nextDelay() -> TimeInterval {
        -        let delay = backoff.delay(afterFailures: failures) * Double.random(in: 0.6...1.4)
        +        let delay = backoff.delay(afterFailures: failures) * jitter.factor(in: 0.6...1.4)
                 failures += 1
                 return delay
             }
        """

    static let demoBackoffPatch = """
        diff --git a/Sources/Pulse/Socket/Backoff.swift b/Sources/Pulse/Socket/Backoff.swift
        index 4b1c0a2..9d21f77 100644
        --- a/Sources/Pulse/Socket/Backoff.swift
        +++ b/Sources/Pulse/Socket/Backoff.swift
        @@ -12,6 +12,7 @@ struct Backoff {
             let ceiling: TimeInterval

             func delay(afterFailures failures: Int) -> TimeInterval {
        -        min(ceiling, base * pow(2, Double(failures)))
        +        let exponent = Double(min(failures, 16))
        +        return min(ceiling, base * pow(2, exponent))
             }
         }
        """

    static let demoReconnectTestsPatch = """
        diff --git a/Tests/PulseTests/ReconnectTests.swift b/Tests/PulseTests/ReconnectTests.swift
        index 51d0c3e..e2a7f18 100644
        --- a/Tests/PulseTests/ReconnectTests.swift
        +++ b/Tests/PulseTests/ReconnectTests.swift
        @@ -8,8 +8,14 @@ import Testing
         struct ReconnectTests {
             @Test func backoffStaysUnderTheCeiling() {
        -        let scheduler = ReconnectScheduler()
        +        let scheduler = ReconnectScheduler(jitter: FixedJitter(value: 1.0))
                 let delays = (0..<6).map { _ in scheduler.nextDelay() }
        -        #expect(delays[0] < 0.5)
        +        #expect(delays[0] == 0.4)
        +        #expect(delays[1] == 0.8)
                 #expect(delays.allSatisfy { $0 <= 30 })
             }
        +
        +    @Test func worstCaseJitterStaysBounded() {
        +        let scheduler = ReconnectScheduler(jitter: FixedJitter(value: 1.4))
        +        #expect(scheduler.nextDelay() == 0.4 * 1.4)
        +    }
         }
        """

    static let demoJitterPatch = """
        diff --git a/Sources/Pulse/Socket/Jitter.swift b/Sources/Pulse/Socket/Jitter.swift
        new file mode 100644
        index 0000000..3e8b1d4
        --- /dev/null
        +++ b/Sources/Pulse/Socket/Jitter.swift
        @@ -0,0 +1,17 @@
        +import Foundation
        +
        +protocol JitterSource: Sendable {
        +    func factor(in range: ClosedRange<Double>) -> Double
        +}
        +
        +struct SystemJitter: JitterSource {
        +    func factor(in range: ClosedRange<Double>) -> Double {
        +        Double.random(in: range)
        +    }
        +}
        +
        +struct FixedJitter: JitterSource {
        +    let value: Double
        +
        +    func factor(in _: ClosedRange<Double>) -> Double { value }
        +}
        """

    static func assistant(
        _ id: String, _ type: AgentType, at date: Date, streaming: Bool = false,
        error: String? = nil, model: String? = nil, provider: String? = nil,
        parts: [MessagePart] = [],
        cost: Double? = nil, tokens: Int? = nil, context: MessageUsage? = nil,
        duration: TimeInterval? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: type, parts: parts, createdAt: date,
            completedAt: streaming ? nil : date.addingTimeInterval(45),
            isStreaming: streaming, error: error, costUSD: cost,
            providerID: provider ?? (type == .openCode ? "opencode-go" : "anthropic"),
            modelID: model, totalTokens: tokens, context: context, duration: duration)
    }
}

extension DemoWorld {
    /// `TAILSCODE_DEMO_RANGE=1` adds one long Claude chat whose context is three quarters full
    /// and whose cache is still warm, so the Range sheet has every section to draw. Unset, the
    /// demo world holds exactly what it always did.
    public static let rangeDemoEnabled =
        ProcessInfo.processInfo.environment["TAILSCODE_DEMO_RANGE"] != nil

    public static let rangeSessionID = "demo-c7"

    static var rangeSessions: [AgentSession] {
        guard rangeDemoEnabled else { return [] }
        return [
            AgentSession(
                id: rangeSessionID, agentType: .claudeCode, title: "Fix the quota parser",
                directory: "/Users/demo/dev/pulse-server", createdAt: ago(5_000),
                updatedAt: ago(915), model: "claude-haiku-4-5", reasoningEffort: "low")
        ]
    }

    static var rangeScripts: [String: [MockScriptStep]] {
        guard rangeDemoEnabled else { return [:] }
        return [rangeSessionID: rangeScript]
    }

    static var rangeScript: [MockScriptStep] {
        rangeTurns.enumerated().flatMap { index, turn -> [MockScriptStep] in
            let number = index + 1
            let finished = TimeInterval(915 + (rangeTurns.count - number) * 540)
            let footprint = turn.footprint
            return [
                step(user("c7u\(number)", .claudeCode, turn.prompt, at: ago(finished + 75))),
                step(assistant(
                    "c7a\(number)", .claudeCode, at: ago(finished + 45),
                    model: "claude-haiku-4-5",
                    parts: [
                        MessagePart(id: "t1", kind: .tool(ToolCall(
                            id: "c7t\(number)", name: turn.tool, status: .completed,
                            input: .object([turn.inputKey: .string(turn.target)]),
                            output: rangeOutput(characters: turn.outputCharacters, seed: number),
                            title: "\(turn.tool) \(turn.target)"))),
                        MessagePart(id: "t2", kind: .text(turn.answer)),
                    ],
                    context: MessageUsage(
                        input: 600, output: 900, cacheRead: footprint - 3_600,
                        cacheWrite: 3_000, cacheLifetime: 3_600),
                    duration: TimeInterval(30 + number * 3))),
            ]
        } + [step(.status(.idle))]
    }

    private struct RangeTurn {
        let prompt: String
        let tool: String
        let inputKey: String
        let target: String
        let outputCharacters: Int
        let answer: String
        let footprint: Int
    }

    private static var rangeTurns: [RangeTurn] {
        [
            RangeTurn(
                prompt: "The quota parser drops the second window when a model is named only by its scope. Where does that happen?",
                tool: "Read", inputKey: "file_path", target: "Sources/Pulse/Quota/QuotaBinding.swift",
                outputCharacters: 4_200,
                answer: "`scope(of:)` strips every plumbing word from a label, so a window named only by its model collapses into the account scope and is folded away.",
                footprint: 96_000),
            RangeTurn(
                prompt: "Which callers rely on that collapse?",
                tool: "Bash", inputKey: "command", target: "rg -n 'scope(of:' Sources Tests",
                outputCharacters: 3_100,
                answer: "Three: the board rollup, the chip reading and the widget glance. Only the rollup depends on the folding.",
                footprint: 104_000),
            RangeTurn(
                prompt: "Show me the rollup so I can see what it assumes.",
                tool: "Read", inputKey: "file_path", target: "Sources/Pulse/Quota/UsageAnalytics.swift",
                outputCharacters: 40_000,
                answer: "It keys holdings by provider and scope and merges equal keys, which is why the scoped window disappears.",
                footprint: 112_000),
            RangeTurn(
                prompt: "Run the quota tests so we know where we start.",
                tool: "Bash", inputKey: "command", target: "swift test --filter QuotaBindingTests",
                outputCharacters: 3_600,
                answer: "Two failures, both in the scoped path. Everything else is green.",
                footprint: 119_000),
            RangeTurn(
                prompt: "Read the window model too, the fix may belong there.",
                tool: "Read", inputKey: "file_path", target: "Sources/Pulse/Quota/QuotaWindow.swift",
                outputCharacters: 5_400,
                answer: "The model is fine. The label is the only thing that decides the scope, so the fix belongs in the binding.",
                footprint: 126_000),
            RangeTurn(
                prompt: "Make the change and show me the diff.",
                tool: "Bash", inputKey: "command", target: "git diff --stat && git diff",
                outputCharacters: 9_000,
                answer: "The binding now keeps a window's own scope and only strips plumbing words when nothing else names it.",
                footprint: 135_000),
            RangeTurn(
                prompt: "Run the whole suite and tell me what is left.",
                tool: "Bash", inputKey: "command", target: "swift test 2>&1 | tail -80",
                outputCharacters: 11_000,
                answer: "All green except one snapshot that still expects the folded window. I will update it next.",
                footprint: 148_000),
        ]
    }

    private static func rangeOutput(characters: Int, seed: Int) -> String {
        var lines: [String] = []
        var length = 0
        var index = 0
        while length < characters {
            let line = "    \(index + 1)  let window\(seed)_\(index) = binding.scope(of: label\(index), account: \(index % 7)) ?? .account"
            lines.append(line)
            length += line.count + 1
            index += 1
        }
        return lines.joined(separator: "\n")
    }
}
