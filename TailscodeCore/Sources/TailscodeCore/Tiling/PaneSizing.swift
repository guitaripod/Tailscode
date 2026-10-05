import Foundation

/// The smallest rectangle a pane may be given, in logical points.
public struct PaneMinimum: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = PaneMinimum(width: 0, height: 0)

    /// The larger of two minimums on each axis. A host may know a slot needs more room than its
    /// kind does — a painter with a wide toolbar — and it can only ever ask for more, never less.
    public func combined(with other: PaneMinimum) -> PaneMinimum {
        PaneMinimum(width: max(width, other.width), height: max(height, other.height))
    }

    public func extent(along axis: SplitAxis) -> Double {
        axis == .horizontal ? width : height
    }
}

/// The geometry every host agrees on: how small each kind of pane may get, how wide the seam
/// between two panes is, how much of it a pointer can grab, and the threshold at which a chat
/// has room to be a whole conversation rather than a status tile.
public enum PaneSizing {
    /// The visible seam between siblings.
    public static let gutter: Double = 1
    /// How much of the seam a pointer can grab: four points either side of a one-point line.
    public static let dividerHit: Double = 9
    /// The overflow strip that names hidden panes.
    public static let stripHeight: Double = 28
    /// How far past the full-density minimum a glance must grow before it is full again, so a
    /// drag that hovers on the threshold does not make the pane flicker between faces.
    public static let hysteresis: Double = 16

    /// How far a keyboard resize moves a divider, and how far with shift.
    public static let keyboardStep: Double = 16
    public static let keyboardStepLarge: Double = 64

    public static let chatFull = PaneMinimum(width: 280, height: 200)
    public static let chatGlance = PaneMinimum(width: 200, height: 88)
    public static let web = PaneMinimum(width: 280, height: 200)
    public static let video = PaneMinimum(width: 280, height: 158)
    public static let draw = PaneMinimum(width: 360, height: 300)
    public static let empty = PaneMinimum(width: 240, height: 160)

    /// The minimum a pane of `kind` needs at `density`. Only a chat changes with density; every
    /// other kind has one face that needs its room whether it is live or parked.
    public static func minimum(kind: PaneKind, density: PaneDensity) -> PaneMinimum {
        switch kind {
        case .chat: return density == .full ? chatFull : chatGlance
        case .web: return web
        case .video: return video
        case .draw: return draw
        case .empty: return empty
        }
    }

    /// The minimum the layout clamps to. A chat can always degrade to a glance, so a split is
    /// held to the glance minimum and density follows whatever room is left.
    public static func layoutMinimum(kind: PaneKind) -> PaneMinimum {
        minimum(kind: kind, density: kind == .chat ? .glance : .full)
    }

    /// Whether a chat pane of this size may be full. A full pane stays full down to the full
    /// minimum; a glance needs the minimum plus the hysteresis before it is promoted again.
    public static func allowsFull(width: Double, height: Double, wasFull: Bool) -> Bool {
        let margin = wasFull ? 0 : hysteresis
        return width >= chatFull.width + margin && height >= chatFull.height + margin
    }
}
