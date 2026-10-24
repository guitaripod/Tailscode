import AppKit
import CodingAgentKit
import TailscodeCore

/// Who the peek is about, from whichever place the person pointed: a card, a row, or a lane of the
/// hour. It carries the listed facts, so a session nobody is watching still has a header and a line.
struct AgentsSubject: Equatable {
    let key: String
    let profileID: String
    let title: String
    let machine: String
    let chip: ModelChip?
    let tone: ActivityTone
    let motion: ActivityMotion
    let startedAt: Date?
    let line: String?
    let card: AgentAskCard?
    let isWatched: Bool
    let isRunning: Bool
    let isAway: Bool

    @MainActor
    static func resolve(key: String, in board: AgentBoard, lane: AgentHourLane? = nil) -> AgentsSubject? {
        if let card = board.needsYou.first(where: { $0.id == key }) {
            return AgentsSubject(
                key: key, profileID: card.profileID, title: card.title, machine: card.machine,
                chip: card.chip, tone: .attention, motion: .attention, startedAt: card.ask.since,
                line: nil, card: card, isWatched: true, isRunning: true, isAway: card.isAway)
        }
        if let row = (board.working + board.background).first(where: { $0.id == key }) {
            return AgentsSubject(
                key: key, profileID: row.profileID, title: row.title, machine: row.machine,
                chip: row.chip, tone: row.tone, motion: row.motion, startedAt: row.startedAt,
                line: row.line, card: nil, isWatched: row.isWatched, isRunning: true,
                isAway: row.isAway)
        }
        if let finish = board.finished.first(where: { $0.id == key }) {
            return AgentsSubject(
                key: key, profileID: finish.profileID, title: finish.title, machine: finish.machine,
                chip: nil, tone: finish.outcome == .failed ? .danger : .quiet, motion: .still,
                startedAt: nil, line: finish.line, card: nil, isWatched: false, isRunning: false,
                isAway: false)
        }
        guard let lane else { return nil }
        return AgentsSubject(
            key: key, profileID: lane.profileID, title: lane.title, machine: lane.machine,
            chip: nil, tone: .quiet, motion: .still, startedAt: nil, line: nil, card: nil,
            isWatched: false, isRunning: false, isAway: false)
    }
}
