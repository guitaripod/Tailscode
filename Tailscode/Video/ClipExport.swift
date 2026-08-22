import TailscodeCore
import UIKit

/// Getting a clip off the renderer and into whatever the phone wants to do with it.
///
/// The bytes are always the file the renderer wrote, fetched by the same three fields a player is
/// pointed at, so what lands in Photos or a message is the render rather than a re-encode of the
/// frames a preview happened to decode. The system share sheet is the whole destination list:
/// saving to the photo library, sending it on and putting it in Files are all things it already
/// offers for a video file, and none of them are worth rebuilding as buttons.
@MainActor
enum ClipExport {
    /// Where a clip is staged for a share sheet to read it from. A staged copy only has to outlive
    /// the sheet, so anything left from an hour ago is litter.
    private static let folder = "shared-clips"
    private static let staleAfter: TimeInterval = 3600

    static func stage(_ data: Data, as asset: ForgeAsset) -> URL? {
        guard !data.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)
        let url = directory.appendingPathComponent(sanitized(asset.filename))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            AppLogger.ui.error("could not stage \(asset.filename): \(error)")
            return nil
        }
    }

    static func share(_ url: URL, from presenter: UIViewController, source: UIView?) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source ?? presenter.view
        sheet.popoverPresentationController?.sourceRect =
            source?.bounds ?? CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(sheet, animated: true)
    }

    private static func prune(_ directory: URL) {
        guard
            let staged = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
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
