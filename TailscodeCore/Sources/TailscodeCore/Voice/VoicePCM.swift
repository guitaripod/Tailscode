import Foundation

/// The call's audio format and the arithmetic on it that needs no audio framework: PCM16
/// little-endian mono at 24 kHz, which is what the gateway takes and gives.
public enum VoicePCM {
    public static let sampleRate = 24_000
    public static let bytesPerSample = 2
    public static let chunkMilliseconds = 80
    public static let chunkBytes = bytes(forMilliseconds: chunkMilliseconds)
    /// The quietest level the meter tells from silence, in decibels below full scale.
    public static let floorDecibels = -50.0

    public static func bytes(forMilliseconds milliseconds: Int) -> Int {
        max(0, milliseconds) * sampleRate / 1000 * bytesPerSample
    }

    public static func milliseconds(forBytes bytes: Int) -> Double {
        Double(max(0, bytes)) * 1000 / Double(sampleRate * bytesPerSample)
    }

    public static func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { encode($0) }
    }

    public static func encode(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples.count * bytesPerSample)
        for index in samples.indices {
            let raw = UInt16(bitPattern: quantised(samples[index]))
            bytes[index * 2] = UInt8(truncatingIfNeeded: raw)
            bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: raw >> 8)
        }
        return Data(bytes)
    }

    /// Samples in `-1...1`. An odd trailing byte is half a sample and is dropped.
    public static func decode(_ pcm: Data) -> [Float] {
        let count = pcm.count / bytesPerSample
        guard count > 0 else { return [] }
        return pcm.withUnsafeBytes { raw in
            (0..<count).map { Float(sample(raw, at: $0)) / 32768 }
        }
    }

    /// How loud a chunk is, `0...1`: its RMS on a decibel scale that runs from `floorDecibels` to
    /// full scale, so speech at ordinary levels (about -35 to -15 dBFS) reads between 0.3 and 0.7
    /// and silence reads 0.
    public static func rms(of pcm: Data) -> Double {
        level(forLinearRMS: linearRMS(of: pcm))
    }

    /// The plain root mean square of a chunk, `0...1`, before the decibel scale.
    public static func linearRMS(of pcm: Data) -> Double {
        let count = pcm.count / bytesPerSample
        guard count > 0 else { return 0 }
        let sumOfSquares = pcm.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for index in 0..<count {
                let value = Double(sample(raw, at: index)) / 32768
                total += value * value
            }
            return total
        }
        return (sumOfSquares / Double(count)).squareRoot()
    }

    public static func level(forLinearRMS value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        let decibels = 20 * log10(value)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    private static func quantised(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((min(max(value, -1), 1) * 32767).rounded())
    }

    private static func sample(_ raw: UnsafeRawBufferPointer, at index: Int) -> Int16 {
        let low = UInt16(raw[index * 2])
        let high = UInt16(raw[index * 2 + 1])
        return Int16(bitPattern: low | high << 8)
    }
}
