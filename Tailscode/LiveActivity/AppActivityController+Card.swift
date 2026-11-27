import ActivityKit
import CodingAgentKit
import Foundation
import TailscodeCore

/// How a card's state is worked out and compared: pure answers about what a card shows, kept
/// apart from the controller that owns the cards.
extension AppActivityController {
    /// Whether the platform refused a card only because too many are standing — the one refusal
    /// that taking an old settled card down can answer.
    static func isFull(_ error: Error) -> Bool {
        guard let refusal = error as? ActivityAuthorizationError else { return false }
        return refusal == .targetMaximumExceeded || refusal == .globalMaximumExceeded
    }

    static func isStanding(_ platform: ActivityState) -> Bool {
        platform == .active || platform == .stale
    }

    static func liveState(
        _ reading: LiveActivityReading, startedAt: Date, toolCount: Int, title: String?,
        brief: LiveActivityBrief? = nil
    ) -> State {
        let face = reading.face
        return State(
            phase: phase(reading.detail),
            statusText: reading.detail.line(tool: reading.tool, toolCount: toolCount),
            lastTool: reading.tool, toolCount: toolCount, startedAt: startedAt, endedAt: nil,
            title: title, symbol: face.symbol, tone: face.tone.rawValue,
            detail: reading.detail.rawValue, background: nil, brief: brief)
    }

    /// What an ended card keeps of its brief: its steps, its words, its files, who answered and the
    /// question it stopped on, and not the pulse, the plan or the moment it last moved, which belong
    /// to a turn that is still going. claude-bridge settles a card to exactly this shape.
    static func settledBrief(_ brief: LiveActivityBrief?) -> LiveActivityBrief? {
        guard var brief else { return nil }
        brief.beat = nil
        brief.moved = nil
        brief.fill = nil
        brief.ultra = nil
        brief.plan = nil
        return brief.isEmpty ? nil : brief
    }

    /// Whether an ending belongs to a turn before the one the card is following: the card is live
    /// for a turn that began after it. A turn wait answered while the phone slept and a chat woken
    /// late both report the last turn's end, and by then the next turn, sent from the desk, may
    /// already have taken the card back.
    static func endsEarlierTurn(_ shown: State, _ reading: LiveActivityReading) -> Bool {
        guard !shown.isSettled, let endedAt = reading.endedAt else { return false }
        return shown.startedAt.timeIntervalSince(endedAt) > 1
    }

    /// Whether a running reading is for a turn that began after the card's ending. A prompt other
    /// than the one this process settled the card on says so outright, while the card still shows
    /// that settle: the ending may be the phone's clock and the start the server's, and a turn
    /// that follows at once — a queued prompt, a send from the desk — can start before the phone
    /// heard the last one end. Otherwise only the turn's start can say, as the transcript has it.
    static func beganAfter(
        _ endedAt: Date, _ reading: LiveActivityReading, settled: (prompt: String, endedAt: Date)?
    ) -> Bool {
        if let settled, let prompt = reading.prompt, prompt != settled.prompt,
            abs(settled.endedAt.timeIntervalSince(endedAt)) < 1
        {
            return true
        }
        guard let began = reading.startedAt else { return false }
        return began > endedAt
    }

    /// Whether a live card's moment of last moving has run far enough ahead of what it shows that
    /// its "nothing new" clock would be wrong without a write.
    static func movedOn(_ state: State, from shown: State) -> Bool {
        guard !state.isSettled, let moved = state.brief?.moved else { return false }
        guard let before = shown.brief?.moved else { return true }
        return moved.timeIntervalSince(before) > movedDrift
    }

    /// Whether two states draw the same card. The words and the face are written from the detail
    /// on the phone, so a push that carries the server's English and no face of its own is the
    /// same card as the one written here, and is not written over again — nor is one whose clock
    /// lost its fraction of a second on the way through the server.
    static func sameFacts(_ a: State, _ b: State) -> Bool {
        a.phase == b.phase && a.detail == b.detail && a.lastTool == b.lastTool
            && a.toolCount == b.toolCount && a.title == b.title && a.background == b.background
            && sameBrief(a.brief, b.brief)
            && sameMoment(a.startedAt, b.startedAt) && a.isSettled == b.isSettled
            && sameMoment(a.endedAt ?? a.startedAt, b.endedAt ?? b.startedAt)
    }

    /// Whether two briefs draw the same card, leaving out the pulse and the moment it last moved:
    /// those ride along with writes the facts call for, and `movedOn` keeps the moment honest.
    static func sameBrief(_ a: LiveActivityBrief?, _ b: LiveActivityBrief?) -> Bool {
        func still(_ brief: LiveActivityBrief?) -> LiveActivityBrief? {
            guard var brief else { return nil }
            brief.beat = nil
            brief.moved = nil
            if let fill = brief.fill { brief.fill = (fill * 100).rounded() / 100 }
            return brief.isEmpty ? nil : brief
        }
        return still(a) == still(b)
    }

    /// The turn's start as the transcript records it, when that is earlier than the card's own: a
    /// card opened on a turn already running starts its clock when it was opened until the
    /// transcript says when the turn really began. Never more than a day back, which no turn is.
    static func earlier(_ shown: Date, _ transcript: Date?) -> Date {
        guard let transcript, transcript < shown, shown.timeIntervalSince(transcript) < 86_400
        else { return shown }
        return transcript
    }

    static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }

    static func phase(_ detail: LiveActivityDetail) -> Phase {
        Phase(rawValue: detail.phase) ?? .thinking
    }

    /// A live card goes stale when nothing has been heard for a while; a settled one never does,
    /// because an ending does not get older in any way a person needs warning of.
    static func content(_ state: State) -> ActivityContent<State> {
        let detail = state.detail.flatMap(LiveActivityDetail.init(rawValue:))
        let relevance = detail?.relevance ?? (state.isSettled ? 10 : 50)
        return ActivityContent(
            state: state, staleDate: staleDate(state, detail: detail, now: Date()),
            relevanceScore: relevance)
    }

    /// When the platform redraws a live card as having heard nothing: the wall's quiet threshold
    /// after it last moved, so a stall reads as one on the Lock Screen as it does on the wall. A
    /// card waiting on the person is not quiet — it is waiting — and a settled one never goes
    /// stale, because an ending does not get older in any way a person needs warning of.
    static func staleDate(_ state: State, detail: LiveActivityDetail?, now: Date) -> Date? {
        guard !state.isSettled else { return nil }
        guard detail?.wantsYou != true, let moved = state.brief?.moved else {
            return now.addingTimeInterval(staleAfter)
        }
        return LiveActivityQuiet.staleDate(moved: moved, now: now, ceiling: staleAfter)
    }

    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
