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
