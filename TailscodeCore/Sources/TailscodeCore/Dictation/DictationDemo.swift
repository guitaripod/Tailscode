import Foundation

/// A take with no microphone and no engine, for the demo world, screenshots and the selftests: the
/// script is "spoken" word by word as volatile results that settle at each sentence end, and the
/// level rises and falls like a voice. It ignores the audio it is handed.
public final class DictationDemoRecognizer: DictationRecognizer, @unchecked Sendable {
    public static let script =
        "Rename the dictation button in composer view dot swift so the hold gesture cancels when you slide left. Keep the words in the box until I send them."

    public static let vocabulary = DictationVocabulary(
        terms: ["ComposerView.swift", "DictationButton.swift", "PromptEditor"], commands: ["compact", "goal"])

    private let lock = NSLock()
    private let wordDelay: TimeInterval
    private let words: [String]
    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DictationHeard, Error>.Continuation?
    private var spoken = 0
    private var settled = 0

    public init(script: String = DictationDemoRecognizer.script, wordDelay: TimeInterval = 0.22) {
        self.words = script.split(separator: " ").map(String.init)
        self.wordDelay = wordDelay
    }

    public func language(for choice: String?, hint: String?) async -> String? { choice ?? "en-US" }

    public func readiness(language: String) async -> DictationReadiness { .ready }

    public func prepare(language: String) -> AsyncThrowingStream<Double?, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func languages() async -> [String] { ["en-US"] }

    public func begin(language: String, vocabulary: [String]) async throws -> AsyncThrowingStream<DictationHeard, Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationHeard, Error>.makeStream()
        lock.withLock {
            self.continuation = continuation
            spoken = 0
            settled = 0
        }
        let delay = wordDelay
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, self.step() else { break }
            }
        }
        return stream
    }

    /// Speaks one more word. Returns false when the script has been spoken.
    private func step() -> Bool {
        lock.withLock {
            guard spoken < words.count, let continuation else { return false }
            spoken += 1
            let tail = words[settled..<spoken].joined(separator: " ")
            if tail.hasSuffix(".") {
                continuation.yield(.final(tail))
                settled = spoken
            } else {
                continuation.yield(.volatile(tail))
            }
            return spoken < words.count
        }
    }

    public func accept(_ pcm: Data) async {}

    public func end() async {
        task?.cancel()
        lock.withLock {
            if settled < spoken {
                continuation?.yield(.final(words[settled..<spoken].joined(separator: " ")))
                settled = spoken
            }
            continuation?.finish()
            continuation = nil
        }
    }

    public func abort() async {
        task?.cancel()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

/// A microphone that delivers silence on time and a level shaped like speech.
public final class DictationDemoCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?
    private let started = ProcessInfo.processInfo.systemUptime

    public init() {}

    public var level: Double {
        guard lock.withLock({ continuation != nil }) else { return 0 }
        let t = ProcessInfo.processInfo.systemUptime - started
        let syllables = 0.5 + 0.5 * sin(t * 11)
        let phrases = 0.55 + 0.45 * sin(t * 1.7)
        return max(0, min(1, 0.15 + 0.75 * syllables * phrases))
    }

    public func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
        lock.withLock { self.continuation = continuation }
        let chunk = Data(count: VoicePCM.chunkBytes)
        task = Task {
            while !Task.isCancelled {
                continuation.yield(chunk)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        return stream
    }

    public func stop() async {
        task?.cancel()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}
