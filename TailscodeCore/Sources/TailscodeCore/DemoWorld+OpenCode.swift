import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation

extension DemoWorld {
    public static let openCode: MockBackend = MockBackend(
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
                directory: "/home/demo/dev/acme-api", createdAt: ago(13_200), updatedAt: ago(540),
                model: "gpt-5.1-codex", reasoningEffort: "high"),
            AgentSession(
                id: "demo-o2", agentType: .openCode, title: "Ship the pricing page A/B test",
                directory: "/home/demo/dev/acme-web", createdAt: ago(11_400), updatedAt: ago(10_200),
                model: "ollama/qwen3:14b", reasoningEffort: "think"),
            AgentSession(
                id: "demo-o3", agentType: .openCode, title: "Hunt the memory leak in ImagePipeline",
                directory: "/home/demo/dev/acme-ios", createdAt: ago(94_000), updatedAt: ago(90_000),
                model: "gemini-3-pro"),
            AgentSession(
                id: "demo-o4", agentType: .openCode, title: "Write the v2.3 release notes",
                directory: "/home/demo/dev/acme-api", createdAt: ago(267_000), updatedAt: ago(266_000),
                model: "ollama/glm-4.7-air:latest"),
        ],
        models: [
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic"),
            ModelInfo(id: "claude-opus-4-8", name: "Opus 4.8", providerID: "anthropic"),
            ModelInfo(
                id: "gpt-5.1-codex", name: "GPT-5.1 Codex", providerID: "openai",
                variants: ["none", "minimal", "low", "medium", "high", "xhigh"]),
            ModelInfo(id: "o4-mini", name: "o4-mini", providerID: "openai"),
            ModelInfo(id: "gemini-3-pro", name: "Gemini 3 Pro", providerID: "google"),
            ModelInfo(
                id: "qwen3:14b", name: "Qwen3 14B", providerID: "ollama",
                variants: ["nothink", "think"]),
            ModelInfo(
                id: "glm-5.3-flash", name: "GLM-5.3 Flash", providerID: "opencode-go",
                variants: ["low", "high"]),
            ModelInfo(
                id: "qwen3-coder-30b-a3b", name: "Bolt", providerID: "llama-server",
                contextWindow: 262_144),
            ModelInfo(
                id: "qwen3.6-27b", name: "Pennyroyal", providerID: "llama-server",
                contextWindow: 131_072),
        ],
        defaultModelID: "claude-sonnet-5",
        health: ServerHealth(healthy: true, version: "0.9.4"),
        capabilities: BackendCapabilities(
            supportsFileBrowsing: true, supportsDiffs: true, supportsPermissions: true,
            supportsMultipleSessions: true, supportsModelSelection: true, supportsAttachments: true,
            supportsReasoningEffort: true, supportsClearing: false, supportsForking: false,
            supportsAbort: true, supportsSessionUsage: true, supportsUsageAnalytics: true,
            supportsQuestions: true, supportsRenaming: true, supportsSubagents: false,
            supportsCommands: true, supportsRevert: true),
        sessionUsage: AgentUsage(costUSD: 0.42, tokens: 18_431),
        analytics: demoLocalAnalytics(),
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
        ],
        diffs: [
            FileDiff(path: "internal/auth/session.go", additions: 122, deletions: 47),
            FileDiff(path: "internal/auth/token.go", additions: 18, deletions: 9),
        ],
        git: demoGit(
            root: "/home/demo/dev/acme-api", branch: "async-auth", upstream: nil, ahead: 0,
            behind: 0,
            changes: [
                GitChange(
                    path: "internal/auth/session.go", worktree: "M", insertions: 122,
                    deletions: 47),
                GitChange(path: "internal/auth/token.go", worktree: "M", insertions: 18, deletions: 9),
                GitChange(path: "cmd/api/main.go", worktree: "D", deletions: 12),
            ],
            commits: [
                ("Take the mutex out of the token refresh", "you", 5_400),
                ("Name the context every handler is given", "you", 40_000),
            ]))

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
            ], cost: 0.42, tokens: 18_431,
                context: MessageUsage(input: 900, output: 1_300, cacheRead: 61_200, cacheWrite: 2_000))),
            step(note("o1n1", .workFinished(
                "go test ./internal/auth/...", work: .command, outcome: .completed), at: ago(700))),
            step(note("o1n2", .model(
                ModelSelection(providerID: "openai", modelID: "gpt-5.1-codex"), effort: "high",
                previous: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")),
                at: ago(560))),
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
            ], cost: 0.55, tokens: 21_600,
                context: MessageUsage(input: 3_200, output: 1_900, cacheRead: 88_000))),
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
                                label: "In-app paywall",
                                description: "Native sheet; needs an app release to change copy"),
                            QuestionRequest.Option(
                                label: "Renewal reminder",
                                description: "Sent the week before; mirrors the checkout variant"),
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
            ], cost: 0.85, tokens: 14_200,
                context: MessageUsage(input: 1_200, output: 2_600, cacheRead: 171_000))),
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
}
