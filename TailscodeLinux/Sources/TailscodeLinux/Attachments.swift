import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A file waiting in the composer: read fully at pick time, so a file edited or deleted between
/// picking and sending still sends the bytes that were chosen. The id is what a chip's remove
/// button holds — two queued clicks by position would delete the wrong file.
struct PendingAttachment {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data

    var prompt: PromptAttachment {
        PromptAttachment(mime: mime, filename: name, data: data)
    }
}

enum AttachmentIntake {
    struct Refusal: Error {
        let message: String
    }

    static let byteCap = 8 * 1024 * 1024

    static func read(path: String) -> Result<PendingAttachment, Refusal> {
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

    static func mime(forExtension ext: String) -> String {
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

    static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

extension Gtk {
    /// The file chooser, completed back into Swift on the GLib main context. Cancel calls back
    /// with an empty list, so the caller never waits on a dialog that already closed.
    static func openFiles(
        parent: UnsafeMutablePointer<GtkWidget>?, _ handler: @escaping ([String]) -> Void
    ) {
        let box = Unmanaged.passRetained(PathListBox(handler)).toOpaque()
        let callback:
            @convention(c) (
                UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafeMutableRawPointer?
            ) -> Void = { paths, count, raw in
                guard let raw else { return }
                let box = Unmanaged<PathListBox>.fromOpaque(raw).takeRetainedValue()
                var result: [String] = []
                if let paths {
                    for index in 0..<Int(count) {
                        if let path = paths[index] { result.append(String(cString: path)) }
                    }
                }
                box.handler(result)
            }
        let window: UnsafeMutablePointer<GtkWindow>? = parent.map {
            ptr(UnsafeMutableRawPointer($0))
        }
        tailscode_file_open(window, callback, box)
    }

    /// The clipboard as PNG bytes, or nil when it holds no picture.
    static func readClipboardImage(_ handler: @escaping (Data?) -> Void) {
        let box = Unmanaged.passRetained(ImageBox(handler)).toOpaque()
        let callback: @convention(c) (UnsafeRawPointer?, gsize, UnsafeMutableRawPointer?) -> Void =
            { bytes, length, raw in
                guard let raw else { return }
                let box = Unmanaged<ImageBox>.fromOpaque(raw).takeRetainedValue()
                guard let bytes, length > 0 else {
                    box.handler(nil)
                    return
                }
                box.handler(Data(bytes: bytes, count: Int(length)))
            }
        tailscode_clipboard_read_image(callback, box)
    }

    final class PathListBox {
        let handler: ([String]) -> Void
        init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
    }

    final class ImageBox {
        let handler: (Data?) -> Void
        init(_ handler: @escaping (Data?) -> Void) { self.handler = handler }
    }
}
