import Foundation

/// How loud a stretch of PCM16 little-endian audio is, as the number a level meter draws.
///
/// The root mean square of the samples against full scale, brought up by a fixed gain because speech
/// sits far below full scale and a meter that only reached a tenth of its height for a shout would
/// read as a quiet room. Pure arithmetic, so the same chunk always reads the same.
enum PCMLevel {
    static let gain = 4.0

    static func rms(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                let unit = Double(sample) / 32768
                sum += unit * unit
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    static func level(_ pcm: Data) -> Double {
        min(1, rms(pcm) * gain)
    }
}
