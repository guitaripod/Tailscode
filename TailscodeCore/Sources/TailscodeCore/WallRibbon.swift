import Foundation

/// The last hour as one thin ribbon: every lane's working, waiting and background stretches laid on
/// a single track, the endings as marks, and the stretches this device never saw, so a quiet hour and
/// a blind one never look alike. Positions are fractions of the hour, `0` an hour ago and `1` now.
public struct WallRibbon: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public let from: Double
        public let to: Double
        public let phase: AgentHourPhase

        public init(from: Double, to: Double, phase: AgentHourPhase) {
            self.from = from
            self.to = to
            self.phase = phase
        }
    }

    public struct Mark: Sendable, Equatable {
        public let at: Double
        public let outcome: AgentFinish.Outcome

        public init(at: Double, outcome: AgentFinish.Outcome) {
            self.at = at
            self.outcome = outcome
        }
    }

    public let spans: [Span]
    /// The stretches nobody here was watching.
    public let unseen: [ClosedRange<Double>]
    public let marks: [Mark]

    public static let empty = WallRibbon(spans: [], unseen: [], marks: [])

    public init(spans: [Span], unseen: [ClosedRange<Double>], marks: [Mark]) {
        self.spans = spans
        self.unseen = unseen
        self.marks = marks
    }

    public static func read(_ hour: AgentHour?, now: Date) -> WallRibbon {
        guard let hour else { return .empty }
        var spans: [Span] = []
        var marks: [Mark] = []
        for lane in hour.lanes where lane.parentID == nil {
            for span in lane.spans {
                let from = fraction(span.start, now: now)
                let to = fraction(span.end, now: now)
                if to >= from { spans.append(Span(from: from, to: to, phase: span.phase)) }
            }
            for mark in lane.marks {
                marks.append(Mark(at: fraction(mark.at, now: now), outcome: mark.outcome))
            }
        }
        var unseen: [ClosedRange<Double>] = []
        for gap in hour.unseen {
            let from = fraction(gap.start, now: now)
            let to = fraction(gap.end, now: now)
            if to > from { unseen.append(from...to) }
        }
        return WallRibbon(spans: spans, unseen: unseen, marks: marks)
    }

    static func fraction(_ date: Date, now: Date) -> Double {
        min(max(1 - now.timeIntervalSince(date) / AgentHour.span, 0), 1)
    }

    /// The thin track inside the ribbon's rectangle: under the caption, as tall as the calm screen's
    /// big ribbon or the busy screen's slim one.
    public static func track(in rect: WallRect, unit: Double, calm: Bool) -> WallRect {
        let small = max(1.6 * unit, 9)
        let height = (calm ? 4.2 : 2.0) * unit
        return WallRect(x: rect.x, y: rect.y + small * 1.4 + 0.4 * unit, width: rect.width, height: height)
    }
}
