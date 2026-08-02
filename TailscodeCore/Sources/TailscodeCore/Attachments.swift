import CodingAgentKit
import Foundation

/// A file waiting in the composer: read fully at pick time, so a file edited or deleted between
/// picking and sending still sends the bytes that were chosen. The id is what a chip's remove
/// button holds — two queued clicks by position would delete the wrong file.
public struct PendingAttachment: Sendable {
    public let id = UUID()
    public let name: String
    public let mime: String
    public let data: Data

    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }

    public var prompt: PromptAttachment {
        PromptAttachment(mime: mime, filename: name, data: data)
    }
}

public enum AttachmentIntake {
    public struct Refusal: Error, Sendable {
        public let message: String
    }

    public static let byteCap = 8 * 1024 * 1024

    public static func read(path: String) -> Result<PendingAttachment, Refusal> {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            return .failure(Refusal(message: Localized.text("Could not read %@", url.lastPathComponent)))
        }
        guard data.count <= byteCap else {
            return .failure(
                Refusal(message: Localized.text(
                    "%@ is %@ — the cap is 8 MB", url.lastPathComponent, sizeText(data.count))))
        }
        return .success(
            PendingAttachment(
                name: url.lastPathComponent, mime: mime(forExtension: url.pathExtension),
                data: data))
    }

    public static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "": return "application/octet-stream"
        default: return "text/plain"
        }
    }

    public static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}
