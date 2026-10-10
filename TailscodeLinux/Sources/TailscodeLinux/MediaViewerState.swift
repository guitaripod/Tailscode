import Foundation
import TailscodeCore

/// Where the viewer is in the pictures it was given. Paging wraps, as the gallery always did, and a
/// viewer holding one picture has nowhere to go and says so by having no counter.
struct ViewerPager: Equatable, Sendable {
    let count: Int
    private(set) var index: Int

    init(count: Int, index: Int = 0) {
        self.count = max(0, count)
        self.index = self.count == 0 ? 0 : min(max(0, index), self.count - 1)
    }

    var canPage: Bool { count > 1 }

    mutating func advance(by delta: Int) {
        guard canPage else { return }
        index = ((index + delta) % count + count) % count
    }

    mutating func first() {
        index = 0
    }

    mutating func last() {
        index = max(0, count - 1)
    }

    /// "2 of 5", or nothing at all when there is no other picture to be the second of.
    var counter: String? {
        canPage ? Localized.text("%lld of %lld", index + 1, count) : nil
    }
}

/// How large the picture is drawn: the whole of it fitted into the room, or a scale of its own
/// pixels. The scale is absolute — 1 is one picture pixel to one screen pixel — so `1:1` is a
/// state rather than a calculation, and the steps are multiplicative so each press looks the same.
enum ViewerZoom: Equatable, Sendable {
    case fit
    case scaled(Double)

    static let step: Double = 1.25
    static let maximum: Double = 16
    static let actual = ViewerZoom.scaled(1)

    var isFit: Bool {
        if case .fit = self { return true }
        return false
    }

    var isActual: Bool { self == .actual }

    /// The scale this zoom draws at, given the scale that fits the picture into the room.
    func scale(fit fitScale: Double) -> Double {
        switch self {
        case .fit: return fitScale
        case .scaled(let value): return value
        }
    }

    /// One step larger than what is drawn now, never past `maximum`.
    func zoomedIn(fit fitScale: Double) -> ViewerZoom {
        let next = min(Self.maximum, scale(fit: fitScale) * Self.step)
        return .scaled(next)
    }

    /// One step smaller; arriving at or under the fitted scale is the fit, so a picture is never
    /// drawn smaller than the room it has.
    func zoomedOut(fit fitScale: Double) -> ViewerZoom {
        guard case .scaled(let value) = self else { return .fit }
        let next = value / Self.step
        return next <= fitScale * 1.0001 ? .fit : .scaled(next)
    }

    /// Double-click: the fit becomes 1:1 and anything else goes back to the fit.
    var toggled: ViewerZoom { isFit ? .actual : .fit }

    /// The words the toolbar's zoom button wears: what pressing it does.
    var buttonWord: String {
        isFit ? Localized.text("1:1") : Localized.text("Fit")
    }
}

/// What a key means to the viewer, decided before anything is touched so the mapping can be proved
/// without a window.
enum ViewerCommand: Equatable, Sendable {
    case previous
    case next
    case first
    case last
    case zoomIn
    case zoomOut
    case fit
    case actualSize
    case toggleZoom
    case copy
    case save
    case close

    /// The command a chord is. Space pages forward unless a button holds the keyboard, whose own
    /// Space it is; Escape and the close chord are the sheet's, so they are not listed here.
    static func command(for chord: KeyChord, buttonHasFocus: Bool) -> ViewerCommand? {
        if chord.control {
            guard !chord.alt, !chord.shift else { return nil }
            switch chord.keyval {
            case UInt32(UnicodeScalar("c").value): return .copy
            case UInt32(UnicodeScalar("s").value): return .save
            default: return nil
            }
        }
        guard !chord.alt else { return nil }
        switch chord.keyval {
        case 0xFF51: return .previous
        case 0xFF53: return .next
        case 0xFF50: return .first
        case 0xFF57: return .last
        case 0x0020: return buttonHasFocus ? nil : .next
        case UInt32(UnicodeScalar("+").value), UInt32(UnicodeScalar("=").value): return .zoomIn
        case UInt32(UnicodeScalar("-").value), UInt32(UnicodeScalar("_").value): return .zoomOut
        case UInt32(UnicodeScalar("0").value): return .fit
        case UInt32(UnicodeScalar("1").value): return .actualSize
        case UInt32(UnicodeScalar("z").value): return .toggleZoom
        default: return nil
        }
    }
}
