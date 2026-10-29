import Foundation

/// A colour as the wall draws it: three channels in `0...1`, mixed and shaded without a toolkit.
public struct WallInk: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: String) {
        let channels = Contrast.channels(hex)
        self.init(red: channels?.red ?? 0.5, green: channels?.green ?? 0.5, blue: channels?.blue ?? 0.5)
    }

    public static let white = WallInk(red: 1, green: 1, blue: 1)
    public static let black = WallInk(red: 0, green: 0, blue: 0)

    public func mixed(with other: WallInk, _ amount: Double) -> WallInk {
        WallInk(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    public func lifted(_ amount: Double) -> WallInk { mixed(with: .white, amount) }

    public func sunk(_ amount: Double) -> WallInk { mixed(with: .black, amount) }

    var hue: Double {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let span = high - low
        guard span > 0.04 else { return -1 }
        var degrees: Double
        if high == red {
            degrees = 60 * ((green - blue) / span).truncatingRemainder(dividingBy: 6)
        } else if high == green {
            degrees = 60 * ((blue - red) / span + 2)
        } else {
            degrees = 60 * ((red - green) / span + 4)
        }
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}

/// The wall's colours: a theme's own dark palette, whatever the device is set to. A screen left up on
/// a desk reads as a screen only when it is dark, so a light appearance borrows the theme's dark side
/// for this one lens and nothing else.
public struct WallPalette: Sendable, Equatable {
    public var ground: WallInk
    public var deep: WallInk
    public var text: WallInk
    public var dim: WallInk
    public var rule: WallInk
    public var working: WallInk
    public var thinking: WallInk
    public var needs: WallInk
    public var overdue: WallInk
    public var quiet: WallInk
    public var finished: WallInk
    public var failed: WallInk

    public init(palette source: Palette) {
        let canvas = WallInk(hex: source.canvas)
        ground = canvas.sunk(0.12)
        deep = canvas.sunk(0.62)
        text = WallInk(hex: source.text).lifted(0.3)
        dim = WallInk(hex: source.textDim).lifted(0.12)
        rule = WallInk(hex: source.rule)
        working = WallInk(hex: source.accent)
        thinking = Self.violet(WallInk(hex: source.special), info: WallInk(hex: source.info))
        needs = WallInk(hex: source.warn)
        failed = WallInk(hex: source.danger)
        overdue = WallInk(hex: source.warn).mixed(with: WallInk(hex: source.danger), 0.62).lifted(0.08)
        quiet = WallInk(hex: source.textDim).mixed(with: WallInk(hex: source.info), 0.22).sunk(0.12)
        finished = WallInk(hex: source.info)
    }

    /// The palette the wall wears for a theme: always its dark side.
    public static func current(theme: AppTheme) -> WallPalette {
        WallPalette(palette: theme.dark)
    }

    /// Thinking is violet on every theme: the theme's own standing mark when it is one, and a violet
    /// mixed toward its information colour when that mark is orange or green, which would read as an
    /// ask or as work.
    private static func violet(_ mark: WallInk, info: WallInk) -> WallInk {
        let hue = mark.hue
        if hue >= 215 && hue <= 320 { return mark }
        return WallInk(red: 0.68, green: 0.56, blue: 1).mixed(with: info, 0.12)
    }

    static let warmth = WallInk(red: 1, green: 0.64, blue: 0.4)

    /// The same palette warmer and dimmer, for the hours when a screen in a dark room should not glare.
    public func night() -> WallPalette {
        var out = self
        let warm = Self.warmth
        func shade(_ ink: WallInk) -> WallInk { ink.mixed(with: warm, 0.22).sunk(0.2) }
        func ground(_ ink: WallInk) -> WallInk { ink.mixed(with: warm, 0.06).sunk(0.25) }
        out.ground = ground(self.ground)
        out.deep = ground(deep)
        out.text = shade(text)
        out.dim = shade(dim)
        out.rule = shade(rule)
        out.working = shade(working)
        out.thinking = shade(thinking)
        out.needs = shade(needs)
        out.overdue = shade(overdue)
        out.quiet = shade(quiet)
        out.finished = shade(finished)
        out.failed = shade(failed)
        return out
    }

    public func ink(for state: WallState) -> WallInk {
        switch state {
        case .working: return working
        case .thinking: return thinking
        case .needsYou(let urgency): return urgency == .overdue ? overdue : needs
        case .retrying: return needs
        case .quiet: return quiet
        case .background(let stuck): return stuck ? needs : working
        case .finished(let outcome):
            switch outcome {
            case .done: return finished
            case .failed: return failed
            case .stopped, .unknown: return dim
            }
        case .away: return dim
        }
    }

    /// The colour a role names; `tile` is the state's own colour, or plain text when no state is given.
    public func ink(_ role: WallEffect.Ink, state: WallState?) -> WallInk {
        switch role {
        case .working: return working
        case .thinking: return thinking
        case .needs: return needs
        case .overdue: return overdue
        case .failed: return failed
        case .finished: return finished
        case .quiet: return quiet
        case .dim: return dim
        case .tile: return state.map { ink(for: $0) } ?? text
        }
    }

    public func ink(for worker: WorkerState) -> WallInk {
        switch worker {
        case .working: return working
        case .quiet: return quiet
        case .background(let stuck): return stuck ? needs : working
        case .finished: return dim
        }
    }

    public func mood(_ mood: WallMood, hasFailure: Bool) -> WallInk {
        switch mood {
        case .calm: return text.mixed(with: dim, 0.35)
        case .busy: return working
        case .attention: return needs
        case .alarm: return hasFailure ? failed : overdue
        }
    }
}
