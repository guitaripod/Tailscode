import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// Masters: the mark (a glyph on the master's own hue, the same pair of colours the phone and
    /// the Mac draw), the sidebar's shelf, the lines that carry a tone, the chips a task starts
    /// with, and the debrief card at the end of a task. Every other colour is a palette slot.
    func masterRules() -> String {
        let hues = MasterHue.allCases.map { hue -> String in
            let value = palette.isDark ? hue.rgb.dark : hue.rgb.light
            let colour = String(format: "#%06X", value)
            let ink = hue.wantsDarkGlyph ? "#1d1d1f" : "#ffffff"
            return ".master-hue-\(hue.rawValue) { background-image: linear-gradient(160deg, \(colour), shade(\(colour), 0.74)); color: \(ink); }"
        }.joined(separator: "\n")
        return """
        .master-mark {
            font-weight: 700;
            border-radius: 7px;
            min-width: 22px;
            min-height: 22px;
            padding: 0;
            font-size: 0.78em;
        }
        .master-mark-tiny { min-width: 16px; min-height: 16px; border-radius: 5px; font-size: 0.6em; }
        .master-mark-row { min-width: 28px; min-height: 28px; border-radius: 8px; font-size: 0.82em; }
        .master-mark-large { min-width: 54px; min-height: 54px; border-radius: 15px; font-size: 1.45em; }
        \(hues)
        .master-hue-picked { outline: 2px solid \(accent); outline-offset: 1px; border-radius: 10px; }
        .master-tone-quiet { color: \(textDim); }
        .master-tone-active { color: \(info); }
        .master-tone-attention { color: \(warn); }
        .master-tone-failing { color: \(danger); }
        .master-tone-good { color: alpha(\(accent), 0.9); }
        .master-line-active .subtitle { color: \(info); opacity: 1; }
        .master-line-attention .subtitle { color: \(warn); opacity: 1; }
        .master-line-failing .subtitle { color: \(danger); opacity: 1; }
        .master-line-good .subtitle { color: alpha(\(accent), 0.9); opacity: 1; }
        .master-shelf { border-top: 1px solid alpha(currentColor, 0.15); padding: 4px 6px 6px 6px; }
        .master-shelf-heading { \(t(.sectionLabel)) color: \(textDim); padding: 2px 4px; }
        .master-shelf-row { padding: 3px 4px; border-radius: 8px; }
        .master-shelf-row:hover { background-color: alpha(currentColor, 0.05); }
        .master-shelf-name { \(t(.rowTitle)) color: \(text); }
        .master-shelf-state { \(t(.rowMeta)) }
        .master-badge {
            \(t(.badge))
            background-color: \(accent);
            color: \(palette.onAccent);
            border-radius: 999px;
            padding: 0 6px;
            min-width: 10px;
        }
        .master-head-name { \(t(.headline)) color: \(text); }
        .master-head-purpose { \(t(.rowDetail)) color: \(textDim); }
        .master-meta {
            \(t(.rowMeta)) color: \(textDim);
            background-color: alpha(\(text), 0.06);
            border-radius: 999px;
            padding: 2px 10px;
        }
        .master-chip {
            \(t(.chip)) color: \(text);
            background-color: alpha(\(text), 0.07);
            border-radius: 999px;
            padding: 3px 11px;
        }
        .master-chip.master-tone-good { color: alpha(\(accent), 0.95); }
        .master-chip.master-tone-active { color: \(info); }
        .master-chip.master-tone-attention { color: \(warn); }
        .master-chip.master-tone-failing { color: \(danger); }
        .master-starts { \(t(.cardTitle)) color: \(text); }
        .master-tokens { \(t(.hint)) color: \(textDim); }
        .master-handover { \(t(.rowDetail)) color: \(text); background-color: alpha(\(info), 0.12); border-radius: 10px; padding: 8px 12px; }
        .master-card {
            padding: 12px 0 6px 0;
            border-radius: 14px;
            border: 1px solid \(rule);
            background-color: \(canvasRaised);
        }
        .master-card-attention { border-color: alpha(\(warn), 0.45); }
        .master-card-failing { border-color: alpha(\(danger), 0.5); }
        .master-card-headline { \(t(.cardTitle)) color: \(text); }
        .master-card-detail { \(t(.rowMeta)) color: \(textDim); }
        .master-journal {
            background-color: alpha(\(text), 0.05);
            border-radius: 10px;
            padding: 8px 10px;
        }
        .master-journal-title { \(t(.rowTitleStrong)) color: \(text); }
        .master-journal-body { \(t(.rowDetail)) color: \(textDim); }
        .master-proposal { padding: 8px 14px; border-top: 1px solid alpha(\(rule), 0.8); }
        .master-proposal-title { \(t(.rowTitle)) color: \(text); }
        .master-proposal-summary { \(t(.rowDetail)) color: \(textDim); }
        .master-proposal-reason { \(t(.rowNote)) color: \(textDim); font-style: italic; }
        .master-proposal-done { opacity: 0.55; }
        .master-op {
            \(t(.badge))
            border-radius: 5px;
            padding: 0 6px;
            font-weight: 700;
        }
        .master-op-add { color: alpha(\(accent), 0.95); background-color: alpha(\(accent), 0.16); }
        .master-op-change { color: \(info); background-color: alpha(\(info), 0.16); }
        .master-op-retire { color: \(textDim); background-color: alpha(\(text), 0.08); }
        .master-stale {
            \(t(.badge))
            color: \(warn);
            background-color: alpha(\(warn), 0.16);
            border-radius: 5px;
            padding: 0 5px;
        }
        .master-outline-value { color: \(text); }
        .master-name-entry { font-weight: 700; }
        .master-skill-detail { font-size: 0.86em; }
        .master-mark-button > button { padding: 3px; border-radius: 18px; }
        .master-draft-row .title { color: \(accent); }
        .master-note-retired { opacity: 0.55; }
        .master-note-retired .title { text-decoration: line-through; }
        """
    }
}
