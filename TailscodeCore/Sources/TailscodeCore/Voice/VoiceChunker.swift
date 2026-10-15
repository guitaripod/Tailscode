import Foundation

/// Re-cuts audio of any buffer size into chunks of exactly `chunkBytes`, keeping what is left over
/// for the next buffer. The remainder is a byte stream, so a buffer that ends mid-sample is joined
/// to the one after it rather than losing half a sample.
public struct VoiceChunker: Sendable {
    public let chunkBytes: Int
    private var held = Data()

    public init(chunkBytes: Int = VoicePCM.chunkBytes) {
        self.chunkBytes = max(2, chunkBytes - chunkBytes % 2)
    }

    public var pendingBytes: Int { held.count }

    public mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        held.append(data)
        var chunks: [Data] = []
        var offset = 0
        let base = held.startIndex
        while held.count - offset >= chunkBytes {
            chunks.append(Data(held[(base + offset)..<(base + offset + chunkBytes)]))
            offset += chunkBytes
        }
        if offset > 0 { held = Data(held[(base + offset)...]) }
        return chunks
    }

    public mutating func reset() {
        held = Data()
    }
}
