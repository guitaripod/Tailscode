import Foundation

/// A speech engine, as a take needs it. Audio arrives as the call's microphone delivers it — PCM16
/// little-endian, mono, 24 kHz — and the engine says what it heard on the stream `begin` returns:
/// volatile results that replace the tail, finals that settle. The stream ends after `end()` once
/// the last words have settled, or at once after `abort()`.
public protocol DictationRecognizer: Sendable {
    /// Which language this engine would listen in for the person's choice, `nil` meaning automatic,
    /// and the language hint a client has (the keyboard's, on a phone).
    func language(for choice: String?, hint: String?) async -> String?

    func readiness(language: String) async -> DictationReadiness

    /// Brings the engine to ready: downloads what is missing and reports progress `0...1` (`nil`
    /// when it cannot tell). Finishes when ready; throws when it cannot get there.
    func prepare(language: String) -> AsyncThrowingStream<Double?, Error>

    func begin(language: String, vocabulary: [String]) async throws -> AsyncThrowingStream<DictationHeard, Error>

    func accept(_ pcm: Data) async

    func end() async

    func abort() async

    /// The languages a person can choose from, as locale identifiers.
    func languages() async -> [String]
}

public enum DictationEngineError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedLanguage(String)
    case notReady
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language): return "Dictation does not support \(language)."
        case .notReady: return "The speech model is not installed."
        case .failed(let detail): return detail
        }
    }

    var problem: DictationProblem {
        switch self {
        case .unsupportedLanguage(let language): return .languageUnsupported(language)
        case .notReady: return .engine("not ready")
        case .failed(let detail): return .engine(detail)
        }
    }
}
