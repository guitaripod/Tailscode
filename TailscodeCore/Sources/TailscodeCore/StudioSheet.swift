import Foundation

/// Which half of the Studio a sheet is showing. Core has no lane type of its own, and the sheet's
/// state machine has to say "change lane" without borrowing a client's.
public enum StudioLaneKind: String, CaseIterable, Sendable {
    case image
    case video
}

/// Every number the Studio sheet's frame is made from, in one place so no client types one.
public enum StudioSheetMetrics {
    /// Left and right inset of the sheet in a window wide enough to have one.
    public static let sideInset: Double = 24
    /// The least the sheet ever starts below the top of the window.
    public static let minimumTopInset: Double = 36
    /// The seam between the title bar and the sheet, present only in a window tall enough to spare it.
    public static let titlebarGap: Double = 8
    /// A window at least this tall keeps the gap; a shorter one gives the stage the points back.
    public static let gapMinimumHeight: Double = 720
    /// A window narrower than this lets the sheet fill it edge to edge.
    public static let narrowWidth: Double = 700
    /// A window wider than this stops the sheet growing and centres it.
    public static let wideWidth: Double = 1800
    /// The widest the sheet ever is, so a 3:2 stage is not stretched across a very wide window.
    public static let cappedWidth: Double = 1752
    /// Radius of the sheet's two top corners.
    public static let cornerRadius: Double = 14
    /// Height of the toolbar the sheet carries inside itself, there being no title bar to borrow.
    public static let toolbarHeight: Double = 44
}

/// Where the sheet sits inside the window, in points, measured from the window's top-left so a
/// client with a flipped or an unflipped space converts once.
public struct StudioSheetFrame: Equatable, Sendable {
    /// Distance from the window's left edge to the sheet's.
    public let x: Double
    /// Distance from the window's top edge to the sheet's.
    public let y: Double
    public let width: Double
    public let height: Double
    public let topInset: Double
    public let leftInset: Double
    public let rightInset: Double
    public let bottomInset: Double
    /// Radius of the two top corners; the bottom is flush with the window's own corners.
    public let cornerRadius: Double
}

/// The rectangle the Studio sheet fills for a window, and nothing else: how it is drawn is a client's.
public enum StudioSheetGeometry {
    /// The frame for a window of this size whose title bar clears `titlebar` points from the top.
    /// The top inset keeps the title bar (traffic lights, chat title) in view, plus a seam of
    /// `StudioSheetMetrics.titlebarGap` in a window at least 720 tall; the sides are 24, or 0 under
    /// 700 of width; above 1800 the sheet caps at 1752 and centres; the bottom is flush. A window
    /// shorter than the top inset gets a sheet of no height rather than a negative one.
    public static func frame(windowWidth: Double, windowHeight: Double, titlebar: Double)
        -> StudioSheetFrame
    {
        let width = finite(windowWidth)
        let height = finite(windowHeight)
        let bar = finite(titlebar)
        let gap = height >= StudioSheetMetrics.gapMinimumHeight ? StudioSheetMetrics.titlebarGap : 0
        let top = max(StudioSheetMetrics.minimumTopInset, bar + gap)
        let sheetWidth: Double
        let side: Double
        if width < StudioSheetMetrics.narrowWidth {
            sheetWidth = width
            side = 0
        } else if width > StudioSheetMetrics.wideWidth {
            sheetWidth = StudioSheetMetrics.cappedWidth
            side = (width - sheetWidth) / 2
        } else {
            side = StudioSheetMetrics.sideInset
            sheetWidth = width - 2 * side
        }
        return StudioSheetFrame(
            x: side, y: top, width: sheetWidth, height: max(0, height - top),
            topInset: top, leftInset: side, rightInset: side, bottomInset: 0,
            cornerRadius: StudioSheetMetrics.cornerRadius)
    }

    /// A size a toolkit never reports, a NaN or a negative, reads as no room at all.
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Which face of the app the scrim is drawn over: a black dim reads very differently on each.
public enum StudioSheetAppearance: Sendable {
    case dark
    case light
}

/// The names of the curves the motion is drawn with, so a client maps a word rather than guessing one.
public enum StudioSheetCurve: Sendable {
    case springCriticallyDamped
    case easeOutQuad
    case easeInQuad
}

/// The sheet's one motion: how long it takes, how far it travels and what fades with it. The
/// functions are pure, so a toolkit's animation, a hand-driven clock and a test all read the same arithmetic.
public enum StudioSheetMotion {
    public static let openDuration: Double = 0.320
    public static let closeDuration: Double = 0.220
    public static let reducedDuration: Double = 0.120
    /// How far below its rest position, as a fraction of its own height, the sheet starts.
    public static let travelFraction: Double = 0.28
    public static let scrimAlphaDark: Double = 0.38
    public static let scrimAlphaLight: Double = 0.26
    /// Width of the hairline in the rule token that edges the sheet along its top and sides.
    public static let edgeHairlineWidth: Double = 1
    /// Blur of the shadow cast upward from the sheet's edge onto the scrim.
    public static let edgeShadowBlur: Double = 24
    public static let edgeShadowAlpha: Double = 0.30

    /// How dark the scrim gets at rest: a light conversation turns to mud under the dark face's 38 %.
    public static func scrimAlpha(for appearance: StudioSheetAppearance) -> Double {
        switch appearance {
        case .dark: return scrimAlphaDark
        case .light: return scrimAlphaLight
        }
    }

    /// How long the motion lasts; reduced motion is one short cross-fade either way.
    public static func duration(opening: Bool, reduced: Bool) -> Double {
        if reduced { return reducedDuration }
        return opening ? openDuration : closeDuration
    }

    /// The share of the motion done after `t` of its time (0…1, clamped): ease-out-quad rising,
    /// ease-in-quad leaving. Ease-out-cubic would have covered 91 % of the travel by 176 ms and
    /// hidden the move, so the quadratic it is.
    public static func eased(_ t: Double, opening: Bool) -> Double {
        let clamped = unit(t)
        return opening ? 1 - (1 - clamped) * (1 - clamped) : clamped * clamped
    }

    /// How present the sheet is after `elapsed` seconds: 0 is away, 1 is at rest. Opening rises
    /// along `eased`, closing falls along it, and both use `duration`.
    public static func progress(elapsed: Double, opening: Bool, reduced: Bool) -> Double {
        let span = duration(opening: opening, reduced: reduced)
        let done = eased(elapsed.isFinite ? elapsed / span : 0, opening: opening)
        return opening ? done : 1 - done
    }

    /// The distance the sheet still has to travel below its rest position at this presence
    /// (0 away, 1 at rest). Zero under reduced motion, which does not travel.
    public static func translation(progress: Double, sheetHeight: Double, reduced: Bool) -> Double {
        guard !reduced else { return 0 }
        return (1 - unit(progress)) * max(0, sheetHeight) * travelFraction
    }

    /// The sheet is opaque from its first frame, because a fade would show the conversation through
    /// the Studio; only reduced motion cross-fades it.
    public static func sheetOpacity(progress: Double, reduced: Bool) -> Double {
        reduced ? unit(progress) : 1
    }

    /// The scrim's alpha at this presence of the sheet.
    public static func scrimOpacity(progress: Double, appearance: StudioSheetAppearance) -> Double {
        scrimAlpha(for: appearance) * unit(progress)
    }

    /// The curve a client draws the motion with: a critically damped spring where the platform has
    /// one, ease-out-quad elsewhere; leaving is always ease-in-quad.
    public static func curve(opening: Bool, hasSpring: Bool) -> StudioSheetCurve {
        guard opening else { return .easeInQuad }
        return hasSpring ? .springCriticallyDamped : .easeOutQuad
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// What happened to the sheet: it was asked for, asked away, or finished moving.
public enum StudioSheetEvent: Equatable, Sendable {
    case show(lane: StudioLaneKind)
    case dismiss
    case finished
}

/// What a client must do about the transition the state machine just made.
public enum StudioSheetEffect: Equatable, Sendable {
    case none
    case animateIn(StudioLaneKind)
    case changeLane(StudioLaneKind)
    case animateOut
}

/// Where the sheet is in its life. `closed → opening → open → closing → closed`, and every client
/// answers the same.
public enum StudioSheetState: Equatable, Sendable {
    case closed
    case opening
    case open
    case closing

    /// The state after `event` and what to do about it. `show` while closed or closing animates in
    /// (from where a closing sheet is, so the client restarts the motion from its current
    /// progress rather than from zero); while opening or open it changes lane and keeps the
    /// state, with no animation. `dismiss` while opening or open animates out and is ignored
    /// when closing or closed. `finished` settles whichever motion was under way and means nothing elsewhere.
    public func reduced(by event: StudioSheetEvent) -> (
        state: StudioSheetState, effect: StudioSheetEffect
    ) {
        switch (self, event) {
        case (.closed, .show(let lane)), (.closing, .show(let lane)):
            return (.opening, .animateIn(lane))
        case (.opening, .show(let lane)), (.open, .show(let lane)):
            return (self, .changeLane(lane))
        case (.opening, .dismiss), (.open, .dismiss):
            return (.closing, .animateOut)
        case (.opening, .finished):
            return (.open, .none)
        case (.closing, .finished):
            return (.closed, .none)
        default:
            return (self, .none)
        }
    }

    /// The sheet owns the keyboard from the first frame of its rise to the moment it starts to leave.
    public var capturesKeys: Bool {
        self == .opening || self == .open
    }

    /// The conversation's chords come back the moment the closing motion starts, not when it ends.
    public var conversationChordsEnabled: Bool {
        self == .closed || self == .closing
    }
}

/// What Esc does with the sheet up.
public enum StudioSheetEscape: Equatable, Sendable {
    case stopRender
    case closeSheet
}

/// The sheet's key rules, one tested place so every desk answers alike.
public enum StudioSheetKeys {
    /// Esc stops a render that is out and only then closes: closing never stops a render, so the
    /// first press must not be spent on leaving while a picture is still being painted.
    public static func escape(renderIsOut: Bool) -> StudioSheetEscape {
        renderIsOut ? .stopRender : .closeSheet
    }

    /// Whether this chord closes the sheet before the window: Ctrl+W on a desk that speaks
    /// Control, or ⌘W when `command` says the Mac's menu key was down (the registry's chords
    /// leave ⌘ out, so a Mac client passes the letter and the flag). Plain `w`, a shifted `w`
    /// and anything with Alt are not it.
    public static func closes(_ chord: KeyChord, command: Bool = false) -> Bool {
        guard chord.keyval == UInt32(UnicodeScalar("w").value), !chord.shift, !chord.alt else {
            return false
        }
        return command ? !chord.control : chord.control
    }
}

/// The words the sheet owns, so no client types one.
public enum StudioSheetWords {
    /// The accessibility name of the sheet, announced as a dialog.
    public static var dialogName: String { Localized.text("Studio, dialog") }
    /// The label of the control that closes the sheet.
    public static var closeLabel: String { Localized.text("Close Studio") }
    /// The hint on Done and the Stop key while a render is out, saying Esc stops before it closes.
    public static var escapeHint: String { Localized.text("Press Esc to stop, again to close") }
}
