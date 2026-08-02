import CAdw
import Foundation

/// The desktop's look: quiet native chrome around a phosphor canvas.
///
/// The sidebar, header bars and dialogs are left to libadwaita, so they follow the system's own
/// accent and dark preference. The transcript, the file tree and the terminal are one surface with
/// its own rules — near-black, monospace throughout, hairline rules, square corners, and a single
/// green that carries every live signal. Nothing in the canvas is rounded and nothing in it is
/// translucent; that is what keeps it reading as a terminal rather than as a chat app wearing one.
///
/// Type size is not one number. Three areas scale independently — the chat list, the prose in the
/// transcript, and everything monospace — because the reason to enlarge a transcript (reading) is
/// not the reason to enlarge a sidebar (glancing), and code that rewraps is worse than code that
/// stays put.
enum MatrixTheme {
    static let phosphor = "#4ade80"
    static let phosphorDim = "#22c55e"
    static let canvas = "#0b0f0c"
    static let canvasRaised = "#11170f"
    static let rule = "#1e2b1f"
    static let text = "#d7e6d9"
    static let textDim = "#7c9481"
    static let amber = "#fbbf24"
    static let danger = "#f87171"
    static let cyan = "#67e8f9"

    private nonisolated(unsafe) static var provider: UnsafeMutablePointer<GtkCssProvider>?

    static var css: String {
        let chrome = Preferences.scale(.chrome)
        let prose = Preferences.scale(.prose)
        let mono = Preferences.scale(.mono)
        func c(_ value: Double) -> String { String(format: "%.3frem", value * chrome) }
        func p(_ value: Double) -> String { String(format: "%.3frem", value * prose) }
        func m(_ value: Double) -> String { String(format: "%.3frem", value * mono) }

        return """
        .canvas {
            background-color: \(canvas);
            color: \(text);
        }
        .transcript {
            background-color: \(canvas);
            padding: 18px 26px;
        }
        .turn-rule {
            background-color: \(rule);
            min-height: 1px;
        }
        .prompt-rule {
            background-color: \(phosphor);
            min-width: 2px;
        }
        .prompt-glyph {
            color: \(phosphor);
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
        .tool-name { color: \(cyan); font-family: monospace; font-size: \(m(0.88)); }
        .tool-detail { color: \(textDim); font-family: monospace; font-size: \(m(0.88)); }
        .glyph-done { color: \(phosphor); }
        .glyph-running { color: \(amber); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .dim { color: \(textDim); }
        .attachment { color: \(cyan); font-family: monospace; font-size: \(m(0.88)); }
        .status-line {
            color: \(phosphorDim);
            font-family: monospace;
            font-size: \(m(0.82));
            padding: 4px 26px;
            background-color: \(canvasRaised);
            border-top: 1px solid \(rule);
        }
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
        .composer-normal { border-color: \(phosphor); }
        .composer-visual { border-color: \(amber); }
        .vim-badge {
            font-family: monospace;
            font-size: \(m(0.72));
            padding: 1px 6px;
            color: \(canvas);
            background-color: \(phosphor);
        }
        .vim-badge-visual { background-color: \(amber); }
        .vim-badge-insert { background-color: \(cyan); }
        .code-block {
            background-color: #080c09;
            border-left: 2px solid \(rule);
            padding: 8px 12px;
            font-family: monospace;
            font-size: \(m(0.85));
            color: \(text);
        }
        .diff-add { color: \(phosphor); font-family: monospace; font-size: \(m(0.85)); }
        .diff-remove { color: \(danger); font-family: monospace; font-size: \(m(0.85)); }

        .pill {
            font-family: monospace;
            font-size: \(c(0.72));
            padding: 1px 6px;
            border-radius: 2px;
        }
        .pill-live { color: \(canvas); background-color: \(phosphor); }
        .pill-needs { color: \(canvas); background-color: \(amber); }
        .pill-error { color: \(canvas); background-color: \(danger); }
        .pill-saved { color: \(cyan); border: 1px solid \(cyan); }
        .pill-offline { color: \(textDim); border: 1px solid \(rule); }

        .row-focused {
            background-color: \(canvasRaised);
            box-shadow: inset 2px 0 0 \(phosphor);
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
        .unread-dot { color: \(phosphor); font-size: \(c(0.7)); }

        .tree-row { font-family: monospace; font-size: \(m(0.85)); color: \(text); }
        .tree-dir { color: \(cyan); font-family: monospace; font-size: \(m(0.85)); }
        .tree-path { color: \(textDim); font-family: monospace; font-size: \(m(0.78)); }

        .code-header {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.75));
            letter-spacing: 0.06em;
        }
        .code-copy { color: \(cyan); font-family: monospace; font-size: \(m(0.75)); padding: 0 6px; }
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
        .card-permission { border-left: 2px solid \(amber); }
        .card-question { border-left: 2px solid \(cyan); }
        .card-title { font-size: \(p(0.95)); font-weight: 600; color: \(text); }
        .answer-option {
            font-family: monospace;
            font-size: \(m(0.88));
            color: \(cyan);
            background-color: transparent;
            border: 1px solid \(rule);
            border-radius: 0;
            padding: 3px 10px;
        }
        .answer-option:hover { border-color: \(cyan); }
        .answer-selected { border-color: \(phosphor); color: \(phosphor); }

        .seam-text {
            color: \(amber);
            font-family: monospace;
            font-size: \(p(0.78));
            letter-spacing: 0.08em;
        }
        .subagent-card {
            border-left: 2px solid \(cyan);
            padding: 6px 10px;
            background-color: #0d120e;
        }
        .image-part { border: 1px solid \(rule); }

        .goal-line {
            color: \(cyan);
            font-family: monospace;
            font-size: \(p(0.8));
            padding: 2px 26px;
        }
        .banner-auth {
            color: \(canvas);
            background-color: \(amber);
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
        .pill-row button:hover { border-color: \(phosphor); color: \(text); }
        popover contents { background-color: \(canvasRaised); border: 1px solid \(rule); }

        .chip {
            font-family: monospace;
            font-size: \(m(0.78));
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvasRaised);
            border: 1px solid \(cyan);
            border-radius: 0;
            color: \(cyan);
        }
        .chip:hover { border-color: \(danger); color: \(danger); }
        .jump-pill {
            font-family: monospace;
            font-size: \(m(0.82));
            padding: 4px 14px;
            border-radius: 14px;
            color: \(canvas);
            background-color: \(phosphor);
            border: none;
        }
        .jump-pill:hover { background-color: \(phosphorDim); }
        .find-bar {
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            padding: 2px 4px;
        }
        .find-hit {
            background-color: #17240f;
            box-shadow: inset 2px 0 0 \(amber);
        }
        .usage-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .gauge-ok, .gauge-warn, .gauge-danger {
            font-family: monospace;
            font-size: \(c(0.75));
        }
        .gauge-ok { color: \(textDim); }
        .gauge-warn { color: \(amber); }
        .gauge-danger { color: \(danger); }
        .settings-group { padding: 6px 0px; }
        """
    }

    /// Loading into the same provider restyles every widget already on screen, so a size change
    /// lands live rather than at the next launch.
    static func install() {
        if provider == nil { provider = gtk_css_provider_new() }
        guard let provider else { return }
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
    }
}
