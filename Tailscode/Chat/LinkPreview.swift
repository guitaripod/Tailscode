import Foundation
import TailscodeCore
import UIKit

/// The iOS face of the shared link fetcher: Core asks the network and keeps the bytes, this keeps
/// the decoded pictures. A row re-rendered on every streamed arrival — or scrolled away and back —
/// costs one request per URL, not one per appearance, and one decode per icon.
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()
    private init() {}

    private let imageCache = NSCache<NSString, UIImage>()

    /// The page's title and icon address — nil only when the page cannot be read at all.
    func metadata(for urlString: String) async -> LinkPreviewMetadata? {
        await LinkPreviewFetcher.shared.metadata(for: urlString)
    }

    /// The page's icon, decoded. A failure is the fetcher's to remember, so a card scrolled back
    /// over does not retry it.
    func favicon(for urlString: String) async -> UIImage? {
        let key = urlString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = await LinkPreviewFetcher.shared.faviconData(for: urlString),
            let image = UIImage(data: data)
        else { return nil }
        imageCache.setObject(image, forKey: key, cost: 4096)
        return image
    }
}
