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

    public init(host: String, serverName: String) {
        self.host = host
        self.serverName = serverName
        phase = .idle
        capabilities = nil
        tiers = []
        runs = []
        stats = []
        stories = [:]
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

    public var statusTone: ActivityTone {
        switch phase {
        case .idle, .checking: return .quiet
        case .ready: return .live
        case .failed: return .danger
        }
    }

    public var tierLines: [DelegateTierLine] { tiers.map(DelegateTierLine.init) }

    public var statRows: [DelegateStatRow] { stats.map(DelegateStatRow.init) }

    public var promotions: [String] { DelegatePromotion.hints(stats, tiers: tierOrder) }

    /// Every run, newest first, as the story a row is drawn from — the live fold where one exists,
    /// otherwise the daemon's stored record.
    public var runStories: [DelegateRunStory] {
        runs.map { run in stories[run.id] ?? DelegateRunStory(runID: run.id, tiers: tiers, run: run) }
    }

    public var liveRunIDs: [String] { runs.filter { $0.status == .running }.map(\.id) }

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

    public mutating func filled(runs: [DelegateRun]) {
        self.runs = runs
        for run in runs where run.status != .running {
            stories[run.id] = nil
        }
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
