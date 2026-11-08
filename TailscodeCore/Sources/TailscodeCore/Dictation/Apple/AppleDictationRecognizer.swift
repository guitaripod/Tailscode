#if canImport(Speech) && (os(iOS) || os(macOS))
    import AVFoundation
    import Foundation
    import Speech

    /// Apple's on-device dictation, as a take needs it: `DictationTranscriber` with punctuation,
    /// volatile results and frequent finalization, so heard words arrive at once and settle soon,
    /// biased toward the chat's own words through `AnalysisContext`. Nothing it hears leaves the
    /// device. The microphone's 24 kHz PCM16 is converted to the analyzer's own format here.
    @available(iOS 26, macOS 26, *)
    public final class AppleDictationRecognizer: DictationRecognizer, @unchecked Sendable {
        private static let progressTick: UInt64 = 200_000_000

        private let lock = NSLock()
        private var analyzer: SpeechAnalyzer?
        private var input: AsyncStream<AnalyzerInput>.Continuation?
        private var output: AsyncThrowingStream<DictationHeard, Error>.Continuation?
        private var resultsTask: Task<Void, Never>?
        private var targetFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        private let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(VoicePCM.sampleRate), channels: 1, interleaved: true)!

        public init() {}

        public func languages() async -> [String] {
            await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
        }

        public func language(for choice: String?, hint: String?) async -> String? {
            if let choice {
                return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: choice))?.identifier(.bcp47)
            }
            let candidates = [hint, Locale.preferredLanguages.first, Locale.current.identifier].compactMap { $0 }
            for candidate in candidates {
                if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: candidate)) {
                    return locale.identifier(.bcp47)
                }
            }
            return nil
        }

        public func readiness(language: String) async -> DictationReadiness {
            let transcriber = Self.transcriber(language)
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed: return .ready
            case .downloading: return .downloading(nil)
            case .supported: return .needsDownload(bytes: nil)
            case .unsupported: return .unavailable(.languageUnsupported(language))
            @unknown default: return .unavailable(.languageUnsupported(language))
            }
        }

        public func prepare(language: String) -> AsyncThrowingStream<Double?, Error> {
            AsyncThrowingStream { continuation in
                let work = Task {
                    do {
                        let transcriber = Self.transcriber(language)
                        _ = try? await AssetInventory.reserve(locale: Locale(identifier: language))
                        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                        else {
                            continuation.finish()
                            return
                        }
                        let progress = request.progress
                        let ticker = Task {
                            while !Task.isCancelled {
                                continuation.yield(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                                try? await Task.sleep(nanoseconds: Self.progressTick)
                            }
                        }
                        defer { ticker.cancel() }
                        try await request.downloadAndInstall()
                        continuation.yield(1)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: DictationEngineError.failed(String(describing: error)))
                    }
                }
                continuation.onTermination = { _ in work.cancel() }
            }
        }

        public func begin(language: String, vocabulary: [String]) async throws -> AsyncThrowingStream<DictationHeard, Error> {
            await abort()
            let transcriber = Self.transcriber(language)
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw DictationEngineError.notReady
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationEngineError.failed("no audio format")
            }
            let analyzer = SpeechAnalyzer(
                modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            let (heard, heardContinuation) = AsyncThrowingStream<DictationHeard, Error>.makeStream()
            let results = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        heardContinuation.yield(result.isFinal ? .final(text) : .volatile(text))
                    }
                    heardContinuation.finish()
                } catch {
                    heardContinuation.finish(throwing: DictationEngineError.failed(String(describing: error)))
                }
            }
            lock.withLock {
                self.analyzer = analyzer
                self.input = inputContinuation
                self.output = heardContinuation
                self.resultsTask = results
                self.targetFormat = format
                self.converter = AVAudioConverter(from: sourceFormat, to: format)
            }
            try await analyzer.start(inputSequence: inputs)
            return heard
        }

        public func accept(_ pcm: Data) async {
            let converted: AVAudioPCMBuffer? = lock.withLock { convert(pcm) }
            guard let converted else { return }
            let continuation = lock.withLock { input }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }

        public func end() async {
            let (analyzer, input) = lock.withLock { (self.analyzer, self.input) }
            input?.finish()
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer?.cancelAndFinishNow()
            }
            lock.withLock {
                self.analyzer = nil
                self.input = nil
                self.converter = nil
            }
        }

        public func abort() async {
            let (analyzer, input, output, results) = lock.withLock {
                let taken = (self.analyzer, self.input, self.output, self.resultsTask)
                self.analyzer = nil
                self.input = nil
                self.output = nil
                self.resultsTask = nil
                self.converter = nil
                return taken
            }
            input?.finish()
            await analyzer?.cancelAndFinishNow()
            results?.cancel()
            output?.finish()
        }

        private static func transcriber(_ language: String) -> DictationTranscriber {
            DictationTranscriber(
                locale: Locale(identifier: language), contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }

        private func convert(_ pcm: Data) -> AVAudioPCMBuffer? {
            let frames = pcm.count / VoicePCM.bytesPerSample
            guard frames > 0, let converter, let targetFormat,
                let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))
            else { return nil }
            source.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, let channel = source.int16ChannelData else { return }
                channel[0].update(from: base.assumingMemoryBound(to: Int16.self), count: frames)
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            guard
                let target = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64)
            else { return nil }
            var supplied = false
            var failure: NSError?
            let status = converter.convert(to: target, error: &failure) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            guard status != .error, failure == nil, target.frameLength > 0 else { return nil }
            return target
        }
    }
#endif
