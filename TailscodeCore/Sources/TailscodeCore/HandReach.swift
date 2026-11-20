import Foundation

/// Where the hands are while a person holds the device, and so which edges of a window a thumb
/// reaches without stretching.
///
/// A tablet turned on its side is held by its two ends: each thumb rests on a side edge a little
/// below the middle and sweeps an arc a few centimetres in from it. The top band and the middle of
/// the glass are for reading; whatever is done over and over belongs in one of the two wells at
/// the sides. A window that shares the screen meets only one of those edges, so only one thumb
/// reaches it, and a single floating action goes to that side. Read from the window's frame on the
/// screen every time it moves, never from the model of the device.
public struct HandReach: Equatable, Sendable {
    public enum Hold: Equatable, Sendable {
        /// Upright, small, or a window that floats clear of both side edges: the ordinary layout.
        case ordinary
        /// A large screen held sideways in both hands.
        case twoThumbs
    }

    public enum Side: Equatable, Sendable {
        case leading, trailing
    }

    public let hold: Hold
    /// The side of the window a thumb reaches: the one meeting the screen's edge when only one
    /// does, the trailing side otherwise.
    public let outerSide: Side
    /// Whether the window's leading edge lies on a side edge of the screen, under a thumb.
    public let reachesLeading: Bool
    /// Whether the window's trailing edge lies on a side edge of the screen, under a thumb.
    public let reachesTrailing: Bool

    public init(hold: Hold, outerSide: Side, reachesLeading: Bool, reachesTrailing: Bool) {
        self.hold = hold
        self.outerSide = outerSide
        self.reachesLeading = reachesLeading
        self.reachesTrailing = reachesTrailing
    }

    public static let ordinary = HandReach(
        hold: .ordinary, outerSide: .trailing, reachesLeading: true, reachesTrailing: true)

    /// How wide a screen held sideways must be before it is held by its ends: a phone on its side
    /// is crossed by either thumb, a tablet is not.
    public static let twoThumbScreenWidth = 1000.0

    /// How close to a screen edge a window's edge must lie to count as on it; tiled windows keep a
    /// few points of margin from the glass.
    public static let edgeSlack = 24.0

    /// Reads the hold from the window's frame in the screen's coordinates and the screen's size.
    /// `rightToLeft` turns leading and trailing to the layout's own sides.
    public static func read(
        windowX: Double, windowWidth: Double, screenWidth: Double, screenHeight: Double,
        rightToLeft: Bool = false
    ) -> HandReach {
        guard screenWidth > screenHeight, screenWidth >= twoThumbScreenWidth, windowWidth > 0 else {
            return .ordinary
        }
        let onLeft = windowX <= edgeSlack
        let onRight = windowX + windowWidth >= screenWidth - edgeSlack
        let leading = rightToLeft ? onRight : onLeft
        let trailing = rightToLeft ? onLeft : onRight
        let outer: Side = leading && !trailing ? .leading : .trailing
        return HandReach(
            hold: .twoThumbs, outerSide: outer, reachesLeading: leading, reachesTrailing: trailing)
    }

    /// Whether the screen is held in both hands.
    public var isTwoThumbs: Bool { hold == .twoThumbs }
}
