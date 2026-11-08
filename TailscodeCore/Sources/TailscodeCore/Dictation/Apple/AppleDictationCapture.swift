#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import AVFoundation
    import Foundation

    /// The microphone as dictation needs it: the input as it comes, with no voice processing and no
    /// call's audio session. The call's path cancels echo for a speaker that dictation never uses,
    /// and switching that processing on reconfigures the engine under itself; a take only listens.
    /// On the phone the session records with others ducked and keeps haptics playing, so the take's
    /// cues are felt. A change of route or hardware restarts the input, at most a few times, and an
    /// interruption ends the stream, which the take reads as the microphone being taken.
    public final class AppleDictationCapture: VoiceAudioCapture, @unchecked Sendable {
        private static let restartLimit = 3

        private let control = DispatchQueue(label: "com.guitaripod.tailscode.dictation.capture")
        private let meter = AppleVoiceMeter()
        private var engine: AVAudioEngine?
        private var chain: AppleVoiceCaptureChain?
        private var observers: [NSObjectProtocol] = []
        private var restarts = 0

        public init() {}

        public var level: Double { meter.value }

        public func start() async throws -> AsyncStream<Data> {
            try await AppleVoiceIO.requireMicrophone()
            return try await withCheckedThrowingContinuation { (done: CheckedContinuation<AsyncStream<Data>, Error>) in
                control.async { done.resume(with: Result { try self.begin() }) }
            }
        }

        public func stop() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                control.async {
                    self.end(because: nil)
                    done.resume()
                }
            }
        }

        private func begin() throws -> AsyncStream<Data> {
            end(because: nil)
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(
                        .playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
                    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                    try session.setActive(true)
                } catch {
                    DictationTrace.note("audio session refused: \(error)")
                    throw VoiceAudioError.unavailable(error.localizedDescription)
                }
            #endif
            let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
            let chain = AppleVoiceCaptureChain(meter: meter, continuation: continuation)
            self.chain = chain
            do {
                try startEngine(feeding: chain)
            } catch {
                end(because: "the input did not start: \(error)")
                throw (error as? VoiceAudioError) ?? VoiceAudioError.unavailable(error.localizedDescription)
            }
            watch()
            return stream
        }

        private func startEngine(feeding chain: AppleVoiceCaptureChain) throws {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAudioError.unavailable("The microphone reports no usable format.")
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in chain.process(buffer) }
            engine.prepare()
            try engine.start()
            self.engine = engine
            DictationTrace.note("input \(Int(format.sampleRate)) Hz × \(format.channelCount), started")
        }

        private func watch() {
            observeEngine()
            #if os(iOS)
                let center = NotificationCenter.default
                observers.append(
                    center.addObserver(
                        forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                        queue: nil
                    ) { [weak self] note in
                        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                        guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
                        self?.control.async { self?.end(because: "the audio session was interrupted") }
                    })
            #endif
        }

        /// The engine stops itself when the input changes under it. It is started again on the new
        /// input with the same stream, so the take keeps listening across a headset plugged in.
        private func restart(because reason: String) {
            guard let chain else { return }
            if let engine, engine.isRunning { return }
            restarts += 1
            guard restarts <= Self.restartLimit else {
                end(because: "\(reason) \(restarts) times")
                return
            }
            DictationTrace.note("\(reason); restarting the input")
            stopEngine()
            do {
                try startEngine(feeding: chain)
                observeEngine()
            } catch {
                end(because: "\(reason) and the input did not come back: \(error)")
            }
        }

        private func observeEngine() {
            guard let engine else { return }
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in
                    self?.control.async { self?.restart(because: "the audio hardware changed") }
                })
        }

        private func stopEngine() {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
        }

        private func end(because reason: String?) {
            let wasOpen = chain != nil
            if let reason, wasOpen { DictationTrace.note("input ended: \(reason)") }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            stopEngine()
            chain?.finish()
            chain = nil
            meter.clear()
            restarts = 0
            #if os(iOS)
                if wasOpen { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            #endif
        }
    }
#endif
