import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    func cardRules() -> String {
        return """
        .card-compaction { border-left: 2px solid \(special); }
        .card-compaction-failed { border-left: 2px solid \(danger); }
        .card-answerless { border-left: 2px solid \(warn); }
        .card-failed { border-left: 2px solid \(danger); }
        .failed-reason {
            \(t(.toolDetail))
            color: \(text);
            background-color: \(palette.codeBg);
            border-left: 2px solid \(rule);
            padding: 6px 10px;
        }
        .link-rail {
            min-height: \(railHeight)px;
            padding: 0 8px 0 2px;
            border-radius: 6px;
        }
        .link-rail:hover, .link-rail-open { background-color: alpha(\(text), 0.07); }
        .link-rail:focus-visible { outline: 2px solid alpha(\(accent), 0.7); outline-offset: -2px; }
        .link-rail-icon {
            border-radius: 7px;
            background-color: mix(\(canvasRaised), \(text), 0.2);
            box-shadow: 0 0 0 1px \(canvas);
        }
        .link-rail-icon-loaded { background-color: #f2f2f2; }
        .link-rail-glyph { color: \(textDim); font-size: 0.55rem; font-weight: 600; }
        .link-rail-host { color: \(accent); \(t(.note)) }
        .link-rail-more, .link-rail-chevron { color: \(textDim); \(t(.note)) }
        .link-plate {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 8px;
            box-shadow: 0 6px 18px alpha(black, 0.35);
            opacity: 0;
            transition: opacity 120ms ease-out;
        }
        .link-plate-on { opacity: 1; }
        .link-plate scrolledwindow { background: none; }
        .link-plate-row {
            min-height: \(plateRow)px;
            padding: 0 12px;
            border-radius: 6px;
            margin: 0 4px;
            color: \(text);
        }
        .link-plate-row:hover, .link-plate-row:focus { background-color: alpha(\(accent), 0.14); }
        .link-plate-title { color: \(text); \(t(.toolName)) }
        .link-plate-host { color: \(textDim); \(t(.treePath)) }
        .seam-line .seam-text { letter-spacing: 0; }
        .seam-line-press { min-height: 0; padding: 0 4px; border-radius: 4px; }
        .seam-line-press:hover { background-color: alpha(\(special), 0.12); }
        .picture-gallery { padding: 0; min-height: 0; min-width: 0; background: none; }
        .picture-gallery-tile {
            padding: 0;
            min-height: 0;
            min-width: 0;
            border: none;
            border-radius: 6px;
            background: none;
            box-shadow: none;
        }
        .picture-gallery-tile:hover { opacity: 0.86; }
        .picture-gallery-tile:active { opacity: 0.74; }
        .picture-gallery-scrim { background-color: alpha(black, 0.6); border-radius: 999px; }
        .picture-gallery-more { color: white; font-weight: 700; font-size: 13px; }
        .picture-gallery-waiting {
            border: 1px solid \(rule);
            border-radius: 6px;
            background-color: alpha(currentColor, 0.05);
        }
        .queued-row { padding: 2px 0; border-radius: 4px; }
        .queued-row .prompt-text { color: \(dimInk); }
        .queued-row:hover { background-color: alpha(\(accent), 0.07); }
        .prompt-rule.queued-rule {
            background-color: transparent;
            background-image: repeating-linear-gradient(
                to bottom, \(dimInk) 0px, \(dimInk) 4px, transparent 4px, transparent 8px);
        }
        .queued-hint { color: \(dimInk); \(t(.hint)) }
        .response-stat-glyph { color: \(dimInk); \(t(.responseStat)) }
        .response-stat-value { color: \(dimInk); \(t(.responseStat)) }
        .card-interrupted { border-left: 2px solid \(warn); }
        .card-retry { border-left: 2px solid \(warn); }
        .card-revert { border-left: 2px solid \(warn); }
        .retry-attempt { \(t(.rowStamp)) color: \(textDim); }
        .note-quiet { color: \(textDim); \(t(.note)) }
        .note-attention { color: \(warn); \(t(.note)) }
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

        .goal-line { color: \(special); \(t(.chip)) padding: 2px \(inset)px; }
        .banner-auth {
            background-color: \(canvasRaised);
            border-bottom: 2px solid \(warn);
            padding: 6px \(inset)px;
        }
        .banner-auth-text { color: \(text); \(t(.banner)) }
        .pill-row { padding: 0px \(inset)px 6px \(inset)px; }
        .pill-row.pill-row-place { padding-bottom: 2px; }
        button.chip-ctl, menubutton.chip-ctl > button {
            \(t(.chip))
            min-height: \(chipHeightEm);
            min-width: 0;
            padding: 0 \(chipPadding)px;
            background-image: none;
            background-color: \(controlFill);
            border: 1px solid \(rule);
            border-radius: 999px;
            color: \(text);
            box-shadow: none;
            text-shadow: none;
            outline: 2px solid transparent;
            outline-offset: 1px;
        }
        button.chip-ctl:hover, menubutton.chip-ctl > button:hover {
            border-color: \(accent);
            background-color: \(factFill);
        }
        button.chip-ctl:focus-visible, menubutton.chip-ctl > button:focus-visible {
            outline: 2px solid \(accent);
            outline-offset: 1px;
        }
        button.chip-ctl:disabled, menubutton.chip-ctl:disabled > button { color: \(dimInk); }
        button.chip-ctl > box, menubutton.chip-ctl > button > box { min-height: 0; }
        button.chip-ctl.chip-on, menubutton.chip-ctl.chip-on > button {
            color: \(palette.onAccent);
            background-color: \(accent);
            border-color: \(accent);
        }
        button.chip-ctl.chip-on:hover, menubutton.chip-ctl.chip-on:hover > button {
            background-color: \(accentDim);
            border-color: \(accentDim);
        }
        .chip-glyph { font-size: \(chipIconEm)em; }
        .carry-chip {
            \(t(.chip))
            padding: 2px 4px 2px 10px;
            background-color: \(controlFill);
            border: 1px solid \(rule);
            border-radius: 14px;
            color: \(text);
        }
        .carry-chip-text { color: \(text); }
        button.carry-chip-clear, button.carry-chip-clear:hover {
            min-height: 0;
            min-width: 0;
            padding: 0 6px;
            border: none;
            border-radius: 999px;
            box-shadow: none;
            background-image: none;
            background-color: transparent;
            color: \(textDim);
        }
        button.carry-chip-clear:hover { color: \(text); background-color: alpha(\(accent), 0.14); }
        .chip-gap { margin-left: \(chipGap)px; }
        .chip-tone-live { color: \(accent); }
        .chip-tone-attention { color: \(warn); }
        .chip-tone-danger { color: \(danger); }
        .chip-tone-quiet { color: \(dimInk); }
        button.chip-ctl.chip-on .chip-glyph { color: \(palette.onAccent); }
        .pill-row arrow { -gtk-icon-size: 8px; opacity: 0.4; }
        popover contents { background-color: \(canvasRaised); border: 1px solid \(rule); }

        .pill-row menubutton.dial-pill > button { padding: 0 \(chipPadding)px; }
        .pill-row menubutton.dial-pill > button arrow { margin-left: 2px; }
        .pill-row menubutton.dial-pill.dial-pill-power > button {
            background-image: \(rainbowWash(0.16));
            border-color: alpha(\(text), 0.3);
        }
        .lane-row button.chip-ctl { margin-left: 2px; }
        button.btn-primary, button.btn-quiet, button.btn-danger {
            \(t(.chip))
            min-height: \(decisiveHeightEm);
            min-width: 0;
            padding: 0 \(chipPadding + 4)px;
            background-image: none;
            border: 1px solid transparent;
            border-radius: 999px;
            box-shadow: none;
            text-shadow: none;
            font-weight: 600;
            outline: 2px solid transparent;
            outline-offset: 1px;
        }
        button.btn-primary { color: \(palette.onAccent); background-color: \(accent); }
        button.btn-primary:hover { background-color: \(accentDim); }
        button.btn-quiet {
            color: \(text);
            background-color: \(controlFill);
            border-color: \(rule);
        }
        button.btn-quiet:hover { border-color: \(accent); background-color: \(factFill); }
        button.btn-danger {
            color: \(danger);
            background-color: alpha(\(danger), 0.12);
            border-color: alpha(\(danger), 0.45);
        }
        button.btn-danger:hover { background-color: alpha(\(danger), 0.22); }
        button.btn-primary:focus-visible, button.btn-quiet:focus-visible,
        button.btn-danger:focus-visible {
            outline: 2px solid \(accent);
            outline-offset: 1px;
        }
        button.btn-primary:disabled, button.btn-quiet:disabled, button.btn-danger:disabled {
            color: \(dimInk);
            background-color: \(controlFill);
            border-color: \(rule);
        }
        .card button.btn-primary:disabled, .card button.btn-primary:disabled label { opacity: 1; }
        button.btn-quiet .btn-hint, button.btn-danger .btn-hint { font-weight: 400; color: \(dimInk); }
        button.btn-primary .btn-hint { font-weight: 400; color: \(palette.onAccent); opacity: 0.8; }
        .dial-dot { \(t(.hint)) color: \(textDim); }
        .dial-model { \(t(.chip)) color: \(text); }
        .dial-sep { color: \(textDim); opacity: 0.5; }
        .dial-effort { \(t(.chip)) font-weight: 700; color: \(text); }
        .dial-effort.dial-effort-server { font-weight: 400; color: \(dimInk); }
        .dial-effort.effort-low { font-weight: 400; }
        .dial-effort.effort-medium { font-weight: 600; }
        .dial-effort.effort-high { font-weight: 700; }
        .dial-effort.effort-xhigh { font-weight: 800; }
        .dial-effort.effort-max { font-weight: 800; }
        .dial-effort.effort-ultracode { font-weight: 800; }
        .dial-meter { margin-left: 2px; }
        .dial-bar {
            min-width: 4px;
            border-radius: 1px;
            background-color: alpha(\(textDim), 0.18);
        }
        .dial-bar-0 { min-height: 6px; }
        .dial-bar-1 { min-height: 8px; }
        .dial-bar-2 { min-height: 10px; }
        .dial-bar-3 { min-height: 12px; }
        .dial-bar-4 { min-height: 14px; }
        .dial-bar-lit { background-color: \(textDim); }
        .dial-bar-lit.dial-bar-ember {
            background-color: transparent;
            border: 1px solid alpha(\(textDim), 0.9);
            box-shadow: none;
        }
        .dial-pop contents { padding: 0; border-radius: 10px; }
        .dial-search {
            \(t(.composer))
            min-height: 0;
            padding: 3px 8px;
            border: 1px solid \(rule);
            border-radius: 6px;
            background-color: \(canvas);
            color: \(text);
        }
        .dial-search:focus-within { border-color: \(accent); }
        .dial-divider { background-color: \(rule); min-width: 1px; }
        .dial-section { \(t(.sectionLabel)) color: \(textDim); opacity: 0.75; }
        .dial-headline { \(t(.hint)) color: \(textDim); }
        .dial-pop button.dial-row, .dial-pop button.dial-rung {
            padding: 0;
            min-height: 0;
            border: 1px solid transparent;
            border-radius: 7px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .dial-pop button.dial-row:hover, .dial-pop button.dial-rung:hover {
            border-color: alpha(\(textDim), 0.4);
        }
        .dial-pop button.dial-row-cursor, .dial-pop button.dial-row-cursor:hover {
            background-color: alpha(\(accentDim), 0.14);
            border-color: alpha(\(accentDim), 0.45);
        }
        .dial-row-here .dial-title { font-weight: 700; color: \(text); }
        .dial-row-door .dial-title { color: \(accentDim); }
        .dial-star { \(t(.hint)) color: \(textDim); opacity: 0.5; }
        .dial-star-on { color: \(warn); opacity: 1; }
        .dial-title { \(t(.rowTitle)) color: \(text); }
        .dial-detail { \(t(.rowDetail)) color: \(textDim); }
        .dial-wall { \(t(.rowDetail)) color: \(danger); }
        .dial-chip {
            \(t(.badge))
            color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 4px;
            padding: 0 4px;
        }
        .dial-chip-local { color: \(special); border-color: alpha(\(special), 0.5); }
        .dial-rung-key { \(t(.hint)) color: \(textDim); opacity: 0.6; }
        .dial-rung-title { \(t(.rowTitle)) font-weight: 700; color: \(textDim); }
        .dial-rung-caption { \(t(.rowDetail)) color: \(textDim); opacity: 0.8; }
        .dial-rung-server .dial-rung-title { font-weight: 500; }
        .dial-pop button.dial-rung-current, .dial-pop button.dial-rung-current:hover {
            border-color: alpha(\(textDim), 0.6);
            background-color: alpha(\(textDim), 0.12);
        }
        .dial-pop button.dial-rung.effort-ultracode { background-image: \(rainbowWash(0.10)); }
        .dial-pop button.dial-rung.effort-ultracode.dial-rung-current {
            background-image: \(rainbowWash(0.22));
            border-color: alpha(\(text), 0.35);
        }
        .dial-hint { \(t(.hint)) color: \(textDim); opacity: 0.7; }
        .dial-row-dot { \(t(.hint)) color: \(textDim); }
        .dial-check { \(t(.hint)) color: \(accent); font-weight: 700; }
        .dial-row-level { margin-left: 4px; }
        .dial-level-word { \(t(.rowDetail)) color: \(text); }
        .dial-level-word.dial-level-server { color: \(textDim); }
        .dial-message-title { \(t(.rowTitle)) color: \(textDim); }
        .dial-message-detail { \(t(.rowDetail)) color: \(textDim); opacity: 0.8; }
        .dial-models, .dial-ladder { border-top: 2px solid transparent; }
        .dial-models.dial-column-active, .dial-ladder.dial-column-active {
            border-top-color: alpha(\(accent), 0.7);
        }
        .dial-ladder.dial-column-active .dial-section { color: \(accent); opacity: 1; }
        .dial-ladder-preview button.dial-rung { opacity: 0.82; }
        .dial-ladder-preview button.dial-rung-current { opacity: 1; }
        .dial-preview-tag {
            \(t(.badge))
            color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 4px;
            padding: 0 4px;
        }
        .dial-carry { \(t(.rowDetail)) color: \(text); }
        """
    }
}
