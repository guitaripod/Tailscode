import Foundation

/// The arithmetic of choosing on the effort rail: which rung a finger is on, and when it has meant
/// to leave.
///
/// A rail is the ladder (`ModelDial.rungs`) drawn as a column opened by one tap, so what a client
/// owes is only where each row's centre is. A level is chosen by tapping it or by putting a finger
/// down and sliding before lifting, and everything that makes the slide feel decided rather than
/// twitchy lives here once: a rung is held until the finger is clearly closer to its neighbour, a
/// finger lifted well off the side chooses nothing, and the tick the hand feels is one per rung
/// entered, never one per frame.
public enum EffortRail {
    /// How much of a row's pitch the finger has to travel past the halfway point before the
    /// thumb lets go of the rung it holds. Without it a finger resting on a boundary flickers
    /// between two levels and ticks on every tremor.
    public static let hysteresis = 0.2

    /// How far, in points, a finger may stray sideways from the rail before the slide reads as
    /// a cancel rather than a choice.
    public static let cancelDistance = 72.0

    /// The rung the thumb is on given the centre of every row, top to bottom, and where the finger
    /// is. `current` is held until the finger is nearer to another centre by more than the
    /// hysteresis band, measured in rows.
    public static func target(current: Int?, centers: [Double], y: Double) -> Int? {
        guard !centers.isEmpty else { return nil }
        let nearest = centers.indices.min { abs(centers[$0] - y) < abs(centers[$1] - y) } ?? 0
        guard let current, centers.indices.contains(current), nearest != current else {
            return nearest
        }
        let pitch = averagePitch(centers)
        let lead = abs(centers[current] - y) - abs(centers[nearest] - y)
        return lead > hysteresis * pitch ? nearest : current
    }

    /// Whether a finger that has strayed this far from the rail's column has chosen nothing.
    public static func cancels(horizontalDistance: Double) -> Bool {
        horizontalDistance > cancelDistance
    }

    /// Whether landing on a rung is a tick the hand should feel: only when it is a different rung
    /// from the one just held.
    public static func ticks(from old: Int?, to new: Int?) -> Bool {
        new != nil && old != new
    }

    /// The word under the rail while a finger is down: what the held rung means and, once the
    /// client knows it, what the person's own turns at that level took.
    public static func footer(for rung: EffortRung, yours: String?) -> String {
        guard let yours, !yours.isEmpty else { return rung.caption }
        return rung.caption + " · " + yours
    }

    private static func averagePitch(_ centers: [Double]) -> Double {
        guard centers.count > 1, let first = centers.first, let last = centers.last else { return 1 }
        return (last - first) / Double(centers.count - 1)
    }
}

/// The arithmetic of sliding along the effort half of the pill: a hand that moves along the bars
/// walks the model's own ladder one notch at a time, hotter toward the end the bars grow to.
///
/// It stops at both ends rather than wrapping, never falls onto the server's own stop (the same
/// rule as the arrow keys, `ModelDial.step`), and keeps no dead zone: a hand that has run past the
/// end is *at* the end, so reversing leaves it at once instead of retracing the distance it
/// overshot.
public struct EffortScrub: Sendable, Equatable {
    /// How far along the bars a hand travels for one level.
    public static let notchWidth = 24.0

    public private(set) var level: String?
    private var applied = 0
    private var slack = 0

    /// A slide that begins at the level the control shows.
    public init(level: String?) {
        self.level = level
    }

    /// The whole notches a hand has crossed after travelling `translation` points along the
    /// screen's x axis. A right-to-left layout grows its bars leftward, so its sign is flipped.
    public static func notches(translation: Double, rightToLeft: Bool = false) -> Int {
        Int(((rightToLeft ? -translation : translation) / notchWidth).rounded(.towardZero))
    }

    /// Carries the slide to `notches` and returns each level it newly reached, in the order the
    /// hand crossed them. Empty when the hand has not crossed a notch or is pinned at an end.
    public mutating func move(to notches: Int, options: [String]) -> [String?] {
        var reached: [String?] = []
        while applied != notches - slack {
            let delta = notches - slack > applied ? 1 : -1
            let next = ModelDial.step(level, by: delta, options: options)
            guard next != level else {
                slack = notches - applied
                break
            }
            applied += delta
            level = next
            reached.append(next)
        }
        return reached
    }
}
