import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// The agents board: its window, the cards that wait on a person, the rows that work, the peek
    /// beside them and the sidebar's entry. Every colour is one of the palette's tone slots, and
    /// every size one of the type roles the rest of the app scales, so a larger type setting
    /// reaches the board with the transcript.
    func agentsRules() -> String {
        return """
        .agents-window { background-color: \(canvas); color: \(text); }
        .agents-sentence { \(t(.headline)) color: \(text); }
        .agents-watch { \(t(.rowMeta)) color: \(textDim); }
        .agents-empty { \(t(.cardBody)) color: \(textDim); padding: 18px 2px; }
        .agents-note { \(t(.rowDetail)) color: \(textDim); }
        .agents-section {
            \(t(.sectionLabel)) color: \(textDim);
            padding: 2px 4px;
        }
        .agents-section-needs { color: \(warn); }
        .agents-section-side { \(t(.rowMeta)) color: \(textDim); }
        .agents-machine {
            \(t(.rowMeta)) color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 2px 10px;
        }
        .agents-machine-off { color: \(danger); border-color: alpha(\(danger), 0.5); }
        .agents-machine-name { \(t(.rowMeta)) color: \(textDim); }
        .agents-card {
            padding: 14px 16px;
            border-radius: 12px;
            border: 1px solid \(rule);
            background-color: alpha(\(text), 0.04);
        }
        .agents-card-needs {
            border-color: alpha(\(warn), 0.55);
            background-color: alpha(\(warn), 0.07);
        }
        .agents-card.agents-selected { box-shadow: 0 0 0 2px alpha(\(accent), 0.7); }
        button.agents-card-head {
            padding: 0;
            min-height: 0;
            background: none;
            box-shadow: none;
            border: none;
        }
        button.agents-card-head:hover { background-color: alpha(\(text), 0.04); }
        .agents-lead { \(t(.cardTitle)) color: \(warn); }
        .agents-meta { \(t(.rowMeta)) color: \(textDim); }
        .agents-object {
            \(t(.toolOutput)) color: \(text);
            background-color: alpha(\(canvas), 0.7);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 8px 10px;
        }
        .agents-added { \(t(.rowStamp)) color: \(accent); font-weight: 700; }
        .agents-removed { \(t(.rowStamp)) color: \(danger); font-weight: 700; }
        .agents-error { \(t(.rowDetail)) color: \(danger); }
        button.agents-approve, button.agents-deny, button.agents-option, button.agents-watch-button,
        button.agents-open, button.agents-stop, button.agents-nudge {
            \(t(.control)) padding: 6px 16px; border-radius: 10px; min-height: 0;
        }
        button.agents-stop label { color: \(danger); }
        button.agents-stop:disabled label { color: \(textDim); }
        button.agents-close { min-width: 24px; min-height: 24px; padding: 0; color: \(textDim); }
        .agents-away { opacity: 0.55; }
        .agents-glyph { \(t(.rowTitle)) }
        .agents-row {
            padding: 8px 10px;
            border-radius: 10px;
            border: 1px solid transparent;
            background-color: transparent;
            box-shadow: none;
            min-height: 0;
        }
        .agents-row:hover { background-color: alpha(\(text), 0.05); }
        .agents-row.agents-selected {
            background-color: alpha(\(accent), 0.1);
            border-color: alpha(\(accent), 0.45);
        }
        .agents-row:focus-visible { outline: 2px solid \(accent); outline-offset: 1px; }
        .agents-title { \(t(.rowTitle)) color: \(text); font-weight: 600; }
        .agents-elapsed { \(t(.rowStamp)) color: \(textDim); }
        .agents-line { \(t(.rowDetail)) color: \(text); opacity: 0.85; }
        .agents-word { \(t(.rowMeta)) color: \(textDim); font-style: italic; }
        .agents-folded {
            \(t(.rowMeta)) color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 1px 10px;
        }
        .agents-child { padding: 2px 0; }
        .agents-child-words { \(t(.rowDetail)) color: \(text); }
        progressbar.agents-todos trough { min-height: 4px; background-color: alpha(\(text), 0.15); border-radius: 2px; }
        progressbar.agents-todos progress { min-height: 4px; background-color: \(accent); border-radius: 2px; }
        .agents-unread { min-width: 8px; min-height: 8px; border-radius: 4px; background-color: \(info); }
        .agents-inspector { background-color: \(canvasRaised); border-left: 1px solid \(rule); }
        .agents-peek-title { \(t(.cardTitle)) color: \(text); }
        .agents-peek-section { \(t(.sectionLabel)) color: \(textDim); }
        .agents-doing { \(t(.headline)) color: \(text); }
        .agents-step { \(t(.rowDetail)) color: \(text); }
        .agents-chip {
            \(t(.rowMeta)) color: \(text);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 2px 10px;
            background-color: alpha(\(text), 0.05);
        }
        .agents-meter {
            padding: 10px 12px;
            border-radius: 10px;
            background-color: alpha(\(text), 0.05);
        }
        .agents-meter-value { \(t(.cardTitle)) color: \(text); }
        .agents-meter-caption { \(t(.rowMeta)) color: \(textDim); }
        .agents-hour { \(t(.rowDetail)) }
        \(agentsEntryRules())
        """
    }
}

extension MatrixStylesheet {
    /// The sidebar's Agents card and the "2 agents" chip of a working row. The card is a rounded
    /// surface with a soft gradient and a one pixel edge in the mood's own tone; under the pointer
    /// it lifts a little, pressed it dips, ringed for the keyboard. The amber light that breathes
    /// along a waiting card's edge is painted over it, inside the same rounded rectangle.
    func agentsEntryRules() -> String {
        return """
        .agents-entry-frame { border-radius: 12px; }
        button.agents-entry {
            padding: 8px 10px;
            min-height: 0;
            border-radius: 12px;
            border: 1px solid \(rule);
            box-shadow: 0 1px 0 alpha(\(text), 0.05);
            background-color: transparent;
            background-image: linear-gradient(180deg, alpha(\(text), 0.06), alpha(\(text), 0.015));
            transition: transform 140ms ease-out, box-shadow 160ms ease-out, border-color 200ms ease-out;
        }
        button.agents-entry:hover {
            transform: translateY(-1px);
            border-color: alpha(\(text), 0.4);
            box-shadow: 0 5px 12px alpha(\(text), 0.14);
        }
        button.agents-entry:active { transform: translateY(1px) scale(0.99); box-shadow: none; }
        button.agents-entry.agents-entry-working {
            border-color: alpha(\(accent), 0.45);
            background-image: linear-gradient(180deg, alpha(\(accent), 0.18), alpha(\(accent), 0.05));
        }
        button.agents-entry.agents-entry-working:hover {
            border-color: alpha(\(accent), 0.85);
            box-shadow: 0 5px 14px alpha(\(accent), 0.28);
        }
        button.agents-entry.agents-entry-needs {
            border-color: alpha(\(warn), 0.65);
            background-image: linear-gradient(180deg, alpha(\(warn), 0.22), alpha(\(warn), 0.06));
        }
        button.agents-entry.agents-entry-needs:hover {
            border-color: alpha(\(warn), 0.95);
            box-shadow: 0 5px 14px alpha(\(warn), 0.32);
        }
        button.agents-entry:focus-visible { outline: 2px solid \(accent); outline-offset: 2px; }
        .agents-entry-title { \(t(.rowTitle)) color: \(text); font-weight: 700; }
        .agents-entry-sentence { \(t(.toolDetail)) color: \(textDim); }
        .agents-entry-working .agents-entry-sentence { color: \(text); opacity: 0.8; }
        .agents-entry-needs .agents-entry-sentence { color: \(warn); font-weight: 600; }
        button.row-agents {
            padding: 0 7px;
            min-height: 0;
            min-width: 0;
            border-radius: 999px;
            border: 1px solid alpha(\(accent), 0.5);
            background-image: none;
            background-color: alpha(\(accent), 0.1);
            box-shadow: none;
        }
        button.row-agents:hover { background-color: alpha(\(accent), 0.24); border-color: \(accent); }
        button.row-agents:active { background-color: alpha(\(accent), 0.34); }
        .row-agents-label { \(t(.rowMeta)) color: \(accent); font-weight: 600; }
        """
    }
}
