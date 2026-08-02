import CAdw
import Foundation

/// The colors of one appearance, named by what they mean rather than what they are: the transcript
/// canvas and its raised surfaces, the two text registers, and the handful of signal colors every
/// glyph, pill and border draws from. Two palettes exist — Rosé Pine when the desktop is dark,
/// Solarized Light when it is light — and everything else styles itself from whichever is current.
struct Palette: Equatable {
    let name: String
    let isDark: Bool
    let canvas: String
    let canvasRaised: String
    let rule: String
    let text: String
    let textDim: String
    /// Live, positive, additions: the running glyph, the prompt rule, `+` in a diff.
    let accent: String
    let accentDim: String
    /// Attention that is not failure: approvals, compaction seams, visual mode.
    let warn: String
    let danger: String
    /// Identity of tools and files: tool names, chips, the file tree's directories.
    let info: String
    /// The goal and other standing marks.
    let special: String
    let codeBg: String
    let subagentBg: String
    let findHit: String
    /// Text set on an accent-filled surface — the vim badge, the jump pill.
    let onAccent: String
    /// The shell pane wears the theme too: sixteen ANSI colors plus its own fg/bg, because a
    /// terminal that stays black inside a Solarized window is a hole in the design.
    let terminalFg: String
    let terminalBg: String
    let ansi: [String]

    static let rosePine = Palette(
        name: "rosepine", isDark: true,
        canvas: "#191724", canvasRaised: "#1f1d2e", rule: "#26233a",
        text: "#e0def4", textDim: "#908caa",
        accent: "#9ccfd8", accentDim: "#31748f",
        warn: "#f6c177", danger: "#eb6f92",
        info: "#c4a7e7", special: "#ebbcba",
        codeBg: "#16141f", subagentBg: "#1f1d2e", findHit: "#403d52",
        onAccent: "#191724",
        terminalFg: "#e0def4", terminalBg: "#191724",
        ansi: [
            "#26233a", "#eb6f92", "#31748f", "#f6c177",
            "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
            "#6e6a86", "#eb6f92", "#31748f", "#f6c177",
            "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
        ])

    static let solarizedLight = Palette(
        name: "solarized", isDark: false,
        canvas: "#fdf6e3", canvasRaised: "#eee8d5", rule: "#ddd6c1",
        text: "#586e75", textDim: "#93a1a1",
        accent: "#859900", accentDim: "#667a00",
        warn: "#b58900", danger: "#dc322f",
        info: "#2aa198", special: "#6c71c4",
        codeBg: "#f5eeda", subagentBg: "#f6f0dd", findHit: "#efe3b3",
        onAccent: "#fdf6e3",
        terminalFg: "#657b83", terminalBg: "#fdf6e3",
        ansi: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ])
}

/// The desktop's look: quiet native chrome around an opaque, terminal-grade canvas.
///
/// The sidebar, header bars and dialogs are left to libadwaita, so they follow the system's own
/// accent and dark preference. The transcript, the file tree and the terminal are one surface with
/// its own rules — monospace throughout, hairline rules, square corners, and a small set of signal
/// colors that carry every live fact. Which colors depends on the desktop: Rosé Pine when it is
/// dark, Solarized Light when it is light, following the system unless the settings pin one.
///
/// Type size is not one number. Three areas scale independently — the chat list, the prose in the
/// transcript, and everything monospace — because the reason to enlarge a transcript (reading) is
/// not the reason to enlarge a sidebar (glancing), and code that rewraps is worse than code that
/// stays put.
enum MatrixTheme {
    /// Read from row-building tasks off the main context, written only on it — a torn read here
    /// costs one wrongly-tinted frame, never a crash.
    nonisolated(unsafe) private(set) static var palette: Palette = .rosePine

    private nonisolated(unsafe) static var provider: UnsafeMutablePointer<GtkCssProvider>?

    /// Re-reads the desktop's dark preference. Only meaningful where a display exists — the
    /// headless selftest keeps the default palette.
    static func refreshPalette() {
        guard gdk_display_get_default() != nil, let manager = adw_style_manager_get_default()
        else { return }
        palette = adw_style_manager_get_dark(manager) != 0 ? .rosePine : .solarizedLight
    }

    static var css: String { css(for: palette) }

    static func css(for palette: Palette) -> String {
        let chrome = Preferences.scale(.chrome)
        let prose = Preferences.scale(.prose)
        let mono = Preferences.scale(.mono)
        func c(_ value: Double) -> String { String(format: "%.3frem", value * chrome) }
        func p(_ value: Double) -> String { String(format: "%.3frem", value * prose) }
        func m(_ value: Double) -> String { String(format: "%.3frem", value * mono) }
        let canvas = palette.canvas
        let canvasRaised = palette.canvasRaised
        let rule = palette.rule
        let text = palette.text
        let textDim = palette.textDim
        let accent = palette.accent
        let accentDim = palette.accentDim
        let warn = palette.warn
        let danger = palette.danger
        let info = palette.info
        let special = palette.special

        return """
        .canvas {
            background-color: \(canvas);
            color: \(text);
        }
        .transcript {
            background-color: \(canvas);
            padding: \(Preferences.denseRows ? "8px 18px" : "18px 26px");
        }
        .turn-rule {
            background-color: \(rule);
            min-height: 1px;
        }
        .prompt-rule {
            background-color: \(accent);
            min-width: 2px;
        }
        .prompt-glyph {
            color: \(accent);
            font-family: monospace;
            font-weight: bold;
        }
        .prompt-text {
            color: \(text);
            font-family: monospace;
            font-size: \(p(0.95));
        }
        .agent-text {
            color: \(text);
            font-size: \(p(0.95));
        }
        .tool-line, .mono {
            font-family: monospace;
            font-size: \(m(0.88));
        }
        .tool-name { color: \(info); font-family: monospace; font-size: \(m(0.88)); }
        .tool-detail { color: \(textDim); font-family: monospace; font-size: \(m(0.88)); }
        .glyph-done { color: \(accent); }
        .glyph-running { color: \(warn); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .dim { color: \(textDim); }
        .attachment { color: \(info); font-family: monospace; font-size: \(m(0.88)); }
        .status-line {
            color: \(accentDim);
            font-family: monospace;
            font-size: \(m(0.82));
            padding: 4px 26px;
            background-color: \(canvasRaised);
            border-top: 1px solid \(rule);
        }
        .status-band {
            background-color: \(canvasRaised);
            border-top: 1px solid \(rule);
            padding: 3px 22px;
        }
        .seg, .seg > button, .seg button {
            font-family: monospace;
            font-size: \(m(0.78));
            min-height: 0;
            padding: 1px 6px;
            border: none;
            border-radius: 3px;
            background: none;
            background-color: transparent;
            box-shadow: none;
            outline: none;
            text-shadow: none;
        }
        .seg:hover, .seg button:hover { background-color: \(canvas); }
        .seg arrow { -gtk-icon-size: 10px; opacity: 0.5; }
        .seg-idle { color: \(textDim); }
        .seg-dim { color: \(textDim); }
        .seg-live { color: \(accent); }
        .seg-warn { color: \(warn); }
        .seg-error { color: \(danger); }
        .seg-agents { color: \(info); }
        .seg-goal { color: \(special); }
        .seg-notice { color: \(accentDim); }
        .composer {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 0;
        }
        .composer text, .composer textview, .composer textview text {
            background-color: transparent;
            color: \(text);
            font-family: monospace;
            font-size: \(m(0.92));
        }
        .composer-normal { border-color: \(accent); }
        .composer-visual { border-color: \(warn); }
        .vim-badge {
            font-family: monospace;
            font-size: \(m(0.72));
            padding: 1px 6px;
            color: \(palette.onAccent);
            background-color: \(accent);
        }
        .vim-badge-visual { background-color: \(warn); }
        .vim-badge-insert { background-color: \(info); }
        .code-block {
            background-color: \(palette.codeBg);
            border-left: 2px solid \(rule);
            padding: 8px 12px;
            font-family: monospace;
            font-size: \(m(0.85));
            color: \(text);
        }
        .diff-add { color: \(accent); font-family: monospace; font-size: \(m(0.85)); }
        .diff-remove { color: \(danger); font-family: monospace; font-size: \(m(0.85)); }

        .pill {
            font-family: monospace;
            font-size: \(c(0.72));
            padding: 1px 6px;
            border-radius: 2px;
        }
        .pill-live { color: \(palette.onAccent); background-color: \(accent); }
        .pill-needs { color: \(palette.onAccent); background-color: \(warn); }
        .pill-error { color: \(palette.onAccent); background-color: \(danger); }
        .pill-saved { color: \(info); border: 1px solid \(info); }
        .pill-offline { color: \(textDim); border: 1px solid \(rule); }

        .row-focused {
            background-color: \(canvasRaised);
            box-shadow: inset 2px 0 0 \(accent);
        }
        .row-title { font-size: \(c(0.92)); }
        .row-title-unread { font-size: \(c(0.92)); font-weight: 700; }
        .row-detail { font-size: \(c(0.78)); opacity: 0.65; font-family: monospace; }
        .section-header {
            font-size: \(c(0.72));
            font-weight: 700;
            letter-spacing: 0.08em;
            opacity: 0.5;
            padding: 10px 8px 2px 8px;
        }
        .unread-dot { color: \(accent); font-size: \(c(0.7)); }

        .tree-row { font-family: monospace; font-size: \(m(0.85)); color: \(text); }
        .tree-dir { color: \(info); font-family: monospace; font-size: \(m(0.85)); }
        .tree-path { color: \(textDim); font-family: monospace; font-size: \(m(0.78)); }

        .code-header {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.75));
            letter-spacing: 0.06em;
        }
        .code-copy { color: \(info); font-family: monospace; font-size: \(m(0.75)); padding: 0 6px; }
        .code-body { font-family: monospace; font-size: \(m(0.85)); color: \(text); }
        .tool-output {
            font-family: monospace;
            font-size: \(m(0.82));
            color: \(textDim);
        }
        .reasoning-body {
            color: \(textDim);
            font-size: \(p(0.9));
            font-style: italic;
        }
        .disclosure { padding: 0; min-height: 0; }
        .disclosure:hover { background-color: \(canvasRaised); }

        .card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            padding: 12px 16px;
        }
        .card-permission { border-left: 2px solid \(warn); }
        .card-question { border-left: 2px solid \(info); }
        .card-title { font-size: \(p(0.95)); font-weight: 600; color: \(text); }
        .answer-option {
            font-family: monospace;
            font-size: \(m(0.88));
            color: \(info);
            background-color: transparent;
            border: 1px solid \(rule);
            border-radius: 0;
            padding: 3px 10px;
        }
        .answer-option:hover { border-color: \(info); }
        .answer-selected { border-color: \(accent); color: \(accent); }

        .seam-text {
            color: \(warn);
            font-family: monospace;
            font-size: \(p(0.78));
            letter-spacing: 0.08em;
        }
        .subagent-card {
            border-left: 2px solid \(info);
            padding: 6px 10px;
            background-color: \(palette.subagentBg);
        }
        .image-part { border: 1px solid \(rule); }

        .goal-line {
            color: \(special);
            font-family: monospace;
            font-size: \(p(0.8));
            padding: 2px 26px;
        }
        .banner-auth {
            color: \(palette.onAccent);
            background-color: \(warn);
            font-family: monospace;
            font-size: \(m(0.85));
            padding: 4px 12px;
        }
        .pill-row { padding: 0px 22px 10px 22px; }
        .pill-row button {
            font-family: monospace;
            font-size: \(m(0.78));
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 0;
            color: \(textDim);
        }
        .pill-row button:hover { border-color: \(accent); color: \(text); }
        popover contents { background-color: \(canvasRaised); border: 1px solid \(rule); }

        .chip {
            font-family: monospace;
            font-size: \(m(0.78));
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvasRaised);
            border: 1px solid \(info);
            border-radius: 0;
            color: \(info);
        }
        .chip:hover { border-color: \(danger); color: \(danger); }
        .jump-pill {
            font-family: monospace;
            font-size: \(m(0.82));
            padding: 4px 14px;
            border-radius: 14px;
            color: \(palette.onAccent);
            background-color: \(accent);
            border: none;
        }
        .jump-pill:hover { background-color: \(accentDim); }
        .find-bar {
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            padding: 2px 4px;
        }
        .find-hit {
            background-color: \(palette.findHit);
            box-shadow: inset 2px 0 0 \(warn);
        }
        .usage-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .gauge-ok, .gauge-warn, .gauge-danger {
            font-family: monospace;
            font-size: \(c(0.75));
        }
        .gauge-ok { color: \(textDim); }
        .gauge-warn { color: \(warn); }
        .gauge-danger { color: \(danger); }
        .gauge-reset {
            font-family: monospace;
            font-size: \(c(0.68));
            color: \(textDim);
            opacity: 0.8;
            margin-bottom: 2px;
        }
        .gauge-track {
            background-color: alpha(currentColor, 0.12);
            border-radius: 3px;
        }
        .gauge-fill-ok { background-color: \(accentDim); border-radius: 3px; }
        .gauge-fill-warn { background-color: \(warn); border-radius: 3px; }
        .gauge-fill-danger { background-color: \(danger); border-radius: 3px; }
        .settings-group { padding: 6px 0px; }
        """
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
