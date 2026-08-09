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
        :root {
            --accent-color: \(accent);
            --accent-bg-color: \(accent);
            --accent-fg-color: \(palette.onAccent);
            --window-bg-color: \(canvas);
            --window-fg-color: \(text);
            --view-bg-color: \(canvas);
            --view-fg-color: \(text);
            --headerbar-bg-color: \(canvasRaised);
            --headerbar-fg-color: \(text);
            --headerbar-border-color: \(rule);
            --headerbar-backdrop-color: \(canvas);
            --headerbar-shade-color: \(rule);
            --headerbar-darker-shade-color: \(rule);
            --sidebar-bg-color: \(canvasRaised);
            --sidebar-fg-color: \(text);
            --sidebar-backdrop-color: \(canvas);
            --sidebar-border-color: \(rule);
            --sidebar-shade-color: \(rule);
            --secondary-sidebar-bg-color: \(canvasRaised);
            --secondary-sidebar-fg-color: \(text);
            --secondary-sidebar-backdrop-color: \(canvas);
            --secondary-sidebar-border-color: \(rule);
            --card-bg-color: \(canvasRaised);
            --card-fg-color: \(text);
            --card-shade-color: \(rule);
            --dialog-bg-color: \(canvas);
            --dialog-fg-color: \(text);
            --popover-bg-color: \(canvasRaised);
            --popover-fg-color: \(text);
            --popover-shade-color: \(rule);
            --shade-color: alpha(\(rule), 0.6);
            --destructive-color: \(danger);
            --destructive-bg-color: \(danger);
            --destructive-fg-color: \(palette.onAccent);
            --warning-color: \(warn);
            --warning-bg-color: \(warn);
            --warning-fg-color: \(palette.onAccent);
            --error-color: \(danger);
            --error-bg-color: \(danger);
            --error-fg-color: \(palette.onAccent);
            --success-color: \(accent);
            --success-bg-color: \(accent);
            --success-fg-color: \(palette.onAccent);
        }
        headerbar {
            box-shadow: none;
            border-bottom: 1px solid \(rule);
            min-height: 40px;
        }
        headerbar button.flat { color: \(textDim); }
        headerbar button.flat:hover { color: \(text); background-color: alpha(\(accent), 0.12); }
        paned > separator { background-color: \(rule); }
        .sidebar-pane { background-color: \(canvasRaised); }
        .sidebar-pane entry {
            background-color: \(canvas);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 6px;
            box-shadow: none;
            font-size: \(c(0.85));
            min-height: 26px;
        }
        .sidebar-pane entry:focus-within { border-color: \(accent); }
        .sidebar-pane entry image { color: \(textDim); }
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
        .md-table { padding: 2px 0; }
        .md-table-header { color: \(text); font-size: \(p(0.92)); }
        .md-table-cell { color: \(text); font-size: \(p(0.92)); }
        .tool-line, .mono {
            font-family: monospace;
            font-size: \(m(0.88));
        }
        .tool-name { color: \(info); font-family: monospace; font-size: \(m(0.88)); }
        .tool-detail { color: \(textDim); font-family: monospace; font-size: \(m(0.88)); }
        .glyph-done { color: alpha(\(accent), 0.72); }
        .glyph-running { color: \(accent); }
        .glyph-needs { color: \(warn); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .fact-good .subtitle { color: alpha(\(accent), 0.85); opacity: 1; }
        .fact-warn .subtitle { color: \(warn); opacity: 1; }
        .fact-bad .subtitle { color: \(danger); opacity: 1; }
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
        .seg-offline { color: \(warn); }
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
        .composer-visual { border-color: \(info); }
        .vim-badge {
            font-family: monospace;
            font-size: \(m(0.72));
            padding: 1px 6px;
            color: \(palette.onAccent);
            background-color: \(accent);
        }
        .vim-badge-visual { background-color: \(info); }
        .vim-badge-insert { background-color: \(accentDim); }
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
        .diff-line { font-family: monospace; font-size: \(m(0.85)); }
        .diff-wash-add { background-color: \(SyntaxPalette.diffLineBackground(.added, in: palette) ?? palette.codeBg); }
        .diff-wash-remove { background-color: \(SyntaxPalette.diffLineBackground(.removed, in: palette) ?? palette.codeBg); }

        .pill {
            font-family: monospace;
            font-size: \(c(0.72));
            padding: 1px 6px;
            border-radius: 2px;
        }
        .pill-live { color: \(palette.onAccent); background-color: \(accent); }
        .pill-needs { color: \(palette.onAccent); background-color: \(warn); font-weight: 700; }
        .pill-error { color: \(palette.onAccent); background-color: \(danger); }
        .pill-saved { color: \(special); border: 1px solid alpha(\(special), 0.7); }
        .pill-pinned { color: \(accent); border: 1px solid alpha(\(accent), 0.7); }
        .pill-offline { color: \(textDim); border: 1px solid alpha(\(textDim), 0.5); }
        \(modelTintCSS(for: palette))

        .session-row {
            padding: 0;
            border: none;
            border-radius: 6px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .session-row:hover { background-color: alpha(\(accent), 0.08); }
        .session-row:active { background-color: alpha(\(accent), 0.16); }
        .row-focused, .row-focused:hover, .row-focused:active {
            background-color: alpha(\(accent), 0.14);
            box-shadow: inset 2px 0 0 \(accent);
        }
        .row-focused .row-title, .row-focused .row-title-unread { color: \(text); }
        .row-focused .row-detail { opacity: 0.85; }
        .row-marked, .row-marked:hover, .row-marked:active {
            background-color: alpha(\(accent), 0.20);
        }
        .row-mark {
            padding: 0 2px;
            min-width: 18px;
            min-height: 18px;
            border: none;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            opacity: 0.18;
        }
        .session-row-holder:hover .row-mark { opacity: 0.75; }
        .row-mark-on, .session-row-holder:hover .row-mark-on { opacity: 1; }
        .row-mark-glyph { font-size: \(c(0.82)); }
        .row-mark-on .row-mark-glyph { color: \(accent); }
        .selection-bar {
            background-color: alpha(\(accent), 0.10);
            border: 1px solid alpha(\(accent), 0.45);
            border-radius: 6px;
        }
        .selection-count {
            font-family: monospace;
            font-size: \(m(0.82));
            font-weight: 700;
            color: \(accent);
        }
        .selection-verb {
            font-size: \(c(0.78));
            padding: 2px 6px;
            border: 1px solid alpha(\(text), 0.20);
            border-radius: 4px;
        }
        .selection-verb:hover { border-color: \(accent); }
        .selection-split-header {
            font-size: \(c(0.72));
            font-weight: 700;
            letter-spacing: 0.08em;
            opacity: 0.5;
        }
        .row-title { font-size: \(c(0.92)); color: \(text); }
        .row-title-unread { font-size: \(c(0.92)); font-weight: 700; color: \(text); }
        .row-detail { font-size: \(c(0.78)); opacity: 0.55; font-family: monospace; }
        .row-model { font-size: \(c(0.78)); font-family: monospace; }
        .row-project { font-size: \(c(0.78)); opacity: 0.9; color: \(text); font-family: monospace; }
        .row-age {
            font-size: \(c(0.75));
            opacity: 0.45;
            color: \(text);
            font-family: monospace;
            font-feature-settings: "tnum";
        }
        .row-focused .row-project, .row-focused .row-age { opacity: 1; }
        .row-note {
            color: \(accent);
            font-size: \(c(0.72));
            opacity: 0.55;
            font-family: monospace;
        }
        .section-header {
            font-size: \(c(0.72));
            font-weight: 700;
            letter-spacing: 0.08em;
            opacity: 0.5;
            padding: 10px 8px 2px 8px;
        }
        .unread-dot { color: \(accent); font-size: \(c(0.7)); }

        .model-summary {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.82));
            padding: 0 2px;
        }
        .model-search {
            background-color: \(canvas);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 4px;
        }
        .model-search:focus-within { border-color: \(accent); }
        .model-search text { color: \(text); font-family: monospace; }
        .model-row {
            padding: 0;
            border: none;
            border-radius: 5px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .model-row:hover { background-color: alpha(\(accent), 0.08); }
        .model-row:active { background-color: alpha(\(accent), 0.16); }
        .model-row-nested { margin-left: 26px; }
        .model-check { color: \(accent); font-family: monospace; font-size: \(c(0.85)); }
        .model-chevron {
            padding: 0 6px;
            min-height: 0;
            border: none;
            border-radius: 4px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
        }
        .model-chevron:hover { background-color: alpha(\(accent), 0.16); }
        .model-chevron-glyph { color: \(textDim); font-size: \(c(0.8)); }
        .model-section-count {
            color: \(textDim);
            font-family: monospace;
            font-size: \(c(0.7));
            opacity: 0.7;
            padding: 10px 8px 2px 8px;
        }
        .model-fact {
            font-family: monospace;
            font-size: \(c(0.66));
            letter-spacing: 0.04em;
            color: \(textDim);
            border: 1px solid alpha(\(textDim), 0.35);
            border-radius: 2px;
            padding: 0px 4px;
        }
        .model-fact-local { color: \(accent); border-color: alpha(\(accent), 0.6); }
        .model-fact-providers { color: \(info); border-color: alpha(\(info), 0.6); }
        .model-fact-server {
            color: \(warn);
            border-color: alpha(\(warn), 0.6);
            background: alpha(\(warn), 0.10);
        }
        .chooser-hint {
            color: \(textDim);
            font-family: monospace;
            font-size: \(c(0.72));
            opacity: 0.75;
            padding: 2px;
        }

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
        .disclosure-chevron {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.78));
        }
        .disclosure:hover .disclosure-chevron { color: \(accent); }

        .card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            padding: 12px 16px;
        }
        .card-permission { border-left: 2px solid \(warn); }
        .card-question { border-left: 2px solid \(warn); }
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

        .command-line:hover { background-color: alpha(\(info), 0.10); border-radius: 4px; }
        .completion-selected { background-color: alpha(\(accent), 0.16); border-radius: 6px; }
        toast {
            background-color: \(canvasRaised);
            color: \(text);
            border: 1px solid \(rule);
        }
        .agent-live {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(0.78));
        }
        .interruption {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.8));
            font-style: italic;
        }
        .seam-text {
            color: \(special);
            font-family: monospace;
            font-size: \(p(0.78));
            letter-spacing: 0.08em;
        }
        .seam-read, .seam-read:hover {
            font-family: monospace;
            font-size: \(m(0.75));
            min-height: 0;
            padding: 1px 8px;
            color: \(info);
            background-color: transparent;
            border: 1px solid \(rule);
            border-radius: 3px;
            box-shadow: none;
        }
        .seam-read:hover { border-color: \(info); background-color: alpha(\(info), 0.08); }
        .card-compaction { border-left: 2px solid \(special); }
        .card-compaction-failed { border-left: 2px solid \(danger); }
        .seam-footnote { color: \(textDim); font-size: \(p(0.82)); }
        .seam-bar trough {
            min-height: 4px;
            background-color: \(rule);
            border: none;
            border-radius: 2px;
        }
        .seam-bar progress {
            min-height: 4px;
            background-color: \(special);
            border: none;
            border-radius: 2px;
        }
        .preflight-headline { font-size: \(p(1.15)); font-weight: 700; color: \(text); }
        .reader-prose { background-color: \(canvas); }
        .reader-body, .reader-body text {
            background-color: \(canvas);
            color: \(text);
            font-size: \(p(0.95));
        }
        .reader-mono, .reader-mono text {
            background-color: \(canvas);
            color: \(text);
            font-family: monospace;
            font-size: \(m(0.85));
        }
        .subagent-card {
            border-left: 2px solid \(info);
            padding: 6px 10px;
            background-color: \(palette.subagentBg);
        }
        .workflow-card {
            border-left: 2px solid \(accent);
            padding: 8px 10px;
            background-color: \(palette.subagentBg);
        }
        .workflow-name {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(0.9));
            font-weight: bold;
        }
        .workflow-summary {
            color: \(textDim);
            font-size: \(p(0.85));
        }
        .workflow-elapsed {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.76));
        }
        .workflow-meter {
            color: \(accentDim);
            font-family: monospace;
            font-size: \(m(0.8));
            letter-spacing: -0.04em;
        }
        .workflow-meter-live {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(0.8));
            letter-spacing: -0.04em;
        }
        .workflow-phase, .workflow-phase-done {
            font-family: monospace;
            font-size: \(m(0.78));
        }
        .workflow-phase { color: \(textDim); }
        .workflow-phase-done { color: \(accent); }
        .workflow-phase-title {
            color: \(text);
            font-family: monospace;
            font-size: \(m(0.8));
        }
        .workflow-model {
            color: \(special);
            font-family: monospace;
            font-size: \(m(0.72));
        }
        .workflow-answer { color: \(text); font-size: \(p(0.9)); }
        .image-part { border: 1px solid \(rule); }
        .task-board { border: 1px solid \(rule); border-radius: 8px; padding: 10px 12px; background-color: alpha(currentColor, 0.03); }
        .task-board-head { font-size: \(c(0.8)); font-weight: 700; color: \(palette.accent); }
        .task-board-item { font-size: \(c(0.86)); }

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
        .pill-row { padding: 0px 22px 6px 22px; }
        .pill-row button {
            font-family: monospace;
            font-size: \(m(0.78));
            min-height: 0;
            padding: 1px 8px;
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 0;
            color: \(textDim);
        }
        .pill-row button:hover { border-color: \(accent); color: \(text); }
        .pill-row arrow { -gtk-icon-size: 8px; opacity: 0.4; }
        .pill-row button.send-pill { color: \(accentDim); border-color: \(accentDim); }
        .pill-row button.send-pill:hover { color: \(accent); border-color: \(accent); }
        .pill-row button.stop-pill { color: \(danger); border-color: \(danger); }
        .pill-row button.stop-pill:hover { color: \(palette.onAccent); background-color: \(danger); }
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
        .chat-pane { border: 1px solid transparent; }
        .video-pane { background-color: #000000; }
        .web-pane { background-color: \(canvas); }
        .video-heading {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(1.1));
            letter-spacing: 1px;
        }
        .video-notice {
            color: \(textDim);
            background-color: alpha(\(accent), 0.10);
            border: 1px solid alpha(\(accent), 0.30);
            border-radius: 10px;
            padding: 8px 12px;
            font-family: monospace;
            font-size: \(m(0.8));
        }
        .watch-ask { background-color: \(canvas); }
        .watch-section-detail {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.72));
            opacity: 0.6;
        }
        .watch-meta {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.72));
            opacity: 0.75;
        }
        .watch-note {
            color: \(textDim);
            font-family: monospace;
            font-size: \(m(0.78));
            opacity: 0.7;
        }
        .watch-thumb {
            background-color: alpha(\(text), 0.06);
            border: 1px solid \(rule);
            border-radius: 4px;
        }
        .watch-followed { color: \(special); font-size: \(c(0.8)); }
        .watch-step {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(0.82));
            font-weight: bold;
        }
        .watch-code {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(1.6));
            letter-spacing: 3px;
        }
        .pill-source { color: \(info); border: 1px solid alpha(\(info), 0.5); }
        .pane-focused { border: 1px solid alpha(\(accent), 0.55); }
        .pane-identity {
            color: \(textDim);
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            font-family: monospace;
            font-size: \(m(0.72));
            padding: 2px 10px;
        }
        .pane-focused .pane-identity { color: \(accent); }
        .drop-zone {
            background-color: alpha(\(accent), 0.16);
            border: 2px solid \(accent);
            border-radius: 4px;
        }
        .drop-caption {
            color: \(accent);
            font-family: monospace;
            font-size: \(m(0.85));
            font-weight: bold;
        }
        .find-hit {
            background-color: \(palette.findHit);
            box-shadow: inset 2px 0 0 \(warn);
        }
        .usage-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .update-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .update-footer:hover { background-color: alpha(currentColor, 0.04); }
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
        .brand-claude { color: \(palette.brandClaude); }
        .brand-opencode { color: \(palette.brandOpencode); }
        .brand-grok { color: \(palette.brandGrok); }
        .gauge-fill-claude { background-color: \(palette.brandClaude); border-radius: 3px; }
        .gauge-fill-opencode { background-color: \(palette.brandOpencode); border-radius: 3px; }
        .gauge-fill-grok { background-color: \(palette.brandGrok); border-radius: 3px; }
        .usage-card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 12px 14px;
        }
        .usage-provider { color: \(text); font-weight: 700; font-size: 1.05rem; }
        .usage-plan { color: \(textDim); font-size: 0.85rem; }
        .usage-live {
            color: \(accent);
            font-size: 0.7rem;
            font-weight: 700;
            letter-spacing: 0.08em;
            border: 1px solid alpha(\(accent), 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-stale {
            color: \(textDim);
            font-size: 0.7rem;
            font-weight: 700;
            letter-spacing: 0.08em;
            border: 1px solid alpha(currentColor, 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-gauge-label { color: \(text); font-size: 0.9rem; }
        .usage-rule { background-color: \(rule); min-height: 1px; margin: 2px 0px; }
        .usage-detail-key { color: \(textDim); font-size: 0.85rem; }
        .usage-detail-value { color: \(text); font-size: 0.85rem; }
        .usage-source { color: \(textDim); font-size: 0.75rem; }
        .spend-total { color: \(text); font-weight: 700; font-size: 1.6rem; }
        .spend-caption { color: \(textDim); font-size: 0.72rem; letter-spacing: 0.06em; }
        .spend-bar { background-color: \(accentDim); border-radius: 2px; }
        .spend-bar-hot { background-color: \(accent); border-radius: 2px; }
        .git-added { color: \(accent); }
        .git-removed { color: \(danger); }
        .git-changed { color: \(info); }
        .git-untracked { color: \(textDim); }
        .git-conflict { color: \(warn); font-weight: 700; }
        .git-neutral {
            color: \(text);
            font-weight: 700;
            font-size: 0.78rem;
            letter-spacing: 0.06em;
        }
        .git-neutral-ink { color: \(text); }
        .git-row { padding: 2px 4px; border-radius: 6px; }
        .git-row:hover { background-color: alpha(currentColor, 0.07); }
        .git-alert {
            color: \(warn);
            font-weight: 700;
            border: 1px solid alpha(\(warn), 0.45);
            border-radius: 8px;
            padding: 4px 8px;
        }
        .git-diff { font-family: monospace; font-size: 0.85rem; }
        .analytics-total { color: \(text); font-weight: 700; font-size: 2.1rem; }
        .analytics-hero-percent { font-weight: 700; font-size: 1.5rem; }
        .hero-ok { color: \(text); }
        .hero-warn { color: \(warn); }
        .hero-danger { color: \(danger); }
        .analytics-delta-up { color: \(warn); font-size: 0.85rem; }
        .analytics-delta-down { color: \(accent); font-size: 0.85rem; }
        .analytics-delta-flat { color: \(textDim); font-size: 0.85rem; }
        .analytics-bar { background-color: \(accentDim); border-radius: 2px; }
        .analytics-bar-today { background-color: \(accent); border-radius: 2px; }
        .analytics-hour { background-color: alpha(\(info), 0.75); border-radius: 2px; }
        .record-card {
            background-color: alpha(currentColor, 0.04);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 8px 10px;
        }
        .record-glyph { color: \(accent); font-size: 1.2rem; }
        .record-title { color: \(textDim); font-size: 0.68rem; letter-spacing: 0.06em; }
        .record-value { color: \(text); font-weight: 700; font-size: 0.9rem; }
        .record-detail { color: \(textDim); font-size: 0.78rem; }
        .analytics-open {
            background-color: alpha(currentColor, 0.05);
            border: 1px solid \(rule);
            border-radius: 8px;
            color: \(text);
            font-size: 0.85rem;
            padding: 8px 12px;
        }
        .analytics-open:hover { background-color: alpha(\(accent), 0.12); }
        .usage-footer:hover { background-color: alpha(currentColor, 0.04); }
        .settings-group { padding: 6px 0px; }
        """
    }

    /// The model chip classes, generated from the shared catalog so a family's hue on this desk is
    /// the same fact the phone and the Mac draw: text colour on a wash of itself for the list
    /// chips, and the same hue on the composer's bordered pills, which need the heavier selector
    /// to outrank `.pill-row button`.
    private static func modelTintCSS(for palette: Palette) -> String {
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
            lines.append(
                ".pill-row menubutton.\(pair.cls) > button { color: \(pair.hex); "
                    + "border-color: alpha(\(pair.hex), 0.55); }")
            lines.append(
                ".pill-row menubutton.\(pair.cls) > button:hover "
                    + "{ background-color: alpha(\(pair.hex), 0.12); }")
        }
        lines.append(
            ".pill-row menubutton.effort-ultracode > button { "
                + "background-image: \(rainbowWash(0.22)); background-color: transparent; "
                + "border-color: alpha(\(palette.text), 0.3); color: \(palette.text); "
                + "font-weight: 700; }")
        lines.append(
            ".pill-row menubutton.effort-ultracode > button:hover "
                + "{ background-image: \(rainbowWash(0.34)); }")
        return lines.joined(separator: "\n        ")
    }

    /// The shared rainbow as a low-alpha wash a word stays readable on: the same stops the aura
    /// travels, laid left to right under the one effort that is a power rather than a level.
    private static func rainbowWash(_ alpha: Double) -> String {
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
