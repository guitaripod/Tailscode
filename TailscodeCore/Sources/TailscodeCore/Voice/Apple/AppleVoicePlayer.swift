#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import AVFoundation
    import Foundation

    /// The speaker side of the call: frames wait in a `VoiceJitterQueue`, only a short stretch is
    /// handed to the player node at a time, and each buffer reports back when it has been consumed so
    /// the next can follow. Everything touching the queue or the node happens on one serial queue,
    /// which is what keeps frames in order; `flush` is awaited by the call before it plays anything
    /// new, so a flush never swallows fresh audio.
    final class AppleVoicePlayer: @unchecked Sendable {
        static let levelTail = 0.05

        let meter = AppleVoiceMeter()
        private let work = DispatchQueue(label: "com.guitaripod.tailscode.voice.player")
        private let format: AVAudioFormat
        private var jitter: VoiceJitterQueue
        private var node: AVAudioPlayerNode?
        private var generation = 0

        init(policy: VoiceJitter) {
            jitter = VoiceJitterQueue(policy: policy)
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(VoicePCM.sampleRate), channels: 1,
                interleaved: false)!
        }

        var nodeFormat: AVAudioFormat { format }

        func attach(_ node: AVAudioPlayerNode) {
            work.sync {
                self.node = node
                generation += 1
                pump()
            }
        }

        func detach() {
            work.sync {
                node = nil
                generation += 1
                jitter.reset()
                meter.clear()
            }
        }

        func enqueue(_ pcm: Data) {
            work.async { [self] in
                jitter.push(pcm, at: ProcessInfo.processInfo.systemUptime)
                pump()
            }
        }

        func flush() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                work.async { [self] in
                    generation += 1
                    jitter.reset()
                    meter.clear()
                    if let node, node.engine?.isRunning == true {
                        node.stop()
                        node.reset()
                        node.play()
                    }
                    done.resume()
                }
            }
        }

        private func pump() {
            guard let node, node.engine?.isRunning == true else { return }
            for frame in jitter.take(at: ProcessInfo.processInfo.systemUptime) {
                schedule(frame, on: node)
            }
        }

        private func schedule(_ frame: Data, on node: AVAudioPlayerNode) {
            let samples = VoicePCM.decode(frame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let target = buffer.floatChannelData
            else {
                jitter.consumed(milliseconds: VoicePCM.milliseconds(forBytes: frame.count))
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { target[0].update(from: $0.baseAddress!, count: samples.count) }
            let milliseconds = VoicePCM.milliseconds(forBytes: frame.count)
            let level = VoicePCM.rms(of: frame)
            let scheduledIn = generation
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [self] _ in
                work.async { [self] in
                    guard scheduledIn == generation else { return }
                    jitter.consumed(milliseconds: milliseconds)
                    meter.set(level, holdingFor: milliseconds / 1000 + Self.levelTail)
                    pump()
                }
            }
        }
    }
#endif
