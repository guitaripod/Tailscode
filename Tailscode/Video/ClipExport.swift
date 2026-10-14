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

    /// Brings the renderer's file onto this device under the name given, straight to disk: a clip
    /// is tens of megabytes, and holding all of it in memory for a share sheet is what a phone
    /// under pressure kills the app for. The name is the clip's own words and seed, so two clips
    /// the renderer filed under the same name on different days never overwrite each other here.
    static func download(_ asset: ForgeAsset, named name: String, from endpoint: ForgeEndpoint)
        async throws -> URL
    {
        guard let source = asset.url(on: endpoint) else {
            throw ForgeFailure.unreachable(endpoint.host)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)
        let request = URLRequest(url: source, timeoutInterval: 120)
        let received: URL
        let response: URLResponse
        do {
            (received, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw ForgeFailure.unreachable(endpoint.host)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 || status == 410 { throw ForgeFailure.missingFile(endpoint.host) }
        guard status < 400 else { throw ForgeFailure.unreachable(endpoint.host) }
        let staged = directory.appendingPathComponent(sanitized(name))
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: received, to: staged)
            return staged
        } catch {
            AppLogger.ui.error("could not stage \(name): \(error)")
            throw ForgeFailure.unreachable(endpoint.host)
        }
    }

    static func share(_ url: URL, from presenter: UIViewController, source: UIView?) {
        let presenter = presenter.frontmostPresented
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

extension UIViewController {
    /// The controller a new sheet can actually be presented from. A controller that is already
    /// presenting something — an alert, another sheet, the system player — refuses a second
    /// presentation without a word, so the answer is whatever sits on top of the chain.
    var frontmostPresented: UIViewController {
        var top = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
