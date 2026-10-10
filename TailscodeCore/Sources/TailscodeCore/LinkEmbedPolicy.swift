import Foundation

/// Which addresses of a prose segment earn a card, and how long an address must hold still before
/// anything is asked of the network about it. Every client asks the same question of the same
/// text, so the same paragraph wears the same shelf on every desk.
public enum LinkEmbedPolicy: Sendable {
    /// Cards per prose segment: a paragraph of references stays a shelf rather than a wall.
    public static let limit = 3

    /// How long an address must go unchanged before its page is asked for anything. A reply that
    /// is still being written grows its address a few characters at a time, and each of those
    /// prefixes is somebody else's server; waiting out the pause is what makes a streamed address
    /// fire no request at all.
    public static let debounce: Duration = .milliseconds(700)

    /// The addresses of one prose segment that get a card: http(s) only, each once, in the order
    /// they were written, at most ``limit``. The address is the card's whole identity, so a streamed
    /// address that is still growing changes one card's content and never moves another row's
    /// place. Off means none.
    ///
    /// - Parameter growing: whether the text is still being written into. An address that runs to
    ///   the very end of such a text is not known to be finished — the next word may be the rest
    ///   of it — so it earns no card until something follows it. The debounce is what keeps a
    ///   request from going out for it either way; this is what keeps the card from appearing for
    ///   an address the reader has not yet been shown.
    public static func urls(
        in text: String, enabled: Bool = LinkEmbedsSetting.isEnabled, growing: Bool = false
    ) -> [String] {
        guard enabled else { return [] }
        return Array(candidates(in: text, growing: growing).prefix(limit))
    }

    /// Every http(s) address of a text, each once, in the order written and with no cap: the
    /// per-segment extraction that ``urls(in:enabled:growing:)`` caps and ``LinkRailPolicy`` gathers
    /// across a whole prose run. The `growing` rule is the same as there.
    public static func candidates(in text: String, growing: Bool = false) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for span in Autolink.spans(in: text) {
            guard !(growing && span.range.upperBound == text.endIndex),
                let url = URL(string: span.url),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                seen.insert(span.url).inserted
            else { continue }
            urls.append(span.url)
        }
        return urls
    }

    /// Waits out the debounce and says whether the address is still the one the card wants. False
    /// means the card moved on (its address grew, it was scrolled away or destroyed) or the wait
    /// was cancelled, and nothing is to be fetched.
    public static func settle(
        debounce: Duration = LinkEmbedPolicy.debounce, isWanted: @Sendable () async -> Bool
    ) async -> Bool {
        do { try await Task.sleep(for: debounce) } catch { return false }
        guard !Task.isCancelled else { return false }
        return await isWanted()
    }
}

/// What a link card says at each stage of its life, worded once for every client. The card never
/// presents an address as a page nobody has read: the host wears the face until the page's own
/// title arrives, and if it never does, the host alone is what the card has to say. Both lines are
/// populated at every stage so the card never changes height under the reader.
public enum LinkCardFace: Sendable, Equatable {
    case placeholder(host: String, path: String)
    case titled(title: String, host: String)
    case hostOnly(host: String, path: String)

    /// The face before the page has spoken.
    public static func placeholder(for url: URL) -> LinkCardFace {
        .placeholder(host: host(of: url), path: readablePath(of: url))
    }

    /// The face once the fetch is over: the page's title when it said one, the host when it did not
    /// or when the fetch failed, which is not a failure of the link.
    public static func settled(for url: URL, metadata: LinkPreviewMetadata?) -> LinkCardFace {
        if let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return .titled(title: title, host: host(of: url))
        }
        return .hostOnly(host: host(of: url), path: readablePath(of: url))
    }

    /// The page's host, whichever stage the face is at.
    public var host: String {
        switch self {
        case .titled(_, let host), .placeholder(let host, _), .hostOnly(let host, _): return host
        }
    }

    /// The first line: the page's title, or the host standing in for it.
    public var headline: String {
        switch self {
        case .titled(let title, _): return title
        case .placeholder(let host, _), .hostOnly(let host, _): return host
        }
    }

    /// The second line: the host under a title, the address's own path under a host.
    public var caption: String {
        switch self {
        case .titled(_, let host): return host
        case .placeholder(_, let path), .hostOnly(_, let path): return path
        }
    }

    /// Whether the headline is a stand-in rather than the page's own words, which a client draws
    /// in the quieter ink.
    public var headlineIsQuiet: Bool {
        if case .titled = self { return false }
        return true
    }

    /// What a screen reader is told about the card's value.
    public var spoken: String { "\(headline) · \(caption)" }

    private static func host(of url: URL) -> String { url.host ?? url.absoluteString }

    private static func readablePath(of url: URL) -> String {
        var text = url.absoluteString
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return text.isEmpty ? url.host ?? "" : text
    }
}

/// Where a link card gets its facts. The live one is the shared fetcher; a harness hands over
/// stubs, so every stage of a card's life can be drawn and checked with no network.
public struct LinkCardSource: Sendable {
    public var cachedFace: @Sendable (String) -> LinkCardFace?
    public var metadata: @Sendable (String) async -> LinkPreviewMetadata?
    public var favicon: @Sendable (String) async -> Data?
    public var debounce: Duration

    public init(
        cachedFace: @escaping @Sendable (String) -> LinkCardFace?,
        metadata: @escaping @Sendable (String) async -> LinkPreviewMetadata?,
        favicon: @escaping @Sendable (String) async -> Data?,
        debounce: Duration
    ) {
        self.cachedFace = cachedFace
        self.metadata = metadata
        self.favicon = favicon
        self.debounce = debounce
    }

    public static let live = LinkCardSource(
        cachedFace: { LinkPreviewFetcher.shared.cachedFace(for: $0) },
        metadata: { await LinkPreviewFetcher.shared.metadata(for: $0) },
        favicon: { await LinkPreviewFetcher.shared.faviconData(for: $0) },
        debounce: LinkEmbedPolicy.debounce)
}
