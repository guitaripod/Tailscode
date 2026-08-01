import CodingAgentKit
import UIKit

/// Fetches and caches attachment images. The bytes live behind the server's
/// auth on a private tailnet, so they can only be pulled through the backend —
/// and a chat scrolls, so the same thumbnail is asked for over and over.
@MainActor
final class AttachmentImageStore {
    static let shared = AttachmentImageStore()

    private let cache = NSCache<NSString, UIImage>()
    /// The bytes as they arrived, kept for saving and sharing: what the photo
    /// library should receive is the file the server has, not a re-encode of the
    /// downsampled bitmap a chat bubble displays.
    private let originals = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 60
        cache.totalCostLimit = 64 * 1024 * 1024
        originals.countLimit = 12
        originals.totalCostLimit = 48 * 1024 * 1024
    }

    func cached(_ file: FileReference) -> UIImage? {
        Self.key(file).flatMap { cache.object(forKey: $0 as NSString) }
    }

    func cachedData(_ file: FileReference) -> Data? {
        Self.key(file).flatMap { originals.object(forKey: $0 as NSString) } as Data?
    }

    /// Decoded off the main thread and downsampled to what a bubble can show:
    /// a full-resolution photo costs tens of megabytes as a CGImage and stutters
    /// the first scroll past it.
    func image(for file: FileReference, using backend: any CodingAgentBackend) async -> UIImage? {
        guard let key = Self.key(file) else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            let data = try? await backend.attachmentData(file)
            guard let data, let image = await Self.decode(data) else { return nil }
            self?.store(image, key: key)
            self?.store(data, key: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func store(_ image: UIImage, for file: FileReference, data: Data? = nil) {
        guard let key = Self.key(file) else { return }
        store(image, key: key)
        if let data { store(data, key: key) }
    }

    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func store(_ data: Data, key: String) {
        originals.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private static func key(_ file: FileReference) -> String? {
        file.url ?? file.path
    }

    private nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }
}

extension FileReference {
    var isImage: Bool { (mime ?? "").hasPrefix("image/") }

    var displayName: String {
        filename ?? path.map { ($0 as NSString).lastPathComponent }
            ?? String(localized: "attachment")
    }
}
