import CSherpa
import Foundation
import TailscodeCore

/// Linux dictation's engine: sherpa-onnx's streaming recognizer over Nemotron Speech Streaming,
/// on this machine's CPU, from the files `DictationModelStore` keeps. Every call into the library
/// runs on one serial queue, so the recognizer is never touched from two threads; the library is
/// opened once per process, and the recognizer stays loaded for a while after a take so the next
/// one wakes at once, then lets go of its memory.
final class SherpaDictationRecognizer: DictationRecognizer, @unchecked Sendable {
    static let shared = SherpaDictationRecognizer()
    static let language = "en-US"
    static let trailingSilence: Float = 1.0
    static let keepWarm: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.guitaripod.tailscode.dictation.sherpa", qos: .userInitiated)
    private let store = DictationModelStore.shared
    private var recognizer: UnsafeMutableRawPointer?
    private var stream: UnsafeMutableRawPointer?
    private var continuation: AsyncThrowingStream<DictationHeard, Error>.Continuation?
    private var lastText = ""
    private var unload: DispatchWorkItem?
    private var text = [CChar](repeating: 0, count: 8192)
    private var samples: [Float] = []

    private static var threads: Int32 {
        Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
    }

    func language(for choice: String?, hint: String?) async -> String? { Self.language }

    func languages() async -> [String] { [Self.language] }

    func readiness(language: String) async -> DictationReadiness {
        guard DictationModelPack.isSupported else { return .unavailable(.engine("unsupported CPU")) }
        switch store.state {
        case .installed: return .ready
        case .installing(let download): return .downloading(download.fraction)
        case .absent, .failed: return .needsDownload(bytes: DictationModelPack.totalBytes)
        }
    }

    func prepare(language: String) -> AsyncThrowingStream<Double?, Error> {
        AsyncThrowingStream { continuation in
            let store = self.store
            let id = store.watch { state in
                switch state {
                case .installing(let download): continuation.yield(download.fraction)
                case .installed: continuation.finish()
                case .failed(let reason): continuation.finish(throwing: DictationEngineError.failed(reason))
                case .absent: break
                }
            }
            continuation.onTermination = { _ in store.unwatch(id) }
            store.install()
        }
    }

    func begin(language: String, vocabulary: [String]) async throws -> AsyncThrowingStream<DictationHeard, Error> {
        let (heard, continuation) = AsyncThrowingStream<DictationHeard, Error>.makeStream()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.openStream()
                    self.continuation?.finish()
                    self.continuation = continuation
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
        return heard
    }

    func accept(_ pcm: Data) async {
        queue.async { self.feed(pcm) }
    }

    func end() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finishStream(keep: true)
                done.resume()
            }
        }
    }

    func abort() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finishStream(keep: false)
                done.resume()
            }
        }
    }

    private func openStream() throws {
        unload?.cancel()
        unload = nil
        if let stream {
            tailscode_sherpa_free_stream(stream)
            self.stream = nil
        }
        if recognizer == nil {
            guard let paths = store.paths else { throw DictationEngineError.notReady }
            var error = [CChar](repeating: 0, count: 512)
            guard tailscode_sherpa_load(paths.library, &error, Int32(error.count)) == 1 else {
                throw DictationEngineError.failed("engine: \(String(cString: error))")
            }
            let started = ProcessInfo.processInfo.systemUptime
            recognizer = tailscode_sherpa_recognizer(
                paths.encoder, paths.decoder, paths.joiner, paths.tokens, Self.threads, Self.trailingSilence)
            guard recognizer != nil else { throw DictationEngineError.failed("the model did not load") }
            let seconds = ProcessInfo.processInfo.systemUptime - started
            AppLog.write(.session, "dictation: model loaded in \(String(format: "%.2f", seconds)) s on \(Self.threads) threads")
        }
        stream = tailscode_sherpa_stream(recognizer)
        guard stream != nil else { throw DictationEngineError.failed("no stream") }
        lastText = ""
    }

    private func feed(_ pcm: Data) {
        guard let recognizer, let stream, continuation != nil else { return }
        let count = pcm.count / VoicePCM.bytesPerSample
        guard count > 0 else { return }
        if samples.count < count { samples = [Float](repeating: 0, count: count) }
        pcm.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for index in 0..<count { samples[index] = Float(Int16(littleEndian: input[index])) / 32768 }
        }
        let ended = samples.withUnsafeBufferPointer { buffer in
            tailscode_sherpa_feed(
                recognizer, stream, Int32(VoicePCM.sampleRate), buffer.baseAddress, Int32(count), &text,
                Int32(text.count))
        }
        let current = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if ended == 1 {
            if !current.isEmpty { continuation?.yield(.final(current)) }
            lastText = ""
        } else if current != lastText {
            lastText = current
            continuation?.yield(.volatile(current))
        }
    }

    private func finishStream(keep: Bool) {
        if let recognizer, let stream, keep {
            tailscode_sherpa_finish(recognizer, stream, Int32(VoicePCM.sampleRate), &text, Int32(text.count))
            let last = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !last.isEmpty { continuation?.yield(.final(last)) }
        }
        continuation?.finish()
        continuation = nil
        if let stream {
            tailscode_sherpa_free_stream(stream)
            self.stream = nil
        }
        lastText = ""
        scheduleUnload()
    }

    private func scheduleUnload() {
        unload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stream == nil, let recognizer = self.recognizer else { return }
            tailscode_sherpa_free_recognizer(recognizer)
            self.recognizer = nil
            AppLog.write(.session, "dictation: model let go after \(Int(Self.keepWarm)) s idle")
        }
        unload = work
        queue.asyncAfter(deadline: .now() + Self.keepWarm, execute: work)
    }
}
