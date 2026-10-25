import CAdw
import Foundation
import TailscodeCore

/// The desktop stylesheet for one palette at one chat density. The values every rule is written from
/// are computed once, here, and the rules are written in sections so no one file holds them all.
struct MatrixStylesheet {
    let palette: Palette
    let inset: Int
    let transcriptPadding: String
    let bandInset: Int
    let codePadding: String
    let flat: Int
    let railHeight: Int
    let plateRow: Int
    let chrome: Double
    let canvas: String
    let canvasRaised: String
    let rule: String
    let text: String
    let textDim: String
    let accent: String
    let accentDim: String
    let warn: String
    let danger: String
    let info: String
    let special: String
    let factFill: String
    let controlFill: String
    let dimInk: String
    let chipPadding: Int
    let chipGap: Int
    let chipIcon: Int
    let chipHeight: Int
    let decisiveHeight: Int
    let chipIconEm: String
    let chipHeightEm: String
    let decisiveHeightEm: String

    init(palette: Palette, density: ChatDensity) {
        self.palette = palette
        let metrics = ChatMetrics.metrics(for: density, input: .pointer)
        let inset = MatrixTheme.chatInset(density)
        let transcriptPadding = density == .compact ? "8px \(inset)px" : "18px \(inset)px"
        let bandInset = inset - 6
        let codePadding = density == .compact ? "6px 12px" : "8px 12px"
        let flat = Int(metrics.activityRowHeight)
        let railHeight = Int(metrics.railRowHeight)
        let plateRow = Int(metrics.railOpenRowHeight)
        let chrome = Preferences.scale(.chrome)
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
        let chipMetrics = ChatChrome.chip(on: .pointer)
        let factFill = Contrast.blend(canvas, text, ChatChrome.fill(.fact).inkShare) ?? canvasRaised
        let controlFill =
            Contrast.blend(canvas, text, ChatChrome.fill(.control).inkShare) ?? canvasRaised
        let dimInk = MatrixTheme.quietInk(for: palette)
        let chipPadding = Int(chipMetrics.padding)
        let chipGap = Int(chipMetrics.iconGap)
        let chipIcon = Int(chipMetrics.iconSize)
        let chipHeight = Int(chipMetrics.height)
        let decisiveHeight = chipHeight + 4
        let chipIconEm = String(format: "%.3f", Double(chipIcon) / MatrixTheme.chipEmPixels)
        let chipHeightEm = String(format: "%.3fem", Double(chipHeight - 2) / MatrixTheme.chipEmPixels)
        let decisiveHeightEm = String(format: "%.3fem", Double(decisiveHeight - 2) / MatrixTheme.chipEmPixels)

        self.inset = inset
        self.transcriptPadding = transcriptPadding
        self.bandInset = bandInset
        self.codePadding = codePadding
        self.flat = flat
        self.railHeight = railHeight
        self.plateRow = plateRow
        self.chrome = chrome
        self.canvas = canvas
        self.canvasRaised = canvasRaised
        self.rule = rule
        self.text = text
        self.textDim = textDim
        self.accent = accent
        self.accentDim = accentDim
        self.warn = warn
        self.danger = danger
        self.info = info
        self.special = special
        self.factFill = factFill
        self.controlFill = controlFill
        self.dimInk = dimInk
        self.chipPadding = chipPadding
        self.chipGap = chipGap
        self.chipIcon = chipIcon
        self.chipHeight = chipHeight
        self.decisiveHeight = decisiveHeight
        self.chipIconEm = chipIconEm
        self.chipHeightEm = chipHeightEm
        self.decisiveHeightEm = decisiveHeightEm
    }

    func c(_ value: Double) -> String { String(format: "%.3frem", value * chrome) }

    func t(_ role: TypeRole) -> String { TypeCSS.declarations(role) }

    func modelTintCSS(for palette: Palette) -> String { MatrixTheme.modelTintCSS(for: palette) }

    func dialTintCSS(for palette: Palette) -> String { MatrixTheme.dialTintCSS(for: palette) }

    func rainbowWash(_ alpha: Double) -> String { MatrixTheme.rainbowWash(alpha) }

    func brandOmp(in palette: Palette) -> String { MatrixTheme.brandOmp(in: palette) }

    var sheet: String {
        [
            chromeRules(),
            transcriptRules(),
            cardRules(),
            composerRules(),
            drawRules(),
            panelRules(),
            agentsRules(),
            settingsRules(),
            keycapRules(),
        ].joined(separator: "\n")
    }

    func chromeRules() -> String {
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
        .forge-ring { opacity: 1; transition: opacity 250ms ease-out; }
        .forge-ring-off { opacity: 0; }
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
            padding: \(transcriptPadding);
        }
        .turn-rule {
            background-color: \(rule);
            min-height: 1px;
        }
        .prompt-rule {
            background-color: \(accent);
            min-width: 2px;
        }
        .pending-rule-failed { background-color: \(danger); }
        .pending-ink { opacity: 1; transition: opacity 250ms ease-out; }
        .pending-text-failed { color: \(danger); }
        .prompt-glyph { color: \(accent); \(t(.promptGlyph)) }
        .prompt-text { color: \(text); \(t(.prompt)) }
        .agent-text { color: \(text); \(t(.answer)) }
        .md-table {
            border: 1px solid alpha(\(text), \(TableStyle.border));
            border-radius: \(Int(TableStyle.radius))px;
            margin: 4px 0;
        }
        .md-table-headrow {
            background-color: alpha(\(accent), \(TableStyle.headerWash));
            border-radius: \(Int(TableStyle.radius - 1))px \(Int(TableStyle.radius - 1))px 0 0;
            padding: \(Int(TableStyle.headerPadding))px \(Int(TableStyle.edge))px;
        }
        .md-table-rule {
            background-color: alpha(\(text), \(TableStyle.headerRule));
            min-height: 1px;
        }
        .md-table-row { padding: \(Int(TableStyle.rowPadding))px \(Int(TableStyle.edge))px; }
        .md-table-band { background-color: alpha(\(text), \(TableStyle.stripe)); }
        .md-table-last {
            border-radius: 0 0 \(Int(TableStyle.radius - 1))px \(Int(TableStyle.radius - 1))px;
        }
        .md-table-fade {
            background-image: linear-gradient(
                to right, alpha(\(canvas), 0), alpha(\(canvas), 0.92) 70%, \(canvas));
        }
        .md-table-draft { margin: 4px 0; }
        .md-table-sweep { color: \(accent); \(t(.tableCell)) }
        .md-table-draft-count { color: \(textDim); \(t(.tableCell)) }
        .md-table-header { color: \(textDim); \(t(.tableHeader)) }
        .md-table-key { color: \(text); \(t(.tableKey)) }
        .md-table-cell { color: \(text); \(t(.tableCell)) }
        .tool-line, .mono { \(t(.toolDetail)) }
        .tool-name { color: \(info); \(t(.toolName)) }
        .tool-detail { color: \(textDim); \(t(.toolDetail)) }
        \(BrainCSS.rules(palette: palette, t: t))
        .glyph-done { color: alpha(\(accent), 0.72); }
        .glyph-running { color: \(accent); }
        .glyph-needs { color: \(warn); }
        .glyph-error { color: \(danger); }
        .glyph-pending { color: \(textDim); }
        .glyph-ok { color: \(accent); }
        .glyph-warn { color: \(warn); }
        .glyph-info { color: \(info); }
        .section-title { \(t(.metricLabel)) color: \(textDim); }
        .fact-good .subtitle { color: alpha(\(accent), 0.85); opacity: 1; }
        .fact-warn .subtitle { color: \(warn); opacity: 1; }
        .fact-bad .subtitle { color: \(danger); opacity: 1; }
        .delegate-tone-live { color: \(accent); }
        .delegate-tone-attention { color: \(warn); }
        .delegate-tone-danger { color: \(danger); }
        .delegate-tone-quiet { color: \(textDim); }
        .delegate-rung { border: 1px solid alpha(\(textDim), 0.3); border-radius: 8px; }
        .dg-headline { \(t(.headline)) color: \(text); }
        button.dg-primary { \(t(.control)) padding: 8px 18px; border-radius: 10px; }
        button.dg-action, menubutton.dg-action > button { \(t(.control)) padding: 6px 14px; border-radius: 10px; }
        .dg-danger-text, .dg-danger-text label { color: \(danger); }
        .dg-facts { \(t(.rowMeta)) color: \(textDim); }
        .dg-section { \(t(.sectionLabel)) color: \(textDim); }
        .dg-note { \(t(.rowDetail)) color: \(textDim); }
        .dg-lead { border-radius: 12px; padding: 14px 16px; border-left: 3px solid \(textDim); }
        .dg-lead-live { background-color: alpha(\(accent), 0.07); border-left-color: \(accent); }
        .dg-lead-attention { background-color: alpha(\(warn), 0.08); border-left-color: \(warn); }
        .dg-lead-danger { background-color: alpha(\(danger), 0.08); border-left-color: \(danger); }
        .dg-lead-quiet { background-color: alpha(\(textDim), 0.06); border-left-color: alpha(\(textDim), 0.5); }
        .dg-lead-title { \(t(.cardTitle)) color: \(text); }
        .dg-lead-caption { \(t(.rowMeta)) color: \(textDim); }
        .dg-lead-body { \(t(.cardBody)) color: \(text); }
        .dg-lead-output {
            \(t(.toolOutput)) color: \(text); background-color: alpha(\(canvas), 0.55);
            border-radius: 8px; padding: 8px 10px;
        }
        .dg-rung {
            background-color: \(canvasRaised); border: 1px solid alpha(\(textDim), 0.22);
            border-radius: 10px; padding: 10px 12px;
        }
        .dg-rung-lit { border-color: \(accent); background-color: alpha(\(accent), 0.08); }
        .dg-rung-failed { border-color: alpha(\(danger), 0.6); }
        .dg-rung-held { border-color: \(warn); background-color: alpha(\(warn), 0.06); }
        .dg-rung-off { opacity: 0.45; }
        .dg-rung-label { \(t(.panelLabel)) color: \(text); }
        .dg-rung-model { \(t(.rowMeta)) color: \(textDim); }
        .dg-rung-note { \(t(.rowStamp)) color: \(textDim); }
        .dg-rung-link { color: alpha(\(textDim), 0.45); }
        .dg-pip { min-width: 7px; min-height: 7px; border-radius: 4px; background-color: alpha(\(textDim), 0.3); }
        .dg-pip-lit { background-color: \(accent); }
        .dg-pip-failed { background-color: \(danger); }
        .dg-pip-held { background-color: \(warn); }
        .dg-pip-off { background-color: alpha(\(textDim), 0.1); }
        .dg-row-meta { \(t(.rowStamp)) color: \(textDim); }
        .dg-file { border-radius: 8px; padding: 6px 10px; }
        .dg-file:hover { background-color: alpha(\(accent), 0.08); }
        .dg-file-name { \(t(.treeRow)) color: \(text); }
        .dg-file-folder { \(t(.treePath)) color: \(textDim); }
        .dg-added { \(t(.rowStamp)) color: \(accent); }
        .dg-removed { \(t(.rowStamp)) color: \(danger); }
        .dg-timeline-detail {
            \(t(.toolOutput)) color: \(textDim); border-left: 2px solid alpha(\(textDim), 0.3);
            padding-left: 10px;
        }
        .dg-choice { border-radius: 8px; padding: 6px 10px; }
        .dg-choice-name { \(t(.rowTitle)) color: \(text); }
        .dg-choice-detail { \(t(.rowStamp)) color: \(textDim); }
        .dim { color: \(textDim); }
        .attachment { color: \(info); \(t(.attachment)) }
        .status-line {
            color: \(accentDim);
            \(t(.statusLine))
            padding: 4px \(inset)px;
            background-color: \(canvasRaised);
            border-top: 1px solid \(rule);
        }
        .status-band {
            background-color: \(canvasRaised);
            border-top: 1px solid \(rule);
            padding: 3px \(bandInset)px;
        }
        .seg, .seg > button, .seg button {
            \(t(.segment))
            min-height: \(chipHeightEm);
            padding: 0 6px;
            border: none;
            border-radius: 3px;
            background: none;
            background-color: transparent;
            box-shadow: none;
            outline: 2px solid transparent;
            outline-offset: -2px;
            text-shadow: none;
        }
        .seg:hover, .seg button:hover { background-color: \(canvas); }
        .seg:focus-visible, .seg > button:focus-visible, button.seg:focus-visible {
            outline: 2px solid \(accent);
            outline-offset: -2px;
        }
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
        .composer-placeholder { color: \(dimInk); \(t(.composer)) }
        .composer-row { padding: 0 \(inset)px; }
        .attachments-row { padding: 0 \(inset)px; }
        .help-overlay { padding: 0 \(inset)px; }
        .pending-strip { color: \(dimInk); \(t(.hint)) }
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
            padding: \(codePadding);
            color: \(text);
            \(t(.code))
        }
        .code-plate {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 6px;
            margin: 4px 6px 0 0;
            padding: 0 2px 0 8px;
            opacity: 0;
            transition: opacity 120ms ease-out;
        }
        .code-wrap:hover .code-plate, .code-wrap:focus-within .code-plate { opacity: 1; }
        .code-plate .code-copy { min-height: 0; padding: 0 6px; }
        .code-gutter { \(t(.code)) color: \(textDim); opacity: 0.7; padding-right: 12px; }
        .code-scroll, .code-scroll > viewport { background: none; }
        .code-scroll scrollbar { margin-top: 4px; }
        .code-fold { color: \(info); \(t(.codeAction)) padding: 2px 0; min-height: 0; }
        .code-fold:hover { color: \(accent); }
        .code-copy:hover { color: \(accent); }
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
        .beta-badge {
            \(t(.pill))
            padding: 2px 9px;
            border-radius: 999px;
            color: \(special);
            background-color: alpha(\(special), 0.14);
            border: 1px solid alpha(\(special), 0.55);
            font-weight: 700;
            letter-spacing: 1px;
        }
        .beta-badge:hover { background-color: alpha(\(special), 0.26); }
        .beta-badge:focus-visible { outline: 2px solid \(special); outline-offset: 2px; }
        .beta-badge-static, .beta-badge-static:hover { background-color: alpha(\(special), 0.14); }
        .beta-card-title { \(t(.panelTitle)) color: \(text); }
        .beta-card-lead { \(t(.panelDetail)) color: \(text); }
        .beta-card-body { \(t(.panelDetail)) color: \(textDim); }
        .beta-card-since { border-radius: 10px; padding: 10px 12px; background-color: alpha(\(special), 0.1); border-left: 3px solid \(special); }
        .beta-card-since .beta-card-body { color: \(text); }
        .beta-glyph-solid { \(t(.panelDetail)) color: \(accent); }
        .beta-glyph-rough { \(t(.panelDetail)) color: \(warn); }
        \(ClockCSS.rules(palette: palette))
        .call-strip {
            margin: 0 \(inset)px 8px \(inset)px;
            padding: 10px 12px;
            border-radius: 14px;
            border: 1px solid \(rule);
            background-color: \(canvasRaised);
        }
        .call-face { min-width: 32px; min-height: 32px; border-radius: 999px; }
        .call-face-glyph { \(t(.control)) color: \(palette.onAccent); }
        .call-face-live { background-color: \(accent); }
        .call-face-attention { background-color: \(warn); }
        .call-face-danger { background-color: \(danger); }
        .call-face-quiet { background-color: \(dimInk); }
        .call-word { \(t(.panelTitle)) color: \(text); }
        .call-clock { \(t(.rowStamp)) color: \(textDim); }
        .call-role { \(t(.sectionLabel)) color: \(textDim); }
        .call-line-you { \(t(.panelDetail)) color: \(textDim); }
        .call-line-partial { font-style: italic; }
        .call-line-end { \(t(.panelDetail)) color: \(text); }
        .call-agent-glyph { \(t(.panelDetail)) }
        .call-agent-text { \(t(.panelDetail)) color: \(textDim); }
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
        """
    }
}
