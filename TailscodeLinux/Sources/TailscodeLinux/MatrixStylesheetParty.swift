import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// The party: six cards on a raised popover. The house's hue reaches the ring, the glow, the
    /// chord and the name's underline through the same identity classes the pill's dot wears, so a
    /// model is one colour wherever it is drawn.
    func partyRules() -> String {
        let tinted = MatrixTheme.modelIdentityPairs(for: palette).map { pair in
            """
            .party-card-use.\(pair.cls) {
                border-color: \(pair.hex);
                box-shadow: inset 0 0 0 1px \(pair.hex), 0 0 18px alpha(\(pair.hex), 0.38);
            }
            .party-chord.\(pair.cls) { color: \(pair.hex); }
            """
        }.joined(separator: "\n")
        return """
        .party-pop contents { padding: 0; border-radius: 18px; }
        .party-head { font-size: 15px; font-weight: 700; color: \(text); }
        .party-count { font-size: 12px; color: \(textDim); }
        .party-count.party-note { font-weight: 600; color: \(accent); }
        button.party-edit {
            min-height: 0;
            padding: 4px 12px;
            border-radius: 8px;
            border: 1px solid \(rule);
            background-color: alpha(\(text), 0.06);
            background-image: none;
            box-shadow: none;
            color: \(text);
            font-size: 12px;
            font-weight: 600;
        }
        button.party-edit:hover { background-color: alpha(\(text), 0.12); }
        .party-cell { padding: 0; }
        .party-card {
            padding: 12px;
            min-height: 0;
            min-width: 0;
            border-radius: 16px;
            border: 1px solid \(rule);
            background-color: alpha(\(text), 0.04);
            background-image: none;
            box-shadow: none;
            outline: none;
            transition: border-color 120ms ease-out, background-color 120ms ease-out;
        }
        button.party-card:hover { border-color: alpha(\(text), 0.32); background-color: alpha(\(text), 0.07); }
        button.party-card:focus-visible { outline: 2px solid \(accent); outline-offset: 1px; }
        button.party-card-hollow {
            border: 1.5px dashed alpha(\(text), 0.3);
            background-color: transparent;
        }
        button.party-card-hollow:hover { border-color: alpha(\(text), 0.55); }
        .party-card-hollow-edit { border-color: alpha(\(accent), 0.6); }
        .party-plus {
            min-width: 36px;
            min-height: 36px;
            border-radius: 999px;
            border: 1.5px solid alpha(\(text), 0.5);
            color: alpha(\(text), 0.75);
            font-size: 22px;
            font-weight: 300;
        }
        .party-hollow-word { font-size: 12px; font-weight: 500; color: \(textDim); }
        .party-title { font-size: 15px; font-weight: 600; color: \(text); }
        .party-sub { font-size: 12px; font-weight: 400; color: \(textDim); }
        .party-chord { font-family: monospace; font-size: 9.5px; font-weight: 400; letter-spacing: 0.02em; color: \(textDim); }
        .party-machine {
            font-size: 11px;
            font-weight: 500;
            color: \(textDim);
            background-color: alpha(\(text), 0.08);
            border-radius: 999px;
            padding: 1px 8px;
        }
        .party-card-away { opacity: 0.45; }
        .party-card-lifted {
            border-color: alpha(\(text), 0.55);
            background-color: \(canvasRaised);
            box-shadow: 0 12px 28px alpha(#000000, 0.55);
        }
        .party-card-drop { border-color: \(accent); background-color: alpha(\(accent), 0.14); }
        .party-name, .party-name:focus {
            min-height: 0;
            padding: 0 0 2px 0;
            margin: 0;
            border: none;
            border-bottom: 1px solid alpha(\(text), 0.7);
            border-radius: 0;
            background: none;
            box-shadow: none;
            outline: none;
            color: \(text);
            font-size: 15px;
            font-weight: 600;
        }
        .party-name:focus-within { border-bottom-color: \(accent); }
        button.party-ball-button {
            padding: 0;
            min-width: 0;
            min-height: 0;
            border: none;
            border-radius: 999px;
            background: none;
            box-shadow: none;
        }
        button.party-ball-button:hover { background-color: alpha(\(text), 0.12); }
        button.party-ball-button:focus-visible { outline: 2px solid \(accent); outline-offset: 1px; }
        button.party-badge {
            min-width: 24px;
            min-height: 24px;
            padding: 0;
            border-radius: 999px;
            border: 1px solid alpha(\(text), 0.4);
            background-color: \(canvasRaised);
            background-image: none;
            box-shadow: 0 2px 6px alpha(#000000, 0.4);
            color: \(text);
        }
        button.party-badge:hover { background-color: \(danger); border-color: \(danger); }
        .party-badge-glyph { font-size: 11px; font-weight: 700; }
        .party-hint { font-size: 12px; color: \(textDim); }
        .party-recent { font-size: 12px; color: \(textDim); }
        button.party-chip {
            min-height: 0;
            padding: 3px 10px;
            border-radius: 14px;
            border: 1px solid \(rule);
            background-color: alpha(\(text), 0.05);
            background-image: none;
            box-shadow: none;
            color: \(text);
        }
        button.party-chip:hover { border-color: alpha(\(text), 0.4); }
        .party-chip-word { font-size: 12px; color: \(text); }
        .party-chip-machine { font-size: 11px; color: \(textDim); }
        button.party-all { padding: 2px 8px; min-height: 0; }
        .party-all-word { font-size: 12px; font-weight: 600; color: \(accent); }
        \(tinted)
        """
    }
}
