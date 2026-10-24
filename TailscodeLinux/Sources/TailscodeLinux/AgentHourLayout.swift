import Foundation
import TailscodeCore

/// Where everything in the hour sits: a label column on the left, the last sixty minutes in the
/// rest, a ruler above, and a row a lane. Pure arithmetic on a width, a row height and a moment,
/// so a lane's place is the same whether it is being drawn, hovered or measured by a check.
struct AgentHourLayout: Equatable {
    var width: Double
    var labelWidth: Double
    var rulerHeight: Double
    var rowHeight: Double
    var childHeight: Double
    var gutter: Double = 16
    var lanes: [AgentHourLane]

    var trackLeft: Double { labelWidth + gutter }
    var trackRight: Double { max(trackLeft + 40, width - gutter) }
    var trackWidth: Double { trackRight - trackLeft }

    func height(of lane: AgentHourLane) -> Double { lane.parentID == nil ? rowHeight : childHeight }

    func top(ofLane index: Int) -> Double {
        rulerHeight + lanes.prefix(index).reduce(0) { $0 + height(of: $1) }
    }

    var contentHeight: Double { top(ofLane: lanes.count) }

    /// The lane under a y, or nil over the ruler and below the last row.
    func lane(atY y: Double) -> Int? {
        guard y >= rulerHeight else { return nil }
        var top = rulerHeight
        for (index, lane) in lanes.enumerated() {
            let bottom = top + height(of: lane)
            if y < bottom { return index }
            top = bottom
        }
        return nil
    }

    /// The x of a moment on the track, with the last hour ending at `now`.
    func x(of date: Date, now: Date) -> Double {
        let fraction = 1 - now.timeIntervalSince(date) / AgentHour.span
        return trackLeft + trackWidth * min(max(fraction, -0.05), 1.02)
    }

    /// The moment at an x on the track.
    func date(atX x: Double, now: Date) -> Date {
        let fraction = (x - trackLeft) / trackWidth
        return now.addingTimeInterval(-AgentHour.span * (1 - fraction))
    }

    /// The minutes-ago of every ruler tick, oldest first, ending at now.
    static let tickMinutes: [Int] = [60, 50, 40, 30, 20, 10, 0]
}

/// What a lane says of itself in words, beside its title: the machine it is on, and what it is
/// doing or how it ended. The only place the lane's state is a word, so it is never colour alone.
enum AgentHourWords {
    static func state(_ lane: AgentHourLane, now: Date) -> String {
        if let span = lane.spans.last, now.timeIntervalSince(span.end) < 3 {
            let age = StatusFacts.age(now.timeIntervalSince(span.start))
            switch span.phase {
            case .working: return Localized.text("working")
            case .needsYou: return Localized.text("needs you, %@", age)
            case .background: return Localized.text("background %@", age)
            }
        }
        if let mark = lane.marks.last {
            let age = StatusFacts.age(now.timeIntervalSince(mark.at))
            switch mark.outcome {
            case .done: return Localized.text("done %@ ago", age)
            case .failed: return Localized.text("failed %@ ago", age)
            case .stopped: return Localized.text("stopped %@ ago", age)
            case .unknown: return Localized.text("ended %@ ago", age)
            }
        }
        return Localized.text("idle")
    }

    static func subtitle(_ lane: AgentHourLane, now: Date) -> String {
        let state = state(lane, now: now)
        return lane.parentID == nil ? lane.machine + " · " + state : state
    }

    static func phase(_ phase: AgentHourPhase) -> String {
        switch phase {
        case .working: return Localized.text("Working")
        case .needsYou: return Localized.text("Waiting on you")
        case .background: return Localized.text("In the background")
        }
    }

    /// The tooltip for a lane at a moment: the span under the pointer, or the hour's blind spot.
    static func tooltip(
        lane: AgentHourLane, at date: Date, unseen: [DateInterval], now: Date
    ) -> String {
        var lines = [lane.title, subtitle(lane, now: now)]
        if let span = lane.spans.first(where: { $0.start <= date && date <= $0.end }) {
            let minutes = Int(span.end.timeIntervalSince(span.start) / 60)
            let length = minutes < 1 ? Localized.text("under a minute") : StatusFacts.age(span.end.timeIntervalSince(span.start))
            lines.append(phase(span.phase) + " · " + length)
        } else if unseen.contains(where: { $0.contains(date) }) {
            lines.append(Localized.text("Not seen by this device"))
        }
        return lines.joined(separator: "\n")
    }
}
