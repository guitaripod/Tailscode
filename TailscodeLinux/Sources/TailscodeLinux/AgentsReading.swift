import CodingAgentKit
import Foundation
import TailscodeCore

/// Everything the sidebar says about the agents at one moment, read from one place: the open
/// board when there is one, the chat list when there is not, Core's fiction in demo mode. The
/// card's chips, its sentence, its orbit and the name a screen reader hears all take their facts
/// from this and nothing else, so they cannot disagree with one another.
struct AgentsReading: Equatable, Sendable {
    static let quiet = AgentsReading(working: 0, needsYou: 0, agents: 0, background: 0, waiting: nil)
    static let shortcut = "Ctrl+Shift+A"

    let working: Int
    let needsYou: Int
    let agents: Int
    let background: Int
    let waiting: String?

    init(working: Int, needsYou: Int, agents: Int, background: Int, waiting: String?) {
        self.working = working
        self.needsYou = needsYou
        self.agents = agents
        self.background = background
        self.waiting = waiting
    }

    /// The board's own reading: what waits on the person, what works, the sub-agents the working
    /// rows carry, and what the machines run between turns.
    init(board: AgentBoard) {
        self.init(
            working: board.headline.working, needsYou: board.headline.needsYou,
            agents: board.working.reduce(0) { $0 + Self.agents(in: $1) },
            background: board.headline.background, waiting: board.needsYou.first?.title)
    }

    /// What the chat list can tell while no board is open: a turn that is open, a turn waiting on
    /// an approval, the sub-agents the listing counts, and work carried between turns.
    init(list rows: [SessionRowModel]) {
        let own = rows.filter { !$0.entry.session.isSubagent }
        let asking = own.filter { $0.state == .awaitingApproval }
        let working = own.filter { $0.state == .live }
        self.init(
            working: working.count, needsYou: asking.count,
            agents: (asking + working).reduce(0) { $0 + ($1.entry.session.activeAgents ?? 0) },
            background: own.count { $0.state.carriesBackgroundWork }, waiting: asking.first?.title)
    }

    private static func agents(in row: AgentRow) -> Int {
        row.children.isEmpty
            ? row.listedAgents : row.children.count { $0.kind == .agent && $0.isActive }
    }

    var running: Int { working + needsYou + background }

    var mood: AgentsMood {
        needsYou > 0 ? .needs : working > 0 ? .working : .idle
    }

    /// The counts the sentence is made of, each one a count and its word, only when there is
    /// something to count.
    var parts: [String] {
        var parts: [String] = []
        if working > 0 { parts.append(Localized.text("%d working", working)) }
        if agents > 0 { parts.append(Self.agentsWords(agents)) }
        if background > 0 { parts.append(Localized.text("%d in the background", background)) }
        return parts.map(Self.unbroken)
    }

    /// The second line of the card. Quiet says so and names the shortcut when there is room for
    /// it; something waiting names the first chat that waits; otherwise the counts.
    func sentence(withShortcut: Bool) -> String {
        if needsYou > 0, let waiting, !waiting.isEmpty { return Localized.text("%@ needs you", waiting) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        let quiet = Localized.text("All quiet").lowercased()
        return withShortcut ? quiet + " · " + Self.shortcut : quiet
    }

    /// A count and its word kept on one line, so a wrap falls between the counts and never
    /// through one.
    private static func unbroken(_ part: String) -> String {
        part.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func agentsWords(_ count: Int) -> String {
        count == 1 ? Localized.text("%d agent", count) : Localized.text("%d agents", count)
    }

    /// The name a screen reader hears: "Agents, 3 working, 1 needs you, 2 agents".
    var spoken: String {
        var parts = [Localized.text("Agents")]
        if working > 0 { parts.append(Localized.text("%d working", working)) }
        if needsYou > 0 { parts.append(Localized.text("%d needs you", needsYou)) }
        if agents > 0 { parts.append(Self.agentsWords(agents)) }
        if background > 0 { parts.append(Localized.text("%d in the background", background)) }
        return parts.joined(separator: ", ")
    }
}

/// How the sidebar's agents face looks: still and dim, breathing green, or knocking amber.
enum AgentsMood: Equatable, Sendable {
    case idle
    case working
    case needs

    var motion: ActivityMotion {
        switch self {
        case .idle: return .still
        case .working: return .working
        case .needs: return .attention
        }
    }

    var tone: ActivityTone {
        switch self {
        case .idle: return .quiet
        case .working: return .live
        case .needs: return .attention
        }
    }

    var cssClass: String {
        switch self {
        case .idle: return "agents-entry-idle"
        case .working: return "agents-entry-working"
        case .needs: return "agents-entry-needs"
        }
    }

    static let cssClasses = ["agents-entry-idle", "agents-entry-working", "agents-entry-needs"]
}
