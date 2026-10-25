import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation

extension DemoWorld {
    public static let claude: MockBackend = MockBackend(
        agentType: .claudeCode,
        scripts: [
            "demo-c1": claudeLiveScript,
            "demo-c2": claudeMigrationScript,
            "demo-c3": claudeDarkModeScript,
            "demo-c4": claudeExplainerScript,
            "demo-c5": claudeDesignScript,
            "demo-c6": claudeNeuralScript,
        ].merging(rangeScripts) { current, _ in current },
        replyTurns: [claudeReplyA, claudeReplyB],
        interactive: true,
        sessions: [
            AgentSession(
                id: "demo-c1", agentType: .claudeCode, title: "Fix the flaky WebSocket reconnect test",
                directory: "/Users/demo/dev/pulse-server", createdAt: ago(400), updatedAt: ago(120),
                isActive: true, model: "claude-fable-5", reasoningEffort: "max"),
            AgentSession(
                id: "demo-c3", agentType: .claudeCode, title: "Dark mode for the settings screen",
                directory: "/Users/demo/dev/pulse-ios", createdAt: ago(1800), updatedAt: ago(1560),
                model: "claude-sonnet-5", reasoningEffort: "high"),
            AgentSession(
                id: "demo-c2", agentType: .claudeCode, title: "Migrate CI to self-hosted runners",
                directory: "/Users/demo/dev/pulse-infra", createdAt: ago(11_000), updatedAt: ago(3300),
                model: "claude-opus-4-8", reasoningEffort: "medium"),
            AgentSession(
                id: "demo-c5", agentType: .claudeCode, title: "Redesign the composer",
                directory: "/Users/demo/dev/pulse-ios", createdAt: ago(2600), updatedAt: ago(2400),
                model: "claude-opus-4-8", reasoningEffort: "high"),
            claudeNeuralSession(created: ago(5_000), updated: ago(3_900)),
            AgentSession(
                id: "demo-c4", agentType: .claudeCode, title: "Explain the auth token refresh flow",
                directory: "/Users/demo/dev/pulse-server", createdAt: ago(95_500), updatedAt: ago(94_000),
                model: "claude-haiku-4-5", reasoningEffort: "low"),
        ] + rangeSessions,
        models: [
            ModelInfo(
                id: "claude-fable-5", name: "Fable 5", providerID: "anthropic",
                capabilities: readsEverything,
                variants: ["low", "medium", "high", "xhigh", "max", "ultracode"],
                contextWindow: 1_000_000),
            ModelInfo(
                id: "claude-opus-4-8", name: "Opus 4.8", providerID: "anthropic",
                capabilities: readsEverything,
                variants: ["low", "medium", "high", "xhigh", "max", "ultracode"],
                contextWindow: 1_000_000),
            ModelInfo(
                id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic",
                capabilities: readsEverything, variants: ["low", "medium", "high"],
                contextWindow: 1_000_000),
            ModelInfo(
                id: "claude-haiku-4-5", name: "Haiku 4.5", providerID: "anthropic",
                capabilities: readsEverything, variants: [], contextWindow: 200_000),
        ],
        defaultModelID: "claude-fable-5",
        reasoningEffortOptions: ["low", "medium", "high", "xhigh", "max", "ultracode"],
        health: ServerHealth(healthy: true, version: "1.2.0"),
        capabilities: BackendCapabilities(
            supportsFileBrowsing: true, supportsDiffs: false, supportsPermissions: true,
            supportsMultipleSessions: true, supportsModelSelection: true, supportsAttachments: true,
            supportsReasoningEffort: true, supportsClearing: true, supportsForking: true,
            supportsAbort: true, supportsSessionUsage: true, supportsUsageAnalytics: true,
            supportsQuestions: false,
            supportsRenaming: true, supportsSubagents: true, supportsCommands: true,
            supportsGoals: true, supportsCompaction: true),
        quota: UsageQuota(
            providerName: "Claude", subtitle: "Max 20×", source: "claude-bridge", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "session", label: "Session", fraction: 0.62,
                    resetsAt: hence(10_080), trustedReset: true),
                UsageQuota.Gauge(
                    key: "week", label: "Weekly", fraction: 0.34,
                    resetsAt: hence(311_000), trustedReset: true),
                UsageQuota.Gauge(
                    key: "opus", label: "Opus", fraction: 0.11,
                    resetsAt: hence(311_000), trustedReset: true),
            ],
            details: [
                UsageQuota.Detail(key: "Plan", value: "Max 20×"),
                UsageQuota.Detail(key: "Session window", value: "5h rolling"),
                UsageQuota.Detail(key: "Most used model", value: "Fable 5"),
            ]),
        additionalQuotas: [
            UsageQuota(
                providerName: "Grok", subtitle: "grok-code-fast-1", source: "claude-bridge",
                live: true,
                gauges: [
                    UsageQuota.Gauge(
                        key: "tokens", label: "Tokens", fraction: 0.27,
                        resetsAt: hence(32_400), trustedReset: true),
                    UsageQuota.Gauge(
                        key: "requests", label: "Requests", fraction: 0.08,
                        resetsAt: hence(32_400), trustedReset: true),
                ],
                details: [UsageQuota.Detail(key: "Window", value: "24h rolling")]),
        ],
        sessionUsage: AgentUsage(costUSD: nil, tokens: 41_320),
        analytics: demoAnalytics(),
        fileTree: [
            ".": [
                FileNode(path: "/Users/demo/dev", name: "dev", isDirectory: true),
                FileNode(path: "/Users/demo/dotfiles", name: "dotfiles", isDirectory: true),
                FileNode(path: "/Users/demo/notes.md", name: "notes.md", isDirectory: false),
            ],
            "/Users/demo/dev": [
                FileNode(path: "/Users/demo/dev/pulse-server", name: "pulse-server", isDirectory: true),
                FileNode(path: "/Users/demo/dev/pulse-ios", name: "pulse-ios", isDirectory: true),
                FileNode(path: "/Users/demo/dev/pulse-infra", name: "pulse-infra", isDirectory: true),
                FileNode(path: "/Users/demo/dev/blog", name: "blog", isDirectory: true),
            ],
            "/Users/demo/dev/pulse-server": [
                FileNode(path: "/Users/demo/dev/pulse-server/Sources", name: "Sources", isDirectory: true),
                FileNode(path: "/Users/demo/dev/pulse-server/Tests", name: "Tests", isDirectory: true),
                FileNode(path: "/Users/demo/dev/pulse-server/Package.swift", name: "Package.swift", isDirectory: false),
                FileNode(path: "/Users/demo/dev/pulse-server/README.md", name: "README.md", isDirectory: false),
            ],
            "/Users/demo/dev/pulse-ios": [
                FileNode(path: "/Users/demo/dev/pulse-ios/Pulse", name: "Pulse", isDirectory: true),
                FileNode(path: "/Users/demo/dev/pulse-ios/project.yml", name: "project.yml", isDirectory: false),
            ],
        ],
        fileContents: demoDesignFiles,
        subagentsBySession: [
            "demo-c2": [
                SubagentSummary(
                    id: "agent-cache-audit", title: "Audit cache keys across workflows",
                    agentType: "Explore", toolUseID: "task-1", updatedAt: ago(3400),
                    isCompleted: true),
                SubagentSummary(
                    id: "agent-test-shard", title: "Shard the UI test suite",
                    agentType: "general-purpose", toolUseID: "task-2", updatedAt: ago(3350),
                    isCompleted: true),
            ]
        ],
        subagentScripts: [
            "agent-cache-audit": subagentCacheScript,
            "agent-test-shard": subagentShardScript,
        ],
        git: demoGit(
            root: "/Users/demo/dev/pulse-server", branch: "reconnect-backoff",
            upstream: "origin/reconnect-backoff", ahead: 2, behind: 0,
            changes: [
                GitChange(
                    path: "Sources/Pulse/Socket/Reconnect.swift", index: "M",
                    stagedInsertions: 7, stagedDeletions: 2),
                GitChange(
                    path: "Sources/Pulse/Socket/Backoff.swift", worktree: "M", insertions: 2,
                    deletions: 1),
                GitChange(
                    path: "Tests/PulseTests/ReconnectTests.swift", worktree: "M", insertions: 8,
                    deletions: 2),
                GitChange(
                    path: "Sources/Pulse/Socket/Jitter.swift", worktree: "?", untracked: true,
                    insertions: 17, bytes: 373),
            ],
            commits: [
                ("Hold the socket open across a suspend", "you", 900),
                ("Give the reconnect its own clock", "you", 26_000),
                ("Log every drop with the reason the peer gave", "you", 88_000),
            ]),
        gitPatches: [
            "Sources/Pulse/Socket/Reconnect.swift": demoReconnectPatch,
            "Sources/Pulse/Socket/Backoff.swift": demoBackoffPatch,
            "Tests/PulseTests/ReconnectTests.swift": demoReconnectTestsPatch,
            "Sources/Pulse/Socket/Jitter.swift": demoJitterPatch,
        ])

    private static var claudeLiveScript: [MockScriptStep] {
        [
            step(user("c1u1", .claudeCode, "The reconnect test fails maybe one run in five on CI. Find the race and fix it.", at: ago(390))),
            step(assistant("c1a1", .claudeCode, at: ago(380), streaming: true, model: "claude-fable-5")),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "r", kind: .reasoning(
                "The test asserts a reconnect within 500 ms, but the scheduler adds jitter to the backoff. Reading the scheduler before touching the test — if the worst case exceeds the assertion, the test is wrong, not the code.")))),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "t1", kind: .tool(ToolCall(
                id: "c1t1", name: "Read", status: .completed,
                input: .object(["file_path": .string("/Users/dev/pulse/Sources/Pulse/ReconnectScheduler.swift")]),
                output: "final class ReconnectScheduler {\n    var baseDelay: Duration = .milliseconds(400)\n    var jitter: ClosedRange<Double> = 0.6...1.4\n    …\n}",
                title: "Read Sources/Pulse/ReconnectScheduler.swift"))))),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "t2", kind: .text("")))),
            step(.partTextDelta(messageID: "c1a1", partID: "t2", delta: "Found it. `ReconnectScheduler` applies ±40% jitter to the 400 ms base delay, so the worst case is 560 ms — past the test's 500 ms ceiling. Pin it in tests:\n\n")),
            step(.partTextDelta(messageID: "c1a1", partID: "t2", delta: "```swift\nprotocol JitterSource: Sendable {\n    func factor(in range: ClosedRange<Double>) -> Double\n}\n\nstruct FixedJitter: JitterSource {\n    let value: Double\n    func factor(in _: ClosedRange<Double>) -> Double { value }\n}\n```\n\n")),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "t2b", kind: .tool(ToolCall(
                id: "c1t3", name: "Edit", status: .completed,
                input: .object(["file_path": .string("/Users/dev/pulse/Tests/PulseTests/ReconnectTests.swift")]),
                output: "Applied 1 edit",
                title: "Edit Tests/PulseTests/ReconnectTests.swift"))))),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "t2c", kind: .text("")))),
            step(.partTextDelta(messageID: "c1a1", partID: "t2c", delta: "The suite now pins the factor to 1.0, so the assertion measures the backoff and not the dice. Running it. The upstream discussion of this exact race is at https://github.com/swiftlang/swift")),
            step(.partUpserted(messageID: "c1a1", MessagePart(id: "t3", kind: .tool(ToolCall(
                id: "c1t2", name: "Bash", status: .running,
                input: .object([
                    "command": .string("swift test --filter ReconnectTests 2>&1 | tail -20"),
                    "description": .string("Run the reconnect suite with deterministic jitter"),
                ]),
                title: "swift test --filter ReconnectTests"))))),
            step(.status(.running)),
        ]
    }

    private static var claudeMigrationScript: [MockScriptStep] {
        [
            step(user("c2u1", .claudeCode, "Move CI from hosted runners to our self-hosted fleet. Keep the macOS builds green.", at: ago(10_900))),
            step(assistant("c2a1", .claudeCode, at: ago(10_880), model: "claude-fable-5", parts: [
                MessagePart(id: "r", kind: .reasoning(
                    "Four workflows reference hosted macOS runners. The fleet advertises self-hosted + macOS + arm64 labels. Cache paths differ per runner, so restore keys need the runner name folded in.")),
                MessagePart(id: "todo", kind: .tool(ToolCall(
                    id: "c2todo", name: "TodoWrite", status: .completed,
                    input: .object(["todos": .array([
                        .object(["content": .string("Inventory workflows on hosted runners"), "status": .string("completed")]),
                        .object(["content": .string("Add runner labels + concurrency groups"), "status": .string("completed")]),
                        .object(["content": .string("Rewrite cache keys per runner"), "status": .string("in_progress")]),
                        .object(["content": .string("Dry-run on the release branch"), "status": .string("pending")]),
                    ])]),
                    title: "Update todos"))),
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "c2t1", name: "Bash", status: .completed,
                    input: .object([
                        "command": .string("grep -rn 'runs-on' .github/workflows/"),
                        "description": .string("Inventory which workflows target hosted runners"),
                    ]),
                    output: "ci.yml: macos-14\nrelease.yml: macos-14\nnightly.yml: ubuntu-22.04\ndocs.yml: ubuntu-22.04",
                    title: "grep -l 'runs-on' .github/workflows"))),
                MessagePart(id: "t2", kind: .tool(ToolCall(
                    id: "c2t2", name: "Edit", status: .completed,
                    input: .object([
                        "file_path": .string(".github/workflows/ci.yml"),
                        "old_string": .string("runs-on: macos-14"),
                        "new_string": .string("runs-on: [self-hosted, macOS, arm64]"),
                    ]),
                    title: "Edit .github/workflows/ci.yml"))),
                MessagePart(id: "t2w", kind: .tool(ToolCall(
                    id: "c2t2w", name: "WebSearch", status: .completed,
                    input: .object(["query": .string("self-hosted GitHub runner cache eviction best practices")]),
                    output: "Web search results for query: \"self-hosted GitHub runner cache eviction best practices\"\n\nLinks: [{\"title\":\"Caching dependencies to speed up workflows\",\"url\":\"https://docs.github.com/actions/using-workflows/caching-dependencies\"},{\"title\":\"actions/cache: self-hosted runner notes\",\"url\":\"https://github.com/actions/cache#readme\"}]\n\nSelf-hosted runners keep caches on local disk, so eviction is the fleet's job — pin a per-runner budget and fold the runner name into restore keys.",
                    title: "WebSearch"))),
                MessagePart(id: "t3", kind: .tool(ToolCall(
                    id: "task-1", name: "Task", status: .completed,
                    input: .object(["description": .string("Audit cache keys across workflows")]),
                    output: "2 workflows share a cache key that collides across runners; keyed restore paths proposed.",
                    title: "Audit cache keys across workflows"))),
                MessagePart(id: "t4", kind: .tool(ToolCall(
                    id: "task-2", name: "Task", status: .completed,
                    input: .object(["description": .string("Shard the UI test suite")]),
                    output: "UI tests split into 3 shards; worst shard 11 min.",
                    title: "Shard the UI test suite"))),
                MessagePart(id: "t5", kind: .text(
                    "Both runners picked up jobs on the dry run. Summary:\n\n- `ci.yml` and `release.yml` now target the fleet with per-runner cache keys\n- concurrency groups cancel superseded runs\n- UI tests run in 3 shards, worst shard 11 min\n\n```yaml\nconcurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true\n```\n\nHosted runners stay as a fallback behind the `hosted-fallback` label until the fleet has a week of green.")),
            ], cost: nil, tokens: 52_800,
                context: MessageUsage(input: 1_800, output: 2_400, cacheRead: 141_600, cacheWrite: 3_100))),
            step(.status(.idle)),
        ]
    }

    private static var claudeDarkModeScript: [MockScriptStep] {
        [
            step(user("c3u1", .claudeCode, "Add dark mode to the settings screen. Match the tokens we use on Home.", at: ago(1740))),
            step(assistant("c3a1", .claudeCode, at: ago(1700), streaming: true, model: "claude-sonnet-5", parts: [
                MessagePart(id: "r", kind: .reasoning(
                    "SettingsView hardcodes .white backgrounds in three places; Home reads Theme.Color tokens. Swapping each literal for the semantic token keeps both screens in lockstep.")),
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "c3t1", name: "Read", status: .completed,
                    output: "12:  .background(Color.white)\n47:  .background(Color.white)\n81:  .foregroundColor(.black)",
                    title: "Read Pulse/Settings/SettingsView.swift"))),
                MessagePart(id: "t2", kind: .text(
                    "Three hardcoded colors, and Home already reads the semantic tokens for exactly these surfaces. Mapping each literal onto the token it should have been:")),
                MessagePart(id: "t2b", kind: .text(
                    "```diff\n- .background(Color.white)\n+ .background(Theme.Color.surface)\n\n- .foregroundColor(.black)\n+ .foregroundColor(Theme.Color.label)\n```")),
                MessagePart(id: "t2c", kind: .text(
                    "That keeps the two screens in lockstep the next time the palette moves. Starting with the first edit:")),
                MessagePart(id: "t3", kind: .tool(ToolCall(
                    id: "c3t2", name: "Edit", status: .pending,
                    input: .object([
                        "file_path": .string("Pulse/Settings/SettingsView.swift"),
                        "old_string": .string(".background(Color.white)"),
                        "new_string": .string(".background(Theme.Color.surface)"),
                    ]),
                    title: "Edit Pulse/Settings/SettingsView.swift"))),
            ])),
            step(.permission(PermissionRequest(
                id: "perm-c3", sessionID: "demo-c3",
                title: "Edit Pulse/Settings/SettingsView.swift", toolName: "Edit"))),
            step(.status(.running)),
        ]
    }

    /// The board every client can open in the demo: the manifest and the mocks the transcript's
    /// card points at, served from the same paths the card names.
    private static var demoDesignFiles: [String: String] {
        var files: [String: String] = [:]
        let board = DesignDemo.board
        let manifest = try? JSONEncoder().encode(board.manifest)
        files[DesignPaths.manifest(in: board.directory)] =
            manifest.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        for artboard in board.artboards {
            files[board.path(of: artboard)] = DesignDemo.pages[artboard.letter] ?? ""
        }
        return files
    }

    /// A design turn: the brief goes out as an ordinary prompt, the agent draws three alternatives
    /// into the project, and the manifest it writes last becomes the board card in the transcript.
    private static var claudeDesignScript: [MockScriptStep] {
        [
            step(user("c5u1", .claudeCode, DesignBrief(
                request: "the composer, for what people actually use it for", count: 3,
                reference: "Pulse/Chat/ComposerView.swift", slug: "composer-0818-1423").prompt,
                at: ago(2580))),
            step(assistant("c5a1", .claudeCode, at: ago(2560), model: "claude-opus-4-8", parts: [
                MessagePart(id: "r", kind: .reasoning(
                    "Reading the composer as it is, then drawing three alternatives that differ in what they make easy rather than in colour.")),
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "c5t1", name: "Read", status: .completed,
                    input: .object(["file_path": .string("Pulse/Chat/ComposerView.swift")]),
                    title: "Read Pulse/Chat/ComposerView.swift"))),
                MessagePart(id: "t2", kind: .text(
                    "Nine actions, one line, and the two people reach for most are behind a menu. Drawing three ways out of that:")),
                MessagePart(id: "t3", kind: .tool(ToolCall(
                    id: "c5t2", name: "Write", status: .completed,
                    input: .object([
                        "file_path": .string("\(DesignDemo.directory)/A.html")
                    ]),
                    title: "Write A.html"))),
                MessagePart(id: "t4", kind: .tool(ToolCall(
                    id: "c5t3", name: "Write", status: .completed,
                    input: .object([
                        "file_path": .string("\(DesignDemo.directory)/B.html")
                    ]),
                    title: "Write B.html"))),
                MessagePart(id: "t5", kind: .tool(ToolCall(
                    id: "c5t4", name: "Write", status: .completed,
                    input: .object([
                        "file_path": .string("\(DesignDemo.directory)/C.html")
                    ]),
                    title: "Write C.html"))),
                MessagePart(id: "t6", kind: .tool(ToolCall(
                    id: "c5t5", name: "Write", status: .completed,
                    input: .object([
                        "file_path": .string(DesignPaths.manifest(in: DesignDemo.directory))
                    ]),
                    title: "Write board.json"))),
                MessagePart(id: "t7", kind: .text(
                    "Three alternatives, drawn and nothing built: conservative, an adaptive row, and everything visible at once.")),
            ], cost: nil, tokens: 18_600)),
            step(.status(.idle)),
        ]
    }

    private static var claudeExplainerScript: [MockScriptStep] {
        [
            step(user("c4u1", .claudeCode, "Walk me through how token refresh works in pulse-server. Where does it retry?", at: ago(95_400))),
            step(assistant("c4a1", .claudeCode, at: ago(95_300), model: "claude-fable-5", parts: [
                MessagePart(id: "t", kind: .text(
                    "## Token lifecycle\n\nThe flow lives in Sources/Pulse/Auth/TokenStore.swift and has three phases:\n\n- **Mint** — `TokenStore.bootstrap()` exchanges the refresh token at startup\n- **Serve** — requests read the in-memory access token; no locking on the hot path\n- **Refresh** — a background task renews 90 seconds before expiry\n\n| Phase | Trigger | Network |\n|---|---|--:|\n| Mint | process start | 1 call |\n| Serve | every request | none |\n| Refresh | 90s before expiry | 1 call |\n\n> The refresh task is the only writer. Readers never block — they race the swap and always see either the old or the new token, both valid.\n\nRetry policy: refresh failures back off exponentially (`1s, 2s, 4s… capped at 60s`) and never give up while the process lives. See [RFC 6749 §6](https://datatracker.ietf.org/doc/html/rfc6749#section-6) for the grant semantics.")),
            ], cost: nil, tokens: 12_400)),
            step(compaction("c4x", .claudeCode, at: ago(94_250))),
            step(user("c4u2", .claudeCode, "And what happens when the refresh itself 401s?", at: ago(94_200))),
            step(assistant("c4a2", .claudeCode, at: ago(94_100), model: "claude-fable-5", parts: [
                MessagePart(id: "t1", kind: .text(
                    "A 401 on refresh means the refresh token itself is dead — retrying is pointless. The store escalates instead:")),
                MessagePart(id: "t2", kind: .text(
                    "```swift\ncase .unauthorized:\n    state = .needsReauth\n    continuations.forEach { $0.finish(throwing: AuthError.sessionExpired) }\n    onReauthRequired?()\n```")),
                MessagePart(id: "t3", kind: .text(
                    "Every in-flight request fails fast with `sessionExpired`, and the reauth hook signs the node back in with its device identity. No half-authenticated limbo.")),
            ], cost: nil, tokens: 9_100)),
            step(.status(.idle)),
        ]
    }

    private static var claudeReplyA: [MockScriptStep] {
        [
            step(assistant("reply-a", .claudeCode, at: now, streaming: true, model: "claude-fable-5"), ms: 350),
            step(.partUpserted(messageID: "reply-a", MessagePart(id: "r", kind: .reasoning(
                "Reading the relevant code before changing anything — the smallest correct diff wins."))), ms: 900),
            step(.partUpserted(messageID: "reply-a", MessagePart(id: "t", kind: .text(""))), ms: 500),
            step(.partTextDelta(messageID: "reply-a", partID: "t", delta: "Here's the plan:\n\n1. Reproduce and pin down the current behavior\n"), ms: 350),
            step(.partTextDelta(messageID: "reply-a", partID: "t", delta: "2. Make the smallest change that fixes it\n3. Prove it with a test\n\n"), ms: 350),
            step(.partUpserted(messageID: "reply-a", MessagePart(id: "tool", kind: .tool(ToolCall(
                id: "reply-a-t1", name: "Bash", status: .running, title: "swift test")))), ms: 500),
            step(.partUpserted(messageID: "reply-a", MessagePart(id: "tool", kind: .tool(ToolCall(
                id: "reply-a-t1", name: "Bash", status: .completed,
                output: "Executed 214 tests, with 0 failures (0 unexpected) in 38.2s",
                title: "swift test")))), ms: 1400),
            step(.partUpserted(messageID: "reply-a", MessagePart(id: "t2", kind: .text(""))), ms: 300),
            step(.partTextDelta(messageID: "reply-a", partID: "t2", delta: "All 214 tests green. The change is minimal and covered by a regression test — want me to open the PR?"), ms: 400),
        ]
    }

    private static var claudeReplyB: [MockScriptStep] {
        [
            step(assistant("reply-b", .claudeCode, at: now, streaming: true, model: "claude-fable-5"), ms: 350),
            step(.partUpserted(messageID: "reply-b", MessagePart(id: "r", kind: .reasoning(
                "This touches a shared code path — checking the call sites before answering."))), ms: 800),
            step(.partUpserted(messageID: "reply-b", MessagePart(id: "t", kind: .text(""))), ms: 400),
            step(.partTextDelta(messageID: "reply-b", partID: "t", delta: "Good question — two call sites depend on the current behavior. "), ms: 400),
            step(.partTextDelta(messageID: "reply-b", partID: "t", delta: "The safe version looks like this:\n\n"), ms: 350),
            step(.partTextDelta(messageID: "reply-b", partID: "t", delta: "```swift\nguard let session = store.session(for: id) else {\n    return .missing(id)\n}\nreturn .found(session)\n```\n\n"), ms: 500),
            step(.partTextDelta(messageID: "reply-b", partID: "t", delta: "Both callers already handle `.missing`, so this ships without a migration."), ms: 400),
        ]
    }

    private static var subagentCacheScript: [MockScriptStep] {
        [
            step(user("sc-u", .claudeCode, "Audit cache keys across all workflows. Report collisions.", at: ago(3500))),
            step(assistant("sc-a", .claudeCode, at: ago(3450), parts: [
                MessagePart(id: "r", kind: .reasoning("Grepping every workflow for actions/cache usage and comparing key expressions.")),
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "sc-t1", name: "Grep", status: .completed,
                    output: "ci.yml: key: spm-${{ hashFiles('Package.resolved') }}\nrelease.yml: key: spm-${{ hashFiles('Package.resolved') }}",
                    title: "grep 'key:' .github/workflows"))),
                MessagePart(id: "t2", kind: .text(
                    "Two workflows share `spm-<hash>` — fine on hosted runners, a collision on the fleet where toolchains differ per machine. Fold `runner.name` into the key:\n\n```yaml\nkey: spm-${{ runner.name }}-${{ hashFiles('Package.resolved') }}\n```")),
            ])),
            step(.status(.idle)),
        ]
    }

    private static var subagentShardScript: [MockScriptStep] {
        [
            step(user("ss-u", .claudeCode, "Shard the UI test suite so the worst shard stays under 12 minutes.", at: ago(3400))),
            step(assistant("ss-a", .claudeCode, at: ago(3360), parts: [
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "ss-t1", name: "Bash", status: .completed,
                    output: "PulseUITests: 41 tests, 31m 12s total\nslowest: CheckoutFlowTests (6m 40s)",
                    title: "xcodebuild test -enumerate-tests"))),
                MessagePart(id: "t2", kind: .text(
                    "Split by historical duration into 3 shards: 10m 50s / 11m 00s / 9m 22s. `CheckoutFlowTests` anchors shard 2 alone with the fast unit-ish tests packed around it.")),
            ])),
            step(.status(.idle)),
        ]
    }
}
