import AppKit
import CodingAgentKit
import TailscodeCore

/// The sections the board is read in, in the order a person has to deal with them.
enum AgentsSection: String, CaseIterable {
    case needsYou
    case working
    case background
    case finished
}

/// The words the Mac adds to Core's own: the headings, the clock, and what each state says for an
/// ear. Core wrote the board's sentence, its watch line and every agent's line; nothing here
/// rewrites them.
enum AgentsWords {
    static func title(_ section: AgentsSection) -> String {
        switch section {
        case .needsYou: return Localized.text("Needs you")
        case .working: return Localized.text("Working")
        case .background: return Localized.text("In the background")
        case .finished: return Localized.text("Finished")
        }
    }

    /// A span said the short way a clock says it: seconds, then minutes, then hours and minutes.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func stopQuestion(_ title: String) -> String {
        Localized.text("Stop “%@”?", title)
    }

    static func waiting(_ elapsed: String) -> String {
        Localized.text("waiting %@", elapsed)
    }

    static func ago(_ date: Date, now: Date) -> String {
        GitState.age(date, now: now)
    }

    static func lastSeen(_ date: Date?, now: Date) -> String {
        guard let date else { return Localized.text("Not answering") }
        return Localized.text("Not answering · last seen %@", ago(date, now: now))
    }

    static func unreadCount(_ count: Int) -> String {
        Localized.text("%d unread", count)
    }

    static func agents(_ count: Int) -> String {
        Localized.text("%d agents", count)
    }

    static func todos(_ todos: (done: Int, total: Int)) -> String {
        "\(todos.done)/\(todos.total)"
    }

    static var emptyTitle: String { Localized.text("Nothing is running") }

    static var emptyDetail: String {
        Localized.text(
            "When an agent works or waits on you, it shows up here: what it is doing, and the command it wants to run.")
    }

    static var listedOnly: String { Localized.text("Listed only, not watched") }

    static func state(word: String?, section: AgentsSection) -> String {
        if let word, !word.isEmpty { return word }
        switch section {
        case .background: return Localized.text("In the background")
        case .finished: return Localized.text("Finished")
        default: return Localized.text("Working")
        }
    }

    static func beat(_ beat: [Int]) -> String {
        beat.contains { $0 > 0 }
            ? Localized.text("Active in the last minute") : Localized.text("No activity in the last minute")
    }

    static func approveVerb(_ ask: AgentAsk) -> String {
        ask.isApproval ? Localized.text("Approve") : Localized.text("Answer")
    }

    /// One sentence for a row, for the ear: the title, the state, how long, what it is doing and
    /// where it runs.
    static func spoken(row: AgentRow, section: AgentsSection, now: Date, showsMachine: Bool) -> String {
        var parts = [row.title, state(word: row.word, section: section)]
        if let started = row.startedAt { parts.append(elapsed(now.timeIntervalSince(started))) }
        if let line = row.line, !line.isEmpty { parts.append(line) }
        if showsMachine { parts.append(row.machine) }
        if let chip = row.chip { parts.append([chip.name, chip.effort].compactMap { $0 }.joined(separator: " ")) }
        if let beat = row.beat { parts.append(Self.beat(beat)) }
        if row.isAway { parts.append(Localized.text("Not answering")) }
        return parts.joined(separator: ", ")
    }

    static func spoken(finish: AgentFinish, now: Date) -> String {
        [finish.title, finish.line, ago(finish.endedAt, now: now)].joined(separator: ", ")
    }
}

/// The things every cell asks of the window that holds it: the clock, when a machine was last
/// heard and what a press on a verb does.
@MainActor
final class AgentsContext {
    var now: () -> Date = { Date() }
    var lastHeard: (String) -> Date? = { profileID in
        guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
        else { return nil }
        return ServerDirectory.shared.lastHeard[ServerLabel.display(profile)]
    }
    var showsMachines = false
    let actions: AgentsActions

    init(actions: AgentsActions) {
        self.actions = actions
    }
}

extension ActivityTone {
    /// The tone's glyph when nothing but the shape may say it: a filled dot for work, a ring for
    /// what is quiet, a mark for what wants a look or broke.
    var agentSymbol: String {
        switch self {
        case .live: return "circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .danger: return "xmark.circle.fill"
        case .quiet: return "circle"
        }
    }
}

extension AgentsSection {
    /// The glyph a row wears in this section: the background's is a clock whatever its tone, so the
    /// two sections of live work never look alike.
    func icon(tone: ActivityTone, motion: ActivityMotion) -> ActivityIcon {
        let symbol: String
        if case .sweep = motion {
            symbol = "circle.dotted"
        } else if self == .background, tone == .live {
            symbol = "clock"
        } else {
            symbol = tone.agentSymbol
        }
        return ActivityIcon(symbol: symbol, glyph: "●", tone: tone, motion: motion)
    }
}
