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
    /// start, or when pressing it is the way to find out or to be asked for a password; it is
    /// dimmed only where the gateway has said that no press could help, and the tooltip says why.
    public static func isEnabled(reach: VoiceReach, active: Bool = false) -> Bool {
        if active { return true }
        switch reach {
        case .unknown, .ready, .stopped, .needsSetup, .wantsPassword, .unreachable: return true
        case .checking, .loading, .busy, .noGateway, .tooOld, .engineDown: return false
        }
    }
}
