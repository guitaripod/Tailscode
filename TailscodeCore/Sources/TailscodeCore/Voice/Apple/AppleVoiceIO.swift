#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import AVFoundation
    import Foundation
    import os

    /// The one Apple implementation of the call's microphone and speaker, shared by the iPhone and the
    /// Mac. It owns a single `AVAudioEngine` and hands out both seams from it, because echo
    /// cancellation only works when the microphone and the speaker run through the same voice
    /// processing unit. The call starts the microphone first and the speaker second, and stops them in
    /// that order; the engine and, on iOS, the audio session live from the first start to the last stop.
    public final class AppleVoiceIO: @unchecked Sendable {
        private static let rebuildWindow: TimeInterval = 10
        private static let rebuildLimit = 5

        private struct Callbacks: Sendable {
            var interruption: (@Sendable () -> Void)?
            var failure: (@Sendable (VoiceAudioError) -> Void)?
        }

        private let control = DispatchQueue(label: "com.guitaripod.tailscode.voice.io")
        private let player: AppleVoicePlayer
        private let captureMeter = AppleVoiceMeter()
        private let callbacks = OSAllocatedUnfairLock(initialState: Callbacks())

        private var engine: AVAudioEngine?
        private var engineHasInput = false
        private var tapInstalled = false
        private var epoch = 0
        private var chain: AppleVoiceCaptureChain?
        private var wantsCapture = false
        private var wantsPlayback = false
        private var engineObserver: NSObjectProtocol?
        private var rebuilds: [TimeInterval] = []
        #if os(iOS)
            private let session = AppleVoiceAudioSession()
        #endif

        public init(jitter: VoiceJitter = .standard) {
            player = AppleVoicePlayer(policy: jitter)
        }

        public var capture: any VoiceAudioCapture { AppleVoiceCapture(io: self) }

        public var playback: any VoiceAudioPlayback { AppleVoicePlayback(io: self) }

        /// Called when another app or a call takes the audio away. The microphone has already ended;
        /// the client hangs up. Only iOS has interruptions.
        public var onInterruption: (@Sendable () -> Void)? {
            get { callbacks.withLock { $0.interruption } }
            set { callbacks.withLock { $0.interruption = newValue } }
        }

        /// Called when the engine cannot be brought back after the hardware changed under it. The
        /// microphone has already ended and everything is torn down; the client hangs up.
        public var onFailure: (@Sendable (VoiceAudioError) -> Void)? {
            get { callbacks.withLock { $0.failure } }
            set { callbacks.withLock { $0.failure = newValue } }
        }

        var captureLevel: Double { captureMeter.value }

        var playbackLevel: Double { player.meter.value }

        func startCapture() async throws -> AsyncStream<Data> {
            try await Self.requireMicrophone()
            return try await performThrowing { try self.beginCapture() }
        }

        func stopCapture() async {
            await perform {
                self.endCapture()
                self.releaseIfIdle()
            }
        }

        func startPlayback() async throws {
            try await performThrowing { try self.beginPlayback() }
        }

        func stopPlayback() async {
            await player.flush()
            await perform {
                self.wantsPlayback = false
                self.releaseIfIdle()
            }
        }

        func play(_ pcm: Data) {
            player.enqueue(pcm)
        }

        func flush() async {
            await player.flush()
        }

        private static func requireMicrophone() async throws {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .undetermined:
                guard await AVAudioApplication.requestRecordPermission() else {
                    throw VoiceAudioError.microphoneDenied
                }
            default:
                throw VoiceAudioError.microphoneDenied
            }
        }

        private func perform(_ work: @escaping @Sendable () -> Void) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                control.async {
                    work()
                    done.resume()
                }
            }
        }

        private func performThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
                control.async { done.resume(with: Result { try work() }) }
            }
        }

        private func beginCapture() throws -> AsyncStream<Data> {
            endCapture()
            wantsCapture = true
            let (stream, continuation) = AsyncStream<Data>.makeStream(
                of: Data.self, bufferingPolicy: .bufferingNewest(64))
            chain = AppleVoiceCaptureChain(meter: captureMeter, continuation: continuation)
            do {
                try ensureEngine()
            } catch {
                endCapture()
                discardEngine()
                releaseIfIdle()
                throw Self.unavailable(error)
            }
            return stream
        }

        private func beginPlayback() throws {
            wantsPlayback = true
            do {
                try ensureEngine()
            } catch {
                wantsPlayback = false
                discardEngine()
                releaseIfIdle()
                throw Self.unavailable(error)
            }
        }

        private func endCapture() {
            chain?.finish()
            chain = nil
            wantsCapture = false
            captureMeter.clear()
            removeTap()
        }

        private func releaseIfIdle() {
            guard !wantsCapture, !wantsPlayback else { return }
            discardEngine()
            #if os(iOS)
                if session.isActive { session.deactivate() }
            #endif
        }

        private func ensureEngine() throws {
            #if os(iOS)
                if !session.isActive {
                    try session.activate(
                        onInterruptionBegan: { [weak self] in self?.interruptionBeganOffControl() },
                        onRouteChange: { [weak self] in self?.routeChangedOffControl() })
                }
            #endif
            if engine != nil, engineHasInput || !wantsCapture {
                try installTapIfNeeded()
                return
            }
            discardEngine()
            try buildEngine(withInput: wantsCapture)
        }

        /// Voice processing is switched on before anything is connected or tapped, because turning it
        /// on reconfigures the engine's input and output and invalidates whatever was attached earlier.
        private func buildEngine(withInput: Bool) throws {
            let engine = AVAudioEngine()
            self.engine = engine
            engineHasInput = withInput
            if withInput {
                let input = engine.inputNode
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min)
            }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: player.nodeFormat)
            try installTapIfNeeded()
            engine.prepare()
            try engine.start()
            node.play()
            player.attach(node)
            observeConfiguration(of: engine)
        }

        private func installTapIfNeeded() throws {
            guard wantsCapture, engineHasInput, !tapInstalled, let engine, let chain else { return }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAudioError.unavailable("The microphone reports no usable format.")
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                chain.process(buffer)
            }
            tapInstalled = true
        }

        private func removeTap() {
            guard tapInstalled else { return }
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        private func discardEngine() {
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
            engineObserver = nil
            player.detach()
            removeTap()
            engine?.stop()
            engine = nil
            engineHasInput = false
            epoch += 1
        }

        private func observeConfiguration(of engine: AVAudioEngine) {
            let current = epoch
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                control.async { self.reconfigured(epoch: current) }
            }
        }

        private func reconfigured(epoch seen: Int) {
            guard seen == epoch else { return }
            rebuild()
        }

        private func rebuild() {
            guard wantsCapture || wantsPlayback else { return }
            let now = ProcessInfo.processInfo.systemUptime
            rebuilds = rebuilds.filter { now - $0 < Self.rebuildWindow } + [now]
            guard rebuilds.count <= Self.rebuildLimit else {
                fail(.unavailable("The audio hardware kept changing."))
                return
            }
            discardEngine()
            do {
                try ensureEngine()
            } catch {
                fail(Self.unavailable(error))
            }
        }

        private func fail(_ error: VoiceAudioError) {
            endCapture()
            wantsPlayback = false
            releaseIfIdle()
            callbacks.withLock { $0.failure }?(error)
        }

        private func interruptionBeganOffControl() {
            control.async { self.interruptionBegan() }
        }

        private func routeChangedOffControl() {
            control.async { self.routeChanged() }
        }

        private func interruptionBegan() {
            guard wantsCapture || wantsPlayback else { return }
            endCapture()
            callbacks.withLock { $0.interruption }?()
        }

        private func routeChanged() {
            guard wantsCapture || wantsPlayback, engine?.isRunning == false else { return }
            rebuild()
        }

        private static func unavailable(_ error: Error) -> VoiceAudioError {
            if let known = error as? VoiceAudioError { return known }
            return .unavailable(error.localizedDescription)
        }
    }

    struct AppleVoiceCapture: VoiceAudioCapture {
        let io: AppleVoiceIO

        func start() async throws -> AsyncStream<Data> { try await io.startCapture() }

        func stop() async { await io.stopCapture() }

        var level: Double { io.captureLevel }
    }

    struct AppleVoicePlayback: VoiceAudioPlayback {
        let io: AppleVoiceIO

        func start() async throws { try await io.startPlayback() }

        func play(_ pcm: Data) async { io.play(pcm) }

        func flush() async { await io.flush() }

        func stop() async { await io.stopPlayback() }

        var level: Double { io.playbackLevel }
    }
#endif
