import CodingAgentKit
import Foundation

/// A session as the board is given it: the listing's word, and what this device heard first-hand
/// when it was watching.
public struct AgentSource: Sendable {
    public let entry: SessionEntry
    public let facts: AgentFacts?
    /// Whether the machine answered its last listing; nil while nobody has asked.
    public let reachable: Bool?
    public let unread: Bool

    public init(entry: SessionEntry, facts: AgentFacts?, reachable: Bool?, unread: Bool) {
        self.entry = entry
        self.facts = facts
        self.reachable = reachable
        self.unread = unread
    }
}

/// An agent working, or carrying work, with what is known of it.
public struct AgentRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let machine: String
    public let chip: ModelChip?
    public let tone: ActivityTone
    public let motion: ActivityMotion
    public let line: String?
    public let startedAt: Date?
    public let beat: [Int]?
    public let children: [AgentChild]
    /// Agents the listing counts for a session nobody is watching, which it cannot name.
    public let listedAgents: Int
    public let isWatched: Bool
    public let isAway: Bool
    public let unread: Bool
    public let word: String?
}

/// A session waiting on a person, with what it asks.
public struct AgentAskCard: Sendable, Equatable, Identifiable {
    public let id: String
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let machine: String
    public let ask: AgentAsk
    public let chip: ModelChip?
    public let isAway: Bool
}

/// A turn that ended in the last hour.
public struct AgentFinish: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case done
        case failed
        case stopped
        /// Ended while nobody here was watching, so how is not known.
        case unknown
    }

    public let id: String
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let machine: String
    public let outcome: Outcome
    public let line: String
    public let endedAt: Date
    public let unread: Bool

    public init(
        id: String, profileID: String, sessionID: String, title: String, machine: String,
        outcome: Outcome, line: String, endedAt: Date, unread: Bool
    ) {
        self.id = id
        self.profileID = profileID
        self.sessionID = sessionID
        self.title = title
        self.machine = machine
        self.outcome = outcome
        self.line = line
        self.endedAt = endedAt
        self.unread = unread
    }
}

public struct AgentMachine: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let reachable: Bool?
    public let running: Int
}

/// Every agent this device knows of, in the order a person has to deal with them: what waits on
/// them, what is working, what the machines carry in the background, what just ended. Each session
/// stands once, in the most urgent place it belongs.
public struct AgentBoard: Sendable, Equatable {
    public struct Headline: Sendable, Equatable {
        public let working: Int
        public let needsYou: Int
        public let background: Int
        public let unread: Int
    }

    public let headline: Headline
    public let needsYou: [AgentAskCard]
    public let working: [AgentRow]
    public let background: [AgentRow]
    public let finished: [AgentFinish]
    public let machines: [AgentMachine]
    public let watched: Int
    public let running: Int

    public static let finishedWindow: TimeInterval = 3600

    public static let empty = AgentBoard(
        headline: Headline(working: 0, needsYou: 0, background: 0, unread: 0), needsYou: [],
        working: [], background: [], finished: [], machines: [], watched: 0, running: 0)

    public var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && background.isEmpty }

    /// Whether a row needs to say which machine it is on: only when there is more than one.
    public var showsMachines: Bool { machines.count > 1 }

    /// "2 working · 1 needs you", or the plain thing when there is nothing to say.
    public var sentence: String {
        var parts: [String] = []
        if headline.working > 0 { parts.append(Localized.text("%d working", headline.working)) }
        if headline.needsYou > 0 { parts.append(Localized.text("%d needs you", headline.needsYou)) }
        if parts.isEmpty, headline.background > 0 {
            parts.append(Localized.text("%d in the background", headline.background))
        }
        return parts.isEmpty ? Localized.text("Nothing is running") : parts.joined(separator: " · ")
    }

    /// What the board is watching, said as it is: all of them, or the six it can afford of more.
    public var watchLine: String {
        let names = machines.map(\.name).joined(separator: ", ")
        let lead: String
        if running == 0 {
            lead = Localized.text("Nothing to watch")
        } else if watched >= running {
            lead = running == 1
                ? Localized.text("Watching the one running")
                : Localized.text("Watching all %d running", running)
        } else {
            lead = Localized.text("Watching %d of %d running", watched, running)
        }
        return names.isEmpty ? lead : lead + " · " + names
    }

    public static func read(
        sources: [AgentSource], finished ledger: [AgentFinish] = [], now: Date
    ) -> AgentBoard {
        let live = sources.filter { !$0.entry.session.isSubagent && $0.entry.session.archived != true }
        var asks: [(AgentAskCard, Date)] = []
        var working: [AgentRow] = []
        var background: [AgentRow] = []
        var settled: Set<String> = []
        for source in live {
            let key = key(source)
            if let facts = source.facts, let ask = facts.ask {
                asks.append(
                    (
                        AgentAskCard(
                            id: key, profileID: source.entry.profileID,
                            sessionID: source.entry.session.id, title: title(source),
                            machine: source.entry.profileName, ask: ask,
                            chip: ModelBadge.chip(for: source.entry),
                            isAway: source.reachable == false),
                        ask.since ?? now
                    ))
                continue
            }
            if let row = runningRow(source, now: now) {
                working.append(row)
            } else if let row = backgroundRow(source, now: now) {
                background.append(row)
            } else {
                settled.insert(key)
            }
        }
        asks.sort { $0.1 < $1.1 }
        working.sort { lhs, rhs in
            if lhs.isWatched != rhs.isWatched { return lhs.isWatched }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
        background.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        let ended = finishes(ledger, sources: live, settled: settled, now: now)
        let machines = machines(live)
        return AgentBoard(
            headline: Headline(
                working: working.count, needsYou: asks.count, background: background.count,
                unread: ended.filter(\.unread).count),
            needsYou: asks.map(\.0), working: working, background: background, finished: ended,
            machines: machines,
            watched: live.filter { $0.facts != nil && ($0.facts?.isRunning == true) }.count,
            running: asks.count + working.count)
    }

    private static func key(_ source: AgentSource) -> String {
        source.entry.profileID + "/" + source.entry.session.id
    }

    private static func title(_ source: AgentSource) -> String {
        let title = source.entry.session.title
        return AgentSession.isPlaceholderTitle(title) ? Localized.text("New chat") : title
    }

    private static func runningRow(_ source: AgentSource, now: Date) -> AgentRow? {
        let session = source.entry.session
        if let facts = source.facts {
            switch facts.phase {
            case .working:
                return row(source, facts: facts, tone: .live, motion: .working, word: nil, now: now)
            case .retrying:
                return row(
                    source, facts: facts, tone: .live, motion: .turning,
                    word: Localized.text("waiting on the provider"), now: now)
            case .needsYou, .background, .idle:
                return nil
            }
        }
        guard session.isWorking else { return nil }
        return AgentRow(
            id: key(source), profileID: source.entry.profileID, sessionID: session.id,
            title: title(source), machine: source.entry.profileName,
            chip: ModelBadge.chip(for: source.entry), tone: .live, motion: .working,
            line: session.agentTask, startedAt: nil, beat: nil, children: [],
            listedAgents: session.activeAgents ?? 0, isWatched: false,
            isAway: source.reachable == false, unread: source.unread, word: nil)
    }

    private static func backgroundRow(_ source: AgentSource, now: Date) -> AgentRow? {
        let session = source.entry.session
        let work: BackgroundWork?
        var children: [AgentChild] = []
        var watched = false
        if let facts = source.facts {
            guard case .background(let tasks, let stalled) = facts.phase else { return nil }
            work = BackgroundWork(
                tasks: tasks, task: facts.children.first { $0.kind == .background }?.title,
                since: facts.children.first { $0.kind == .background }?.startedAt, stalled: stalled)
            children = facts.children
            watched = true
        } else {
            work = session.backgroundWork
        }
        guard let work, work.tasks > 0 else { return nil }
        let line =
            work.task
            ?? (work.tasks == 1
                ? Localized.text("one task running")
                : Localized.text("%d tasks running", work.tasks))
        return AgentRow(
            id: key(source), profileID: source.entry.profileID, sessionID: session.id,
            title: title(source), machine: source.entry.profileName,
            chip: ModelBadge.chip(for: source.entry), tone: work.stalled ? .attention : .live,
            motion: work.stalled ? .still : .working, line: line, startedAt: work.since,
            beat: nil, children: watched ? children : [], listedAgents: 0, isWatched: watched,
            isAway: source.reachable == false, unread: source.unread,
            word: work.stalled ? Localized.text("stuck") : nil)
    }

    private static func row(
        _ source: AgentSource, facts: AgentFacts, tone: ActivityTone, motion: ActivityMotion,
        word: String?, now: Date
    ) -> AgentRow {
        let session = source.entry.session
        return AgentRow(
            id: key(source), profileID: source.entry.profileID, sessionID: session.id,
            title: title(source), machine: source.entry.profileName,
            chip: ModelBadge.chip(for: source.entry), tone: tone, motion: motion,
            line: facts.doing, startedAt: facts.startedAt, beat: facts.beat,
            children: facts.children, listedAgents: 0, isWatched: true,
            isAway: source.reachable == false, unread: source.unread, word: word)
    }

    /// The last hour's endings: what this device watched end, then the sessions the listing says
    /// moved since the person last looked, which it cannot say more of than that they ended.
    private static func finishes(
        _ ledger: [AgentFinish], sources: [AgentSource], settled: Set<String>, now: Date
    ) -> [AgentFinish] {
        let recent = ledger.filter { now.timeIntervalSince($0.endedAt) < finishedWindow }
        let known = Set(recent.map(\.id))
        let listed = sources.compactMap { source -> AgentFinish? in
            let id = key(source)
            let session = source.entry.session
            guard settled.contains(id), !known.contains(id), source.unread,
                now.timeIntervalSince(session.updatedAt) < finishedWindow
            else { return nil }
            return AgentFinish(
                id: id, profileID: source.entry.profileID, sessionID: session.id,
                title: title(source), machine: source.entry.profileName, outcome: .unknown,
                line: Localized.text("Finished"), endedAt: session.updatedAt, unread: true)
        }
        return (recent + listed).sorted { $0.endedAt > $1.endedAt }
    }

    private static func machines(_ sources: [AgentSource]) -> [AgentMachine] {
        var order: [String] = []
        var names: [String: String] = [:]
        var reach: [String: Bool?] = [:]
        var running: [String: Int] = [:]
        for source in sources {
            let id = source.entry.profileID
            if names[id] == nil {
                order.append(id)
                names[id] = source.entry.profileName
            }
            reach[id] = source.reachable
            if source.facts?.isRunning == true || (source.facts == nil && source.entry.session.isWorking) {
                running[id, default: 0] += 1
            }
        }
        return order.map {
            AgentMachine(id: $0, name: names[$0] ?? $0, reachable: reach[$0] ?? nil, running: running[$0] ?? 0)
        }
    }
}

extension AgentFinish {
    /// How a turn is remembered in a line: how long, how much, what it touched — or what went wrong.
    public static func line(
        outcome: Outcome, duration: TimeInterval?, tools: Int, files: Int, failure: String? = nil
    ) -> String {
        switch outcome {
        case .failed:
            if let failure, !failure.isEmpty { return Localized.text("Failed: %@", failure) }
            return Localized.text("Something went wrong")
        case .stopped:
            return Localized.text("Stopped")
        case .unknown:
            return Localized.text("Finished")
        case .done:
            var parts = [Localized.text("Done")]
            if let duration, duration >= 1 { parts[0] += " " + Localized.text("in %@", clock(duration)) }
            if tools > 0 { parts.append(Localized.text("%lld tools", tools)) }
            if files > 0 {
                parts.append(
                    files == 1
                        ? Localized.text("edited 1 file") : Localized.text("edited %lld files", files))
            }
            return parts.joined(separator: " · ")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
