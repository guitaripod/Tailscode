import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// The keys of the Keyboard page drawn as caps: a raised, mono cap with a heavier foot so it
    /// reads as something pressed, the quiet words between them, and the card the capture dialog
    /// listens with.
    func keycapRules() -> String {
        return """
        label.keycap {
            \(t(.rowMeta))
            color: \(text);
            min-width: 22px;
            padding: 1px 7px;
            border-radius: 6px;
            border: 1px solid alpha(\(text), 0.28);
            border-bottom-width: 2px;
            background-color: alpha(\(text), 0.06);
        }
        label.keycap-bad {
            color: \(danger);
            border-color: alpha(\(danger), 0.6);
            background-color: alpha(\(danger), 0.1);
        }
        label.keycap-then, label.keycap-or {
            \(t(.rowNote))
            color: \(textDim);
            padding: 0 2px;
        }
        label.keycap-unset {
            \(t(.rowNote))
            color: \(textDim);
            padding: 0 2px;
        }
        .key-capture label.keycap {
            padding: 3px 11px;
            min-width: 30px;
            border-radius: 7px;
        }
        .key-capture {
            border: 1px dashed alpha(\(text), 0.35);
            border-radius: 10px;
            padding: 18px;
            min-height: 72px;
            background-color: alpha(\(text), 0.03);
            outline: none;
        }
        .key-capture:focus-within, .key-capture-live {
            border-color: \(accent);
            background-color: alpha(\(accent), 0.06);
        }
        .key-capture:focus-within { border-style: solid; }
        label.key-capture-prompt {
            \(t(.rowDetail))
            color: \(textDim);
        }
        label.key-capture-bad { color: \(danger); }
        """
    }
}
