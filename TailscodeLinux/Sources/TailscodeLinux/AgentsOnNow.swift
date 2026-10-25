import CodingAgentKit
import Foundation
import TailscodeCore

/// One line of the sidebar's "On now" section: a chat that is working or waiting on the person.
struct AgentsOnNowRow: Equatable, Sendable {
    let key: String
    let title: String
    let words: String
    let since: Date?
    let needsYou: Bool

    var tone: ActivityTone { needsYou ? .attention : .live }
}

/// Everything the sidebar says about the agents at one moment, read from one place: the open
/// board when there is one, the chat list when there is not, Core's fiction in demo mode. The
/// entry, the "On now" section and the footer pill all take their words from this and nothing
/// else, so they cannot disagree with one another.
struct AgentsReading: Equatable, Sendable {
    static let capacity = 4
    static let quiet = AgentsReading(chip: AgentsChip(needsYou: 0, working: 0), running: 0, rows: [])

    let chip: AgentsChip
    let running: Int
    let rows: [AgentsOnNowRow]

    init(chip: AgentsChip, running: Int, rows: [AgentsOnNowRow]) {
        self.chip = chip
        self.running = running
        self.rows = rows
    }

    /// The board's own reading: what waits on the person first, then what works, in the order the
    /// board keeps them.
    init(board: AgentBoard) {
        let asking = board.needsYou.map {
            AgentsOnNowRow(
                key: $0.id, title: $0.title, words: $0.ask.lead, since: $0.ask.since, needsYou: true)
        }
        let working = board.working.map {
            AgentsOnNowRow(
                key: $0.id, title: $0.title,
                words: $0.line ?? $0.word ?? Localized.text("Working"), since: $0.startedAt,
                needsYou: false)
        }
        self.init(
            chip: AgentsChip(headline: board.headline),
            running: board.headline.needsYou + board.headline.working + board.headline.background,
            rows: Array((asking + working).prefix(Self.capacity)))
    }

    /// What the chat list can tell while no board is open: a turn that is open, a turn waiting on
    /// an approval, and work carried between turns. It cannot say what a turn is doing, so a row
    /// says the state in a word, and has no clock because the list knows no start.
    init(list rows: [SessionRowModel]) {
        func row(_ model: SessionRowModel, needsYou: Bool) -> AgentsOnNowRow {
            AgentsOnNowRow(
                key: model.entry.profileID + "/" + model.entry.session.id, title: model.title,
                words: model.snippet ?? (needsYou ? Localized.text("Needs you") : Localized.text("Working")),
                since: nil, needsYou: needsYou)
        }
        let asking = rows.filter { $0.state == .awaitingApproval }
        let working = rows.filter { $0.state == .live }
        let carried = rows.count {
            switch $0.state {
            case .background, .stalled: return true
            default: return false
            }
        }
        self.init(
            chip: AgentsChip(needsYou: asking.count, working: working.count),
            running: asking.count + working.count + carried,
            rows: Array((asking.map { row($0, needsYou: true) } + working.map { row($0, needsYou: false) })
                .prefix(Self.capacity)))
    }

    var mood: AgentsMood {
        chip.needsYou > 0 ? .needs : chip.working > 0 ? .working : .idle
    }

    /// The footer pill's words: what waits on the person outranks what merely runs.
    var footerText: String {
        if chip.needsYou > 0 { return Localized.text("%d needs you", chip.needsYou) }
        if running > 0 { return Localized.text("%d running", running) }
        return Localized.text("All quiet")
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
