import Foundation

public enum VoiceAudioError: Error, Sendable, Equatable {
    case microphoneDenied
    case unavailable(String)
}

/// The microphone, as the call needs it: PCM16 little-endian, mono, 24 kHz, echo cancelled by the
/// client, delivered in chunks and never after `stop()`. A client implements it over its own audio
/// stack and throws `VoiceAudioError.microphoneDenied` when the person has said no.
public protocol VoiceAudioCapture: Sendable {
    func start() async throws -> AsyncStream<Data>
    func stop() async
    /// How loud the person is right now, `0...1`, read from the display clock.
    var level: Double { get }
}

/// The speaker, taking the same PCM the gateway sends and playing it through a jitter buffer.
public protocol VoiceAudioPlayback: Sendable {
    func start() async throws
    func play(_ pcm: Data) async
    /// Drops everything queued and not yet heard, at once. The call does this the moment the person
    /// talks over the voice.
    func flush() async
    func stop() async
    /// How loud the voice is right now, `0...1`, read from the display clock.
    var level: Double { get }
}

public enum VoiceChunks {
    /// A chunk the gateway will accept: even in length and no longer than `VoiceWire.maxChunkBytes`.
    /// A longer one is cut into pieces, and an odd trailing byte, which is half a sample, is dropped.
    public static func split(_ data: Data, limit: Int) -> [Data] {
        let usable = data.count - data.count % 2
        guard usable > 0 else { return [] }
        let step = max(2, limit - limit % 2)
        var pieces: [Data] = []
        var start = data.startIndex
        let end = data.startIndex + usable
        while start < end {
            let next = min(start + step, end)
            pieces.append(data[start..<next])
            start = next
        }
        return pieces
    }
}
