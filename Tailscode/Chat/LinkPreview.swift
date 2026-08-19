import Foundation
import UIKit

/// What a page says about itself in its head: a title and an icon. The card shows only these —
/// the fetch is a metadata read, never a page embed, and never the conversation's context.
struct LinkPreviewMetadata: Sendable {
    let title: String?
    let faviconURL: URL?
}

/// Fetches page metadata for link cards, deduplicated and cached.
///
/// The store is the one place a URL's face is asked for, so a row re-rendered on every streamed
/// arrival — or scrolled away and back — costs one request per URL, not one per appearance. The
/// cell owns the debounce: this store only shares what arrived.
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()
    private init() {}

    private final class MetadataBox {
        let value: LinkPreviewMetadata?
        init(_ value: LinkPreviewMetadata?) { self.value = value }
    }

    private static let bodyLimit = 256 * 1024
    private static let imageLimit = 1024 * 1024

    private let metadataCache = NSCache<NSString, MetadataBox>()
    private let imageCache = NSCache<NSString, UIImage>()
    private var inflightMetadata: [String: Task<LinkPreviewMetadata?, Never>] = [:]
    private var inflightImages: [String: Task<UIImage?, Never>] = [:]
    private var failedImages = Set<String>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    /// The page's title and icon address — nil only when the page cannot be read at all, since a
    /// page that loads but carries neither still earns its cached nil so nobody re-fetches it.
    func metadata(for urlString: String) async -> LinkPreviewMetadata? {
        guard let url = URL(string: urlString), Self.isWeb(url) else { return nil }
        let key = urlString as NSString
        if let cached = metadataCache.object(forKey: key) { return cached.value }
        if let task = inflightMetadata[urlString] { return await task.value }
        let task = Task<LinkPreviewMetadata?, Never> { [session] in
            do {
                let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                    let type = http.mimeType, Self.isHTML(type)
                else { return nil }
                var data = Data()
                for try await byte in bytes {
                    if data.count < Self.bodyLimit { data.append(byte) } else { break }
                }
                return LinkPreviewParser.parse(data, finalURL: url)
            } catch {
                return nil
            }
        }
        inflightMetadata[urlString] = task
        let result = await task.value
        inflightMetadata[urlString] = nil
        metadataCache.setObject(MetadataBox(result), forKey: key)
        return result
    }

    /// The page's icon image. A page without a declared icon gets its root `/favicon.ico` as the
    /// one guess; a failure is remembered so a card scrolled back over does not retry it.
    func favicon(for urlString: String) async -> UIImage? {
        let key = urlString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        if failedImages.contains(urlString) { return nil }
        guard let metadata = await metadata(for: urlString),
            let iconURL = metadata.faviconURL ?? Self.defaultFavicon(for: urlString),
            Self.isWeb(iconURL)
        else { return nil }
        if let task = inflightImages[urlString] { return await task.value }
        let task = Task<UIImage?, Never> { [session] in
            do {
                let (data, response) = try await session.data(for: URLRequest(url: iconURL))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                    let type = http.mimeType, Self.isImage(type),
                    data.count < Self.imageLimit,
                    let image = UIImage(data: data)
                else { return nil }
                return image
            } catch {
                return nil
            }
        }
        inflightImages[urlString] = task
        let result = await task.value
        inflightImages[urlString] = nil
        if let result {
            imageCache.setObject(result, forKey: key, cost: 4096)
        } else {
            if failedImages.count >= 512 { failedImages.removeAll(keepingCapacity: true) }
            failedImages.insert(urlString)
        }
        return result
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func isHTML(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower.hasPrefix("text/") || lower.contains("html") || lower.contains("xml")
    }

    private static func isImage(_ type: String) -> Bool {
        type.lowercased().hasPrefix("image/")
    }

    private static func defaultFavicon(for urlString: String) -> URL? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }
}

/// Reads a page's head for what a card needs. Deliberately loose: HTML in the wild is broken, so a
/// regex over the first bytes of the document, entities decoded, is the whole grammar.
enum LinkPreviewParser {
    static func parse(_ data: Data, finalURL: URL) -> LinkPreviewMetadata? {
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let metas = tags(named: "meta", in: html)
        let title = ogTitle(metas)
            ?? plainTitle(html)
            ?? metas.first(where: { attribute($0, "name")?.lowercased() == "title" })
                .flatMap { attribute($0, "content") }
        let favicon = faviconURL(in: html, finalURL: finalURL)
        guard title != nil || favicon != nil else { return nil }
        return LinkPreviewMetadata(
            title: title.map(Self.clean),
            faviconURL: favicon)
    }

    private static func plainTitle(_ html: String) -> String? {
        guard let match = html.firstMatch(of: /(?si)<title[^>]*>(.*?)<\/title>/) else { return nil }
        let inner = String(match.1)
        let stripped = inner.replacing(/<[^>]+>/, with: " ")
        let cleaned = Self.clean(stripped)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func ogTitle(_ metas: [[String: String]]) -> String? {
        for meta in metas where attribute(meta, "property")?.lowercased() == "og:title" {
            if let content = attribute(meta, "content"), !content.isEmpty { return content }
        }
        return nil
    }

    /// The best icon a page declares: a touch icon first, then a real `icon` link, and only then any
    /// other `-icon` relation. Masks and SVGs are not icons a card can draw and are skipped, which
    /// is what keeps `fluid-icon` (often dead) and `mask-icon` from beating a page's actual favicon.
    /// Relative addresses resolve against the final URL, so a redirect that moved the page still
    /// lands the icon.
    private static func faviconURL(in html: String, finalURL: URL) -> URL? {
        var best: (score: Int, url: URL)?
        for link in tags(named: "link", in: html) {
            guard let rel = attribute(link, "rel")?.lowercased(),
                let href = attribute(link, "href"),
                !href.hasPrefix("data:"),
                !href.lowercased().hasSuffix(".svg"),
                let url = URL(string: Self.clean(href), relativeTo: finalURL)?.absoluteURL,
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { continue }
            let tokens = rel.split(whereSeparator: \.isWhitespace)
            guard !tokens.contains("mask") else { continue }
            let score =
                rel.contains("apple-touch-icon") ? 3
                : tokens.contains("icon") ? 2
                : rel.contains("icon") ? 1
                : 0
            guard score > 0, score > (best?.score ?? 0) else { continue }
            best = (score, url)
        }
        return best?.url
    }

    private static func tags(named name: String, in html: String) -> [[String: String]] {
        var result: [[String: String]] = []
        for match in html.matches(of: /(?i)<(meta|link)\b([^>]*)>/) {
            guard match.1.lowercased() == name else { continue }
            result.append(attributes(in: String(match.2)))
        }
        return result
    }

    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in tag.matches(of: /([\w-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/) {
            var value = String(match.2)
            if value.count >= 2,
                (value.first == "\"" && value.last == "\"")
                    || (value.first == "'" && value.last == "'")
            {
                value.removeFirst()
                value.removeLast()
            }
            result[match.1.lowercased()] = value
        }
        return result
    }

    private static func attribute(_ tag: [String: String], _ name: String) -> String? {
        tag[name]
    }

    /// A title read for a human: entities decoded, tags gone, whitespace back to single spaces.
    private static func clean(_ text: String) -> String {
        var result = decodeEntities(text)
        result = result.replacing(/[ \t\r\n]+/, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#x27;": "'",
        ]
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = result.replacing(
            /&#(\d+);/,
            with: { match in
                guard let scalar = UInt32(match.1), let unicode = Unicode.Scalar(scalar) else {
                    return String(match.0)
                }
                return String(unicode)
            })
        return result
    }
}
