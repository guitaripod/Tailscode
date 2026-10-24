import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    func transcriptRules() -> String {
        return """
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
        .model-chip-strip > flowboxchild {
            padding: 0;
            margin: 0 6px 4px 0;
            background: none;
            outline: none;
        }
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
        .model-star {
            padding: 0 6px;
            min-height: 0;
            border: none;
            border-radius: 4px;
            background-color: transparent;
            background-image: none;
            box-shadow: none;
        }
        .model-star:hover { background-color: alpha(\(accent), 0.16); }
        .model-star-glyph { color: \(textDim); font-size: \(c(0.9)); }
        .model-refresh-glyph { font-size: \(c(0.9)); }
        .model-row-current .model-star-glyph { color: \(accent); }
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
        .model-machine-dot { \(t(.hint)) }
        .model-consequence { color: \(warn); \(t(.hint)) }
        .model-wall { color: \(danger); \(t(.hint)) }
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
            border-radius: 6px;
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
        headerbar menubutton.ask-dial > button {
            padding: 1px 9px 1px 8px;
            border-radius: 999px;
            border: 1px solid alpha(\(textDim), 0.28);
            background-color: transparent;
            background-image: none;
            box-shadow: none;
        }
        headerbar menubutton.ask-dial > button:hover { border-color: \(accent); }
        headerbar menubutton.ask-dial.dial-pill-power > button {
            background-image: \(rainbowWash(0.16));
            border-color: alpha(\(text), 0.3);
        }
        .ask-aim-segment {
            \(t(.chip))
            color: \(textDim);
            padding: 3px 10px;
            border: 1px solid alpha(\(textDim), 0.28);
            background: none;
        }
        .ask-aim-segment:hover { color: \(accent); }
        .ask-aim-segment:checked {
            color: \(accent);
            background-color: alpha(\(accent), 0.14);
            border-color: alpha(\(accent), 0.7);
        }
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
        .ask-tile {
            padding: 9px 10px 9px 9px;
            border: 1px solid alpha(\(textDim), 0.16);
            border-radius: 8px;
            background-color: alpha(\(text), 0.025);
            background-image: none;
            box-shadow: none;
            outline: none;
        }
        .ask-tile:hover { border-color: alpha(\(accent), 0.55); background-color: alpha(\(accent), 0.08); }
        .ask-tile:active { background-color: alpha(\(accent), 0.16); }
        .ask-tile-glyph {
            \(t(.rowTitleStrong))
            color: \(accent);
            background-color: alpha(\(accent), 0.12);
            border-radius: 7px;
            min-width: 30px;
            min-height: 30px;
        }
        .ask-tile:hover .ask-tile-glyph { background-color: alpha(\(accent), 0.22); }
        .ask-tile-title { \(t(.rowTitleStrong)) color: \(text); }
        .ask-tile-detail { \(t(.rowDetail)) color: \(textDim); opacity: 0.72; }
        .ask-tile:hover .ask-tile-detail { opacity: 0.9; }
        .ask-tile .ask-keycap { padding: 0 5px; }
        .ask-tile:hover .ask-keycap { color: \(accent); border-color: alpha(\(accent), 0.55); opacity: 1; }
        .ask-copied {
            padding: 10px 12px 12px 12px;
            border: 1px solid alpha(\(accent), 0.30);
            border-left: 3px solid \(accent);
            border-radius: 8px;
            background-color: alpha(\(accent), 0.06);
        }
        .ask-copied-head { \(t(.sectionLabel)) color: \(accent); }
        .ask-copied-close {
            \(t(.chip))
            color: \(textDim);
            min-height: 0;
            min-width: 0;
            padding: 0 6px;
            border-radius: 6px;
        }
        .ask-copied-close:hover { color: \(text); background-color: alpha(\(text), 0.08); }
        .ask-copied-preview { \(t(.rowDetail)) color: \(text); opacity: 0.8; }
        .ask-errand {
            \(t(.chip))
            color: \(text);
            padding: 3px 8px 3px 10px;
            border-radius: 999px;
            border: 1px solid alpha(\(accent), 0.35);
            background-color: transparent;
            background-image: none;
            box-shadow: none;
        }
        .ask-errand:hover { border-color: \(accent); background-color: alpha(\(accent), 0.14); }
        .ask-errand:active { background-color: alpha(\(accent), 0.22); }
        .ask-errand-glyph { color: \(accent); }
        .ask-errand .ask-keycap { padding: 0 4px; }

        .tree-row { \(t(.treeRow)) color: \(text); }
        .tree-dir { color: \(info); \(t(.treeRow)) }
        .tree-path { color: \(textDim); \(t(.treePath)) }

        .code-header { color: \(textDim); \(t(.codeLabel)) }
        .code-copy { color: \(info); \(t(.codeAction)) padding: 0 6px; }
        .code-body { \(t(.code)) color: \(text); }
        .tool-output { \(t(.toolOutput)) color: \(textDim); }
        .reasoning-body { color: \(textDim); \(t(.thought)) }
        .disclosure { padding: 0; min-height: \(flat)px; }
        .disclosure:hover { background-color: \(canvasRaised); }
        .disclosure-chevron { color: \(textDim); \(t(.note)) }
        .reasoning-label { color: \(textDim); \(t(.thoughtLabel)) }
        .disclosure:hover .disclosure-chevron { color: \(accent); }

        .card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: \(Int(ChatChrome.Radius.card))px;
            box-shadow: none;
            padding: 12px 16px;
        }
        .card-permission { border-left: 2px solid \(warn); }
        .card-question { border-left: 2px solid \(warn); }
        .card-title { \(t(.cardTitle)) color: \(text); }
        .card-title.pending-text-failed { color: \(danger); }
        .update-link { padding: 2px 0; min-height: 0; min-width: 0; }
        .update-heading { \(t(.sectionLabel)) opacity: 0.5; padding: 6px 0 0 0; }
        button.answer-option, button.answer-option:hover { font-weight: 500; }
        button.answer-option.answer-selected, button.answer-option.answer-selected:hover {
            border-color: \(accent);
            background-color: alpha(\(accent), 0.12);
            box-shadow: inset 0 0 0 1px \(accent);
        }

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
        .model-seam-text { color: \(text); \(t(.note)) }
        .carried-text, .carried-glyph { color: \(textDim); \(t(.note)) }
        .carried-line, .carried-line:hover {
            min-height: 0;
            padding: 0 4px;
            border: none;
            border-radius: 4px;
            box-shadow: none;
            background-color: transparent;
        }
        .carried-line:hover { background-color: alpha(\(special), 0.12); }
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
        """
    }
}
