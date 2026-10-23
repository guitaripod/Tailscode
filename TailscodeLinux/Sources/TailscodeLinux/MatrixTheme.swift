import CAdw
import Foundation
import TailscodeCore

/// The desktop's look: quiet native chrome around an opaque, terminal-grade canvas.
///
/// The sidebar, header bars and dialogs are left to libadwaita, so they follow the system's own
/// accent and dark preference. The transcript, the file tree and the terminal are one surface with
/// its own rules — monospace throughout, hairline rules, square corners, and a small set of signal
/// colors that carry every live fact. Which colors is the chosen theme's business — the settings
/// pick one identity from `AppTheme.all`, and it follows the desktop between its own two
/// appearances rather than being two unrelated choices.
///
/// Type size is not one number. Three areas scale independently — the chat list, the prose in the
/// transcript, and everything monospace — because the reason to enlarge a transcript (reading) is
/// not the reason to enlarge a sidebar (glancing), and code that rewraps is worse than code that
/// stays put.
enum MatrixTheme {
    /// Read from row-building tasks off the main context, written only on it — a torn read here
    /// costs one wrongly-tinted frame, never a crash.
    nonisolated(unsafe) private(set) static var palette: Palette = AppTheme.fallback.dark.corrected()

    private nonisolated(unsafe) static var provider: UnsafeMutablePointer<GtkCssProvider>?

    /// Re-reads the chosen theme and the desktop's dark preference. Only the dark flag needs a
    /// display — the headless selftest still picks up a pinned theme, in its dark appearance.
    static func refreshPalette() {
        var dark = true
        if gdk_display_get_default() != nil, let manager = adw_style_manager_get_default() {
            dark = adw_style_manager_get_dark(manager) != 0
        }
        palette = palette(for: Preferences.themeID, dark: dark)
    }

    /// The choice itself, with no display and no stored preference in it, so the one thing that
    /// turns a saved id into the colours on screen can be asserted headlessly.
    static func palette(for themeID: String?, dark: Bool) -> Palette {
        AppTheme.named(themeID).palette(dark: dark).corrected()
    }

    /// Oh My Pi's mint, published the way the shared brand slots are: the authored hue held to
    /// the readable contrast floor against the canvas it will sit on. Authored here rather than
    /// in the shared `Palette` because the other brands predate the third agent; the value is the
    /// same on every desk.
    static func brandOmp(in palette: Palette) -> String {
        Contrast.adjusted("#2ab6a3", on: palette.canvas, ratio: Contrast.readable) ?? "#2ab6a3"
    }

    static var css: String { css(for: palette) }

    /// The stylesheet for a palette at a chat density. The density is a table of numbers in Core
    /// (`ChatMetrics`); what is interpolated here is the transcript's own padding, the height of a
    /// flat line, and the code block's padding — the gaps between rows are margins the pane writes
    /// from the same table, since they depend on which rows are neighbours.
    static func css(for palette: Palette, density: ChatDensity = Preferences.chatDensity) -> String {
        MatrixStylesheet(palette: palette, density: density).sheet
    }

    /// The model chip classes, generated from the shared catalog so a family's hue on this desk is
    /// the same fact the phone and the Mac draw: text colour on a wash of itself for the list
    /// chips, and the same hue on the composer's bordered pills, which need the heavier selector
    /// to outrank `.pill-row button`.
    static func chatInset(_ density: ChatDensity = Preferences.chatDensity) -> Int {
        density == .compact ? 18 : 26
    }

    /// Pixels in one `em` of the chip's own type at normal size, which is how a 24-pixel chip
    /// becomes a height that grows with the type slider rather than a number that ignores it. The
    /// border is outside the content height the stylesheet states, so it is taken off first.
    static let chipEmPixels = 11.5

    /// The dim register as ink that clears AA against the lightest fill a chip or a row wears, so
    /// a waiting row or a placeholder is read from a colour that was computed rather than from an
    /// opacity that was hoped for. The palette's own dim ink is held to the lower, graphical bar.
    static func quietInk(for palette: Palette) -> String {
        let fill =
            Contrast.blend(
                palette.canvas, palette.text, ChatChrome.fill(.fact).inkShare) ?? palette.canvas
        let against = [palette.canvas, palette.canvasRaised, fill]
        var ink = palette.textDim
        for background in against {
            ink = Contrast.adjusted(ink, on: background, ratio: Contrast.readable) ?? ink
        }
        return ink
    }

    static func modelTintCSS(for palette: Palette) -> String {
        var lines: [String] = []
        var pairs: [(cls: String, hex: String)] = ModelTint.Family.allCases.map {
            (ModelTint.cssClass($0), ModelTint.hex($0, in: palette))
        }
        for bucket in 0..<12 {
            pairs.append(("model-hue-\(bucket)", ModelTint.bucketHex(bucket, in: palette)))
        }
        pairs.append(("model-plain", palette.textDim))
        for tier in ModelTint.effortTiers {
            if let hex = ModelTint.effortHex(tier, in: palette) {
                pairs.append(("effort-\(tier)", hex))
            }
        }
        for pair in pairs {
            lines.append(".dial-dot.\(pair.cls), .dial-row-dot.\(pair.cls) { color: \(pair.hex); }")
        }
        return lines.joined(separator: "\n        ")
    }

    /// The dial's heat, one class per tier from the shared catalog: the level's word, the lit
    /// bars, a rung's title and the wash behind the rung it lights. The rainbow bars each take
    /// one stop of the shared rainbow so the power's meter is the aura in five pieces.
    static func dialTintCSS(for palette: Palette) -> String {
        var lines: [String] = []
        for tier in ModelTint.effortTiers {
            guard let hex = ModelTint.effortHex(tier, in: palette) else { continue }
            lines.append(
                ".dial-bar-lit.effort-\(tier) { background-color: \(hex); "
                    + "box-shadow: 0 0 \(tierGlow(tier))px alpha(\(hex), 0.7); }")
            lines.append(
                ".dial-bar-lit.dial-bar-ember.effort-\(tier) { background-color: transparent; "
                    + "border: 1px solid alpha(\(hex), 0.9); box-shadow: none; }")
            lines.append(".dial-rung.effort-\(tier) .dial-rung-title { color: \(hex); }")
            lines.append(
                ".dial-pop button.dial-rung.effort-\(tier).dial-rung-current { "
                    + "background-color: alpha(\(hex), 0.14); border-color: alpha(\(hex), 0.55); }")
        }
        for (index, hex) in ModelTint.rainbow(letters: EffortMeter.bars, onCanvas: palette.canvas)
            .enumerated()
        {
            lines.append(
                ".dial-bar-rainbow-\(index) { background-color: \(hex); "
                    + "box-shadow: 0 0 6px alpha(\(hex), 0.85); }")
        }
        return lines.joined(separator: "\n        ")
    }

    /// How far a tier's bars spill their light: the cool tiers sit flat, the hot ones glow, and
    /// the glow grows with the heat so the levels are told apart at a glance rather than by
    /// reading. The word itself stays sharp — a glow under type is a smear, not a signal.
    private static func tierGlow(_ tier: String) -> Int {
        switch tier {
        case "high": return 2
        case "xhigh": return 4
        case "max": return 6
        default: return 0
        }
    }

    /// The shared rainbow as a low-alpha wash a word stays readable on: the same stops the aura
    /// travels, laid left to right under the one effort that is a power rather than a level.
    static func rainbowWash(_ alpha: Double) -> String {
        let stops = Ultracode.rainbowStops
            .map { "alpha(\(Contrast.hex(red: $0.red, green: $0.green, blue: $0.blue)), \(alpha))" }
            .joined(separator: ", ")
        return "linear-gradient(to right, \(stops))"
    }

    /// Loading into the same provider restyles every widget already on screen, so a size or
    /// palette change lands live rather than at the next launch.
    static func install() {
        refreshPalette()
        if provider == nil { provider = gtk_css_provider_new() }
        guard let provider else { return }
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
    }

}
