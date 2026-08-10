import Foundation

/// What a picture's bytes actually are, judged from magic numbers rather than from a filename
/// that may be missing or lying. Every save path uses this so the file written carries the
/// extension of the bytes the server sent — the one thing a re-encode can never promise.
public enum ImageBytes {
    public static func sniffedExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if head[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]),
            head[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50])
        {
            return "webp"
        }
        if head[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) { return "heic" }
        return nil
    }

    /// What to call the bytes when they are handed to a model: the container they actually are,
    /// never the one a picker's filename claimed. A pasteboard image, a camera frame and a photo
    /// library original arrive as three different containers under the same request, and a mime
    /// that disagrees with the bytes is refused on the other machine.
    public static func kind(of data: Data) -> (mime: String, ext: String) {
        let ext = sniffedExtension(data) ?? "jpg"
        return (AttachmentIntake.mime(forExtension: ext), ext)
    }

    /// The name to save under: the given one, gaining the sniffed extension only when it has
    /// none of its own.
    public static func exportFilename(_ filename: String, data: Data) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "image" : trimmed
        guard (base as NSString).pathExtension.isEmpty,
            let ext = sniffedExtension(data)
        else { return base }
        return base + "." + ext
    }
}
