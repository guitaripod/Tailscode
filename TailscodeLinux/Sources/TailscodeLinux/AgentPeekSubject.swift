import CodingAgentKit
import Foundation
import TailscodeCore

/// What the board knows of the session a peek is about, whichever section it sits in.
struct AgentPeekSubject {
    let key: String
    let title: String
    let machine: String
    let profileID: String
    let chip: ModelChip?
    let tone: ActivityTone
    let motion: ActivityMotion
    let isAway: Bool
    let row: AgentRow?
    let card: AgentAskCard?
    let finish: AgentFinish?
    let laneNote: String?

    init(
        key: String, title: String, machine: String, profileID: String, chip: ModelChip?,
        tone: ActivityTone, motion: ActivityMotion, isAway: Bool, row: AgentRow? = nil,
        card: AgentAskCard? = nil, finish: AgentFinish? = nil, laneNote: String? = nil
    ) {
        self.laneNote = laneNote
        self.key = key
        self.title = title
        self.machine = machine
        self.profileID = profileID
        self.chip = chip
        self.tone = tone
        self.motion = motion
        self.isAway = isAway
        self.row = row
        self.card = card
        self.finish = finish
    }

    /// A session the hour remembers and the board no longer lists: all that is known of it is the
    /// lane's own words, and the chat.
    static func lane(_ lane: AgentHourLane, now: Date = Date()) -> AgentPeekSubject {
        AgentPeekSubject(
            key: lane.profileID + "/" + lane.sessionID, title: lane.title, machine: lane.machine,
            profileID: lane.profileID, chip: nil, tone: .quiet, motion: .still, isAway: false,
            laneNote: AgentHourWords.state(lane, now: now))
    }

    static func find(_ key: String, in board: AgentBoard) -> AgentPeekSubject? {
        if let card = board.needsYou.first(where: { $0.id == key }) {
            return AgentPeekSubject(
                key: key, title: card.title, machine: card.machine, profileID: card.profileID,
                chip: card.chip, tone: .attention, motion: .attention, isAway: card.isAway, card: card)
        }
        if let row = (board.working + board.background).first(where: { $0.id == key }) {
            return AgentPeekSubject(
                key: key, title: row.title, machine: row.machine, profileID: row.profileID,
                chip: row.chip, tone: row.tone, motion: row.motion, isAway: row.isAway, row: row)
        }
        if let finish = board.finished.first(where: { $0.id == key }) {
            let face = AgentsParts.finishGlyph(finish.outcome)
            return AgentPeekSubject(
                key: key, title: finish.title, machine: finish.machine, profileID: "", chip: nil,
                tone: face.tone, motion: .still, isAway: false, finish: finish)
        }
        return nil
    }
}
