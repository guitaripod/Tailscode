import CodingAgentKit
import Foundation

/// The two sounds a call makes by itself, as the PCM the call's own speaker takes: PCM16
/// little-endian, mono, 24 kHz. A client plays them through `VoiceAudioPlayback.play(_:)` so they
/// follow the call's audio route and its echo cancellation, and no platform type is involved.
public enum VoiceChime {
    public static let attack: TimeInterval = 0.015
    public static let taper: TimeInterval = 0.005

    private struct Note {
        let frequency: Double
        let start: TimeInterval
        let length: TimeInterval
    }

    /// The agent finished while the person was quiet: two soft notes a fifth apart, about 420 ms,
    /// peaking near -14 dBFS.
    public static func finished() -> Data {
        render(
            [Note(frequency: 523.25, start: 0, length: 0.21), Note(frequency: 783.99, start: 0.21, length: 0.21)],
            peak: 0.2)
    }

    /// A question or an approval is waiting: one lower, softer note, about 250 ms.
    public static func attention() -> Data {
        render([Note(frequency: 392, start: 0, length: 0.25)], peak: 0.1)
    }

    private static func render(_ notes: [Note], peak: Double) -> Data {
        let rate = Double(VoiceWire.sampleRate)
        let total = Int(((notes.map { $0.start + $0.length }.max() ?? 0) * rate).rounded())
        var mix = [Double](repeating: 0, count: total)
        for note in notes {
            let first = Int((note.start * rate).rounded())
            let count = Int((note.length * rate).rounded())
            for index in 0..<count where first + index < total {
                let time = Double(index) / rate
                mix[first + index] += sin(2 * Double.pi * note.frequency * time) * envelope(at: time, length: note.length)
            }
        }
        let loudest = mix.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak * Double(Int16.max) / loudest : 0
        var data = Data(capacity: total * 2)
        for value in mix {
            let sample = Int16(max(-Double(Int16.max), min(Double(Int16.max), (value * scale).rounded())))
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }

    /// A linear attack, an exponential release that has fallen to a quarter of a percent by the end
    /// of the note, and a raised-cosine taper over the last few milliseconds so it ends on zero.
    private static func envelope(at time: TimeInterval, length: TimeInterval) -> Double {
        let rise = min(1, time / attack)
        let fall = exp(-6 * time / length)
        let remaining = length - time
        let close = remaining >= taper ? 1 : 0.5 * (1 - cos(Double.pi * max(0, remaining) / taper))
        return rise * fall * close
    }
}
