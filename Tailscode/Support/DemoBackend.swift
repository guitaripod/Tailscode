import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// The self-contained demo world: two scripted servers that saturate every screen with
/// believable sessions, quotas, models, and file trees — no tailnet required. Ships in
/// Release so App Review and first-run users can explore the full app before owning a server.
enum DemoWorld {
    static let profilePrefix = "demo-"

    static let claudeProfile = ConnectionProfile(
        id: "demo-claude", name: "studio", backend: .claudeCode,
        baseURL: URL(string: "http://studio.tailnet-demo.ts.net:4098")!)

    static let openCodeProfile = ConnectionProfile(
        id: "demo-opencode", name: "homelab", backend: .openCode,
        baseURL: URL(string: "http://homelab.tailnet-demo.ts.net:4096")!)

    static var profiles: [ConnectionProfile] { [claudeProfile, openCodeProfile] }

    static func backend(for profileID: String) -> (any CodingAgentBackend)? {
        switch profileID {
        case claudeProfile.id: return claude
        case openCodeProfile.id: return openCode
        default: return nil
        }
    }

    private static let now = Date()
    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private static func hence(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    // MARK: - Claude Code server ("studio", claude-bridge)

    static let claude: MockBackend = MockBackend(
        agentType: .claudeCode,
        scripts: [
            "demo-c1": claudeLiveScript,
            "demo-c2": claudeMigrationScript,
            "demo-c3": claudeDarkModeScript,
            "demo-c4": claudeExplainerScript,
        ],
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
                id: "demo-c4", agentType: .claudeCode, title: "Explain the auth token refresh flow",
                directory: "/Users/demo/dev/pulse-server", createdAt: ago(95_500), updatedAt: ago(94_000),
                model: "claude-haiku-4-5", reasoningEffort: "low"),
        ],
        models: [
            ModelInfo(id: "claude-fable-5", name: "Fable 5", providerID: "anthropic"),
            ModelInfo(id: "claude-opus-4-8", name: "Opus 4.8", providerID: "anthropic"),
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic"),
            ModelInfo(id: "claude-haiku-4-5", name: "Haiku 4.5", providerID: "anthropic"),
        ],
        defaultModelID: "claude-fable-5",
        reasoningEffortOptions: ["low", "medium", "high", "xhigh"],
        health: ServerHealth(healthy: true, version: "1.2.0"),
        capabilities: BackendCapabilities(
            supportsFileBrowsing: true, supportsDiffs: false, supportsPermissions: true,
            supportsMultipleSessions: true, supportsModelSelection: true, supportsAttachments: true,
            supportsReasoningEffort: true, supportsClearing: true, supportsForking: true,
            supportsAbort: true, supportsSessionUsage: true, supportsQuestions: false,
            supportsRenaming: true, supportsSubagents: true),
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
        subagents: [
            SubagentSummary(
                id: "agent-cache-audit", title: "Audit cache keys across workflows",
                agentType: "Explore", toolUseID: "task-1", updatedAt: ago(3400), isCompleted: true),
            SubagentSummary(
                id: "agent-test-shard", title: "Shard the UI test suite",
                agentType: "general-purpose", toolUseID: "task-2", updatedAt: ago(3350),
                isCompleted: true),
        ],
        subagentScripts: [
            "agent-cache-audit": subagentCacheScript,
            "agent-test-shard": subagentShardScript,
        ])

    // MARK: - opencode server ("homelab")

    static let openCode: MockBackend = MockBackend(
        agentType: .openCode,
        scripts: [
            "demo-o1": openCodeRefactorScript,
            "demo-o2": openCodePricingScript,
            "demo-o3": openCodeLeakScript,
            "demo-o4": openCodeNotesScript,
        ],
        replyTurns: [openCodeReplyA, openCodeReplyB],
        interactive: true,
        sessions: [
            AgentSession(
                id: "demo-o1", agentType: .openCode, title: "Refactor the auth module to async/await",
                directory: "/home/demo/dev/acme-api", createdAt: ago(13_200), updatedAt: ago(540)),
            AgentSession(
                id: "demo-o2", agentType: .openCode, title: "Ship the pricing page A/B test",
                directory: "/home/demo/dev/acme-web", createdAt: ago(11_400), updatedAt: ago(10_200)),
            AgentSession(
                id: "demo-o3", agentType: .openCode, title: "Hunt the memory leak in ImagePipeline",
                directory: "/home/demo/dev/acme-ios", createdAt: ago(94_000), updatedAt: ago(90_000)),
            AgentSession(
                id: "demo-o4", agentType: .openCode, title: "Write the v2.3 release notes",
                directory: "/home/demo/dev/acme-api", createdAt: ago(267_000), updatedAt: ago(266_000)),
        ],
        models: [
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic"),
            ModelInfo(id: "claude-opus-4-8", name: "Opus 4.8", providerID: "anthropic"),
            ModelInfo(id: "gpt-5.1-codex", name: "GPT-5.1 Codex", providerID: "openai"),
            ModelInfo(id: "o4-mini", name: "o4-mini", providerID: "openai"),
            ModelInfo(id: "gemini-3-pro", name: "Gemini 3 Pro", providerID: "google"),
        ],
        defaultModelID: "claude-sonnet-5",
        health: ServerHealth(healthy: true, version: "0.9.4"),
        capabilities: BackendCapabilities(
            supportsFileBrowsing: true, supportsDiffs: true, supportsPermissions: true,
            supportsMultipleSessions: true, supportsModelSelection: true, supportsAttachments: true,
            supportsReasoningEffort: false, supportsClearing: false, supportsForking: false,
            supportsAbort: true, supportsSessionUsage: true, supportsQuestions: true,
            supportsRenaming: true, supportsSubagents: false),
        sessionUsage: AgentUsage(costUSD: 0.42, tokens: 18_431),
        fileTree: [
            ".": [
                FileNode(path: "/home/demo/dev", name: "dev", isDirectory: true),
                FileNode(path: "/home/demo/ops", name: "ops", isDirectory: true),
                FileNode(path: "/home/demo/notes.md", name: "notes.md", isDirectory: false),
            ],
            "/home/demo/dev": [
                FileNode(path: "/home/demo/dev/acme-api", name: "acme-api", isDirectory: true),
                FileNode(path: "/home/demo/dev/acme-web", name: "acme-web", isDirectory: true),
                FileNode(path: "/home/demo/dev/acme-ios", name: "acme-ios", isDirectory: true),
            ],
            "/home/demo/dev/acme-api": [
                FileNode(path: "/home/demo/dev/acme-api/cmd", name: "cmd", isDirectory: true),
                FileNode(path: "/home/demo/dev/acme-api/internal", name: "internal", isDirectory: true),
                FileNode(path: "/home/demo/dev/acme-api/go.mod", name: "go.mod", isDirectory: false),
                FileNode(path: "/home/demo/dev/acme-api/README.md", name: "README.md", isDirectory: false),
            ],
        ])

    // MARK: - Claude scripts

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
            step(.partTextDelta(messageID: "c1a1", partID: "t2", delta: "Found it. `ReconnectScheduler` applies ±40% jitter to the 400 ms base delay, so the worst case is 560 ms — past the test's 500 ms ceiling.\n\n")),
            step(.partTextDelta(messageID: "c1a1", partID: "t2", delta: "Injecting a deterministic jitter source in tests is the honest fix — the scheduler keeps its production behavior. Running the suite now.")),
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
            ], cost: nil, tokens: 52_800)),
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
                    "Three hardcoded colors. Replacing them with the semantic tokens — this is the first edit:")),
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

    private static var claudeExplainerScript: [MockScriptStep] {
        [
            step(user("c4u1", .claudeCode, "Walk me through how token refresh works in pulse-server. Where does it retry?", at: ago(95_400))),
            step(assistant("c4a1", .claudeCode, at: ago(95_300), model: "claude-fable-5", parts: [
                MessagePart(id: "t", kind: .text(
                    "## Token lifecycle\n\nThe flow lives in Sources/Pulse/Auth/TokenStore.swift and has three phases:\n\n- **Mint** — `TokenStore.bootstrap()` exchanges the refresh token at startup\n- **Serve** — requests read the in-memory access token; no locking on the hot path\n- **Refresh** — a background task renews 90 seconds before expiry\n\n> The refresh task is the only writer. Readers never block — they race the swap and always see either the old or the new token, both valid.\n\nRetry policy: refresh failures back off exponentially (`1s, 2s, 4s… capped at 60s`) and never give up while the process lives. See [RFC 6749 §6](https://datatracker.ietf.org/doc/html/rfc6749#section-6) for the grant semantics.")),
            ], cost: nil, tokens: 12_400)),
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
            step(.partTextDelta(messageID: "reply-a", partID: "t", delta: "All 214 tests green. The change is minimal and covered by a regression test — want me to open the PR?"), ms: 400),
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

    // MARK: - opencode scripts

    private static var openCodeRefactorScript: [MockScriptStep] {
        [
            step(user("o1u0", .openCode, "Run the linter and fix anything it flags.", at: ago(13_100))),
            step(assistant("o1a0", .openCode, at: ago(13_050), model: "claude-sonnet-5", parts: [
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "o1t0", name: "Bash", status: .completed,
                    output: "internal/auth/client.go:88: error strings should not be capitalized\ninternal/auth/client.go:114: unused parameter ctx",
                    title: "golangci-lint run ./..."))),
                MessagePart(id: "t2", kind: .text("Two findings, both in `auth/client.go` — fixed and re-ran clean.")),
            ], cost: 0.38, tokens: 9_800)),
            step(user("o1u1", .openCode, "Refactor the auth module to async/await and add a test.", at: ago(840))),
            step(assistant("o1a1", .openCode, at: ago(800), model: "claude-sonnet-5", parts: [
                MessagePart(id: "r", kind: .reasoning("Scanning the auth module for completion-handler APIs to convert.")),
                MessagePart(id: "t1", kind: .text("I'll convert `AuthClient` to async/await, then add a unit test.\n\nFirst, finding the callback-based call sites.")),
                MessagePart(id: "t2", kind: .tool(ToolCall(
                    id: "o1t1", name: "Grep", status: .completed,
                    output: "Sources/Auth/AuthClient.swift:42: func login(completion:)\nSources/Auth/AuthClient.swift:58: func refresh(completion:)",
                    title: "grep -rn completionHandler Sources/Auth"))),
                MessagePart(id: "t3", kind: .text(
                    "Found 2 call sites — converting both and adding `AuthClientTests.login()`.\n\n```swift\nfunc login() async throws -> Session {\n    let token = try await api.token()\n    return Session(token: token)\n}\n```\n\nDone. Both call sites migrated; the test covers the happy path and the expired-token retry.")),
            ], cost: 0.42, tokens: 18_431)),
            step(.status(.idle)),
        ]
    }

    private static var openCodePricingScript: [MockScriptStep] {
        [
            step(user("o2u1", .openCode, "Set up the pricing page A/B test. Two variants: monthly-first vs annual-first.", at: ago(11_200))),
            step(assistant("o2a1", .openCode, at: ago(11_100), model: "gpt-5.1-codex", parts: [
                MessagePart(id: "t1", kind: .text("Wiring the experiment through our flags service so the split is sticky per visitor.")),
                MessagePart(id: "t2", kind: .tool(ToolCall(
                    id: "o2t1", name: "Write", status: .completed,
                    input: .object([
                        "file_path": .string("src/experiments/pricing-order.ts"),
                        "content": .string("export const pricingOrder = experiment('pricing-order', {\n  variants: ['monthly-first', 'annual-first'],\n  exposure: 0.5,\n})"),
                    ]),
                    title: "Write src/experiments/pricing-order.ts"))),
                MessagePart(id: "t3", kind: .text("Both variants render behind the flag and the exposure event fires once per visitor. One decision before I flip it on:")),
            ], cost: 0.55, tokens: 21_600)),
            step(.question(QuestionRequest(
                id: "q-o2", sessionID: "demo-o2",
                questions: [
                    QuestionRequest.Item(
                        question: "Which surfaces should the experiment run on? Pick every one that applies.",
                        header: "Target surfaces",
                        options: [
                            QuestionRequest.Option(
                                label: "Web checkout",
                                description: "Highest traffic — fastest read on significance"),
                            QuestionRequest.Option(
                                label: "iOS paywall",
                                description: "Native sheet; needs an app release to change copy"),
                            QuestionRequest.Option(
                                label: "Android paywall",
                                description: "Play billing; mirrors the iOS variant"),
                            QuestionRequest.Option(
                                label: "Email upgrade nudge",
                                description: "Lower volume, but attributes cleanly"),
                        ],
                        multiple: true, custom: true)
                ]))),
            step(.status(.running)),
        ]
    }

    private static var openCodeLeakScript: [MockScriptStep] {
        [
            step(user("o3u1", .openCode, "Memory climbs about 40 MB per scroll session in ImagePipeline. Find the leak.", at: ago(93_800))),
            step(assistant("o3a1", .openCode, at: ago(93_700), model: "claude-opus-4-8", parts: [
                MessagePart(id: "r", kind: .reasoning("A steady climb tied to scrolling smells like a cache without eviction or a retain cycle in a scroll callback.")),
                MessagePart(id: "t1", kind: .tool(ToolCall(
                    id: "o3t1", name: "Bash", status: .error,
                    output: "leaks: target process died before scan completed",
                    title: "leaks --atExit -- ./ImagePipelineBench"))),
            ], cost: 0.85, tokens: 14_200)),
            step(assistant("o3a2", .openCode, at: ago(93_500),
                error: "Provider overloaded — the turn was retried automatically.")),
            step(assistant("o3a3", .openCode, at: ago(93_300), model: "claude-opus-4-8", parts: [
                MessagePart(id: "t1", kind: .text("The bench crash was the leak itself — unbounded thumbnail cache. `ImagePipeline` captures `self` strongly in the prefetch closure, so cancelled prefetches never release their buffers:")),
                MessagePart(id: "t2", kind: .tool(ToolCall(
                    id: "o3t2", name: "Edit", status: .completed,
                    input: .object([
                        "file_path": .string("Sources/ImagePipeline/Prefetcher.swift"),
                        "old_string": .string("queue.async { self.decode(request) }"),
                        "new_string": .string("queue.async { [weak self] in self?.decode(request) }"),
                    ]),
                    title: "Edit Sources/ImagePipeline/Prefetcher.swift"))),
                MessagePart(id: "t3", kind: .text("With the cycle broken, the cache actually evicts. Steady state is now ~31 MB regardless of scroll distance.")),
            ], cost: 1.85, tokens: 61_204)),
            step(user("o3u2", .openCode, "Nice. Add a regression test that fails on the old code.", at: ago(90_600))),
            step(assistant("o3a4", .openCode, at: ago(90_400), model: "claude-opus-4-8", parts: [
                MessagePart(id: "t1", kind: .text(
                    "```swift\nfunc testPrefetcherReleasesCancelledRequests() {\n    weak var leaked: Prefetcher?\n    autoreleasepool {\n        let prefetcher = Prefetcher(cache: .ephemeral)\n        leaked = prefetcher\n        prefetcher.prefetch(.stub(count: 200))\n        prefetcher.cancelAll()\n    }\n    XCTAssertNil(leaked)\n}\n```")),
                MessagePart(id: "t2", kind: .text("Fails in 0.3s on the old code, passes on the fix.")),
            ], cost: 2.10, tokens: 48_900)),
            step(.status(.idle)),
        ]
    }

    private static var openCodeNotesScript: [MockScriptStep] {
        [
            step(ChatMessage(
                id: "o4u1", role: .user, agentType: .openCode,
                parts: [
                    MessagePart(id: "t", kind: .text("Draft release notes for v2.3 from the merged PRs. Style guide attached.")),
                    MessagePart(id: "f", kind: .file(FileReference(
                        mime: "text/markdown", filename: "release-style.md"))),
                ],
                createdAt: ago(266_800))),
            step(assistant("o4a1", .openCode, at: ago(266_600), model: "gemini-3-pro", parts: [
                MessagePart(id: "t", kind: .text(
                    "## v2.3 — Faster feeds, calmer nights\n\n**Highlights**\n\n- Feed loads 2.1× faster on cold start (query batching, #482)\n- Push notifications respect quiet hours across time zones (#476)\n- CSV export for workspace admins (#469)\n\n**Fixes**\n\n- Avatar cache no longer grows unbounded (#488)\n- Deep links open the right tab after cold launch (#471)\n\nMatched the attached style guide — verbs first, no internal ticket ids, user-visible wins only.")),
            ], cost: 1.20, tokens: 26_700)),
            step(.status(.idle)),
        ]
    }

    private static var openCodeReplyA: [MockScriptStep] {
        [
            step(assistant("oreply-a", .openCode, at: now, streaming: true, model: "claude-sonnet-5"), ms: 350),
            step(.partUpserted(messageID: "oreply-a", MessagePart(id: "t", kind: .text(""))), ms: 600),
            step(.partTextDelta(messageID: "oreply-a", partID: "t", delta: "On it. Checking the project first so the change lands in the right place.\n\n"), ms: 400),
            step(.partUpserted(messageID: "oreply-a", MessagePart(id: "tool", kind: .tool(ToolCall(
                id: "oreply-a-t1", name: "Grep", status: .running, title: "grep -rn TODO src/")))), ms: 600),
            step(.partUpserted(messageID: "oreply-a", MessagePart(id: "tool", kind: .tool(ToolCall(
                id: "oreply-a-t1", name: "Grep", status: .completed,
                output: "src/routes/billing.ts:41\nsrc/lib/flags.ts:12",
                title: "grep -rn TODO src/")))), ms: 1100),
            step(.partTextDelta(messageID: "oreply-a", partID: "t", delta: "Two spots to touch. Making the edits and running the checks — I'll report back with the diff."), ms: 450),
        ]
    }

    private static var openCodeReplyB: [MockScriptStep] {
        [
            step(assistant("oreply-b", .openCode, at: now, streaming: true, model: "claude-sonnet-5"), ms: 350),
            step(.partUpserted(messageID: "oreply-b", MessagePart(id: "t", kind: .text(""))), ms: 500),
            step(.partTextDelta(messageID: "oreply-b", partID: "t", delta: "Done — here's the shape of it:\n\n"), ms: 400),
            step(.partTextDelta(messageID: "oreply-b", partID: "t", delta: "```ts\nexport async function loadFeed(cursor?: string) {\n  const page = await api.feed({ cursor, limit: 50 })\n  return { items: page.items, next: page.cursor }\n}\n```\n\n"), ms: 550),
            step(.partTextDelta(messageID: "oreply-b", partID: "t", delta: "Typed, paginated, and the caller controls the batch size. Tests pass."), ms: 400),
        ]
    }

    // MARK: - Builders

    private static func step(_ event: BackendEvent, ms: Int = 10) -> MockScriptStep {
        MockScriptStep(event, delay: .milliseconds(ms))
    }

    private static func step(_ message: ChatMessage, ms: Int = 10) -> MockScriptStep {
        MockScriptStep(.messageUpserted(message, replaceParts: true), delay: .milliseconds(ms))
    }

    private static func user(
        _ id: String, _ type: AgentType, _ text: String, at date: Date
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: type,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date)
    }

    private static func assistant(
        _ id: String, _ type: AgentType, at date: Date, streaming: Bool = false,
        error: String? = nil, model: String? = nil, parts: [MessagePart] = [],
        cost: Double? = nil, tokens: Int? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: type, parts: parts, createdAt: date,
            completedAt: streaming ? nil : date.addingTimeInterval(45),
            isStreaming: streaming, error: error, costUSD: cost,
            providerID: type == .openCode ? "opencode-go" : "anthropic",
            modelID: model, totalTokens: tokens)
    }
}
