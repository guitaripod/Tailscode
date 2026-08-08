import Foundation

/// A picture the agent hands you is content — you read it, so it gets the row's whole preview. A
/// picture *you* sent is a receipt: you already know what it was, and the only question it has to
/// answer while scrolling past is *which* one. So it renders small, and the transcript stays a
/// transcript instead of a roll of your own screenshots. Both open full-size on a tap; nothing is
/// hidden, only sized. One rule, three clients — each applies it in its own units.
public enum ImagePreview {
    /// What a sent picture keeps of the box a handed-over one would fill.
    public static let sentScale: Double = 0.42

    /// Below this a thumbnail stops being recognisable, so a small box never shrinks past it.
    public static let sentFloor: Double = 96

    /// A pixel bound (a thumbnail's side, a maximum height) for one direction of travel.
    public static func bound(_ full: Double, mine: Bool) -> Double {
        guard mine else { return full }
        return max(min(full, sentFloor), (full * sentScale).rounded())
    }

    /// A share of the row's width, for clients that size a bubble against its container.
    public static func share(_ full: Double, mine: Bool) -> Double {
        mine ? full * sentScale : full
    }
}
