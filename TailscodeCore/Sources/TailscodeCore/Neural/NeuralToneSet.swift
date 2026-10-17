import Foundation

/// Which of the two tone sets an element of the open row or the card is painted in. The head is
/// drawn dark in every theme, so what sits on it (zone lights, nodes, rings, the eye) wears the
/// lifted tones the stage overrides the theme with; what sits on the transcript's canvas (the
/// leader and its tab, chips, text, bars, ticks, the card's edge) wears the theme's corrected
/// palette, because on a light theme such as Dawn a lifted leader vanishes on cream.
public enum NeuralToneSet: Sendable, Equatable {
    case corrected
    case lifted

    /// The things that wear a tone.
    public enum Element: Sendable, CaseIterable {
        case cardLight
        case cardRing
        case eye
        case node
        case nodeRing
        case stageLight
        case leader
        case leaderTab
        case leaderDot
        case chip
        case text
        case bar
        case tick
        case edge
        case diffWash
    }

    public static func set(for element: Element) -> NeuralToneSet {
        switch element {
        case .cardLight, .cardRing, .eye, .node, .nodeRing, .stageLight: return .lifted
        case .leader, .leaderTab, .leaderDot, .chip, .text, .bar, .tick, .edge, .diffWash:
            return .corrected
        }
    }
}
