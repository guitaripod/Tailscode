import CoreGraphics
import Foundation
import TailscodeCore

/// Where the gallery stands among its pictures. Paging wraps, as the old window's did: the last picture
/// is one press from the first.
struct ViewerPager: Equatable {
    private(set) var count: Int
    private(set) var index: Int

    init(count: Int, index: Int = 0) {
        self.count = max(0, count)
        self.index = self.count == 0 ? 0 : min(max(0, index), self.count - 1)
    }

    mutating func step(_ delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    mutating func first() { index = 0 }

    mutating func last() { index = max(0, count - 1) }

    mutating func select(_ position: Int) {
        guard count > 0 else { return }
        index = min(max(0, position), count - 1)
    }

    /// "2 of 5", and nothing at all for a single picture, which has no place among others.
    var counter: String? {
        count > 1 ? Localized.text("%d of %d", index + 1, count) : nil
    }
}

/// How the picture is scaled: to fit the pane, at one image pixel per screen pixel, or wherever a
/// pinch or a `+ −` left it.
enum ViewerZoomMode: Equatable {
    case fit
    case actual
    case custom
}

/// The zoom's arithmetic, apart from the scroll view that wears it. Fit never enlarges: a picture
/// smaller than the pane — an icon, a small chart the agent drew — would otherwise open as an
/// interpolated smear and offer 1:1 as though the view it replaced were not already a zoom.
struct ViewerZoom: Equatable {
    static let limits: ClosedRange<CGFloat> = 0.02...12
    static let step: CGFloat = 1.25

    var mode: ViewerZoomMode = .fit

    /// The double-click and `z`: between fit and true pixels, from wherever a pinch left it.
    mutating func toggle() {
        mode = mode == .actual ? .fit : .actual
    }

    mutating func fit() { mode = .fit }

    mutating func actual() { mode = .actual }

    /// The scale one `+` or `−` press lands on, and the mode becomes whatever it is now.
    mutating func stepped(from scale: CGFloat, in direction: Int) -> CGFloat {
        mode = .custom
        let factor = direction >= 0 ? Self.step : 1 / Self.step
        return min(Self.limits.upperBound, max(Self.limits.lowerBound, scale * factor))
    }

    /// One image pixel per screen pixel: the document is sized in image pixels, so that is
    /// `1 / backingScale`.
    static func actualScale(backingScale: CGFloat) -> CGFloat {
        1 / max(1, backingScale)
    }

    /// The magnification the mode asks for in a pane showing a picture of `image` pixels, or nil when
    /// the mode is a hand's own and the scale is to be left where it is. A fitted picture keeps `margin`
    /// points clear of the pane on every side, so it sits on its canvas rather than against the sheet's edges.
    func scale(pane: CGSize, image: CGSize, backingScale: CGFloat, margin: CGFloat = 0) -> CGFloat? {
        let actual = Self.actualScale(backingScale: backingScale)
        let pane = CGSize(width: pane.width - 2 * margin, height: pane.height - 2 * margin)
        switch mode {
        case .actual:
            return actual
        case .fit:
            guard image.width > 0, image.height > 0, pane.width > 0, pane.height > 0 else { return actual }
            let fit = min(pane.width / image.width, pane.height / image.height)
            return min(max(Self.limits.lowerBound, fit), actual)
        case .custom:
            return nil
        }
    }
}

/// What a key means in the viewer, apart from the event that made it.
enum ViewerKey: Equatable {
    case close
    case previous
    case next
    case first
    case last
    case advance
    case zoomIn
    case zoomOut
    case fit
    case actual
    case toggleZoom
    case copy
    case save

    /// The key table. ← → Home End page, Space pages forward (or plays and pauses a clip), `+ − 0 1`
    /// zoom, `z` toggles, ⌘C copies the picture, ⌘S saves it, Esc closes. Control and Option make a
    /// chord that is somebody else's, so they match nothing.
    static func match(keyCode: UInt16, character: String, command: Bool, shift: Bool, other: Bool) -> ViewerKey? {
        guard !other else { return nil }
        if command {
            guard !shift else { return nil }
            switch character {
            case "c": return .copy
            case "s": return .save
            default: return nil
            }
        }
        switch keyCode {
        case 53: return .close
        case 123: return .previous
        case 124: return .next
        case 115: return .first
        case 119: return .last
        case 49: return .advance
        default: break
        }
        switch character {
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .fit
        case "1": return .actual
        case "z": return .toggleZoom
        default: return nil
        }
    }
}
