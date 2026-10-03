import CodingAgentKit
import Foundation

/// One line per tier on the board: the rung, what answers there right now, and whether it will.
public struct DelegateTierLine: Sendable, Hashable, Identifiable {
    public var tier: String
    public var label: String
    public var model: String
    public var detail: String
    public var tone: ActivityTone

    public var id: String { tier }

    public init(_ tier: DelegateTier) {
        self.tier = tier.tier
        label = tier.label
        if let active = tier.activeEntry {
            model = active.model
            let probed = tier.chain.filter { $0.healthy != nil }
            if active.healthy == true {
                detail = Localized.text("answering")
                tone = .live
            } else if probed.isEmpty {
                detail = Localized.text("not probed")
                tone = .quiet
            } else {
                detail = Localized.text("unprobed fallback")
                tone = .quiet
            }
        } else {
            model = tier.chain.first?.model ?? "-"
            detail = tier.chain.compactMap(\.reason).first ?? Localized.text("nothing answering")
            tone = .danger
        }
    }
}

/// One row of the pass-rate table, plus the words a promotion decision is made from.
public struct DelegateStatRow: Sendable, Hashable, Identifiable {
    public var taskClass: String
    public var tier: String
    public var attempts: Int
    public var passes: Int
    public var rate: Double
    public var averageMS: Double

    public var id: String { "\(taskClass)/\(tier)" }

    public init(_ stat: DelegateStat) {
        taskClass = stat.taskClass
        tier = stat.tier
        attempts = stat.attempts
        passes = stat.passes
        rate = stat.passRate
        averageMS = stat.averageMS
    }

    public var rateText: String { attempts == 0 ? "–" : "\(Int((rate * 100).rounded()))%" }

    public var line: String {
        Localized.text("%d of %d passed · %@ average", passes, attempts, DelegateWords.seconds(Int(averageMS)))
    }
}

/// What the numbers say about where a class should start. The words are the whole point: a tier
/// assignment changes only on a streak the table can show, never on a feeling.
public enum DelegatePromotion {
    public static let streak = 10
    public static let promoteRate = 0.9
    public static let demoteAttempts = 5
    public static let demoteRate = 0.3

    public static func hints(_ stats: [DelegateStat], tiers: [String]) -> [String] {
        var hints: [String] = []
        let byClass = Dictionary(grouping: stats, by: \.taskClass)
        for taskClass in byClass.keys.sorted() {
            let rows = byClass[taskClass] ?? []
            for row in rows {
                guard let index = tiers.firstIndex(of: row.tier) else { continue }
                if row.attempts >= streak, row.passRate >= promoteRate, index > 0 {
                    let cheaper = tiers[index - 1]
                    let tried = rows.first { $0.tier == cheaper }?.attempts ?? 0
                    if tried < 3 {
                        hints.append(
                            Localized.text(
                                "%@ passes %d of %d at %@ — try starting it at %@", taskClass, row.passes,
                                row.attempts, row.tier, cheaper))
                    }
                }
                if row.attempts >= demoteAttempts, row.passRate <= demoteRate, index + 1 < tiers.count {
                    hints.append(
                        Localized.text(
                            "%@ fails %d of %d at %@ — start it at %@", taskClass, row.attempts - row.passes,
                            row.attempts, row.tier, tiers[index + 1]))
                }
            }
        }
        return hints
    }
}

/// Where the board is in its life: the daemon is another machine's process and may be asleep.
public enum DelegatePhase: Sendable, Equatable {
    case idle
    case checking
    case ready
    case failed(String)
}

/// The dispatcher on one machine as a surface: whether it answers, what its ladder is, every run
/// it remembers with the live ones folding as they go, and what the numbers say. The board holds
/// the state and every word; a client draws rows.
public struct DelegateBoard: Sendable, Equatable {
    public var host: String
    public var serverName: String
    public var phase: DelegatePhase
    public var capabilities: DelegateCapabilities?
    public var tiers: [DelegateTier]
    public var runs: [DelegateRun]
    public var stats: [DelegateStat]
    public var stories: [String: DelegateRunStory]
    /// Patches read from the daemon, by run. A patch never changes once its attempt passed, so one
    /// read serves every later look.
    public var patches: [String: String]

    public init(host: String, serverName: String) {
        self.host = host
        self.serverName = serverName
        phase = .idle
        capabilities = nil
        tiers = []
        runs = []
        stats = []
        stories = [:]
        patches = [:]
    }

    public var title: String { DelegateEntryPoint.title }

    public var isReady: Bool { phase == .ready }

    public var tierOrder: [String] { capabilities?.tiers ?? tiers.map(\.tier) }

    public var classes: [String] { capabilities?.classes ?? [] }

    public var statusLine: String {
        switch phase {
        case .idle: return Localized.text("Not checked yet")
        case .checking: return Localized.text("Asking %@…", serverName)
        case .ready:
            let version = capabilities?.version ?? "?"
            let count = tierOrder.count
            return count == 1
                ? Localized.text("delegate %@ on %@ · 1 tier", version, capabilities?.host ?? serverName)
                : Localized.text("delegate %@ on %@ · %d tiers", version, capabilities?.host ?? serverName, count)
        case .failed(let reason): return reason
        }
    }

    /// The line under the board's title: the machine and the dispatcher's version once it answers.
    public var subtitle: String {
        guard phase == .ready, let capabilities else { return serverName }
        return Localized.text("%@ · delegate %@", capabilities.host, capabilities.version)
    }

    /// Whether this machine's dispatcher can hold a patch for review.
    public var supportsReview: Bool { capabilities?.supportsReview ?? false }

    public var statusTone: ActivityTone {
        switch phase {
        case .idle, .checking: return .quiet
        case .ready: return .live
        case .failed: return .danger
        }
    }

    public var tierLines: [DelegateTierLine] { tiers.map(DelegateTierLine.init) }

    /// The ladder as the board draws it: every rung with its model, its health when that says
    /// something, and its record across every class.
    public var ladderRungs: [DelegateBoardRung] { tiers.map { DelegateBoardRung(tier: $0, stats: stats) } }

    /// The runs grouped by what they ask of the reader — waiting on you, still out, settled — each
    /// group newest first, and a group with nothing in it left out.
    public func sections(now: Date = Date()) -> [DelegateRunSection] {
        var needsYou: [DelegateRunRow] = []
        var running: [DelegateRunRow] = []
        var earlier: [DelegateRunRow] = []
        for run in runs {
            let story = stories[run.id] ?? DelegateRunStory(runID: run.id, tiers: tiers, run: run)
            let row = DelegateRunRow(story: story, run: run, now: now)
            if story.needsYou {
                needsYou.append(row)
            } else if story.isLive {
                running.append(row)
            } else {
                earlier.append(row)
            }
        }
        return [
            DelegateRunSection(kind: .needsYou, rows: needsYou),
            DelegateRunSection(kind: .running, rows: running),
            DelegateRunSection(kind: .earlier, rows: earlier),
        ].filter { !$0.rows.isEmpty }
    }

    /// The reading a run's own screen draws, with its patch's line counts once the patch is read.
    public func reading(for runID: String) -> DelegateRunReading? {
        guard let story = story(for: runID) else { return nil }
        return DelegateRunReading(
            story: story, run: runs.first { $0.id == runID }, tierOrder: tierOrder, patch: patches[runID])
    }

    /// How many runs are waiting on a person, for a door that wants to say so.
    public var waitingCount: Int {
        runs.filter { (stories[$0.id] ?? DelegateRunStory(runID: $0.id, tiers: tiers, run: $0)).needsYou }.count
    }

    public var statRows: [DelegateStatRow] { stats.map(DelegateStatRow.init) }

    public var promotions: [String] { DelegatePromotion.hints(stats, tiers: tierOrder) }

    /// What the numbers say about one rung for one class: a pass rate and an average, or that the
    /// rung is untried, so the composer's ladder is chosen on evidence.
    public func rungNote(taskClass: String, tier: String) -> String {
        guard let stat = stats.first(where: { $0.taskClass == taskClass && $0.tier == tier }), stat.attempts > 0 else {
            return Localized.text("untried")
        }
        return "\(Int((stat.passRate * 100).rounded()))% · \(DelegateWords.seconds(Int(stat.averageMS)))"
    }

    /// The ladder as the composer draws it for one class: every tier, unlit, each with its note.
    public func composerRungs(taskClass: String) -> [DelegateRung] {
        tiers.map { tier in
            DelegateRung(
                tier: tier.tier, label: tier.label, model: tier.activeEntry?.model, state: .pending,
                note: rungNote(taskClass: taskClass, tier: tier.tier))
        }
    }

    /// Every run, newest first, as the story a row is drawn from — the live fold where one exists,
    /// otherwise the daemon's stored record.
    public var runStories: [DelegateRunStory] {
        runs.map { run in stories[run.id] ?? DelegateRunStory(runID: run.id, tiers: tiers, run: run) }
    }

    public var liveRunIDs: [String] { runs.filter { $0.status == .running }.map(\.id) }

    /// The demo's one standing sentence, and nil on a real machine.
    public var note: String? { DelegateDemo.isDemoHost(host) ? DelegateDemo.note : nil }

    public var emptyLine: String {
        Localized.text("No runs yet. Write a packet and this machine will pick a tier for it.")
    }

    public mutating func landed(capabilities: DelegateCapabilities, tiers: [DelegateTier]) {
        self.capabilities = capabilities
        self.tiers = tiers
        phase = .ready
    }

    public mutating func failed(_ reason: String) {
        phase = .failed(reason)
    }

    /// The listing replaces the records; every fold this device made is kept, because the record
    /// has no events and a story rebuilt from it would forget the rungs it failed on.
    public mutating func filled(runs: [DelegateRun]) {
        self.runs = runs
        for run in runs {
            guard let delivery = run.delivery, stories[run.id] != nil else { continue }
            stories[run.id]?.delivery = delivery
        }
    }

    /// A held patch went one way or the other: the record and the fold both say so at once, before
    /// the daemon's listing catches up.
    public mutating func delivered(runID: String, _ delivery: DelegateDelivery) {
        if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index].delivery = delivery }
        if stories[runID] == nil, let run = runs.first(where: { $0.id == runID }) {
            stories[runID] = DelegateRunStory(runID: runID, tiers: tiers, run: run)
        }
        stories[runID]?.delivery = delivery
    }

    public mutating func filled(stats: [DelegateStat]) {
        self.stats = stats
    }

    /// A run this device just started, placed at the top before the daemon's listing catches up.
    public mutating func expect(runID: String, packet: DelegatePacket, startTier: String?, ceiling: String?) {
        var story = DelegateRunStory(runID: runID, tiers: tiers)
        story.packet = packet
        story.startTier = startTier ?? packet.tier
        story.ceiling = ceiling ?? packet.ceiling
        stories[runID] = story
        if !runs.contains(where: { $0.id == runID }) {
            runs.insert(
                DelegateRun(
                    id: runID, packetID: packet.id, taskClass: packet.taskClass, repo: packet.repo ?? "",
                    host: capabilities?.host ?? host, mode: packet.mode ?? .normal,
                    startTier: story.startTier ?? tierOrder.first ?? "", ceiling: story.ceiling ?? tierOrder.last ?? "",
                    status: .running, createdAt: DelegateTimestamp.format(Date()), finishedAt: nil,
                    passedTier: nil, escalations: 0, summary: "", packet: packet), at: 0)
        }
    }

    public mutating func fold(_ envelope: DelegateEnvelope) {
        var story = stories[envelope.runID]
            ?? runs.first { $0.id == envelope.runID }.map { DelegateRunStory(runID: $0.id, tiers: tiers, run: $0) }
            ?? DelegateRunStory(runID: envelope.runID, tiers: tiers)
        story.fold(envelope)
        stories[envelope.runID] = story
        if let index = runs.firstIndex(where: { $0.id == envelope.runID }) {
            runs[index].status = story.status
            runs[index].passedTier = story.passedTier
            runs[index].escalations = story.escalations
            runs[index].summary = story.summary
            if let delivery = story.delivery, story.status == .passed { runs[index].delivery = delivery }
            if story.status != .running, runs[index].finishedAt == nil {
                runs[index].finishedAt = envelope.timestamp
            }
        }
    }

    /// The story to draw for one run: the fold when this device followed it, else the stored record.
    public func story(for runID: String) -> DelegateRunStory? {
        stories[runID] ?? runs.first { $0.id == runID }.map { DelegateRunStory(runID: $0.id, tiers: tiers, run: $0) }
    }

    public mutating func remember(_ story: DelegateRunStory) {
        stories[story.runID] = story
    }
}
