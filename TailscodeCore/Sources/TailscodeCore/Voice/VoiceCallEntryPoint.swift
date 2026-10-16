import Foundation

/// The control that starts and ends a call, in the style of every other entry point: a symbol for
/// the Apple clients, one column for the text ones, and a tooltip and a spoken name that say what
/// is true of this server's gateway.
public enum VoiceCallEntryPoint {
    public static var title: String { VoiceCallReading.name }

    public static var symbol: String { "waveform" }

    public static var glyph: String { "~" }

    public static func label(active: Bool) -> String { VoiceCallReading.buttonLabel(active: active) }

    public static func tooltip(reach: VoiceReach, active: Bool = false) -> String {
        VoiceCallReading.tooltip(reach: reach, active: active)
    }

    public static func accessibilityLabel(reach: VoiceReach, active: Bool) -> String {
        VoiceCallReading.accessibility(reach: reach, active: active)
    }

    /// A call in progress can always be hung up. Otherwise the control is live when a call can
    /// start, or when pressing it is the way to find out, to be asked for a password, or to be shown
    /// what the server still needs; it is dimmed only where the gateway has said that no press could
    /// help, and the tooltip says why.
    public static func isEnabled(reach: VoiceReach, active: Bool = false) -> Bool {
        if active { return true }
        switch reach {
        case .unknown, .ready, .stopped, .needsSetup, .noGateway, .engineDown, .wantsPassword, .unreachable:
            return true
        case .checking, .loading, .busy, .tooOld:
            return false
        }
    }

    /// Whether pressing the control opens the voice checklist instead of starting a call: the server
    /// has no gateway, the gateway says it needs setting up, or its engine is down. Every road that
    /// would have toasted one of those reasons opens the same checklist for the same capability.
    public static func pressOpensSetup(reach: VoiceReach) -> Bool {
        switch reach {
        case .needsSetup, .noGateway, .engineDown: return true
        default: return false
        }
    }
}
