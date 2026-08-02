import CAdw
import Foundation

/// The desktop's look: quiet native chrome around a phosphor canvas.
///
/// The sidebar, header bars and dialogs are left to libadwaita, so they follow the system's own
/// accent and dark preference. The transcript, the file tree and the terminal are one surface with
/// its own rules — near-black, monospace throughout, hairline rules, square corners, and a single
/// green that carries every live signal. Nothing in the canvas is rounded and nothing in it is
/// translucent; that is what keeps it reading as a terminal rather than as a chat app wearing one.
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

    static var css: String {
        """
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
            font-size: 0.95rem;
        }
        .agent-text {
            color: \(text);
            font-size: 0.95rem;
        }
        .tool-line, .mono {
            font-family: monospace;
            font-size: 0.88rem;
        }
        .tool-name { color: \(cyan); font-family: monospace; font-size: 0.88rem; }
        .tool-detail { color: \(textDim); font-family: monospace; font-size: 0.88rem; }
        .glyph-done { color: \(phosphor); }
        .glyph-running { color: \(amber); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .dim { color: \(textDim); }
        .attachment { color: \(cyan); font-family: monospace; font-size: 0.88rem; }
        .status-line {
            color: \(phosphorDim);
            font-family: monospace;
            font-size: 0.82rem;
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
        }
        .code-block {
            background-color: #080c09;
            border-left: 2px solid \(rule);
            padding: 8px 12px;
            font-family: monospace;
            font-size: 0.85rem;
            color: \(text);
        }
        .diff-add { color: \(phosphor); font-family: monospace; font-size: 0.85rem; }
        .diff-remove { color: \(danger); font-family: monospace; font-size: 0.85rem; }

        .pill {
            font-family: monospace;
            font-size: 0.72rem;
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
        .row-title { font-size: 0.92rem; }
        .row-title-unread { font-size: 0.92rem; font-weight: 700; }
        .row-detail { font-size: 0.78rem; opacity: 0.65; font-family: monospace; }
        .section-header {
            font-size: 0.72rem;
            font-weight: 700;
            letter-spacing: 0.08em;
            opacity: 0.5;
            padding: 10px 8px 2px 8px;
        }
        .unread-dot { color: \(phosphor); font-size: 0.7rem; }

        .tree-row { font-family: monospace; font-size: 0.85rem; color: \(text); }
        .tree-dir { color: \(cyan); font-family: monospace; font-size: 0.85rem; }
        .tree-path { color: \(textDim); font-family: monospace; font-size: 0.78rem; }

        .code-header {
            color: \(textDim);
            font-family: monospace;
            font-size: 0.75rem;
            letter-spacing: 0.06em;
        }
        .code-copy { color: \(cyan); font-family: monospace; font-size: 0.75rem; padding: 0 6px; }
        .code-body { font-family: monospace; font-size: 0.85rem; color: \(text); }
        .tool-output {
            font-family: monospace;
            font-size: 0.82rem;
            color: \(textDim);
        }
        .reasoning-body {
            color: \(textDim);
            font-size: 0.9rem;
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
        .card-title { font-size: 0.95rem; font-weight: 600; color: \(text); }
        .answer-option {
            font-family: monospace;
            font-size: 0.88rem;
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
            font-size: 0.78rem;
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
            font-size: 0.8rem;
            padding: 2px 26px;
        }
        .banner-auth {
            color: \(canvas);
            background-color: \(amber);
            font-family: monospace;
            font-size: 0.85rem;
            padding: 4px 12px;
        }
        .pill-row { padding: 0px 22px 10px 22px; }
        .pill-row button {
            font-family: monospace;
            font-size: 0.78rem;
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
            font-size: 0.78rem;
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
            font-size: 0.82rem;
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
            font-size: 0.75rem;
        }
        .gauge-ok { color: \(textDim); }
        .gauge-warn { color: \(amber); }
        .gauge-danger { color: \(danger); }
        """
    }

    static func install() {
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider!), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
    }
}
