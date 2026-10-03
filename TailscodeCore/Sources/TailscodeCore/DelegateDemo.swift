import CodingAgentKit
import Foundation

/// What a desk talks to: the daemon over HTTP, or the demo's scripted dispatcher. One shape, so
/// every surface behaves identically on both and the demo is the real thing minus the machine.
public protocol DelegateTransport: Sendable {
    func capabilities() async throws -> DelegateCapabilities
    func tiers() async throws -> [DelegateTier]
    func runs(limit: Int) async throws -> [DelegateRun]
    func run(id: String) async throws -> DelegateRunDetail
    func stats(taskClass: String?) async throws -> [DelegateStat]
    func start(packet: DelegatePacket, overrides: DelegateOverrides) async throws -> String
    func replay(runID: String, overrides: DelegateOverrides) async throws -> String
    func approve(runID: String, approved: Bool) async throws
    func cancel(runID: String) async throws
    func events(runID: String, after: Int) -> AsyncThrowingStream<DelegateEnvelope, Error>
    func patch(runID: String) async throws -> String
    func apply(runID: String) async throws -> [String]
    func discard(runID: String) async throws -> [String]
}

extension DelegateClient: DelegateTransport {}

/// The demo dispatcher: the two demo machines share one scripted daemon that behaves like the real
/// one — a run climbs its ladder over seconds, a gated rung waits for your answer and climbs when
/// you give it, a packet you write is tried, fails once where the ladder lets it, and passes one
/// rung up. Nothing here reaches a network, and it ships in Release so App Review and a first-run
/// user can work the whole feature before owning a machine.
public enum DelegateDemo {
    public static let hosts: Set<String> = ["studio.tailnet-demo.ts.net", "homelab.tailnet-demo.ts.net"]

    public static func isDemoHost(_ host: String) -> Bool { hosts.contains(host) }

    public static let server = DelegateDemoServer()

    public static var note: String {
        Localized.text(
            "This is the demo dispatcher, and everything here is scripted: open the run waiting for you and approve it, or write a packet and watch it climb.")
    }

    static let tiers = [
        DelegateTier(
            tier: "t1", label: "local",
            chain: [DelegateChainEntry(runner: "omp", model: "llama-swap/qwen3.8-27b", thinking: "low", health: "http://127.0.0.1:8081/v1/models", healthy: true)]),
        DelegateTier(
            tier: "t2", label: "cheap cloud",
            chain: [DelegateChainEntry(runner: "omp", model: "ollama-cloud/glm-5.3-flash", thinking: "low")]),
        DelegateTier(
            tier: "t3", label: "frontier",
            chain: [DelegateChainEntry(runner: "claude", model: "claude-fable-5-1", thinking: "high")]),
    ]

    static let classes = ["default", "docs", "rust-mech", "rust-impl", "swift-impl", "strings", "review"]

    static let capabilities = DelegateCapabilities(
        api: 1, version: "0.4.0", host: "studio", features: ["runs", "events", "approve", "cancel", "replay", "stats", "tiers", "policies", "review"],
        tiers: tiers.map(\.tier), classes: classes, modes: ["normal", "conserve", "rush"],
        classPolicies: Dictionary(uniqueKeysWithValues: classes.map { name in
            (name, DelegateClassPolicy(tier: DelegateDemoServer.classStart(name), ceiling: DelegateDemoServer.classCeiling(name), verify: classVerify(name), verified: classVerify(name) != nil, attempts: 2))
        }),
        modePolicies: DelegateModePolicies(
            conserve: DelegateModePolicy(shift: -1, ceilingVerified: "t2", askBefore: "t3"),
            rush: DelegateModePolicy(shift: 1)))

    static func classVerify(_ taskClass: String) -> String? {
        switch taskClass {
        case "rust-mech": return "cargo build && cargo test"
        case "rust-impl": return "cargo clippy --all-targets -- -D warnings && cargo test"
        case "swift-impl": return "swift test"
        case "strings": return "swift build"
        default: return nil
        }
    }

    static let stats = [
        DelegateStat(taskClass: "docs", tier: "t1", attempts: 14, passes: 13, passRate: 0.93, averageMS: 6_400, tokensIn: 812_000, tokensOut: 9_100),
        DelegateStat(taskClass: "strings", tier: "t1", attempts: 22, passes: 22, passRate: 1, averageMS: 4_100, tokensIn: 1_300_000, tokensOut: 6_800),
        DelegateStat(taskClass: "rust-mech", tier: "t1", attempts: 9, passes: 6, passRate: 0.67, averageMS: 31_000, tokensIn: 2_400_000, tokensOut: 21_000),
        DelegateStat(taskClass: "rust-impl", tier: "t1", attempts: 6, passes: 1, passRate: 0.17, averageMS: 58_000, tokensIn: 3_100_000, tokensOut: 24_000),
        DelegateStat(taskClass: "rust-impl", tier: "t2", attempts: 12, passes: 11, passRate: 0.92, averageMS: 44_000, tokensIn: 2_900_000, tokensOut: 30_000),
        DelegateStat(taskClass: "swift-impl", tier: "t2", attempts: 7, passes: 6, passRate: 0.86, averageMS: 71_000, tokensIn: 3_800_000, tokensOut: 41_000),
    ]
}

/// One scripted run: the stored record plus the events already in its past and the ones still to come.
struct DelegateDemoRun: Sendable {
    var run: DelegateRun
    var events: [DelegateEnvelope]
    /// Events that play out over time once somebody watches, with the pause before each.
    var pending: [(delay: Duration, event: DelegateEvent)]
    var awaitingApproval: Bool
    var review = true
}

/// The demo daemon. An actor because a run's events land from timers while surfaces read the
/// listing; every reader sees one consistent story.
public actor DelegateDemoServer: DelegateTransport {
    private var runs: [String: DelegateDemoRun] = [:]
    private var order: [String] = []
    private var watchers: [String: [UUID: AsyncThrowingStream<DelegateEnvelope, Error>.Continuation]] = [:]
    private var players: [String: Task<Void, Never>] = [:]
    private var counter = 0
    /// How fast the script plays: 1 is the demo's own pace, 0 lands every event at once for tests.
    private let pace: Double

    public init(pace: Double = 1) {
        self.pace = pace
        let world = Self.seed()
        runs = world.runs
        order = world.order
    }

    public func capabilities() async throws -> DelegateCapabilities { DelegateDemo.capabilities }

    public func tiers() async throws -> [DelegateTier] { DelegateDemo.tiers }

    public func runs(limit: Int) async throws -> [DelegateRun] {
        Array(order.compactMap { runs[$0]?.run }.prefix(limit))
    }

    public func run(id: String) async throws -> DelegateRunDetail {
        guard let demo = runs[id] else { throw AgentError.http(status: 404, body: "no run \(id)") }
        return DelegateRunDetail(run: demo.run, attempts: Self.attempts(of: demo), live: demo.run.status == .running)
    }

    public func stats(taskClass: String?) async throws -> [DelegateStat] {
        DelegateDemo.stats.filter { taskClass == nil || $0.taskClass == taskClass }
    }

    public func start(packet: DelegatePacket, overrides: DelegateOverrides) async throws -> String {
        let start = overrides.tier ?? packet.tier ?? Self.classStart(packet.taskClass)
        let ceiling = overrides.ceiling ?? packet.ceiling ?? Self.classCeiling(packet.taskClass)
        let mode = overrides.mode ?? packet.mode ?? .normal
        return begin(packet: packet, start: start, ceiling: ceiling, mode: mode, review: overrides.review == true)
    }

    public func replay(runID: String, overrides: DelegateOverrides) async throws -> String {
        guard let demo = runs[runID] else { throw AgentError.http(status: 404, body: "no run \(runID)") }
        let packet = demo.run.packet
        return begin(
            packet: packet, start: overrides.tier ?? demo.run.startTier,
            ceiling: overrides.ceiling ?? demo.run.ceiling, mode: overrides.mode ?? demo.run.mode,
            review: overrides.review == true)
    }

    public func patch(runID: String) async throws -> String {
        guard let demo = runs[runID] else { throw AgentError.http(status: 404, body: "no run \(runID)") }
        guard let files = Self.passedFiles(demo) else {
            throw AgentError.http(status: 404, body: #"{"error":"this run has no passing patch"}"#)
        }
        return DelegateDemoPatches.patch(runID: runID, goal: demo.run.packet.goal, files: files)
    }

    public func apply(runID: String) async throws -> [String] {
        try deliver(runID, as: .applied)
    }

    public func discard(runID: String) async throws -> [String] {
        try deliver(runID, as: .discarded)
    }

    private func deliver(_ runID: String, as delivery: DelegateDelivery) throws -> [String] {
        guard let demo = runs[runID] else { throw AgentError.http(status: 404, body: "no run \(runID)") }
        guard demo.run.delivery == .pending, let files = Self.passedFiles(demo) else {
            throw AgentError.http(status: 409, body: #"{"error":"this run has no patch waiting for review"}"#)
        }
        let bytes = DelegateDemoPatches.patch(runID: runID, goal: demo.run.packet.goal, files: files).utf8.count
        land(runID, delivery == .applied ? .applied(files: files, patchBytes: bytes) : .discarded(files: files))
        return files
    }

    static func passedFiles(_ demo: DelegateDemoRun) -> [String]? {
        for envelope in demo.events.reversed() {
            if case .attemptFinished(let outcome) = envelope.event, outcome.status == .pass { return outcome.changedFiles }
        }
        return nil
    }

    public func approve(runID: String, approved: Bool) async throws {
        guard var demo = runs[runID], demo.awaitingApproval else { return }
        demo.awaitingApproval = false
        let tier = demo.run.ceiling
        if approved {
            demo.pending = Self.climb(
                tier: tier, model: Self.model(tier), files: demo.run.packet.paths, seconds: 22,
                fromEscalations: demo.run.escalations, review: demo.review)
            demo.pending.insert((.zero, .approvalResolved(tier: tier, approved: true)), at: 0)
        } else {
            demo.pending = [
                (.zero, .approvalResolved(tier: tier, approved: false)),
                (.milliseconds(300), .runFinished(status: .held, passedTier: nil, escalations: demo.run.escalations, durationMS: 61_000, summary: "held before \(tier)")),
            ]
        }
        runs[runID] = demo
        play(runID)
    }

    public func cancel(runID: String) async throws {
        guard var demo = runs[runID], demo.run.status == .running else { return }
        players[runID]?.cancel()
        players[runID] = nil
        demo.awaitingApproval = false
        demo.pending = []
        runs[runID] = demo
        land(runID, .runFinished(status: .cancelled, passedTier: nil, escalations: demo.run.escalations, durationMS: 30_000, summary: "cancelled"))
    }

    public nonisolated func events(runID: String, after: Int) -> AsyncThrowingStream<DelegateEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await self.subscribe(runID: runID, after: after, id: id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.unsubscribe(runID: runID, id: id) } }
        }
    }

    private func subscribe(runID: String, after: Int, id: UUID, continuation: AsyncThrowingStream<DelegateEnvelope, Error>.Continuation) {
        guard let demo = runs[runID] else {
            continuation.finish(throwing: AgentError.http(status: 404, body: "no run \(runID)"))
            return
        }
        for envelope in demo.events where envelope.seq > after {
            continuation.yield(envelope)
        }
        if demo.run.status != .running {
            continuation.finish()
            return
        }
        watchers[runID, default: [:]][id] = continuation
        play(runID)
    }

    private func unsubscribe(runID: String, id: UUID) {
        watchers[runID]?[id] = nil
    }

    /// Plays a run's pending events on their delays; the run keeps going whether or not anybody watches.
    private func play(_ runID: String) {
        guard players[runID] == nil, let demo = runs[runID], !demo.pending.isEmpty, !demo.awaitingApproval else { return }
        players[runID] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = await self.nextPending(runID) {
                if await self.pace > 0 { try? await Task.sleep(for: next.delay * self.pace) }
                if Task.isCancelled { return }
                await self.land(runID, next.event)
            }
            await self.finishedPlaying(runID)
        }
    }

    private func nextPending(_ runID: String) -> (delay: Duration, event: DelegateEvent)? {
        guard var demo = runs[runID], !demo.pending.isEmpty, !demo.awaitingApproval else { return nil }
        let next = demo.pending.removeFirst()
        runs[runID] = demo
        return next
    }

    private func finishedPlaying(_ runID: String) {
        players[runID] = nil
    }

    private func land(_ runID: String, _ event: DelegateEvent) {
        guard var demo = runs[runID] else { return }
        let seq = (demo.events.last?.seq ?? 0) + 1
        let envelope = DelegateEnvelope(runID: runID, seq: seq, timestamp: DelegateTimestamp.format(Date()), event: event)
        demo.events.append(envelope)
        switch event {
        case .approvalRequired:
            demo.awaitingApproval = true
        case .escalated:
            demo.run.escalations += 1
        case .applied:
            demo.run.delivery = .applied
        case .awaitingReview:
            demo.run.delivery = .pending
        case .discarded:
            demo.run.delivery = .discarded
        case .runFinished(let status, let passed, let escalations, _, let summary):
            demo.run.status = status
            demo.run.passedTier = passed
            demo.run.escalations = escalations
            demo.run.summary = summary
            demo.run.finishedAt = DelegateTimestamp.format(Date())
        default:
            break
        }
        runs[runID] = demo
        for continuation in watchers[runID]?.values ?? [:].values {
            continuation.yield(envelope)
        }
        if demo.run.status != .running {
            for continuation in watchers[runID]?.values ?? [:].values { continuation.finish() }
            watchers[runID] = nil
        }
    }

    private func begin(packet: DelegatePacket, start: String, ceiling: String, mode: DelegateMode, review: Bool) -> String {
        counter += 1
        let runID = DelegateIdentifier.mint()
        let files = packet.paths.isEmpty ? ["src/lib.rs"] : packet.paths
        var run = DelegateRun(
            id: runID, packetID: packet.id, taskClass: packet.taskClass, repo: packet.repo ?? "/Users/demo/dev/pulse-server",
            host: "studio", mode: mode, startTier: start, ceiling: ceiling, status: .running,
            createdAt: DelegateTimestamp.format(Date()), packet: packet)
        run.packet.tier = start
        run.packet.ceiling = ceiling
        var pending: [(delay: Duration, event: DelegateEvent)] = [
            (.zero, .runStarted(packetID: packet.id, taskClass: packet.taskClass, startTier: start, ceiling: ceiling, mode: mode, host: "studio", repo: run.repo)),
        ]
        let order = DelegateDemo.capabilities.tiers
        let startIndex = order.firstIndex(of: start) ?? 0
        let ceilingIndex = order.firstIndex(of: ceiling) ?? startIndex
        if mode != .rush, startIndex < ceilingIndex {
            pending += Self.stumble(tier: start, model: Self.model(start), verify: packet.verify)
            let next = order[startIndex + 1]
            pending.append((.milliseconds(600), .escalated(from: start, to: next, reason: "\(start) failed at 1")))
            if mode == .conserve, next == ceiling, ceilingIndex - startIndex >= 1, next == "t3" {
                pending.append((.milliseconds(400), .approvalRequired(tier: next, reason: "mode conserve requires approval before \(next)")))
            } else {
                pending += Self.climb(tier: next, model: Self.model(next), files: files, seconds: 20, fromEscalations: 1, review: review)
            }
        } else {
            pending += Self.climb(tier: start, model: Self.model(start), files: files, seconds: 12, fromEscalations: 0, review: review)
        }
        runs[runID] = DelegateDemoRun(run: run, events: [], pending: pending, awaitingApproval: false, review: review)
        self.order.insert(runID, at: 0)
        play(runID)
        return runID
    }

    static func classStart(_ taskClass: String) -> String {
        switch taskClass {
        case "docs", "strings", "rust-mech", "rust-impl": return "t1"
        case "review": return "t3"
        default: return "t2"
        }
    }

    static func classCeiling(_ taskClass: String) -> String {
        switch taskClass {
        case "docs", "strings", "rust-mech": return "t2"
        default: return "t3"
        }
    }

    static func model(_ tier: String) -> String {
        DelegateDemo.tiers.first { $0.tier == tier }?.chain.first?.model ?? tier
    }

    /// An attempt that reads, edits, runs the verifier and fails it — the failure every ladder is for.
    static func stumble(tier: String, model: String, verify: String?) -> [(delay: Duration, event: DelegateEvent)] {
        let check = verify ?? "cargo test"
        return [
            (.milliseconds(500), .tierSelected(tier: tier, label: tier == "t1" ? "local" : "cheap cloud", runner: "omp", model: model, chainIndex: 0)),
            (.milliseconds(400), .attemptStarted(tier: tier, attempt: 1, model: model)),
            (.milliseconds(1_400), .progress(tier: tier, attempt: 1, text: "read src/lib.rs")),
            (.milliseconds(1_800), .progress(tier: tier, attempt: 1, text: "edit src/lib.rs")),
            (.milliseconds(1_600), .progress(tier: tier, attempt: 1, text: "bash \(check)")),
            (.milliseconds(2_200), .attemptFinished(DelegateAttemptOutcome(
                tier: tier, attempt: 1, status: .fail, verifyExit: 101, durationMS: 9_400, tokensIn: 41_200, tokensOut: 1_310,
                changedFiles: ["src/lib.rs"],
                verifyTail: "test tests::adds ... FAILED\n\nfailures:\n    tests::adds\n\ntest result: FAILED. 0 passed; 1 failed",
                workerSummary: "Changed add() but the assertion still fails on negative input."))),
        ]
    }

    /// An attempt that reads, edits, verifies and passes, then the patch landing and the run ending.
    static func climb(
        tier: String, model: String, files: [String], seconds: Int, fromEscalations: Int, review: Bool
    ) -> [(delay: Duration, event: DelegateEvent)] {
        let label = tier == "t1" ? "local" : (tier == "t2" ? "cheap cloud" : "frontier")
        let runner = tier == "t3" ? "claude" : "omp"
        let first = files.first ?? "src/lib.rs"
        return [
            (.milliseconds(500), .tierSelected(tier: tier, label: label, runner: runner, model: model, chainIndex: 0)),
            (.milliseconds(400), .attemptStarted(tier: tier, attempt: 1, model: model)),
            (.milliseconds(1_500), .progress(tier: tier, attempt: 1, text: "read \(first)")),
            (.milliseconds(2_000), .progress(tier: tier, attempt: 1, text: "edit \(first)")),
            (.milliseconds(1_800), .progress(tier: tier, attempt: 1, text: "bash cargo test")),
            (.milliseconds(2_400), .attemptFinished(DelegateAttemptOutcome(
                tier: tier, attempt: 1, status: .pass, verifyExit: 0, durationMS: seconds * 1_000, tokensIn: 58_900, tokensOut: 2_140,
                changedFiles: files, verifyTail: "", workerSummary: "Fixed the sign in add() and kept the tests untouched; cargo test passes."))),
            (.milliseconds(300), review ? .awaitingReview(files: files, patchBytes: 412) : .applied(files: files, patchBytes: 412)),
            (.milliseconds(200), .runFinished(status: .passed, passedTier: tier, escalations: fromEscalations, durationMS: (seconds + 12 * fromEscalations) * 1_000, summary: "\(DelegateWords.files(files.count)): cargo test passes")),
        ]
    }

    static func attempts(of demo: DelegateDemoRun) -> [DelegateAttempt] {
        var model: [String: String] = [:]
        var attempts: [DelegateAttempt] = []
        for envelope in demo.events {
            switch envelope.event {
            case .tierSelected(let tier, _, _, let name, _):
                model[tier] = name
            case .attemptFinished(let outcome):
                attempts.append(DelegateAttempt(
                    runID: demo.run.id, tier: outcome.tier, chainIndex: 0, runner: outcome.tier == "t3" ? "claude" : "omp",
                    model: model[outcome.tier] ?? Self.model(outcome.tier), attempt: outcome.attempt, status: outcome.status,
                    verifyExit: outcome.verifyExit, durationMS: outcome.durationMS, tokensIn: outcome.tokensIn,
                    tokensOut: outcome.tokensOut, changedFiles: outcome.changedFiles, scopeViolations: outcome.scopeViolations,
                    verifyTail: outcome.verifyTail, workerSummary: outcome.workerSummary,
                    startedAt: envelope.timestamp, finishedAt: envelope.timestamp))
            default:
                break
            }
        }
        return attempts
    }

    /// The world as it stands when the demo opens: a run that passed cheaply, one that had to climb,
    /// one waiting for your answer, one that ran out of ladder, and one still working.
    private static func seed() -> (runs: [String: DelegateDemoRun], order: [String]) {
        var runs: [String: DelegateDemoRun] = [:]
        var order: [String] = []
        let base = Date().addingTimeInterval(-3_600)
        func stamp(_ offset: Double) -> String { DelegateTimestamp.format(base.addingTimeInterval(offset)) }
        func settled(
            id: String, taskClass: String, goal: String, paths: [String], verify: String?, start: String, ceiling: String,
            mode: DelegateMode, at offset: Double, script: [DelegateEvent], status: DelegateRunStatus, passed: String?,
            escalations: Int, summary: String
        ) {
            let packet = DelegatePacket(id: "P-\(id)", taskClass: taskClass, goal: goal, paths: paths, verify: verify, tier: start, ceiling: ceiling, mode: mode == .normal ? nil : mode, repo: "/Users/demo/dev/pulse-server", created: stamp(offset))
            let run = DelegateRun(
                id: id, packetID: packet.id, taskClass: taskClass, repo: packet.repo ?? "", host: "studio", mode: mode,
                startTier: start, ceiling: ceiling, status: status, createdAt: stamp(offset),
                finishedAt: status == .running ? nil : stamp(offset + 90), passedTier: passed, escalations: escalations,
                summary: summary, packet: packet)
            let events = script.enumerated().map { index, event in
                DelegateEnvelope(runID: id, seq: index + 1, timestamp: stamp(offset + Double(index) * 4), event: event)
            }
            runs[id] = DelegateDemoRun(run: run, events: events, pending: [], awaitingApproval: false)
            order.append(id)
        }

        settled(
            id: "demo-run-live", taskClass: "rust-impl", goal: "Add --json output to `hinta compare` with the same fields as the table, and a test for the JSON shape.",
            paths: ["src/compare.rs", "tests/"], verify: "cargo build && cargo clippy --all-targets -- -D warnings && cargo test",
            start: "t1", ceiling: "t3", mode: .normal, at: 3_480,
            script: [
                .runStarted(packetID: "P-demo-run-live", taskClass: "rust-impl", startTier: "t1", ceiling: "t3", mode: .normal, host: "studio", repo: "/Users/demo/dev/pulse-server"),
                .tierSelected(tier: "t1", label: "local", runner: "omp", model: DelegateDemoServer.model("t1"), chainIndex: 0),
                .attemptStarted(tier: "t1", attempt: 1, model: DelegateDemoServer.model("t1")),
                .progress(tier: "t1", attempt: 1, text: "read src/compare.rs"),
            ],
            status: .running, passed: nil, escalations: 0, summary: "")
        runs["demo-run-live"]?.pending = [
            (.milliseconds(2_500), .progress(tier: "t1", attempt: 1, text: "edit src/compare.rs")),
            (.milliseconds(2_500), .progress(tier: "t1", attempt: 1, text: "write tests/compare_json.rs")),
            (.milliseconds(2_500), .progress(tier: "t1", attempt: 1, text: "bash cargo clippy --all-targets -- -D warnings")),
            (.milliseconds(3_000), .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 101, durationMS: 38_000, tokensIn: 96_400, tokensOut: 3_900, changedFiles: ["src/compare.rs", "tests/compare_json.rs"], verifyTail: "error: unused import: `serde_json::Value`\n  --> src/compare.rs:3:5\n\nerror: could not compile `hinta` due to 1 previous error", workerSummary: "Added the JSON printer; clippy rejects an import I left in."))),
            (.milliseconds(1_200), .attemptStarted(tier: "t1", attempt: 2, model: DelegateDemoServer.model("t1"))),
            (.milliseconds(2_200), .progress(tier: "t1", attempt: 2, text: "edit src/compare.rs")),
            (.milliseconds(2_200), .progress(tier: "t1", attempt: 2, text: "bash cargo test")),
            (.milliseconds(3_000), .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 2, status: .pass, verifyExit: 0, durationMS: 27_000, tokensIn: 71_000, tokensOut: 2_600, changedFiles: ["src/compare.rs", "tests/compare_json.rs"], workerSummary: "Removed the unused import; build, clippy and the new JSON test pass."))),
            (.milliseconds(300), .awaitingReview(files: ["src/compare.rs", "tests/compare_json.rs"], patchBytes: 2_140)),
            (.milliseconds(200), .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 66_000, summary: "2 files: build, clippy and tests pass")),
        ]

        settled(
            id: "demo-run-held", taskClass: "swift-impl", goal: "Add a Logs tab to Tailscode showing the AppLogger file with a share sheet and a clear button.",
            paths: ["Tailscode/Settings/LogsViewController.swift", "Tailscode/Resources/"], verify: "xcodebuild -scheme Tailscode build",
            start: "t1", ceiling: "t3", mode: .conserve, at: 2_900,
            script: [
                .runStarted(packetID: "P-demo-run-held", taskClass: "swift-impl", startTier: "t1", ceiling: "t3", mode: .conserve, host: "studio", repo: "/Users/demo/dev/pulse-ios"),
                .tierSelected(tier: "t1", label: "local", runner: "omp", model: DelegateDemoServer.model("t1"), chainIndex: 0),
                .attemptStarted(tier: "t1", attempt: 1, model: DelegateDemoServer.model("t1")),
                .progress(tier: "t1", attempt: 1, text: "write Tailscode/Settings/LogsViewController.swift"),
                .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 65, durationMS: 44_000, tokensIn: 88_000, tokensOut: 3_100, changedFiles: ["Tailscode/Settings/LogsViewController.swift"], verifyTail: "error: value of type 'AppLogger' has no member 'fileURL'\n** BUILD FAILED **", workerSummary: "Guessed the logger's API and got it wrong.")),
                .escalated(from: "t1", to: "t2", reason: "t1 failed at 1"),
                .tierSelected(tier: "t2", label: "cheap cloud", runner: "omp", model: DelegateDemoServer.model("t2"), chainIndex: 0),
                .attemptStarted(tier: "t2", attempt: 1, model: DelegateDemoServer.model("t2")),
                .progress(tier: "t2", attempt: 1, text: "read Tailscode/Logging/AppLogger.swift"),
                .progress(tier: "t2", attempt: 1, text: "edit Tailscode/Settings/LogsViewController.swift"),
                .attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .fail, verifyExit: 65, durationMS: 61_000, tokensIn: 132_000, tokensOut: 5_400, changedFiles: ["Tailscode/Settings/LogsViewController.swift"], verifyTail: "error: 'ShareSheet' is unavailable in iOS\n** BUILD FAILED **", workerSummary: "The share sheet compiles on macOS but not on iOS.")),
                .escalated(from: "t2", to: "t3", reason: "t2 failed at 1"),
                .approvalRequired(tier: "t3", reason: "mode conserve requires approval before t3"),
            ],
            status: .running, passed: nil, escalations: 2, summary: "")
        runs["demo-run-held"]?.awaitingApproval = true

        settled(
            id: "demo-run-climbed", taskClass: "rust-impl", goal: "Make `flaccy scan` skip files whose tags already match, and add a test proving a second scan is a no-op.",
            paths: ["src/scan.rs", "tests/scan.rs"], verify: "cargo test scan", start: "t1", ceiling: "t3", mode: .normal, at: 1_900,
            script: [
                .runStarted(packetID: "P-demo-run-climbed", taskClass: "rust-impl", startTier: "t1", ceiling: "t3", mode: .normal, host: "studio", repo: "/Users/demo/dev/flaccy"),
                .tierSelected(tier: "t1", label: "local", runner: "omp", model: DelegateDemoServer.model("t1"), chainIndex: 0),
                .attemptStarted(tier: "t1", attempt: 1, model: DelegateDemoServer.model("t1")),
                .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 101, durationMS: 35_000, tokensIn: 74_000, tokensOut: 2_900, changedFiles: ["src/scan.rs"], verifyTail: "test scan::second_scan_is_noop ... FAILED", workerSummary: "Skips by path but not by tag hash.")),
                .attemptStarted(tier: "t1", attempt: 2, model: DelegateDemoServer.model("t1")),
                .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 2, status: .fail, verifyExit: 101, durationMS: 33_000, tokensIn: 69_000, tokensOut: 2_400, changedFiles: ["src/scan.rs"], verifyTail: "test scan::second_scan_is_noop ... FAILED", workerSummary: "Same failure.")),
                .escalated(from: "t1", to: "t2", reason: "t1 failed at 2"),
                .tierSelected(tier: "t2", label: "cheap cloud", runner: "omp", model: DelegateDemoServer.model("t2"), chainIndex: 0),
                .attemptStarted(tier: "t2", attempt: 1, model: DelegateDemoServer.model("t2")),
                .attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .pass, verifyExit: 0, durationMS: 52_000, tokensIn: 141_000, tokensOut: 6_100, changedFiles: ["src/scan.rs", "tests/scan.rs"], workerSummary: "Compares the stored tag hash before rewriting; the no-op test passes.")),
                .applied(files: ["src/scan.rs", "tests/scan.rs"], patchBytes: 3_020),
                .runFinished(status: .passed, passedTier: "t2", escalations: 1, durationMS: 120_000, summary: "2 files: the no-op test passes"),
            ],
            status: .passed, passed: "t2", escalations: 1, summary: "2 files: the no-op test passes")
        runs["demo-run-climbed"]?.run.delivery = .applied

        settled(
            id: "demo-run-docs", taskClass: "docs", goal: "Write docs/RELEASE.md describing the three-step release: tag, build, notarize.",
            paths: ["docs/RELEASE.md"], verify: nil, start: "t1", ceiling: "t2", mode: .normal, at: 1_100,
            script: [
                .runStarted(packetID: "P-demo-run-docs", taskClass: "docs", startTier: "t1", ceiling: "t2", mode: .normal, host: "studio", repo: "/Users/demo/dev/pulse-ios"),
                .tierSelected(tier: "t1", label: "local", runner: "omp", model: DelegateDemoServer.model("t1"), chainIndex: 0),
                .attemptStarted(tier: "t1", attempt: 1, model: DelegateDemoServer.model("t1")),
                .progress(tier: "t1", attempt: 1, text: "write docs/RELEASE.md"),
                .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .pass, verifyExit: nil, durationMS: 7_000, tokensIn: 19_000, tokensOut: 900, changedFiles: ["docs/RELEASE.md"], workerSummary: "Three numbered steps with the exact commands.")),
                .awaitingReview(files: ["docs/RELEASE.md"], patchBytes: 1_180),
                .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 7_400, summary: "1 file: three numbered steps"),
            ],
            status: .passed, passed: "t1", escalations: 0, summary: "1 file: three numbered steps")
        runs["demo-run-docs"]?.run.delivery = .pending

        settled(
            id: "demo-run-failed", taskClass: "strings", goal: "Translate the new settings strings into Finnish and Swedish.",
            paths: ["Tailscode/Resources/fi.lproj/", "Tailscode/Resources/sv.lproj/"], verify: "plutil -lint Tailscode/Resources/*.lproj/*.strings", start: "t1", ceiling: "t2", mode: .normal, at: 400,
            script: [
                .runStarted(packetID: "P-demo-run-failed", taskClass: "strings", startTier: "t1", ceiling: "t2", mode: .normal, host: "studio", repo: "/Users/demo/dev/pulse-ios"),
                .tierSelected(tier: "t1", label: "local", runner: "omp", model: DelegateDemoServer.model("t1"), chainIndex: 0),
                .attemptStarted(tier: "t1", attempt: 1, model: DelegateDemoServer.model("t1")),
                .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .scope, durationMS: 21_000, tokensIn: 44_000, tokensOut: 2_000, changedFiles: ["Tailscode/Resources/fi.lproj/Localizable.strings", "Tailscode/Resources/Base.lproj/Localizable.strings"], scopeViolations: ["Tailscode/Resources/Base.lproj/Localizable.strings"], workerSummary: "Also touched the base strings.")),
                .escalated(from: "t1", to: "t2", reason: "t1 failed at 1"),
                .tierSelected(tier: "t2", label: "cheap cloud", runner: "omp", model: DelegateDemoServer.model("t2"), chainIndex: 0),
                .attemptStarted(tier: "t2", attempt: 1, model: DelegateDemoServer.model("t2")),
                .attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .fail, verifyExit: 1, durationMS: 30_000, tokensIn: 61_000, tokensOut: 2_700, changedFiles: ["Tailscode/Resources/fi.lproj/Localizable.strings", "Tailscode/Resources/sv.lproj/Localizable.strings"], verifyTail: "sv.lproj/Localizable.strings: Unexpected character \" at line 41", workerSummary: "An unescaped quote in the Swedish file.")),
                .runFinished(status: .failed, passedTier: nil, escalations: 1, durationMS: 55_000, summary: "exhausted ladder; last failure at t2 attempt 1"),
            ],
            status: .failed, passed: nil, escalations: 1, summary: "exhausted ladder; last failure at t2 attempt 1")

        order = ["demo-run-live", "demo-run-held", "demo-run-failed", "demo-run-docs", "demo-run-climbed"]
        return (runs, order)
    }
}

/// The diffs the demo's runs produce: hand-written for the seeded runs, so the review a first-run
/// person or App Review opens reads like a real one, and a small honest one for a packet written in
/// the demo, which names its own goal rather than pretending to have solved it.
enum DelegateDemoPatches {
    static func patch(runID: String, goal: String, files: [String]) -> String {
        switch runID {
        case "demo-run-docs": return release
        case "demo-run-climbed": return scan
        case "demo-run-live": return compare
        default: return files.map { generic(path: $0, goal: goal) }.joined(separator: "\n")
        }
    }

    private static func generic(path: String, goal: String) -> String {
        let first = goal.components(separatedBy: "\n").first ?? goal
        return """
            diff --git a/\(path) b/\(path)
            index 3f2a1c0..9b7e4d2 100644
            --- a/\(path)
            +++ b/\(path)
            @@ -1,4 +1,6 @@
             // The demo machine wrote this hunk; nothing on a real machine changed.
            +// Task: \(first)
            +// Verified by the packet's own verifier on the demo dispatcher.
             
             pub fn add(a: i64, b: i64) -> i64 {
            -    a - b
            +    a + b
             }
            """
    }

    private static let release = """
        diff --git a/docs/RELEASE.md b/docs/RELEASE.md
        new file mode 100644
        index 0000000..4c1e2f7
        --- /dev/null
        +++ b/docs/RELEASE.md
        @@ -0,0 +1,22 @@
        +# Releasing
        +
        +Three steps, in this order. Each one checks the last.
        +
        +## 1. Tag
        +
        +    git tag -s v1.4.0 -m "1.4.0"
        +    git push origin v1.4.0
        +
        +## 2. Build
        +
        +    xcodebuild -scheme Pulse -configuration Release archive \\
        +      -archivePath build/Pulse.xcarchive
        +
        +## 3. Notarize
        +
        +    xcrun notarytool submit build/Pulse.zip --keychain-profile pulse --wait
        +    xcrun stapler staple build/Pulse.app
        +
        +A tag without a notarized build is not a release; delete the tag
        +rather than leave it pointing at nothing.
        +
        """

    private static let scan = """
        diff --git a/src/scan.rs b/src/scan.rs
        index 81d0c2a..f3b9e10 100644
        --- a/src/scan.rs
        +++ b/src/scan.rs
        @@ -42,9 +42,14 @@ pub fn scan(library: &Library, files: &[PathBuf]) -> Result<Report> {
             let mut report = Report::default();
             for path in files {
                 let wanted = library.tags_for(path)?;
        -        write_tags(path, &wanted)?;
        -        report.written += 1;
        +        let current = read_tag_hash(path)?;
        +        if current == wanted.hash() {
        +            report.skipped += 1;
        +            continue;
        +        }
        +        write_tags(path, &wanted)?;
        +        report.written += 1;
             }
             Ok(report)
         }
        diff --git a/tests/scan.rs b/tests/scan.rs
        index 2a7c911..c40d8e5 100644
        --- a/tests/scan.rs
        +++ b/tests/scan.rs
        @@ -18,3 +18,14 @@ fn first_scan_writes_every_file() {
             assert_eq!(report.written, 3);
         }
        +
        +#[test]
        +fn second_scan_is_noop() {
        +    let library = fixture_library();
        +    let files = fixture_files();
        +    scan(&library, &files).unwrap();
        +    let report = scan(&library, &files).unwrap();
        +    assert_eq!(report.written, 0);
        +    assert_eq!(report.skipped, 3);
        +}
        +
        """

    private static let compare = """
        diff --git a/src/compare.rs b/src/compare.rs
        index 5d1e0aa..e2f7c31 100644
        --- a/src/compare.rs
        +++ b/src/compare.rs
        @@ -1,6 +1,7 @@
         use crate::shops::Offer;
        +use serde::Serialize;
         
        -#[derive(Debug)]
        +#[derive(Debug, Serialize)]
         pub struct Row {
             pub shop: String,
             pub price_cents: u64,
        @@ -28,6 +29,13 @@ pub fn print_table(rows: &[Row]) {
             }
         }
        +
        +/// The table's rows as JSON, field for field, for scripts that read `hinta compare`.
        +pub fn print_json(rows: &[Row]) -> serde_json::Result<()> {
        +    println!("{}", serde_json::to_string_pretty(rows)?);
        +    Ok(())
        +}
        diff --git a/tests/compare_json.rs b/tests/compare_json.rs
        new file mode 100644
        index 0000000..7a04b9c
        --- /dev/null
        +++ b/tests/compare_json.rs
        @@ -0,0 +1,12 @@
        +use hinta::compare::{Row, print_json};
        +
        +#[test]
        +fn json_has_the_table_fields() {
        +    let rows = vec![Row { shop: "Jimms".into(), price_cents: 41_990, in_stock: true }];
        +    let json = serde_json::to_value(&rows).unwrap();
        +    let first = &json[0];
        +    assert_eq!(first["shop"], "Jimms");
        +    assert_eq!(first["price_cents"], 41_990);
        +    assert_eq!(first["in_stock"], true);
        +    print_json(&rows).unwrap();
        +}
        """
}
