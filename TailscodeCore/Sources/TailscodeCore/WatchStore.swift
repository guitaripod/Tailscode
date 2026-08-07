import Foundation

/// The channels this device follows, and what it last watched. Device-local on purpose: which
/// streams somebody keeps an eye on while they work is not the server's business, and the list has
/// to render — with names, sources and the order they were added — when no source is answering at
/// all. A live check enriches these rows; it never supplies them.
public enum WatchStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let channelsKey = "tailscode.watch.channels"
    static let recentsKey = "tailscode.watch.recents"
    public static let didChange = Notification.Name("tailscode.watch.didChange")

    private static let recentCapacity = 12
    private static let channelCapacity = 60

    public static func channels() -> [MediaChannel] {
        guard let data = defaults.data(forKey: channelsKey) else { return [] }
        return (try? JSONDecoder().decode([MediaChannel].self, from: data)) ?? []
    }

    public static func follows(_ channel: MediaChannel) -> Bool {
        channels().contains { $0.id == channel.id }
    }

    /// Follows the channel, or stops. Answers whether it is followed afterwards, so a row can
    /// restate itself from the return rather than re-reading the store.
    @discardableResult
    public static func toggle(_ channel: MediaChannel) -> Bool {
        var list = channels()
        if let index = list.firstIndex(where: { $0.id == channel.id }) {
            list.remove(at: index)
            write(list, forKey: channelsKey)
            return false
        }
        list.insert(channel, at: 0)
        write(Array(list.prefix(channelCapacity)), forKey: channelsKey)
        return true
    }

    /// The last few things this device actually played, newest first. A recent carries the name it
    /// had when it played, so the row reads as something rather than as an address.
    public static func recents() -> [MediaChannel] {
        guard let data = defaults.data(forKey: recentsKey) else { return [] }
        return (try? JSONDecoder().decode([MediaChannel].self, from: data)) ?? []
    }

    /// Records what a slot was pointed at. A link or a search has no channel behind it, so only the
    /// two that read back to somebody who broadcasts are kept — a recents list of raw URLs is a
    /// history, not a shortlist.
    public static func record(_ target: VideoTarget, title: String? = nil) {
        guard let channel = channel(for: target, title: title) else { return }
        var list = recents().filter { $0.id != channel.id }
        list.insert(channel, at: 0)
        write(Array(list.prefix(recentCapacity)), forKey: recentsKey)
    }

    public static func channel(for target: VideoTarget, title: String? = nil) -> MediaChannel? {
        let name = title.flatMap { $0.isEmpty ? nil : $0 }
        switch target {
        case .twitch(let login):
            return MediaChannel(source: .twitch, handle: login, name: name ?? login)
        case .youtube(let handle):
            return MediaChannel(source: .youtube, handle: handle, name: name ?? handle)
        case .link, .search:
            return nil
        }
    }

    /// Everything worth checking the live state of: what is followed first, then anything recently
    /// watched that is not already followed. Capped, because each one costs a round trip and a
    /// board that takes ten seconds to fill is a board nobody waits for.
    public static func watchlist(limit: Int = 16) -> [MediaChannel] {
        var seen = Set<String>()
        let ordered = channels() + recents()
        return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    public static func forget() {
        defaults.removeObject(forKey: channelsKey)
        defaults.removeObject(forKey: recentsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func write(_ list: [MediaChannel], forKey key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// What the pane chooser's "Watch something…" row says before anybody opens it. A row that reads
/// "2 live · Caedrel, Lofi Girl" is an invitation; "Twitch or YouTube, in this pane" is a label.
/// The summary is derived from a feed the app already fetched, so producing one costs nothing.
public struct WatchSummary: Sendable, Equatable {
    public let live: [String]
    public let followed: Int

    public init(live: [String], followed: Int) {
        self.live = live
        self.followed = followed
    }

    public init(feed: MediaFeed, followed: Int) {
        live = feed.entries.filter(\.isLive).map(\.channel.name)
        self.followed = followed
    }

    public var isEmpty: Bool { live.isEmpty }

    /// The line the row wears in place of its static one. Two names is what fits; the rest is a
    /// count, because a row that wraps to three lines stops being a row.
    public var detail: String {
        guard !live.isEmpty else {
            return followed > 0
                ? Localized.text("Nothing you follow is live") : Localized.text("Twitch or YouTube, in this pane")
        }
        let named = live.prefix(2).joined(separator: ", ")
        if live.count <= 2 {
            return live.count == 1
                ? Localized.text("%@ is live", named)
                : Localized.text("%@ are live", named)
        }
        return Localized.text("%@ and %@ more are live", named, "\(live.count - 2)")
    }

    public var badge: String? {
        live.isEmpty ? nil : Localized.text("%@ live", "\(live.count)")
    }
}
