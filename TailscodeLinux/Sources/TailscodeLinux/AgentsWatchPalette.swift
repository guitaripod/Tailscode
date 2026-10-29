import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension PartyInk {
    var hex: String {
        func channel(_ value: Double) -> String {
            let byte = Int((min(1, max(0, value)) * 255).rounded())
            return (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }
        return "#" + channel(red) + channel(green) + channel(blue)
    }

    func lifted(_ amount: Double) -> PartyInk { mixed(with: .white, amount) }

    func sunk(_ amount: Double) -> PartyInk { mixed(with: .black, amount) }
}

/// The wall's colours: the current theme's own dark palette, whatever the desk is set to. A screen
/// left up on a monitor reads as a screen only when it is dark, so a light appearance borrows the
/// theme's dark variant for this one lens and nothing else.
struct WatchPalette: Equatable, Sendable {
    let ground: PartyInk
    let groundDeep: PartyInk
    let text: PartyInk
    let dim: PartyInk
    let rule: PartyInk
    let working: PartyInk
    let thinking: PartyInk
    let needs: PartyInk
    let overdue: PartyInk
    let quiet: PartyInk
    let finished: PartyInk
    let failed: PartyInk
    let source: Palette

    private init(
        source: Palette, ground: PartyInk, groundDeep: PartyInk, text: PartyInk, dim: PartyInk,
        rule: PartyInk, working: PartyInk, thinking: PartyInk, needs: PartyInk, overdue: PartyInk,
        quiet: PartyInk, finished: PartyInk, failed: PartyInk
    ) {
        self.source = source
        self.ground = ground
        self.groundDeep = groundDeep
        self.text = text
        self.dim = dim
        self.rule = rule
        self.working = working
        self.thinking = thinking
        self.needs = needs
        self.overdue = overdue
        self.quiet = quiet
        self.finished = finished
        self.failed = failed
    }

    init(source: Palette) {
        self.source = source
        let canvas = PartyInk(hex: source.canvas)
        ground = canvas.sunk(0.12)
        groundDeep = canvas.sunk(0.62)
        text = PartyInk(hex: source.text).lifted(0.3)
        dim = PartyInk(hex: source.textDim).lifted(0.12)
        rule = PartyInk(hex: source.rule)
        working = PartyInk(hex: source.accent)
        thinking = Self.violet(PartyInk(hex: source.special), info: PartyInk(hex: source.info))
        needs = PartyInk(hex: source.warn)
        failed = PartyInk(hex: source.danger)
        overdue = PartyInk(hex: source.warn).mixed(with: PartyInk(hex: source.danger), 0.62).lifted(0.08)
        quiet = PartyInk(hex: source.textDim).mixed(with: PartyInk(hex: source.info), 0.22).sunk(0.12)
        finished = PartyInk(hex: source.info)
    }

    private static let warmth = PartyInk(red: 1, green: 0.64, blue: 0.4)

    /// The same palette warmer and dimmer, for the hours when a screen in a dark room should not
    /// glare. Core's `WallPalette.night()` has the same formulas, so the three walls go warm alike.
    func night() -> WatchPalette {
        let warm = Self.warmth
        func shade(_ ink: PartyInk) -> PartyInk { ink.mixed(with: warm, 0.22).sunk(0.2) }
        func settle(_ ink: PartyInk) -> PartyInk { ink.mixed(with: warm, 0.06).sunk(0.25) }
        return WatchPalette(
            source: source, ground: settle(ground), groundDeep: settle(groundDeep), text: shade(text),
            dim: shade(dim), rule: shade(rule), working: shade(working), thinking: shade(thinking),
            needs: shade(needs), overdue: shade(overdue), quiet: shade(quiet), finished: shade(finished),
            failed: shade(failed))
    }

    /// The colour an effect's role names; `tile` is the state's own, or plain text when no state is
    /// given.
    func ink(_ role: WallEffect.Ink, state: WallState?) -> PartyInk {
        switch role {
        case .working: return working
        case .thinking: return thinking
        case .needs: return needs
        case .overdue: return overdue
        case .failed: return failed
        case .finished: return finished
        case .quiet: return quiet
        case .dim: return dim
        case .tile: return state.map { ink($0) } ?? text
        }
    }

    static func current() -> WatchPalette {
        WatchPalette(source: MatrixTheme.palette(for: Preferences.themeID, dark: true))
    }

    /// Thinking is violet on every theme: the theme's own standing mark when it is one, and a
    /// violet mixed toward its information colour when it is orange or green, which would read as
    /// an ask or as work.
    private static func violet(_ mark: PartyInk, info: PartyInk) -> PartyInk {
        let hue = Self.hue(mark)
        if hue >= 215 && hue <= 320 { return mark }
        return PartyInk(red: 0.68, green: 0.56, blue: 1).mixed(with: info, 0.12)
    }

    static func hue(_ ink: PartyInk) -> Double {
        let high = max(ink.red, ink.green, ink.blue)
        let low = min(ink.red, ink.green, ink.blue)
        let span = high - low
        guard span > 0.04 else { return -1 }
        var degrees: Double
        if high == ink.red {
            degrees = 60 * ((ink.green - ink.blue) / span).truncatingRemainder(dividingBy: 6)
        } else if high == ink.green {
            degrees = 60 * ((ink.blue - ink.red) / span + 2)
        } else {
            degrees = 60 * ((ink.red - ink.green) / span + 4)
        }
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    func ink(_ state: WallState) -> PartyInk {
        switch state {
        case .working: return working
        case .thinking: return thinking
        case .needsYou(let urgency): return urgency == .overdue ? overdue : needs
        case .retrying: return needs
        case .quiet: return quiet
        case .background(let isStuck): return isStuck ? needs : working
        case .finished(let outcome):
            switch outcome {
            case .done: return finished
            case .failed: return failed
            case .stopped, .unknown: return dim
            }
        case .away: return dim
        }
    }

    func mood(_ mood: WallMood, hasFailure: Bool) -> PartyInk {
        switch mood {
        case .calm: return text.mixed(with: dim, 0.35)
        case .busy: return working
        case .attention: return needs
        case .alarm: return hasFailure ? failed : overdue
        }
    }
}

/// The wall's own stylesheet: the chips, the header and the peek's panel in the dark palette,
/// scoped under `.agents-wall` so the Now and Hour lenses keep the desk's look.
enum WatchStyle {
    nonisolated(unsafe) private static var provider: UnsafeMutablePointer<GtkCssProvider>?
    nonisolated(unsafe) private static var installed: WatchPalette?

    static func install(_ palette: WatchPalette) {
        guard installed != palette, let display = gdk_display_get_default() else { return }
        installed = palette
        if provider == nil {
            provider = gtk_css_provider_new()
            gtk_style_context_add_provider_for_display(
                display, op(provider!), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2))
        }
        gtk_css_provider_load_from_string(provider!, css(palette))
    }

    static func css(_ palette: WatchPalette) -> String {
        let sheet = MatrixStylesheet(palette: palette.source, density: Preferences.chatDensity)
        let text = palette.text.hex
        let dim = palette.dim.hex
        let ground = palette.ground.hex
        let accent = palette.working.hex
        let rule = palette.rule.hex
        return scoped(sheet.agentsRules(), under: ".agents-wall") + """
            window.agents-wall-window, window.agents-wall-window > * { background-color: \(ground); color: \(text); }
            .agents-wall-bar { background-color: \(ground); color: \(text); box-shadow: none; border: none; }
            .agents-wall-bar button { color: \(text); background: alpha(\(text), 0.07); border: 1px solid alpha(\(text), 0.12); box-shadow: none; }
            .agents-wall-bar button:checked { background: alpha(\(accent), 0.22); border-color: alpha(\(accent), 0.7); }
            .agents-wall-bar button:hover { background: alpha(\(text), 0.14); }
            .agents-wall-bar windowcontrols button { background: transparent; border: none; }
            .agents-wall-chip { background: alpha(\(text), 0.06); border: 1px solid alpha(\(text), 0.16); border-radius: 999px; padding: 0; min-height: 0; min-width: 0; box-shadow: none; color: \(text); }
            .agents-wall-chip:hover { background: alpha(\(text), 0.14); border-color: alpha(\(accent), 0.6); }
            .agents-wall-btn { background: alpha(\(text), 0.08); border: 1px solid alpha(\(text), 0.2); border-radius: 999px; padding: 0; min-height: 0; min-width: 0; box-shadow: none; color: \(text); }
            .agents-wall-btn:hover { background: alpha(\(text), 0.16); }
            .agents-wall-btn:disabled { opacity: 0.5; }
            .agents-wall-btn:focus-visible { outline: 2px solid \(accent); outline-offset: 2px; }
            .agents-wall-sheet { background-color: \(ground); border: 1px solid alpha(\(text), 0.18); border-radius: 18px; color: \(text); }
            .agents-wall-sheet entry { background: alpha(\(text), 0.07); color: \(text); border: 1px solid alpha(\(text), 0.2); box-shadow: none; }
            .agents-wall-sheet button { color: \(text); background: alpha(\(text), 0.08); border: 1px solid alpha(\(text), 0.2); box-shadow: none; }
            .agents-wall-sheet button.suggested-action { background: alpha(\(accent), 0.28); border-color: alpha(\(accent), 0.7); }
            .agents-wall-sheet scrolledwindow, .agents-wall-sheet viewport { background: transparent; }
            .agents-wall-sheet label { color: \(text); }
            .agents-wall-sheet .agents-meta, .agents-wall-sheet .agents-peek-section, .agents-wall-sheet .agents-elapsed, .agents-wall-sheet .agents-note { color: \(dim); }
            tile-canvas.agents-wall, tile-canvas.agents-wall-tile { background-color: transparent; }
            .agents-wall-scrim { background-color: black; }
            .agents-wall-backdrop { background-color: alpha(black, 0.58); }
            .agents-wall-hairline { background-color: \(rule); }
            """
    }

    /// Prefixes every selector of a stylesheet with a scope, so the same rules can be written a
    /// second time for a subtree that wears another palette.
    static func scoped(_ css: String, under scope: String) -> String {
        var out = ""
        var selectors = ""
        var depth = 0
        for character in css {
            if character == "{" {
                depth += 1
                if depth == 1 {
                    let list = selectors.split(separator: ",").map {
                        scope + " " + $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    out += list.joined(separator: ", ") + " {"
                    selectors = ""
                    continue
                }
            } else if character == "}" {
                depth -= 1
            }
            if depth == 0 && character != "}" {
                selectors.append(character)
            } else {
                out.append(character)
            }
        }
        return out
    }
}
