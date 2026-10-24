import Foundation

public enum AgentHourPhase: Sendable, Equatable {
    case working
    case needsYou
    case background
}

/// One stretch of an hour a session was doing one thing.
public struct AgentHourSpan: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let phase: AgentHourPhase
}

/// A turn's end, as a mark on its lane.
public struct AgentHourMark: Sendable, Equatable {
    public let at: Date
    public let outcome: AgentFinish.Outcome
}

public struct AgentHourLane: Sendable, Equatable, Identifiable {
    public let id: String
    public let parentID: String?
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let machine: String
    public let spans: [AgentHourSpan]
    public let marks: [AgentHourMark]
}

/// The last hour as lanes, drawn only from what this device saw: a span it did not watch is
/// returned as unseen rather than filled in, so a quiet gap and a blind one never look alike.
public struct AgentHour: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let lanes: [AgentHourLane]
    public let unseen: [DateInterval]

    public static let span: TimeInterval = 3600
}

/// The phases this device saw, kept in the order they were seen.
public struct AgentHourLog: Sendable {
    private struct Lane {
        var id: String
        var profileID: String
        var sessionID: String
        var parentID: String?
        var title: String
        var machine: String
        var order: Int
        var notes: [(at: Date, phase: AgentHourPhase?)] = []
        var marks: [AgentHourMark] = []
    }

    private var lanes: [String: Lane] = [:]
    private var observing: [(start: Date, end: Date?)] = []
    private var counter = 0

    public init() {}

    public mutating func beginObserving(at now: Date) {
        guard observing.last?.end != nil || observing.isEmpty else { return }
        observing.append((now, nil))
    }

    public mutating func endObserving(at now: Date) {
        guard var last = observing.last, last.end == nil else { return }
        last.end = now
        observing[observing.count - 1] = last
    }

    /// Notes what a session was doing at a moment; the same thing twice is one note.
    public mutating func note(
        id: String, parentID: String? = nil, profileID: String, sessionID: String, title: String,
        machine: String, phase: AgentHourPhase?, at now: Date
    ) {
        var lane =
            lanes[id]
            ?? {
                counter += 1
                return Lane(
                    id: id, profileID: profileID, sessionID: sessionID, parentID: parentID, title: title,
                    machine: machine, order: counter)
            }()
        lane.title = title
        defer { lanes[id] = lane }
        if let last = lane.notes.last, last.phase == phase { return }
        if lane.notes.last == nil, phase == nil { return }
        lane.notes.append((now, phase))
    }

    public mutating func end(id: String, outcome: AgentFinish.Outcome, at now: Date) {
        guard var lane = lanes[id] else { return }
        lane.marks.append(AgentHourMark(at: now, outcome: outcome))
        lanes[id] = lane
    }

    public func hour(now: Date, span: TimeInterval = AgentHour.span) -> AgentHour {
        let start = now.addingTimeInterval(-span)
        let ordered = lanes.values.sorted { $0.order < $1.order }
        let top = ordered.filter { $0.parentID == nil }
        var result: [AgentHourLane] = []
        for lane in top {
            guard let made = Self.lane(lane, start: start, now: now) else { continue }
            result.append(made)
            for child in ordered where child.parentID == lane.id {
                if let childLane = Self.lane(child, start: start, now: now) {
                    result.append(childLane)
                }
            }
        }
        return AgentHour(start: start, end: now, lanes: result, unseen: unseen(start: start, now: now))
    }

    private static func lane(_ lane: Lane, start: Date, now: Date) -> AgentHourLane? {
        var spans: [AgentHourSpan] = []
        for (index, note) in lane.notes.enumerated() {
            guard let phase = note.phase else { continue }
            let end = index + 1 < lane.notes.count ? lane.notes[index + 1].at : now
            let from = max(note.at, start)
            if end > from { spans.append(AgentHourSpan(start: from, end: end, phase: phase)) }
        }
        let marks = lane.marks.filter { $0.at >= start }
        guard !spans.isEmpty || !marks.isEmpty else { return nil }
        return AgentHourLane(
            id: lane.id, parentID: lane.parentID, profileID: lane.profileID, sessionID: lane.sessionID,
            title: lane.title, machine: lane.machine, spans: spans, marks: marks)
    }

    private func unseen(start: Date, now: Date) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = start
        for interval in observing {
            let from = max(interval.start, start)
            let to = min(interval.end ?? now, now)
            guard to > from else { continue }
            if from > cursor { gaps.append(DateInterval(start: cursor, end: from)) }
            cursor = max(cursor, to)
        }
        if cursor < now { gaps.append(DateInterval(start: cursor, end: now)) }
        return gaps
    }
}
