import Foundation
import Testing

@testable import TailscodeCore

private func sine(amplitude: Float, frequency: Double = 220, count: Int = 1920) -> Data {
    let samples = (0..<count).map { index in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(VoicePCM.sampleRate)))
    }
    return VoicePCM.encode(samples)
}

private func ramp(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
}

@Suite("VoicePCM conversion")
struct VoicePCMTests {
    @Test("a chunk is 80 ms of 24 kHz mono PCM16, 3840 bytes")
    func chunkSize() {
        #expect(VoicePCM.chunkBytes == 3840)
        #expect(VoicePCM.bytes(forMilliseconds: 80) == 3840)
        #expect(VoicePCM.milliseconds(forBytes: 3840) == 80)
        #expect(VoicePCM.bytes(forMilliseconds: -5) == 0)
        #expect(VoicePCM.milliseconds(forBytes: -5) == 0)
    }

    @Test("samples are written little-endian")
    func littleEndian() {
        let data = VoicePCM.encode([1, -1, 0, 0.5])
        #expect(Array(data) == [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00, 0x00, 0x40])
    }

    @Test("out of range and non-finite samples are clamped or silenced")
    func clamping() {
        let data = VoicePCM.encode([2, -3, .nan, .infinity, -.infinity])
        #expect(Array(data) == [0xFF, 0x7F, 0x01, 0x80, 0, 0, 0, 0, 0, 0])
    }

    @Test("float to PCM16 to float stays within two least significant bits")
    func roundTrip() {
        let source: [Float] = [0, 0.25, -0.25, 0.999, -0.999, 0.0001, -0.5, 1, -1]
        let back = VoicePCM.decode(VoicePCM.encode(source))
        #expect(back.count == source.count)
        for (original, restored) in zip(source, back) {
            #expect(abs(original - restored) <= 2.0 / 32768 + 1e-6)
        }
    }

    @Test("decode reads whole samples only and works on a slice that does not start at zero")
    func decodeOddAndSlice() {
        let data = VoicePCM.encode([0.5, -0.5, 0.25])
        #expect(VoicePCM.decode(data.prefix(5)).count == 2)
        let slice = data.suffix(4)
        #expect(slice.startIndex != 0)
        let samples = VoicePCM.decode(slice)
        #expect(samples.count == 2)
        #expect(abs(samples[0] + 0.5) < 0.001)
        #expect(abs(samples[1] - 0.25) < 0.001)
        #expect(VoicePCM.decode(Data()).isEmpty)
        #expect(VoicePCM.decode(Data([1])).isEmpty)
    }

    @Test("silence and nothing read zero, full scale reads one")
    func extremes() {
        #expect(VoicePCM.rms(of: Data()) == 0)
        #expect(VoicePCM.rms(of: Data(count: 3840)) == 0)
        let fullScale = VoicePCM.encode([Float](repeating: 1, count: 1920))
        #expect(VoicePCM.rms(of: fullScale) > 0.99)
        #expect(VoicePCM.rms(of: fullScale) <= 1)
    }

    @Test("ordinary speech reads between 0.3 and 0.7")
    func speechBand() {
        for amplitude: Float in [0.035, 0.1, 0.2] {
            let level = VoicePCM.rms(of: sine(amplitude: amplitude))
            #expect(level > 0.3 && level < 0.7, "amplitude \(amplitude) read \(level)")
        }
    }

    @Test("louder always reads higher, and a whisper reads low")
    func monotone() {
        let levels = [0.002, 0.01, 0.05, 0.2, 0.8].map { VoicePCM.rms(of: sine(amplitude: Float($0))) }
        #expect(levels == levels.sorted())
        #expect(levels[0] < 0.1)
    }

    @Test("a slice and an odd trailing byte do not change the reading")
    func sliceAndOdd() {
        let data = sine(amplitude: 0.1)
        var padded = Data([0xAA, 0xBB])
        padded.append(data)
        padded.append(0x7F)
        let slice = padded.dropFirst(2).dropLast()
        #expect(slice.startIndex != 0)
        #expect(VoicePCM.rms(of: padded.dropFirst(2)) == VoicePCM.rms(of: data))
        #expect(VoicePCM.rms(of: Data(slice)) == VoicePCM.rms(of: data))
    }

    @Test("linear rms of a square wave is its amplitude")
    func linear() {
        let square = VoicePCM.encode([0.5, -0.5, 0.5, -0.5])
        #expect(abs(VoicePCM.linearRMS(of: square) - 0.5) < 0.001)
        #expect(VoicePCM.level(forLinearRMS: .nan) == 0)
        #expect(VoicePCM.level(forLinearRMS: -1) == 0)
        #expect(VoicePCM.level(forLinearRMS: 5) == 1)
    }
}

@Suite("VoicePCM chunker")
struct VoicePCMChunkerTests {
    @Test("every chunk is exactly 3840 bytes and the rest is kept")
    func exactChunks() {
        var chunker = VoiceChunker()
        let chunks = chunker.append(ramp(3840 * 2 + 100))
        #expect(chunks.map(\.count) == [3840, 3840])
        #expect(chunker.pendingBytes == 100)
    }

    @Test("a buffer smaller than a chunk waits for the next one")
    func smallBuffers() {
        var chunker = VoiceChunker()
        #expect(chunker.append(ramp(1000)).isEmpty)
        #expect(chunker.append(ramp(2000)).isEmpty)
        #expect(chunker.pendingBytes == 3000)
        let chunks = chunker.append(ramp(900))
        #expect(chunks.map(\.count) == [3840])
        #expect(chunker.pendingBytes == 60)
    }

    @Test("the bytes come out in the order they went in, across any buffer sizes")
    func orderPreserved() {
        let source = ramp(20_000)
        var chunker = VoiceChunker()
        var out = Data()
        var offset = 0
        for size in [1, 7, 4096, 333, 3840, 5, 9000, 1717] {
            let end = min(offset + size, source.count)
            for chunk in chunker.append(source[offset..<end]) { out.append(chunk) }
            offset = end
        }
        for chunk in chunker.append(source[offset...]) { out.append(chunk) }
        #expect(out.count + chunker.pendingBytes == source.count)
        #expect(out == source.prefix(out.count))
        #expect(out.count % 3840 == 0)
    }

    @Test("an empty buffer changes nothing and reset forgets the remainder")
    func emptyAndReset() {
        var chunker = VoiceChunker()
        #expect(chunker.append(Data()).isEmpty)
        _ = chunker.append(ramp(500))
        #expect(chunker.pendingBytes == 500)
        chunker.reset()
        #expect(chunker.pendingBytes == 0)
        #expect(chunker.append(ramp(3840)).map(\.count) == [3840])
    }

    @Test("a chunk size is kept even and at least one sample")
    func chunkSizeClamped() {
        #expect(VoiceChunker(chunkBytes: 101).chunkBytes == 100)
        #expect(VoiceChunker(chunkBytes: 0).chunkBytes == 2)
        #expect(VoiceChunker(chunkBytes: -8).chunkBytes == 2)
    }

    @Test("a slice that does not start at zero is cut correctly")
    func sliceInput() {
        var chunker = VoiceChunker(chunkBytes: 4)
        let source = Data([9, 9, 1, 2, 3, 4, 5, 6])
        let chunks = chunker.append(source.dropFirst(2))
        #expect(chunks == [Data([1, 2, 3, 4])])
        #expect(chunker.pendingBytes == 2)
        #expect(chunker.append(Data([7, 8])) == [Data([5, 6, 7, 8])])
    }
}

@Suite("VoicePCM jitter")
struct VoicePCMJitterTests {
    private let frame = Data(count: VoicePCM.chunkBytes)

    @Test("the policy clamps itself to something that can work")
    func policyClamped() {
        let policy = VoiceJitter(
            prebufferMilliseconds: -1, lateAfterMilliseconds: -1, maxQueuedMilliseconds: 10,
            lookaheadMilliseconds: 0)
        #expect(policy.prebufferMilliseconds == 0)
        #expect(policy.lateAfterMilliseconds == 0)
        #expect(policy.lookaheadMilliseconds == 80)
        #expect(policy.maxQueuedMilliseconds == 80)
    }

    @Test("start, late and overflow decisions")
    func decisions() {
        let policy = VoiceJitter.standard
        #expect(!policy.shouldStart(queuedMilliseconds: 119))
        #expect(policy.shouldStart(queuedMilliseconds: 120))
        #expect(!policy.isLate(waitedMilliseconds: 1000))
        #expect(policy.isLate(waitedMilliseconds: 1001))
        #expect(policy.overflow(queuedMilliseconds: 1500) == 0)
        #expect(policy.overflow(queuedMilliseconds: 1700) == 200)
    }

    @Test("nothing plays until the prebuffer is held, then the device is kept a short way ahead")
    func prebufferThenLookahead() {
        var queue = VoiceJitterQueue(policy: .standard)
        queue.push(frame, at: 0)
        #expect(queue.take(at: 0).isEmpty)
        #expect(!queue.isPlaying)
        queue.push(frame, at: 0.08)
        #expect(queue.take(at: 0.08).count == 2)
        #expect(queue.isPlaying)
        for index in 0..<5 { queue.push(frame, at: 0.16 + Double(index) * 0.08) }
        #expect(queue.take(at: 0.6).count == 1)
        #expect(queue.take(at: 0.6).isEmpty)
        queue.consumed(milliseconds: 80)
        #expect(queue.take(at: 0.7).count == 1)
    }

    @Test("running dry goes back to prebuffering")
    func underrun() {
        var queue = VoiceJitterQueue(policy: .standard)
        queue.push(frame, at: 0)
        queue.push(frame, at: 0.01)
        let handed = queue.take(at: 0.01)
        #expect(handed.count == 2)
        queue.consumed(milliseconds: 80)
        #expect(queue.isPlaying)
        queue.consumed(milliseconds: 80)
        #expect(!queue.isPlaying)
        queue.push(frame, at: 1)
        #expect(queue.take(at: 1).isEmpty)
        queue.push(frame, at: 1.08)
        #expect(queue.take(at: 1.08).count == 2)
    }

    @Test("too much waiting drops the oldest and keeps the newest")
    func overflowDropsOldest() {
        let policy = VoiceJitter(
            prebufferMilliseconds: 80, lateAfterMilliseconds: 60_000, maxQueuedMilliseconds: 400,
            lookaheadMilliseconds: 80)
        var queue = VoiceJitterQueue(policy: policy)
        for index in 0..<10 { queue.push(Data(repeating: UInt8(index), count: 3840), at: 0) }
        #expect(queue.waitingMilliseconds <= 400)
        #expect(queue.droppedFrames == 5)
        let handed = queue.take(at: 0)
        #expect(handed.first?.first == 5)
    }

    @Test("audio that waited too long is dropped instead of played late")
    func lateDropped() {
        var queue = VoiceJitterQueue(policy: .standard)
        queue.push(frame, at: 0)
        queue.push(frame, at: 0.5)
        queue.push(frame, at: 1.2)
        let handed = queue.take(at: 1.3)
        #expect(handed.count == 2)
        #expect(queue.droppedFrames == 1)
    }

    @Test("reset forgets everything and an odd byte is trimmed")
    func resetAndOdd() {
        var queue = VoiceJitterQueue(policy: .standard)
        queue.push(Data(count: 3841), at: 0)
        #expect(queue.waitingMilliseconds == 80)
        queue.push(Data([1]), at: 0)
        queue.push(Data(), at: 0)
        #expect(queue.waitingMilliseconds == 80)
        queue.push(frame, at: 0)
        _ = queue.take(at: 0)
        queue.reset()
        #expect(queue.queuedMilliseconds == 0)
        #expect(!queue.isPlaying)
        #expect(queue.take(at: 0).isEmpty)
    }
}
