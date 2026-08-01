import Photos
import UIKit
import UniformTypeIdentifiers

/// A picture in the conversation together with the bytes it arrived as. Saving
/// and sharing use the original bytes wherever they exist: a screenshot the
/// agent sent is a PNG, and re-encoding it from the decoded bitmap would hand
/// the photo library a different, larger, lossier file than the one on the
/// server.
struct ImagePayload: Sendable {
    let image: UIImage
    let data: Data?
    let filename: String

    init(image: UIImage, data: Data?, filename: String) {
        self.image = image
        self.data = data
        self.filename = filename
    }

    var type: UTType {
        if let data, let identified = ImagePayload.type(of: data) { return identified }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? .png
    }

    /// Bytes fit to write out: the originals when they are a format everything
    /// downstream understands, a PNG rendering when they are not (or absent).
    var exportData: Data {
        if let data, ImagePayload.type(of: data) != nil { return data }
        return image.pngData() ?? image.jpegData(compressionQuality: 0.95) ?? Data()
    }

    var exportFilename: String {
        let name = filename.isEmpty ? String(localized: "Image") : filename
        let preferred = type.preferredFilenameExtension ?? "png"
        guard (name as NSString).pathExtension.isEmpty else { return name }
        return "\(name).\(preferred)"
    }

    /// Sniffed from the bytes rather than trusted from the filename — a server
    /// path says `.png` about whatever was written to it.
    private static func type(of data: Data) -> UTType? {
        let prefix = [UInt8](data.prefix(12))
        guard prefix.count >= 12 else { return nil }
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return .gif }
        if prefix.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(prefix[8..<12]) == Array("WEBP".utf8)
        {
            return .webP
        }
        if Array(prefix[4..<8]) == Array("ftyp".utf8) { return .heic }
        return nil
    }
}

/// Getting a picture out of the chat: into the photo library, the pasteboard,
/// the Files app, or whatever a share sheet offers.
enum ImageExport {
    enum Outcome: Sendable {
        case saved
        case denied
        case failed
    }

    /// Asks only for add-only access — the app writes one picture and never
    /// reads the library, and the add-only prompt says exactly that.
    static func saveToPhotos(_ payload: ImagePayload) async -> Outcome {
        let bytes = payload.exportData
        let fallback = payload.image.pngData()
        guard !bytes.isEmpty else { return .failed }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        if await write(bytes) { return .saved }
        if let fallback, fallback != bytes, await write(fallback) { return .saved }
        AppLogger.ui.error("save to photos failed for \(payload.exportFilename)")
        return .failed
    }

    private static func write(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Puts both the original bytes and a decoded image on the pasteboard, so a
    /// paste target that understands PNG gets the PNG and one that only speaks
    /// UIImage still gets something.
    @MainActor
    static func copy(_ payload: ImagePayload) {
        let bytes = payload.exportData
        guard !bytes.isEmpty else {
            UIPasteboard.general.image = payload.image
            return
        }
        UIPasteboard.general.setItems([[payload.type.identifier: bytes]])
    }

    /// Writes the picture where a share sheet or the Files exporter can take
    /// it from, under the name it has on the server.
    static func temporaryFile(_ payload: ImagePayload) -> URL? {
        let bytes = payload.exportData
        guard !bytes.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)
        let url = directory.appendingPathComponent(sanitized(payload.exportFilename))
        do {
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            AppLogger.ui.error("could not stage \(payload.exportFilename): \(error)")
            return nil
        }
    }

    /// A staged copy only has to outlive the share sheet that reads it, so an
    /// hour-old one is litter in the app's temp directory.
    private static func prune(_ directory: URL) {
        guard
            let staged = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in staged {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.map { $0 == "/" || $0 == ":" ? "_" : $0 }
        return String(String(cleaned).suffix(80))
    }
}
