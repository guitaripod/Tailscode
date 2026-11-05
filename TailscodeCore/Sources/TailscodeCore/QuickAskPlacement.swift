import Foundation

/// Where the quick ask stands and how big it is, remembered across summons.
///
/// The card opens under the pointer, because the pointer is where the person already is
/// (`QuickAskGeometry.origin(pointer:anchor:…)`); what is remembered is its size and, for a desktop
/// that cannot say where the pointer is, its place. The size is one answer for every screen,
/// because a person sizes the card for how much they want to see, not for a monitor. The place is
/// remembered per screen, by the connector the desktop names it with, because the corner that
/// suits a wide monitor is the wrong corner on a laptop panel; a screen with no place of its own
/// gets the last place used anywhere, at the same share of the screen. Everything read back is
/// clamped into the screen it opens on, so a monitor that shrank or went away never leaves the
/// card off the edge.
public struct QuickAskPlacement: Codable, Sendable, Equatable {
    public struct Spot: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        /// The screen the spot was taken on, so it can be carried to another as a share of it.
        public var screenWidth: Double
        public var screenHeight: Double

        public init(x: Double, y: Double, screenWidth: Double, screenHeight: Double) {
            self.x = x
            self.y = y
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
        }
    }

    public var width: Double?
    public var height: Double?
    public var spots: [String: Spot]
    public var lastScreen: String?

    public init(
        width: Double? = nil, height: Double? = nil, spots: [String: Spot] = [:],
        lastScreen: String? = nil
    ) {
        self.width = width
        self.height = height
        self.spots = spots
        self.lastScreen = lastScreen
    }
}

public struct QuickAskRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Which edges a press near the card's border takes hold of.
public struct QuickAskEdges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = QuickAskEdges(rawValue: 1)
    public static let right = QuickAskEdges(rawValue: 2)
    public static let top = QuickAskEdges(rawValue: 4)
    public static let bottom = QuickAskEdges(rawValue: 8)

    /// The cursor a desktop shows over these edges, by its CSS name.
    public var cursor: String? {
        switch self {
        case [.left], [.right]: return "ew-resize"
        case [.top], [.bottom]: return "ns-resize"
        case [.left, .top], [.right, .bottom]: return "nwse-resize"
        case [.right, .top], [.left, .bottom]: return "nesw-resize"
        default: return nil
        }
    }
}

public enum QuickAskGeometry {
    public static let defaultWidth: Double = 680
    public static let defaultHeight: Double = 600
    public static let minimumWidth: Double = 480
    public static let minimumHeight: Double = 320
    /// How close to the screen's edge the card may come.
    public static let inset: Double = 8
    /// How far either side of the card's border a press takes hold of it: the band straddles the
    /// edge, so the border can be caught without aiming at a hairline and a rounded corner, which
    /// the card itself does not cover, can be caught at all.
    public static let grip: Double = 6
    /// How far along an edge from a corner a press near that edge takes the corner instead.
    public static let cornerGrip: Double = 18

    /// The card's size on a screen: the remembered one, or the first-run one, never smaller than
    /// what the card needs to hold a question and a few lines, never bigger than the screen.
    public static func size(_ placement: QuickAskPlacement, screenWidth: Double, screenHeight: Double)
        -> (width: Double, height: Double)
    {
        let width = placement.width ?? defaultWidth
        let height = placement.height ?? min(defaultHeight, screenHeight * 0.7)
        return (
            clamp(width, minimumWidth, max(minimumWidth, screenWidth - 2 * inset)),
            clamp(height, minimumHeight, max(minimumHeight, screenHeight - 2 * inset))
        )
    }

    /// Where the card's top-left corner goes for it to open under the pointer: the pointer lands on
    /// `anchor`, a point of the card measured from its top-left corner — the mark at the head of the
    /// question box, so what is typed starts right beside the pointer — and the card is then clamped
    /// into the screen, sliding in from an edge rather than leaving any of itself past it.
    public static func origin(
        pointer: (x: Double, y: Double), anchor: (x: Double, y: Double), screenWidth: Double,
        screenHeight: Double, width: Double, height: Double
    ) -> (x: Double, y: Double) {
        clampOrigin(
            x: pointer.x - anchor.x, y: pointer.y - anchor.y, width: width, height: height,
            screenWidth: screenWidth, screenHeight: screenHeight)
    }

    /// Where the card's top-left corner goes on a screen when the pointer cannot be read: its own
    /// remembered place, else the last place used on any screen at the same share of this one, else
    /// centred across and a little above the middle, where a palette is expected.
    public static func origin(
        _ placement: QuickAskPlacement, screen: String?, screenWidth: Double, screenHeight: Double,
        width: Double, height: Double
    ) -> (x: Double, y: Double) {
        let spot: (x: Double, y: Double)
        if let screen, let own = placement.spots[screen] {
            spot = (own.x, own.y)
        } else if let last = placement.lastScreen.flatMap({ placement.spots[$0] }),
            last.screenWidth > 0, last.screenHeight > 0
        {
            spot = (
                last.x / last.screenWidth * screenWidth, last.y / last.screenHeight * screenHeight
            )
        } else {
            spot = ((screenWidth - width) / 2, screenHeight * 0.18)
        }
        return clampOrigin(
            x: spot.x, y: spot.y, width: width, height: height, screenWidth: screenWidth,
            screenHeight: screenHeight)
    }

    public static func clampOrigin(
        x: Double, y: Double, width: Double, height: Double, screenWidth: Double,
        screenHeight: Double
    ) -> (x: Double, y: Double) {
        (
            clamp(x, inset, max(inset, screenWidth - width - inset)),
            clamp(y, inset, max(inset, screenHeight - height - inset))
        )
    }

    /// The edges a press at `x`, `y` — measured from the card's top-left corner, so outside the
    /// card is negative or past its size — takes hold of: none away from the border, two near a
    /// corner.
    public static func edges(atX x: Double, y: Double, width: Double, height: Double)
        -> QuickAskEdges
    {
        guard x >= -grip, x <= width + grip, y >= -grip, y <= height + grip else { return [] }
        let nearLeft = x <= grip
        let nearRight = x >= width - grip
        let nearTop = y <= grip
        let nearBottom = y >= height - grip
        let nearSide = nearLeft || nearRight
        let nearEnd = nearTop || nearBottom
        var edges: QuickAskEdges = []
        if nearLeft || (nearEnd && x <= cornerGrip) { edges.insert(.left) }
        if nearRight || (nearEnd && x >= width - cornerGrip) { edges.insert(.right) }
        if nearTop || (nearSide && y <= cornerGrip) { edges.insert(.top) }
        if nearBottom || (nearSide && y >= height - cornerGrip) { edges.insert(.bottom) }
        return edges
    }

    /// The card after a drag of its border by `dx`, `dy`: the held edges follow the pointer, the
    /// opposite ones stay put, and the card never goes under its minimum or past the screen.
    public static func resized(
        _ frame: QuickAskRect, edges: QuickAskEdges, dx: Double, dy: Double, screenWidth: Double,
        screenHeight: Double
    ) -> QuickAskRect {
        var left = frame.x
        var top = frame.y
        var right = frame.x + frame.width
        var bottom = frame.y + frame.height
        if edges.contains(.left) {
            left = clamp(frame.x + dx, inset, right - minimumWidth)
        }
        if edges.contains(.right) {
            right = clamp(right + dx, left + minimumWidth, screenWidth - inset)
        }
        if edges.contains(.top) {
            top = clamp(frame.y + dy, inset, bottom - minimumHeight)
        }
        if edges.contains(.bottom) {
            bottom = clamp(bottom + dy, top + minimumHeight, screenHeight - inset)
        }
        return QuickAskRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), max(low, high))
    }
}

/// The remembered placement, on this device.
public enum QuickAskPlacementStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let key = "tailscode.quickask.placement"

    public static func load() -> QuickAskPlacement {
        guard let raw = defaults.string(forKey: key), let data = raw.data(using: .utf8),
            let placement = try? JSONDecoder().decode(QuickAskPlacement.self, from: data)
        else { return QuickAskPlacement() }
        return placement
    }

    public static func save(_ placement: QuickAskPlacement) {
        guard let data = try? JSONEncoder().encode(placement),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: key)
    }

    public static func recordSize(width: Double, height: Double) {
        var placement = load()
        placement.width = width.rounded()
        placement.height = height.rounded()
        save(placement)
    }

    public static func recordSpot(
        x: Double, y: Double, screen: String, screenWidth: Double, screenHeight: Double
    ) {
        var placement = load()
        placement.spots[screen] = QuickAskPlacement.Spot(
            x: x.rounded(), y: y.rounded(), screenWidth: screenWidth, screenHeight: screenHeight)
        placement.lastScreen = screen
        save(placement)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }
}
