import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// Experts: the mark (a glyph on the expert's own hue, the same pair of colours the phone and
    /// the Mac draw), the sidebar's shelf, the lines that carry a tone, the chips a task starts
    /// with, and the debrief card at the end of a task. Every other colour is a palette slot.
    func expertRules() -> String {
        let hues = ExpertHue.allCases.map { hue -> String in
            let value = palette.isDark ? hue.rgb.dark : hue.rgb.light
            let colour = String(format: "#%06X", value)
            let ink = hue.wantsDarkGlyph ? "#1d1d1f" : "#ffffff"
            return ".expert-hue-\(hue.rawValue) { background-image: linear-gradient(160deg, \(colour), shade(\(colour), 0.74)); color: \(ink); }"
        }.joined(separator: "\n")
        return """
        .expert-mark {
            font-weight: 700;
            border-radius: 7px;
            min-width: 22px;
            min-height: 22px;
            padding: 0;
            font-size: 0.78em;
        }
        .expert-mark-tiny { min-width: 16px; min-height: 16px; border-radius: 5px; font-size: 0.6em; }
        .expert-mark-row { min-width: 28px; min-height: 28px; border-radius: 8px; font-size: 0.82em; }
        .expert-mark-large { min-width: 54px; min-height: 54px; border-radius: 15px; font-size: 1.45em; }
        \(hues)
        .expert-hue-picked { outline: 2px solid \(accent); outline-offset: 1px; border-radius: 10px; }
        .expert-tone-quiet { color: \(textDim); }
        .expert-tone-active { color: \(info); }
        .expert-tone-attention { color: \(warn); }
        .expert-tone-failing { color: \(danger); }
        .expert-tone-good { color: alpha(\(accent), 0.9); }
        .expert-line-active .subtitle { color: \(info); opacity: 1; }
        .expert-line-attention .subtitle { color: \(warn); opacity: 1; }
        .expert-line-failing .subtitle { color: \(danger); opacity: 1; }
        .expert-line-good .subtitle { color: alpha(\(accent), 0.9); opacity: 1; }
        .expert-shelf { border-top: 1px solid alpha(currentColor, 0.15); padding: 4px 6px 6px 6px; }
        .expert-shelf-heading { \(t(.sectionLabel)) color: \(textDim); padding: 2px 4px; }
        .expert-shelf-row { padding: 3px 4px; border-radius: 8px; }
        .expert-shelf-row:hover { background-color: alpha(currentColor, 0.05); }
        .expert-shelf-name { \(t(.rowTitle)) color: \(text); }
        .expert-shelf-state { \(t(.rowMeta)) }
        .expert-badge {
            \(t(.badge))
            background-color: \(accent);
            color: \(palette.onAccent);
            border-radius: 999px;
            padding: 0 6px;
            min-width: 10px;
        }
        .expert-head-name { \(t(.headline)) color: \(text); }
        .expert-head-purpose { \(t(.rowDetail)) color: \(textDim); }
        .expert-meta {
            \(t(.rowMeta)) color: \(textDim);
            background-color: alpha(\(text), 0.06);
            border-radius: 999px;
            padding: 2px 10px;
        }
        .expert-chip {
            \(t(.chip)) color: \(text);
            background-color: alpha(\(text), 0.07);
            border-radius: 999px;
            padding: 3px 11px;
        }
        .expert-chip.expert-tone-good { color: alpha(\(accent), 0.95); }
        .expert-chip.expert-tone-active { color: \(info); }
        .expert-chip.expert-tone-attention { color: \(warn); }
        .expert-chip.expert-tone-failing { color: \(danger); }
        .expert-starts { \(t(.cardTitle)) color: \(text); }
        .expert-tokens { \(t(.hint)) color: \(textDim); }
        .expert-handover { \(t(.rowDetail)) color: \(text); background-color: alpha(\(info), 0.12); border-radius: 10px; padding: 8px 12px; }
        .expert-card {
            padding: 12px 0 6px 0;
            border-radius: 14px;
            border: 1px solid \(rule);
            background-color: \(canvasRaised);
        }
        .expert-card-attention { border-color: alpha(\(warn), 0.45); }
        .expert-card-failing { border-color: alpha(\(danger), 0.5); }
        .expert-card-headline { \(t(.cardTitle)) color: \(text); }
        .expert-card-detail { \(t(.rowMeta)) color: \(textDim); }
        .expert-journal {
            background-color: alpha(\(text), 0.05);
            border-radius: 10px;
            padding: 8px 10px;
        }
        .expert-journal-title { \(t(.rowTitleStrong)) color: \(text); }
        .expert-journal-body { \(t(.rowDetail)) color: \(textDim); }
        .expert-proposal { padding: 8px 14px; border-top: 1px solid alpha(\(rule), 0.8); }
        .expert-proposal-title { \(t(.rowTitle)) color: \(text); }
        .expert-proposal-summary { \(t(.rowDetail)) color: \(textDim); }
        .expert-proposal-reason { \(t(.rowNote)) color: \(textDim); font-style: italic; }
        .expert-proposal-done { opacity: 0.55; }
        .expert-op {
            \(t(.badge))
            border-radius: 5px;
            padding: 0 6px;
            font-weight: 700;
        }
        .expert-op-add { color: alpha(\(accent), 0.95); background-color: alpha(\(accent), 0.16); }
        .expert-op-change { color: \(info); background-color: alpha(\(info), 0.16); }
        .expert-op-retire { color: \(textDim); background-color: alpha(\(text), 0.08); }
        .expert-stale {
            \(t(.badge))
            color: \(warn);
            background-color: alpha(\(warn), 0.16);
            border-radius: 5px;
            padding: 0 5px;
        }
        .expert-outline-value { color: \(text); }
        .expert-name-entry { font-weight: 700; }
        .expert-skill-detail { font-size: 0.86em; }
        .expert-mark-button > button { padding: 3px; border-radius: 18px; }
        .expert-draft-row .title { color: \(accent); }
        .expert-note-retired { opacity: 0.55; }
        .expert-note-retired .title { text-decoration: line-through; }
        """
    }
}
