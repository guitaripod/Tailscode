import Foundation

/// One frame of the picture as it is being painted. ComfyUI decodes the sampler's latent to a
/// small picture after every step and sends it down the same socket the progress comes on, as a
/// binary frame rather than a JSON one: four bytes naming the event, then — for a preview —
/// four bytes naming the encoding and the encoded bytes. A frame is the machine's own sketch of
/// where the picture stands, so a stage that shows it is showing the truth a step at a time
/// rather than a pulse over a blank.
public struct ImageGenPreviewFrame: Sendable, Equatable {
    public enum Encoding: Sendable, Equatable {
        case jpeg
        case png
    }

    public let encoding: Encoding
    public let bytes: Data

    public init(encoding: Encoding, bytes: Data) {
        self.encoding = encoding
        self.bytes = bytes
    }

    /// ComfyUI's binary event numbers: a preview, and a preview with a JSON block in front of it
    /// naming the node, which the server sends only to a client that asked for that shape.
    static let previewEvent: UInt32 = 1
    static let previewWithMetadataEvent: UInt32 = 4

    /// Reads one binary socket frame. Anything that is not a preview — a text event, an unknown
    /// number, a frame too short to hold its own header — reads as nil rather than as a picture.
    public static func read(_ frame: Data) -> ImageGenPreviewFrame? {
        guard frame.count >= 8 else { return nil }
        let event = frame.bigEndian32(at: frame.startIndex)
        switch event {
        case previewEvent:
            return readPicture(frame, from: frame.startIndex + 4)
        case previewWithMetadataEvent:
            let length = Int(frame.bigEndian32(at: frame.startIndex + 4))
            let start = frame.startIndex + 8 + length
            guard length >= 0, start + 4 <= frame.endIndex else { return nil }
            return readPicture(frame, from: start)
        default:
            return nil
        }
    }

    private static func readPicture(_ frame: Data, from start: Data.Index) -> ImageGenPreviewFrame? {
        guard start + 4 <= frame.endIndex else { return nil }
        let kind = frame.bigEndian32(at: start)
        let bytes = frame[(start + 4)...]
        guard !bytes.isEmpty else { return nil }
        switch kind {
        case 1: return ImageGenPreviewFrame(encoding: .jpeg, bytes: Data(bytes))
        case 2: return ImageGenPreviewFrame(encoding: .png, bytes: Data(bytes))
        default: return nil
        }
    }
}

/// Puts a preview back together from the pieces a socket hands over. The machine sends one
/// binary message per sketch, but not every WebSocket client hands a message over whole: the
/// one under Linux Foundation delivers it in sixteen-kilobyte pieces, each as if it were a
/// message of its own, and a sketch read from the first piece alone is a picture with a grey
/// band across its bottom. So the pieces are gathered until the encoding's own end marker —
/// JPEG's `FF D9`, PNG's `IEND` — closes the picture, and only then is a frame handed on. A
/// client that delivers whole messages passes straight through, one piece per frame.
public struct ImageGenPreviewAssembler: Sendable, Equatable {
    private var pending: (encoding: ImageGenPreviewFrame.Encoding, bytes: Data)?
    /// A sketch past this size is not a sketch; the machine bounds them to a few hundred pixels.
    static let ceiling = 8 * 1024 * 1024

    public init() {}

    /// Feeds one binary message or piece. Answers with the frame it completes, if any.
    public mutating func feed(_ chunk: Data) -> ImageGenPreviewFrame? {
        if var held = pending {
            held.bytes.append(chunk)
            if Self.isComplete(held.bytes, encoding: held.encoding) {
                pending = nil
                return ImageGenPreviewFrame(encoding: held.encoding, bytes: held.bytes)
            }
            pending = held.bytes.count > Self.ceiling ? nil : held
            return nil
        }
        guard let frame = ImageGenPreviewFrame.read(chunk) else { return nil }
        if Self.isComplete(frame.bytes, encoding: frame.encoding) { return frame }
        pending = (frame.encoding, frame.bytes)
        return nil
    }

    /// Whether the bytes end where the encoding says a picture ends.
    public static func isComplete(_ bytes: Data, encoding: ImageGenPreviewFrame.Encoding) -> Bool {
        switch encoding {
        case .jpeg:
            guard bytes.count >= 4 else { return false }
            return bytes[bytes.endIndex - 2] == 0xFF && bytes[bytes.endIndex - 1] == 0xD9
        case .png:
            guard bytes.count >= 12 else { return false }
            let tail = Array(bytes.suffix(8))
            return tail == [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        }
    }

    public static func == (lhs: ImageGenPreviewAssembler, rhs: ImageGenPreviewAssembler) -> Bool {
        lhs.pending?.encoding == rhs.pending?.encoding && lhs.pending?.bytes == rhs.pending?.bytes
    }
}

extension Data {
    fileprivate func bigEndian32(at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(self[index + offset])
        }
        return value
    }
}

/// What a stage says about a sketch: its caption for a screen reader, and the note under it.
public enum ImageGenPreviewWords {
    public static var note: String {
        Localized.text("the machine's own sketch of the picture so far")
    }

    public static func caption(_ progress: ImageGenProgress?) -> String {
        guard let progress, let step = progress.step, let steps = progress.steps, steps > 0 else {
            return Localized.text("Sketch")
        }
        return Localized.text("Sketch · step %@ of %@", "\(min(step, steps))", "\(steps)")
    }
}
