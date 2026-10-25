import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// What Settings draws that nothing else does: the theme cards and the type preview. The
    /// preview's samples are set from the same roles the window sets its own text from, which is
    /// the whole point of having one — a sample that drifted from the real thing would be a
    /// promise the slider could not keep.
    func settingsRules() -> String {
        let shell = String(format: "%.3f", Preferences.terminalScale)
        return """
        button.theme-swatch {
            padding: 6px 6px 8px 6px;
            border-radius: 14px;
            border: 2px solid transparent;
            background-image: none;
            background-color: transparent;
            box-shadow: none;
        }
        button.theme-swatch:hover { background-color: alpha(\(text), 0.05); }
        button.theme-swatch-selected { border-color: \(accent); background-color: alpha(\(accent), 0.08); }
        .theme-swatch-name { \(t(.panelLabel)) }
        .theme-caption { font-size: 0.9em; color: \(textDim); }
        .type-preview {
            background-color: \(canvasRaised);
            border: 1px solid alpha(\(textDim), 0.22);
            border-radius: 12px;
            padding: 14px 16px;
        }
        .type-sample-chat { \(t(.rowTitleStrong)) }
        .type-sample-chat-detail { \(t(.rowDetail)) color: \(textDim); }
        .type-sample-prompt { \(t(.prompt)) }
        .type-sample-answer { \(t(.answer)) }
        .type-sample-tool { \(t(.toolName)) }
        .type-sample-code { \(t(.code)) }
        .type-sample-shell { font-family: monospace; font-size: \(shell)rem; color: \(textDim); }
        .type-value { font-feature-settings: "tnum"; min-width: 44px; }
        """
    }
}
