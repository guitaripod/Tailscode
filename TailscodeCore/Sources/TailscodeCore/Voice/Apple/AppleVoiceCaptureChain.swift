#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import AVFoundation
    import Foundation

    /// What happens to one microphone buffer: the first channel is taken (voice processing puts the
    /// cleaned voice there), converted to 24 kHz mono Int16, measured, re-cut into 80 ms chunks and
    /// yielded. The tap calls it on an audio thread, so it holds one lock and no actor.
    final class AppleVoiceCaptureChain: @unchecked Sendable {
        private static let holdSeconds = 0.25

        private let lock = NSLock()
        private let meter: AppleVoiceMeter
        private let output: AVAudioFormat
        private var continuation: AsyncStream<Data>.Continuation?
        private var chunker = VoiceChunker()
        private var converter: AVAudioConverter?
        private var mono: AVAudioPCMBuffer?

        init(meter: AppleVoiceMeter, continuation: AsyncStream<Data>.Continuation) {
            self.meter = meter
            self.continuation = continuation
            self.output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(VoicePCM.sampleRate), channels: 1,
                interleaved: true)!
        }

        func process(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation, let pcm = convert(buffer) else { return }
            meter.set(VoicePCM.rms(of: pcm), holdingFor: Self.holdSeconds)
            for chunk in chunker.append(pcm) { continuation.yield(chunk) }
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            continuation?.finish()
            continuation = nil
            chunker.reset()
            converter = nil
            mono = nil
        }

        private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
            let frames = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            guard frames > 0, rate > 0, let channels = buffer.floatChannelData,
                let source = monoBuffer(rate: rate, frames: frames),
                let converter = converter(for: source.format),
                let target = AVAudioPCMBuffer(
                    pcmFormat: output,
                    frameCapacity: AVAudioFrameCount(Double(frames) * Double(VoicePCM.sampleRate) / rate) + 32)
            else { return nil }
            source.frameLength = AVAudioFrameCount(frames)
            source.floatChannelData![0].update(from: channels[0], count: frames)
            let feed = ConverterFeed(source)
            var failure: NSError?
            let status = converter.convert(to: target, error: &failure) { _, inputStatus in
                feed.next(inputStatus)
            }
            guard status != .error, failure == nil, target.frameLength > 0, let samples = target.int16ChannelData
            else { return nil }
            return Data(bytes: samples[0], count: Int(target.frameLength) * VoicePCM.bytesPerSample)
        }

        private func monoBuffer(rate: Double, frames: Int) -> AVAudioPCMBuffer? {
            if let mono, mono.format.sampleRate == rate, Int(mono.frameCapacity) >= frames { return mono }
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
            else { return nil }
            mono = fresh
            converter = nil
            return fresh
        }

        private func converter(for input: AVAudioFormat) -> AVAudioConverter? {
            if let converter, converter.inputFormat == input { return converter }
            converter = AVAudioConverter(from: input, to: output)
            return converter
        }
    }

    /// Hands a converter its one buffer and then says there is no more for now, so the converter keeps
    /// its resampling state for the next tap instead of treating the stream as finished.
    private final class ConverterFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
#endif
