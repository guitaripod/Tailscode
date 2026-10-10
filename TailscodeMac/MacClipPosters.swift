import AVFoundation
import AppKit
import TailscodeCore

/// A poster for a clip that lives on another machine: its first frame, read over the same `/view`
/// road a player uses, small, and kept for the life of the process in a cache that cannot outgrow
/// its bound. A clip the renderer has since cleaned up has no first frame to give, which is an
/// answer rather than an error — the tile wears its marker instead.
@MainActor
enum MacClipPosters {
    private static let held: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static var loading: [String: Task<NSImage?, Never>] = [:]

    /// The longest side a poster is decoded to: a tile is 88 points, a drag preview twice that.
    static let side: CGFloat = 320

    static func key(for asset: ForgeAsset, host: String?) -> String {
        "\(host ?? "-")/\(asset.annotatedName)"
    }

    static func cached(_ key: String) -> NSImage? { held.object(forKey: key as NSString) }

    /// A poster put in by hand, for a state staged without a machine to read one from.
    static func seed(_ image: NSImage, key: String) {
        held.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
    }

    /// The poster of a clip, asking the renderer where the file is first — a clip that is gone says
    /// so through the runner, once, rather than the generator failing in words about nothing.
    static func poster(for asset: ForgeAsset, entryID: String? = nil, via runner: ForgeRunner) async -> NSImage? {
        let key = key(for: asset, host: runner.endpoint?.host)
        if let image = cached(key) { return image }
        guard let url = try? await runner.locate(asset, entryID: entryID) else { return nil }
        return await poster(of: url, key: key)
    }

    static func poster(of url: URL, key: String) async -> NSImage? {
        if let image = cached(key) { return image }
        if let running = loading[key] { return await running.value }
        let load = Task<NSImage?, Never> {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: side, height: side)
            guard let result = try? await generator.image(at: .zero) else { return nil }
            return NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height))
        }
        loading[key] = load
        let image = await load.value
        loading[key] = nil
        if let image {
            held.setObject(
                image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}
