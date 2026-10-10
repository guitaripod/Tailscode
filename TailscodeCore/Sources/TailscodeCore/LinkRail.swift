import Foundation

/// Which addresses of a prose run earn a place on its rail, when the rail arrives, and which of
/// them the network is asked about. A run is the consecutive prose between two pieces of
/// furniture, so a message with prose, a tool run and more prose has two rails; every client asks
/// the same question of the same text and the same rail appears on every desk.
public enum LinkRailPolicy: Sendable {
    /// Addresses per rail: the rest of a longer run is counted, not drawn.
    public static let limit = 12

    /// How many favicons the collapsed rail stacks, which is also the hosts it names.
    public static let stackSize = 3

    /// How many addresses are asked about when the rail is made. The rest wait for it to be opened.
    public static let eagerFetch = 3

    /// The addresses of one run, http(s) only, each once across all its segments, in the order they
    /// were written, at most ``limit``. Empty until the run has settled — a streaming run's tail
    /// has no rail, because its own growth would keep pushing the rail down — and empty when the
    /// reader turned link previews off.
    public static func addresses(
        inRun segments: [String], enabled: Bool = LinkEmbedsSetting.isEnabled, settled: Bool
    ) -> [String] {
        guard enabled, settled else { return [] }
        var seen = Set<String>()
        var urls: [String] = []
        for segment in segments {
            for url in LinkEmbedPolicy.candidates(in: segment) where seen.insert(url).inserted {
                urls.append(url)
                if urls.count == limit { return urls }
            }
        }
        return urls
    }

    /// Whether a run has closed and may wear its rail: something other than prose follows it, or
    /// the turn it belongs to has ended, and the run's last row is no longer the one being
    /// written into.
    public static func isSettled(lastRowIsLive: Bool, followedByFurniture: Bool, turnIsOpen: Bool) -> Bool {
        !lastRowIsLive && (followedByFurniture || !turnIsOpen)
    }

    /// The addresses to ask the fetcher about: the first ``eagerFetch`` at creation, every one of
    /// them once the rail has been opened.
    public static func fetchPlan(for urls: [String], opened: Bool) -> [String] {
        Array(urls.prefix(opened ? urls.count : eagerFetch))
    }
}

/// Which addresses a rail has already asked about, so that opening it, closing it and opening it
/// again, or a rebuild of the row, asks for nothing twice.
public struct LinkRailFetches: Sendable, Equatable {
    public private(set) var fetched: Set<String> = []

    public init() {}

    /// The addresses to ask about now: the plan less everything already asked, which this call
    /// then records.
    public mutating func claim(for urls: [String], opened: Bool) -> [String] {
        let fresh = LinkRailPolicy.fetchPlan(for: urls, opened: opened).filter { !fetched.contains($0) }
        fetched.formUnion(fresh)
        return fresh
    }
}

/// One address on a rail and what is known about its page.
public struct LinkRailItem: Sendable, Equatable {
    public let url: String
    public let face: LinkCardFace

    public init(url: String, face: LinkCardFace) {
        self.url = url
        self.face = face
    }
}

/// Everything a rail says, worded once for every client: the stack of favicons' hosts, the count
/// of the rest, the title of a lone address, what a screen reader is told and what the rail's own
/// menu offers. A client decides only how a line is drawn.
public struct LinkRailReading: Sendable, Equatable {
    public let items: [LinkRailItem]

    public init(items: [LinkRailItem]) {
        self.items = items
    }

    /// The rail before any page has spoken: every address wears its host.
    public static func placeholder(for urls: [String]) -> LinkRailReading {
        LinkRailReading(
            items: urls.compactMap { url in
                URL(string: url).map { LinkRailItem(url: url, face: .placeholder(for: $0)) }
            })
    }

    /// The rail once fetches are over. An address with an entry in `metadata` is settled — its
    /// title when the page said one, its host when the fetch failed, which the entry's `nil`
    /// records; an address with no entry has not been asked about and keeps its placeholder.
    public static func settled(for urls: [String], metadata: [String: LinkPreviewMetadata?]) -> LinkRailReading {
        LinkRailReading(
            items: urls.compactMap { url in
                guard let parsed = URL(string: url) else { return nil }
                guard let entry = metadata[url] else { return LinkRailItem(url: url, face: .placeholder(for: parsed)) }
                return LinkRailItem(url: url, face: .settled(for: parsed, metadata: entry))
            })
    }

    /// The same rail with one address's face replaced, for a fetch that landed.
    public func replacing(_ face: LinkCardFace, for url: String) -> LinkRailReading {
        LinkRailReading(items: items.map { $0.url == url ? LinkRailItem(url: url, face: face) : $0 })
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var urls: [String] { items.map(\.url) }

    /// The addresses whose favicons are stacked at rest.
    public var stack: [LinkRailItem] { Array(items.prefix(LinkRailPolicy.stackSize)) }

    /// The hosts of the stack, each once, joined by a middle dot: the line a collapsed rail reads.
    public var hostsLine: String {
        var seen = Set<String>()
        return stack.map(\.face.host).filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// How many addresses lie beyond the stack.
    public var moreCount: Int { max(0, count - LinkRailPolicy.stackSize) }

    /// The `+N` that ends the line, or nil when nothing lies beyond the stack.
    public var moreLabel: String? {
        moreCount > 0 ? Localized.text("+%lld", moreCount) : nil
    }

    /// For exactly one address, the page's title once it is known and the host until then.
    public var singleTitle: String? {
        count == 1 ? items[0].face.headline : nil
    }

    /// The faces of the opened list, in order.
    public var rowFaces: [LinkCardFace] { items.map(\.face) }

    /// Every address, one per line: what the rail's menu copies.
    public var copyAllText: String { urls.joined(separator: "\n") }

    public static var copyAllTitle: String { Localized.text("Copy all addresses") }
    public static var openAllTitle: String { Localized.text("Open all in browser") }

    /// What a screen reader is told of the rail as one disclosure button: how many links, the first
    /// two hosts, how many more, and whether the list is open.
    public func spoken(expanded: Bool) -> String {
        let state = expanded ? Localized.text("expanded") : Localized.text("collapsed")
        if count == 1 {
            return Localized.text("Link: %@, %@", items[0].face.headline, state)
        }
        var seen = Set<String>()
        let hosts = items.prefix(2).map(\.face.host).filter { seen.insert($0).inserted }.joined(separator: ", ")
        let named = count > 2 ? Localized.text("%@ and %lld more", hosts, count - 2) : hosts
        return Localized.text("Links (%lld): %@, %@", count, named, state)
    }
}

/// Where the opened rail's plate goes and how tall it is: a floating list on the pointer clients
/// that never changes a row's place.
public enum LinkRailPlate {
    /// Whether the plate opens above the rail: when the viewport has less room below the rail than
    /// the plate is tall, which is always the case at the tail of a live conversation.
    public static func opensUpward(roomBelow: Double, plateHeight: Double) -> Bool {
        roomBelow < plateHeight
    }

    /// The plate's height for a number of addresses: one row each, at most the metrics' visible
    /// rows, the rest reached by scrolling.
    public static func plateHeight(rows: Int, metrics: ChatMetrics) -> Double {
        Double(max(0, min(rows, metrics.railPlateRows))) * metrics.railOpenRowHeight
    }
}
