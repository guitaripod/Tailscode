import Foundation

/// What a take produced once it ended: the words, shaped, and how it ended.
public struct DictationTake: Sendable, Equatable {
    public let text: String
    public let end: DictationEnd

    public init(text: String, end: DictationEnd) {
        self.text = text
        self.end = end
    }
}

/// One take. It owns the microphone and the engine for as long as the take lasts and nothing
/// after: whichever way it ends, capture is stopped and the engine let go before the last snapshot
/// is published. It is never main-actor, so a toolkit that cannot drain the main queue can run it.
///
/// The microphone opens first and the engine wakes beside it, so the first word is never lost:
/// audio that arrives before the engine is ready waits in `pending` and is handed over the moment
/// it is.
public actor DictationSession {
    public static let limit: TimeInterval = 600
    public static let warning: TimeInterval = 570
    public static let settleTimeout: TimeInterval = 1.2
    public static let pendingLimit = VoicePCM.bytes(forMilliseconds: 15_000)
    public static let wakeTimeout: TimeInterval = 4

    public nonisolated let snapshots: AsyncStream<DictationSnapshot>
    private let output: AsyncStream<DictationSnapshot>.Continuation

    private let capture: any VoiceAudioCapture
    private let recognizer: any DictationRecognizer
    private let language: String
    private let vocabulary: DictationVocabulary
    private let shaper: DictationShaper
    private let atStart: Bool
    private let clock: any VoiceClock
    private let take: Int

    private var phase = DictationPhase.idle
    private var mode = DictationMode.held
    private var arm = DictationArm.none
    private var settledRaw = ""
    private var heardRaw = ""
    private var startedAt: TimeInterval?
    private var nearingLimit = false
    private var ended: DictationEnd?
    private var engineReady = false
    private var engineFailed = false
    private var discarding = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var closing = false
    private var resultsDone = false
    private var settleWaiter: CheckedContinuation<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var finished: DictationTake?

    public init(
        capture: any VoiceAudioCapture, recognizer: any DictationRecognizer, language: String,
        vocabulary: DictationVocabulary, atStartOfBox: Bool, clock: any VoiceClock = SystemVoiceClock(),
        take: Int = 1
    ) {
        self.capture = capture
        self.recognizer = recognizer
        self.language = language
        self.vocabulary = vocabulary
        self.shaper = DictationShaper(vocabulary)
        self.atStart = atStartOfBox
        self.clock = clock
        self.take = take
        let (stream, continuation) = AsyncStream<DictationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.output = continuation
    }

    /// How loud the person is right now, `0...1`, read from the display clock.
    public nonisolated var level: Double { capture.level }

    public func current() -> DictationSnapshot { snapshot() }

    public var isOpen: Bool { !closing && (phase == .waking || phase == .listening) }

    /// Opens the microphone and wakes the engine. Returns once the microphone is open, or with the
    /// take already ended when it could not open.
    public func open(mode: DictationMode) async {
        guard phase == .idle, ended == nil, !closing else { return }
        self.mode = mode
        phase = .waking
        startedAt = clock.now()
        publish()
        let chunks: AsyncStream<Data>
        do {
            chunks = try await capture.start()
        } catch {
            await close(as: .problem(Self.problem(error)))
            return
        }
        guard !closing else {
            await capture.stop()
            return
        }
        captureTask = Task { [weak self] in
            for await chunk in chunks { await self?.heardAudio(chunk) }
            await self?.captureEnded()
        }
        engineTask = Task { [weak self] in await self?.wakeEngine() }
        limitTask = Task { [weak self] in await self?.watchLimit() }
    }

    public func setMode(_ value: DictationMode) {
        guard mode != value, !closing else { return }
        mode = value
        if value == .handsFree { arm = .none }
        publish()
    }

    public func setArm(_ value: DictationArm) {
        guard arm != value, !closing, mode == .held else { return }
        arm = value
        publish()
    }

    /// Stops listening and waits, at most `settleTimeout`, for the last words to settle. Words still
    /// being heard when the wait ends are kept as they are shown: what you see is what you keep.
    @discardableResult
    public func finish(sending: Bool = false) async -> DictationTake {
        if let finished { return finished }
        guard !closing else { return await waitForEnd() }
        closing = true
        phase = .settling
        arm = .none
        publish()
        limitTask?.cancel()
        await capture.stop()
        captureTask?.cancel()
        await waitForEngine()
        if engineReady {
            await recognizer.end()
            await waitForSettle()
        } else {
            engineTask?.cancel()
            await recognizer.abort()
        }
        let text = words
        let count = DictationText.wordCount(text)
        let end: DictationEnd = count == 0 ? .nothingHeard : (sending ? .sent(words: count) : .kept(words: count))
        return seal(text: text, end: end)
    }

    /// Throws the take away. The box goes back to what it held before.
    @discardableResult
    public func cancel() async -> DictationTake {
        if let finished { return finished }
        guard !closing else { return await waitForEnd() }
        closing = true
        discarding = true
        limitTask?.cancel()
        await capture.stop()
        captureTask?.cancel()
        engineTask?.cancel()
        await recognizer.abort()
        resultsTask?.cancel()
        settledRaw = ""
        heardRaw = ""
        return seal(text: "", end: .discarded)
    }

    private var words: String {
        let settled = shaper.shape(settledRaw, atStart: atStart)
        let heard = shaper.shape(heardRaw, atStart: atStart && settledRaw.isEmpty)
        return DictationText.join(settled, heard)
    }

    private func seal(text: String, end: DictationEnd) -> DictationTake {
        let take = DictationTake(text: text, end: end)
        finished = take
        ended = end
        phase = .idle
        arm = .none
        settledRaw = text
        heardRaw = ""
        publish()
        output.finish()
        return take
    }

    private func waitForEnd() async -> DictationTake {
        while finished == nil {
            try? await clock.sleep(for: 0.02)
        }
        return finished ?? DictationTake(text: "", end: .discarded)
    }

    private func close(as end: DictationEnd) async {
        guard finished == nil else { return }
        closing = true
        discarding = true
        limitTask?.cancel()
        await capture.stop()
        captureTask?.cancel()
        engineTask?.cancel()
        resultsTask?.cancel()
        await recognizer.abort()
        let text = end.keepsWords ? words : ""
        _ = seal(text: text, end: end)
    }

    private func heardAudio(_ chunk: Data) async {
        guard !closing else { return }
        if phase == .waking {
            phase = .listening
            DictationTrace.note("take \(take) first sound after \(sinceStart) s")
            publish()
        }
        if engineReady {
            await recognizer.accept(chunk)
            return
        }
        pending.append(chunk)
        pendingBytes += chunk.count
        while pendingBytes > Self.pendingLimit, !pending.isEmpty {
            pendingBytes -= pending.removeFirst().count
        }
    }

    private func captureEnded() async {
        guard !closing else { return }
        DictationTrace.note("take \(take) lost its microphone after \(sinceStart) s, engine \(engineReady ? "ready" : "waking"), \(words.isEmpty ? "no words" : "words kept")")
        let keep = !words.isEmpty
        if keep, engineReady {
            closing = true
            phase = .settling
            publish()
            limitTask?.cancel()
            await recognizer.end()
            await waitForSettle()
            _ = seal(text: words, end: .problem(.taken))
        } else {
            await close(as: .problem(.taken))
        }
    }

    private func wakeEngine() async {
        let stream: AsyncThrowingStream<DictationHeard, Error>
        do {
            stream = try await recognizer.begin(language: language, vocabulary: vocabulary.phrases)
        } catch {
            engineFailed = true
            DictationTrace.note("take \(take) engine did not begin: \(error)")
            guard !closing else { return }
            await close(as: .problem(Self.problem(error)))
            return
        }
        guard !discarding else {
            await recognizer.abort()
            return
        }
        engineReady = true
        DictationTrace.note("take \(take) engine ready after \(sinceStart) s with \(pending.count) chunks waiting")
        let backlog = pending
        pending = []
        pendingBytes = 0
        for chunk in backlog { await recognizer.accept(chunk) }
        resultsTask = Task { [weak self] in
            do {
                for try await heard in stream { await self?.apply(heard) }
                await self?.resultsFinished(error: nil)
            } catch {
                await self?.resultsFinished(error: error)
            }
        }
    }

    private func apply(_ heard: DictationHeard) {
        guard finished == nil else { return }
        if settledRaw.isEmpty, heardRaw.isEmpty { DictationTrace.note("take \(take) first words after \(sinceStart) s") }
        switch heard {
        case .volatile(let text):
            heardRaw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .final(let text):
            settledRaw = DictationText.join(settledRaw, text.trimmingCharacters(in: .whitespacesAndNewlines))
            heardRaw = ""
        }
        publish()
    }

    private func resultsFinished(error: Error?) async {
        resultsDone = true
        if let waiter = settleWaiter {
            settleWaiter = nil
            waiter.resume()
        }
        guard let error, !closing else { return }
        DictationTrace.note("take \(take) engine stopped: \(error)")
        await close(as: .problem(Self.problem(error)))
    }

    /// A take stopped while the engine is still waking — a quick tap on a cold Linux model — waits
    /// for it, so the words already buffered are heard rather than dropped.
    private func waitForEngine() async {
        var waited: TimeInterval = 0
        while !engineReady, !engineFailed, !discarding, engineTask != nil, waited < Self.wakeTimeout {
            try? await clock.sleep(for: 0.05)
            waited += 0.05
        }
    }

    private func waitForSettle() async {
        guard !resultsDone else { return }
        let clock = self.clock
        let timeout = Task { [weak self] in
            try? await clock.sleep(for: Self.settleTimeout)
            await self?.settleTimedOut()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if resultsDone {
                continuation.resume()
            } else {
                settleWaiter = continuation
            }
        }
        timeout.cancel()
        resultsTask?.cancel()
    }

    private func settleTimedOut() {
        guard let waiter = settleWaiter else { return }
        settleWaiter = nil
        waiter.resume()
    }

    private func watchLimit() async {
        do {
            try await clock.sleep(for: Self.warning)
            guard !closing else { return }
            nearingLimit = true
            publish()
            try await clock.sleep(for: Self.limit - Self.warning)
        } catch {
            return
        }
        guard !closing else { return }
        closing = true
        phase = .settling
        publish()
        await capture.stop()
        captureTask?.cancel()
        if engineReady {
            await recognizer.end()
            await waitForSettle()
        }
        _ = seal(text: words, end: .problem(.timeUp))
    }

    private func snapshot() -> DictationSnapshot {
        let settled = shaper.shape(settledRaw, atStart: atStart)
        let heard = shaper.shape(heardRaw, atStart: atStart && settledRaw.isEmpty)
        return DictationSnapshot(
            phase: phase, mode: mode, arm: arm, settled: settled, heard: heard, startedAt: startedAt,
            nearingLimit: nearingLimit, ended: ended, take: take)
    }

    private func publish() {
        output.yield(snapshot())
    }

    private var sinceStart: String {
        String(format: "%.2f", startedAt.map { clock.now() - $0 } ?? 0)
    }

    static func problem(_ error: Error) -> DictationProblem {
        if let audio = error as? VoiceAudioError {
            switch audio {
            case .microphoneDenied: return .microphoneDenied
            case .unavailable: return .noMicrophone
            }
        }
        if let engine = error as? DictationEngineError { return engine.problem }
        return .engine(String(describing: error))
    }
}

extension DictationEnd {
    var keepsWords: Bool {
        switch self {
        case .problem(let problem): return problem.keepsWords
        case .kept, .sent: return true
        case .discarded, .nothingHeard: return false
        }
    }
}
