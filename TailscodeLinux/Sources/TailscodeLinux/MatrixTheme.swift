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
        func c(_ value: Double) -> String { String(format: "%.3frem", value * chrome) }
        func t(_ role: TypeRole) -> String { TypeCSS.declarations(role) }
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
            \(t(.control))
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
        .prompt-glyph { color: \(accent); \(t(.promptGlyph)) }
        .prompt-text { color: \(text); \(t(.prompt)) }
        .agent-text { color: \(text); \(t(.answer)) }
        .md-table { padding: 2px 0; }
        .md-table-header { color: \(text); \(t(.tableHeader)) }
        .md-table-cell { color: \(text); \(t(.tableCell)) }
        .tool-line, .mono { \(t(.toolDetail)) }
        .tool-name { color: \(info); \(t(.toolName)) }
        .tool-detail { color: \(textDim); \(t(.toolDetail)) }
        .glyph-done { color: alpha(\(accent), 0.72); }
        .glyph-running { color: \(accent); }
        .glyph-needs { color: \(warn); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .fact-good .subtitle { color: alpha(\(accent), 0.85); opacity: 1; }
        .fact-warn .subtitle { color: \(warn); opacity: 1; }
        .fact-bad .subtitle { color: \(danger); opacity: 1; }
        .dim { color: \(textDim); }
        .attachment { color: \(info); \(t(.attachment)) }
        .status-line {
            color: \(accentDim);
            \(t(.statusLine))
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
            \(t(.segment))
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
            \(t(.composer))
        }
        .composer-placeholder { color: \(textDim); \(t(.composer)) opacity: 0.55; }
        .composer-normal { border-color: \(accent); }
        .composer-visual { border-color: \(info); }
        .vim-badge {
            \(t(.badge))
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
            color: \(text);
            \(t(.code))
        }
        .diff-add { color: \(accent); \(t(.diff)) }
        .diff-remove { color: \(danger); \(t(.diff)) }
        .diff-line { \(t(.diff)) }
        .diff-wash-add { background-color: \(SyntaxPalette.diffLineBackground(.added, in: palette) ?? palette.codeBg); }
        .diff-wash-remove { background-color: \(SyntaxPalette.diffLineBackground(.removed, in: palette) ?? palette.codeBg); }

        .pill {
            \(t(.pill))
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
        .split-tab-holder {
            border-left: 2px solid alpha(\(accent), 0.35);
            margin-bottom: 2px;
        }
        .split-tab-member {
            padding: 1px 6px 1px 22px;
            border: none;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            opacity: 0.8;
        }
        .split-tab-member:hover {
            background-color: alpha(\(accent), 0.08);
            opacity: 1;
        }
        .selection-bar {
            background-color: alpha(\(accent), 0.10);
            border: 1px solid alpha(\(accent), 0.45);
            border-radius: 6px;
        }
        .selection-count { \(t(.metricValue)) color: \(accent); }
        .selection-verb {
            \(t(.control))
            padding: 2px 6px;
            border: 1px solid alpha(\(text), 0.20);
            border-radius: 4px;
        }
        .selection-verb:hover { border-color: \(accent); }
        .selection-split-header { \(t(.sectionLabel)) opacity: 0.5; }
        .row-title { \(t(.rowTitle)) color: \(text); }
        .row-title-unread { \(t(.rowTitleStrong)) color: \(text); }
        .row-detail { \(t(.rowDetail)) opacity: 0.55; }
        .row-model { \(t(.rowMeta)) }
        .row-project { \(t(.rowMeta)) opacity: 0.9; color: \(text); }
        .row-age { \(t(.rowStamp)) opacity: 0.45; color: \(text); }
        .row-focused .row-project, .row-focused .row-age { opacity: 1; }
        .row-note { color: \(accent); \(t(.rowNote)) opacity: 0.55; }
        .section-header {
            \(t(.sectionLabel))
            opacity: 0.5;
            padding: 10px 8px 2px 8px;
        }
        .unread-dot { color: \(accent); font-size: \(c(0.7)); }

        .model-summary { color: \(textDim); \(t(.note)) padding: 0 2px; }
        .model-search {
            background-color: \(canvas);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 4px;
        }
        .model-search:focus-within { border-color: \(accent); }
        .model-search text { color: \(text); \(t(.composer)) }
        .model-scope {
            \(t(.chip))
            color: \(textDim);
            min-height: 0;
            padding: 2px 12px;
            border: 1px solid alpha(\(textDim), 0.28);
            border-radius: 999px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
        }
        .model-scope:hover { color: \(accent); border-color: alpha(\(accent), 0.7); }
        .model-scope-on, .model-scope-on:hover {
            color: \(palette.onAccent);
            background-color: \(accent);
            border-color: \(accent);
        }
        .model-scope-key { opacity: 0.55; }
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
        .model-row-nested {
            margin-left: 22px;
            border-left: 2px solid alpha(\(accent), 0.22);
        }
        .model-check { color: \(accent); \(t(.note)) }
        .model-mark { color: \(textDim); \(t(.hint)) opacity: 0.5; }
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
        .model-section-button {
            padding: 0;
            border: none;
            border-radius: 5px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .model-section-button:hover { background-color: alpha(\(accent), 0.07); }
        .model-section-button:hover .section-header { opacity: 0.85; }
        .model-section-fold { color: \(textDim); \(t(.hint)) opacity: 0.6; }
        .model-section-count {
            color: \(textDim);
            \(t(.hint))
            opacity: 0.7;
            padding: 10px 8px 2px 8px;
        }
        .model-fact {
            \(t(.pill))
            color: \(textDim);
            border: 1px solid alpha(\(textDim), 0.30);
            border-radius: 3px;
            padding: 0px 5px;
        }
        .model-row-current, .model-row-current:hover {
            background-color: alpha(\(accent), 0.10);
            border-radius: 5px;
        }
        .model-fact-local { color: \(accent); border-color: alpha(\(accent), 0.6); }
        .model-fact-providers { color: \(info); border-color: alpha(\(info), 0.6); }
        .model-fact-server {
            color: \(warn);
            border-color: alpha(\(warn), 0.6);
            background: alpha(\(warn), 0.10);
        }
        .model-fact-spent {
            color: \(danger);
            border-color: alpha(\(danger), 0.6);
            background: alpha(\(danger), 0.10);
        }
        .model-row-spent { color: \(textDim); }
        .chooser-hint { color: \(textDim); \(t(.hint)) opacity: 0.75; padding: 2px; }

        .ask-field {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 12px;
            padding: 6px 10px;
        }
        .ask-field:focus-within {
            border-color: \(accent);
            background-color: alpha(\(accent), 0.05);
        }
        .ask-caret { color: \(accent); \(t(.composer)) opacity: 0.8; }
        .ask-entry {
            background: none;
            background-image: none;
            border: none;
            box-shadow: none;
            outline: none;
            min-height: 30px;
            padding: 0;
            color: \(text);
            \(t(.composer))
        }
        .ask-entry text { background: none; color: \(text); }
        .ask-entry text selection { background-color: alpha(\(accent), 0.30); color: \(text); }
        .ask-entry, .ask-entry textview, .ask-entry textview text {
            background-color: transparent;
            background-image: none;
            color: \(text);
            \(t(.composer))
        }
        .ask-entry textview text selection {
            background-color: alpha(\(accent), 0.30);
            color: \(text);
        }
        .ask-send {
            color: \(textDim);
            \(t(.composer))
            min-width: 30px;
            padding: 0 6px;
            border-radius: 8px;
            opacity: 0.45;
        }
        .ask-send-ready { color: \(accent); opacity: 1; }
        .ask-send:hover { background-color: alpha(\(accent), 0.14); }
        .ask-chip {
            \(t(.chip))
            color: \(textDim);
            padding: 2px 10px;
            border-radius: 999px;
            border: 1px solid alpha(\(textDim), 0.28);
        }
        .ask-chip:hover { color: \(accent); border-color: alpha(\(accent), 0.7); }
        .ask-section {
            \(t(.sectionLabel))
            color: \(textDim);
            opacity: 0.5;
            padding: 14px 10px 4px 10px;
        }
        .ask-hint { color: \(textDim); \(t(.hint)) opacity: 0.7; padding: 0 6px; }
        .ask-row {
            padding: 7px 10px;
            border: none;
            border-radius: 10px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .ask-row:hover { background-color: alpha(\(accent), 0.10); }
        .ask-row:active { background-color: alpha(\(accent), 0.18); }
        .ask-glyph { color: \(accent); \(t(.rowTitleStrong)) }
        .ask-row-title { \(t(.rowTitleStrong)) color: \(text); }
        .ask-row-detail { \(t(.rowDetail)) color: \(textDim); opacity: 0.72; }
        .ask-row:hover .ask-row-detail { opacity: 0.9; }
        .ask-keycap {
            \(t(.pill))
            color: \(textDim);
            border: 1px solid alpha(\(textDim), 0.30);
            border-radius: 5px;
            padding: 1px 6px;
            opacity: 0.75;
        }
        .ask-row:hover .ask-keycap { color: \(accent); border-color: alpha(\(accent), 0.55); opacity: 1; }

        .tree-row { \(t(.treeRow)) color: \(text); }
        .tree-dir { color: \(info); \(t(.treeRow)) }
        .tree-path { color: \(textDim); \(t(.treePath)) }

        .code-header { color: \(textDim); \(t(.codeLabel)) }
        .code-copy { color: \(info); \(t(.codeAction)) padding: 0 6px; }
        .code-body { \(t(.code)) color: \(text); }
        .tool-output { \(t(.toolOutput)) color: \(textDim); }
        .reasoning-body { color: \(textDim); \(t(.thought)) }
        .disclosure { padding: 0; min-height: 0; }
        .disclosure:hover { background-color: \(canvasRaised); }
        .disclosure-chevron { color: \(textDim); \(t(.note)) }
        .reasoning-label { color: \(textDim); \(t(.thoughtLabel)) }
        .disclosure:hover .disclosure-chevron { color: \(accent); }

        .card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            padding: 12px 16px;
        }
        .card-permission { border-left: 2px solid \(warn); }
        .card-question { border-left: 2px solid \(warn); }
        .card-title { \(t(.cardTitle)) color: \(text); }
        .answer-option {
            \(t(.option))
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
        .agent-live { color: \(accent); \(t(.segment)) }
        .interruption { color: \(textDim); \(t(.interruption)) }
        .seam-text { color: \(special); \(t(.seamLabel)) }
        .seam-read, .seam-read:hover {
            \(t(.codeAction))
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
        .card-answerless { border-left: 2px solid \(warn); }
        .response-stats { opacity: 0.62; }
        .queued-row { opacity: 0.55; padding: 2px 0; border-radius: 4px; }
        .queued-row:hover { opacity: 0.85; background-color: alpha(\(accent), 0.07); }
        .queued-rule { background-color: \(textDim); }
        .queued-hint { color: \(textDim); \(t(.hint)) }
        .response-stat-glyph { color: \(textDim); \(t(.responseStat)) }
        .response-stat-value { color: \(textDim); \(t(.responseStat)) }
        .card-interrupted { border-left: 2px solid \(warn); }
        .card button:disabled, .card button:disabled label { opacity: 0.45; }
        .card-design { border-left: 2px solid \(info); }
        .design-letter, .design-letter:hover {
            \(t(.chip))
            min-height: 0;
            padding: 2px 12px;
            color: \(textDim);
            background-color: transparent;
            border: 1px solid \(rule);
            border-radius: 3px;
            box-shadow: none;
        }
        .design-letter:hover { border-color: \(info); color: \(text); }
        .design-letter-on, .design-letter-on:hover {
            color: \(palette.onAccent);
            background-color: \(accent);
            border-color: \(accent);
        }
        .design-frame { background-color: \(canvasRaised); border: 1px solid \(rule); }
        .design-note {
            \(t(.cardBody))
            color: \(text);
            background-color: alpha(\(special), 0.12);
            border-left: 2px solid \(special);
            padding: 8px 10px;
        }
        .design-rationale { color: \(text); \(t(.cardBody)) }
        .design-caption { color: \(accent); \(t(.cardTitle)) }
        .seam-footnote { color: \(textDim); \(t(.seamFootnote)) }
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
        .preflight-headline { \(t(.headline)) color: \(text); }
        .reader-prose { background-color: \(canvas); }
        .reader-body, .reader-body text {
            background-color: \(canvas);
            color: \(text);
            \(t(.answer))
        }
        .reader-mono, .reader-mono text {
            background-color: \(canvas);
            color: \(text);
            \(t(.code))
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
        .workflow-name { color: \(accent); \(t(.workflowName)) }
        .workflow-summary { color: \(textDim); \(t(.workflowSummary)) }
        .workflow-elapsed { color: \(textDim); \(t(.workflowModel)) }
        .workflow-meter { color: \(accentDim); \(t(.workflowMeter)) }
        .workflow-meter-live { color: \(accent); \(t(.workflowMeter)) }
        .workflow-phase, .workflow-phase-done, .workflow-phase-unfinished { \(t(.workflowStep)) }
        .workflow-phase { color: \(textDim); }
        .workflow-phase-done { color: \(accent); }
        .workflow-phase-unfinished { color: \(textDim); }
        .workflow-phase-title { color: \(text); \(t(.workflowStep)) }
        .workflow-model { color: \(special); \(t(.workflowModel)) }
        .workflow-answer { color: \(text); \(t(.cardBody)) }
        .image-part { border: 1px solid \(rule); }
        .task-board { border: 1px solid \(rule); border-radius: 8px; padding: 10px 12px; background-color: alpha(currentColor, 0.03); }
        .task-board-head { \(t(.sectionLabel)) color: \(palette.accent); }
        .task-board-item { \(t(.panelLabel)) }

        .goal-line { color: \(special); \(t(.chip)) padding: 2px 26px; }
        .banner-auth {
            color: \(palette.onAccent);
            background-color: \(warn);
            \(t(.banner))
            padding: 4px 12px;
        }
        .pill-row { padding: 0px 22px 6px 22px; }
        .pill-row button {
            \(t(.chip))
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
            \(t(.chip))
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvasRaised);
            border: 1px solid \(info);
            border-radius: 0;
            color: \(info);
        }
        .chip:hover { border-color: \(danger); color: \(danger); }
        .jump-pill {
            \(t(.statusLine))
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
        .video-heading { color: \(accent); \(t(.paneHeadline)) }
        .video-notice {
            color: \(textDim);
            background-color: alpha(\(accent), 0.10);
            border: 1px solid alpha(\(accent), 0.30);
            border-radius: 10px;
            padding: 8px 12px;
            \(t(.note))
        }
        .watch-ask { background-color: \(canvas); }
        .watch-section-detail { color: \(textDim); \(t(.hint)) opacity: 0.6; }
        .watch-meta { color: \(textDim); \(t(.hint)) opacity: 0.75; }
        .watch-note { color: \(textDim); \(t(.note)) opacity: 0.7; }
        .watch-thumb {
            background-color: alpha(\(text), 0.06);
            border: 1px solid \(rule);
            border-radius: 4px;
        }
        .watch-followed { color: \(special); \(t(.panelDetail)) }
        .watch-step { color: \(accent); \(t(.statusLine)) font-weight: 700; }
        .watch-code { color: \(accent); \(t(.pairingCode)) }
        .pill-source { color: \(info); border: 1px solid alpha(\(info), 0.5); }
        .forge-pane { background-color: \(canvas); }
        .forge-call {
            \(t(.control))
            min-height: 0;
            padding: 3px 14px;
            border: none;
            border-radius: 999px;
            color: \(palette.onAccent);
            background-color: \(accent);
            background-image: none;
            box-shadow: none;
        }
        .forge-call:hover { background-color: \(accentDim); }
        .forge-render-row {
            background-color: alpha(\(accent), 0.07);
            border: 1px solid alpha(\(accent), 0.28);
        }
        .forge-render-row:hover { background-color: alpha(\(accent), 0.13); }
        .row-focused.forge-render-row { background-color: alpha(\(accent), 0.18); }
        .forge-state { color: \(text); \(t(.cardBody)) }
        .forge-stage {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 8px;
            min-height: 116px;
            padding: 10px;
        }
        .forge-stage-glyph { color: \(textDim); \(t(.paneHeadline)) font-size: 200%; }
        .forge-stage-caption { color: \(textDim); \(t(.hint)) }
        .forge-affordance { color: \(textDim); \(t(.hint)) opacity: 0.7; }
        .forge-row-spent { opacity: 0.5; }
        .forge-bar trough {
            min-height: 4px;
            background-color: \(rule);
            border: none;
            border-radius: 2px;
        }
        .forge-bar progress {
            min-height: 4px;
            background-color: \(accent);
            border: none;
            border-radius: 2px;
        }
        .forge-reason { \(t(.note)) padding: 0 2px; }
        .forge-working { color: \(textDim); }
        .forge-refusal { color: \(danger); }
        .pane-focused { border: 1px solid alpha(\(accent), 0.55); }
        .pane-identity {
            color: \(textDim);
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            \(t(.paneIdentity))
            padding: 2px 10px;
        }
        .pane-focused .pane-identity { color: \(accent); }
        .drop-zone {
            background-color: alpha(\(accent), 0.16);
            border: 2px solid \(accent);
            border-radius: 4px;
        }
        .drop-caption { color: \(accent); \(t(.banner)) font-weight: 700; }
        .find-hit {
            background-color: \(palette.findHit);
            box-shadow: inset 2px 0 0 \(warn);
        }
        .usage-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .glance-row { min-height: \(c(1.15)); }
        .glance-dot { font-size: \(c(0.5)); }
        .glance-label { color: \(text); \(t(.rowDetail)) }
        .glance-value { \(t(.gauge)) }
        .glance-notice { \(t(.gaugeCaption)) }
        .glance-ok { color: \(accent); }
        .glance-warn { color: \(warn); }
        .glance-danger { color: \(danger); }
        .glance-balance { color: \(text); }
        .glance-quiet { color: \(textDim); }
        .glance-row .glance-notice.glance-quiet { opacity: 0.85; }
        .update-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .update-footer:hover { background-color: alpha(currentColor, 0.04); }
        .gauge-ok, .gauge-warn, .gauge-danger { \(t(.gauge)) }
        .gauge-ok { color: \(textDim); }
        .gauge-warn { color: \(warn); }
        .gauge-danger { color: \(danger); }
        .gauge-reset { \(t(.gaugeCaption)) color: \(textDim); opacity: 0.8; margin-bottom: 2px; }
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
        .brand-deepseek { color: \(palette.brandDeepseek); }
        .gauge-fill-claude { background-color: \(palette.brandClaude); border-radius: 3px; }
        .gauge-fill-opencode { background-color: \(palette.brandOpencode); border-radius: 3px; }
        .gauge-fill-grok { background-color: \(palette.brandGrok); border-radius: 3px; }
        .gauge-fill-deepseek { background-color: \(palette.brandDeepseek); border-radius: 3px; }
        .usage-card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 12px 14px;
        }
        .usage-provider { color: \(text); \(t(.panelTitle)) }
        .usage-plan { color: \(textDim); \(t(.panelDetail)) }
        .usage-live {
            color: \(accent);
            \(t(.metricLabel))
            border: 1px solid alpha(\(accent), 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-stale {
            color: \(textDim);
            \(t(.metricLabel))
            border: 1px solid alpha(currentColor, 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-gauge-label { color: \(text); \(t(.panelLabel)) }
        .usage-rule { background-color: \(rule); min-height: 1px; margin: 2px 0px; }
        .usage-detail-key { color: \(textDim); \(t(.panelDetail)) }
        .usage-detail-value { color: \(text); \(t(.metricDetail)) }
        .usage-source { color: \(textDim); \(t(.panelFootnote)) }
        .spend-total { color: \(text); \(t(.metricLarge)) }
        .spend-caption { color: \(textDim); \(t(.metricLabel)) }
        .spend-bar { background-color: \(accentDim); border-radius: 2px; }
        .spend-bar-hot { background-color: \(accent); border-radius: 2px; }
        .git-added { color: \(accent); }
        .git-removed { color: \(danger); }
        .git-changed { color: \(info); }
        .git-untracked { color: \(textDim); }
        .git-conflict { color: \(warn); font-weight: 700; }
        .git-neutral { color: \(text); \(t(.pill)) }
        .git-neutral-ink { color: \(text); }
        .git-row { padding: 2px 4px; border-radius: 6px; }
        .git-row:hover { background-color: alpha(currentColor, 0.07); }
        .git-alert {
            color: \(warn);
            \(t(.control))
            border: 1px solid alpha(\(warn), 0.45);
            border-radius: 8px;
            padding: 4px 8px;
        }
        .git-diff { \(t(.diff)) }
        .analytics-total { color: \(text); \(t(.metricHero)) }
        .analytics-hero-percent { \(t(.metricLarge)) }
        .hero-ok { color: \(text); }
        .hero-warn { color: \(warn); }
        .hero-danger { color: \(danger); }
        .analytics-delta-up { color: \(warn); \(t(.metricDetail)) }
        .analytics-delta-down { color: \(accent); \(t(.metricDetail)) }
        .analytics-delta-flat { color: \(textDim); \(t(.metricDetail)) }
        .analytics-bar { background-color: \(accentDim); border-radius: 2px; }
        .analytics-bar-today { background-color: \(accent); border-radius: 2px; }
        .analytics-hour { background-color: alpha(\(info), 0.75); border-radius: 2px; }
        .record-card {
            background-color: alpha(currentColor, 0.04);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 8px 10px;
        }
        .record-glyph { color: \(accent); font-size: \(c(1.2)); }
        .record-title { color: \(textDim); \(t(.metricLabel)) }
        .record-value { color: \(text); \(t(.metricValue)) }
        .record-detail { color: \(textDim); \(t(.metricDetail)) }
        .analytics-open {
            background-color: alpha(currentColor, 0.05);
            border: 1px solid \(rule);
            border-radius: 8px;
            color: \(text);
            \(t(.control))
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
