import Foundation

/// Where a take writes down what happened to it — the microphone's format, the engine waking, the
/// first sound, the first words, and why a take ended on its own — so a take that fails on a real
/// device leaves the reason in the app's own log. Each client points it at its logger.
public enum DictationTrace {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?

    static func note(_ line: @autoclosure () -> String) {
        guard let sink else { return }
        sink("dictation: " + line())
    }
}
