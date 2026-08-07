import Foundation

/// Where a stream came from. `VideoTarget` already names these when a slot is pointed at one; this
/// is the same vocabulary on the way in, before anything has been chosen.
public enum MediaSource: String, Sendable, Codable, Hashable, CaseIterable {
    case twitch
    case youtube

    public var label: String {
        switch self {
        case .twitch: return Localized.text("Twitch")
        case .youtube: return Localized.text("YouTube")
        }
    }
}

/// Somebody who broadcasts, independent of whether they are broadcasting now. A channel survives
/// going offline — that is the whole reason the list is worth keeping — so it carries no live
/// state of its own and reads back to the `VideoTarget` a slot would open.
public struct MediaChannel: Sendable, Codable, Hashable, Identifiable {
    public let source: MediaSource
    public let handle: String
    public let name: String
    public let avatar: String?

    public init(source: MediaSource, handle: String, name: String, avatar: String? = nil) {
        self.source = source
        self.handle = handle
        self.name = name
        self.avatar = avatar
    }

    public var id: String { "\(source.rawValue)/\(handle.lowercased())" }

    /// What a slot is pointed at when this channel is chosen. A Twitch login and a YouTube handle
    /// are the two things `VideoTarget` already round-trips through a layout snapshot.
    public var target: VideoTarget {
        switch source {
        case .twitch: return .twitch(handle.lowercased())
        case .youtube: return .youtube(handle)
        }
    }
}

/// What is happening on a channel right now, when something is. Every field past the title is
/// optional because the two sources answer different amounts and a row must render from whatever
/// arrived rather than wait for all of it.
public struct MediaStream: Sendable, Codable, Hashable {
    public let title: String
    public let category: String?
    public let viewers: Int?
    public let startedAt: Date?
    public let thumbnail: String?
    public let tags: [String]
    /// The one-off page a search or a category listing found, when the row is a video rather than
    /// a channel — a slot opens this instead of the channel's live URL.
    public let link: String?

    public init(
        title: String, category: String? = nil, viewers: Int? = nil, startedAt: Date? = nil,
        thumbnail: String? = nil, tags: [String] = [], link: String? = nil
    ) {
        self.title = title
        self.category = category
        self.viewers = viewers
        self.startedAt = startedAt
        self.thumbnail = thumbnail
        self.tags = tags
        self.link = link
    }
}

/// A channel and what it is doing, as of a moment. `stream == nil` is offline; the timestamp is
/// what lets a board say "checked a minute ago" rather than imply it is watching continuously.
public struct MediaEntry: Sendable, Codable, Hashable, Identifiable {
    public let channel: MediaChannel
    public let stream: MediaStream?
    public let checkedAt: Date

    public init(channel: MediaChannel, stream: MediaStream? = nil, checkedAt: Date = Date()) {
        self.channel = channel
        self.stream = stream
        self.checkedAt = checkedAt
    }

    public var id: String { channel.id }
    public var isLive: Bool { stream != nil }

    /// What a slot opens. A one-off video carries its own page; a channel opens whatever it is
    /// broadcasting now.
    public var target: VideoTarget {
        if let link = stream?.link, !link.isEmpty { return .link(link) }
        return channel.target
    }

    /// The line under the name: what is on, in the order a person scans it — the category, then
    /// how many are watching, then how long it has been running.
    public func detail(now: Date = Date()) -> String {
        guard let stream else { return Localized.text("Offline") }
        var parts: [String] = []
        if let category = stream.category, !category.isEmpty { parts.append(category) }
        if let viewers = stream.viewers { parts.append(MediaFormat.viewers(viewers)) }
        if let startedAt = stream.startedAt, let uptime = MediaFormat.uptime(since: startedAt, now: now) {
            parts.append(uptime)
        }
        return parts.isEmpty ? channel.source.label : parts.joined(separator: " · ")
    }

    /// The same facts minus the audience, for a row whose badge is already carrying it — a count
    /// said twice on one line reads as two different numbers at a glance.
    public func context(now: Date = Date()) -> String {
        guard let stream else { return Localized.text("Offline") }
        var parts: [String] = []
        if let category = stream.category, !category.isEmpty { parts.append(category) }
        if let startedAt = stream.startedAt, let uptime = MediaFormat.uptime(since: startedAt, now: now) {
            parts.append(uptime)
        }
        parts += stream.tags.prefix(2)
        return parts.isEmpty ? channel.source.label : parts.joined(separator: " · ")
    }

    /// The badge a live row wears: the audience if the source counted it, the bare word if not.
    public var badge: String? {
        guard let stream else { return nil }
        guard let viewers = stream.viewers else { return Localized.text("live") }
        return MediaFormat.viewers(viewers)
    }
}

/// A heading somebody browses by — Twitch's games and categories. Rendered as a row that opens
/// into the channels inside it rather than as something a slot can play.
public struct MediaCategory: Sendable, Codable, Hashable, Identifiable {
    public let source: MediaSource
    public let id: String
    public let name: String
    public let viewers: Int?
    public let art: String?

    public init(source: MediaSource, id: String, name: String, viewers: Int? = nil, art: String? = nil) {
        self.source = source
        self.id = id
        self.name = name
        self.viewers = viewers
        self.art = art
    }

    public var detail: String {
        guard let viewers else { return source.label }
        return Localized.text("%@ watching", MediaFormat.viewers(viewers))
    }
}

/// Numbers as a person reads them at a glance. A live board is scanned, not studied: four
/// characters that say roughly how many and roughly how long beat an exact count nobody parses.
public enum MediaFormat {
    public static func viewers(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 {
            let thousands = Double(count) / 1000
            return thousands < 10
                ? String(format: "%.1fK", thousands) : String(format: "%.0fK", thousands)
        }
        let millions = Double(count) / 1_000_000
        return millions < 10 ? String(format: "%.1fM", millions) : String(format: "%.0fM", millions)
    }

    /// How long it has been running, in the two units that matter at that scale. Nil for anything
    /// under a minute or in the future — a stream that just started says nothing rather than "0m".
    public static func uptime(since start: Date, now: Date = Date()) -> String? {
        let seconds = Int(now.timeIntervalSince(start))
        guard seconds >= 60 else { return nil }
        let minutes = seconds / 60
        if minutes < 60 { return Localized.text("%@m", "\(minutes)") }
        let hours = minutes / 60
        if hours < 24 { return Localized.text("%@h %@m", "\(hours)", "\(minutes % 60)") }
        return Localized.text("%@d %@h", "\(hours / 24)", "\(hours % 24)")
    }

    /// A count of subscribers or followers, when a source hands one over — same shorthand, said as
    /// the thing it counts.
    public static func followers(_ count: Int) -> String {
        Localized.text("%@ followers", viewers(count))
    }
}

/// Why a source could not answer, in words a person can act on. A board that quietly shows nothing
/// is indistinguishable from a board where nothing is on, so every path that fails says which
/// source failed and what would fix it.
public enum MediaFailure: Error, CustomStringConvertible, Sendable, Equatable {
    case unreachable(MediaSource)
    case refused(MediaSource, String)
    case toolMissing(MediaSource)
    /// The account this device had is gone — expired past refreshing, or revoked from the site. The
    /// board keeps working on the signed-out paths; only what an account added goes away.
    case signedOut(MediaSource)
    /// The site will only answer a registered application and this build was given none.
    case unconfigured(MediaSource)

    public var source: MediaSource {
        switch self {
        case .unreachable(let source), .refused(let source, _), .toolMissing(let source),
            .signedOut(let source), .unconfigured(let source):
            return source
        }
    }

    public var description: String {
        switch self {
        case .unreachable(let source):
            return Localized.text("%@ did not answer", source.label)
        case .refused(_, let reason):
            return reason
        case .toolMissing:
            return Localized.text("yt-dlp is not installed, so a channel cannot be looked up")
        case .signedOut(let source):
            return Localized.text("Your %@ account needs signing in again", source.label)
        case .unconfigured(let source):
            return Localized.text("%@ has no sign-in configured on this build", source.label)
        }
    }
}

/// What came back and what did not. Two sources answer independently and one of them failing is
/// not the other's problem, so a feed carries both halves rather than collapsing to an empty list.
public struct MediaFeed: Sendable, Equatable {
    public let entries: [MediaEntry]
    public let categories: [MediaCategory]
    public let failures: [String]

    public init(
        entries: [MediaEntry] = [], categories: [MediaCategory] = [], failures: [String] = []
    ) {
        self.entries = entries
        self.categories = categories
        self.failures = failures
    }

    public var isEmpty: Bool { entries.isEmpty && categories.isEmpty }
}

/// What a source can be asked. Two of these exist — Twitch and YouTube — and both answer without
/// an account, because asking somebody to paste an API key before they can see what is on defeats
/// the point of the pane.
public protocol MediaProvider: Sendable {
    var source: MediaSource { get }
    /// Live state for channels the person already follows here. Answers one entry per channel
    /// asked about, offline ones included, because an offline channel is still a row.
    func status(of handles: [String]) async throws -> [MediaEntry]
    func search(_ words: String, limit: Int) async throws -> [MediaEntry]
    func top(limit: Int) async throws -> [MediaEntry]
    func categories(limit: Int) async throws -> [MediaCategory]
    func inside(_ categoryID: String, limit: Int) async throws -> [MediaEntry]
}

extension MediaProvider {
    public func categories(limit: Int) async throws -> [MediaCategory] { [] }
    public func inside(_ categoryID: String, limit: Int) async throws -> [MediaEntry] { [] }
}

/// Every source, asked at once. The two answer at very different speeds — Twitch's endpoint is one
/// round trip of about fifty milliseconds, YouTube's costs a page or a subprocess — so a caller
/// that wants the fast half first asks the fast provider directly; asking here waits for both and
/// merges them into one ordering.
public struct MediaDirectory: Sendable {
    public let providers: [any MediaProvider]

    public init(providers: [any MediaProvider] = [TwitchDirectory(), YouTubeDirectory()]) {
        self.providers = providers
    }

    public func provider(for source: MediaSource) -> (any MediaProvider)? {
        providers.first { $0.source == source }
    }

    /// Live state for a mixed list of channels, each asked of its own source, all at once.
    public func status(of channels: [MediaChannel]) async -> MediaFeed {
        let grouped = Dictionary(grouping: channels) { $0.source }
        return await gather { provider in
            guard let handles = grouped[provider.source]?.map(\.handle), !handles.isEmpty else {
                return []
            }
            return try await provider.status(of: handles)
        }
    }

    public func search(_ words: String, limit: Int = 6) async -> MediaFeed {
        await gather { try await $0.search(words, limit: limit) }
    }

    public func top(limit: Int = 6) async -> MediaFeed {
        await gather { try await $0.top(limit: limit) }
    }

    public func inside(_ category: MediaCategory, limit: Int = 12) async -> MediaFeed {
        guard let provider = provider(for: category.source) else { return MediaFeed() }
        do {
            return MediaFeed(entries: MediaRank.byAudience(try await provider.inside(category.id, limit: limit)))
        } catch {
            return MediaFeed(failures: [Self.reason(error, provider.source)])
        }
    }

    public func categories(limit: Int = 8) async -> MediaFeed {
        var found: [MediaCategory] = []
        var failures: [String] = []
        await withTaskGroup(of: Result<[MediaCategory], MediaFailure>.self) { group in
            for provider in providers {
                group.addTask {
                    do { return .success(try await provider.categories(limit: limit)) } catch {
                        return .failure(.refused(provider.source, Self.reason(error, provider.source)))
                    }
                }
            }
            for await answer in group {
                switch answer {
                case .success(let list): found += list
                case .failure(let failure): failures.append(failure.description)
                }
            }
        }
        return MediaFeed(
            categories: found.sorted { ($0.viewers ?? 0) > ($1.viewers ?? 0) }, failures: failures)
    }

    private func gather(
        _ ask: @escaping @Sendable (any MediaProvider) async throws -> [MediaEntry]
    ) async -> MediaFeed {
        var entries: [MediaEntry] = []
        var failures: [String] = []
        await withTaskGroup(of: Result<[MediaEntry], MediaFailure>.self) { group in
            for provider in providers {
                group.addTask {
                    do { return .success(try await ask(provider)) } catch {
                        return .failure(.refused(provider.source, Self.reason(error, provider.source)))
                    }
                }
            }
            for await answer in group {
                switch answer {
                case .success(let found): entries += found
                case .failure(let failure): failures.append(failure.description)
                }
            }
        }
        return MediaFeed(entries: MediaRank.byAudience(entries), failures: failures.sorted())
    }

    static func reason(_ error: Error, _ source: MediaSource) -> String {
        if let failure = error as? MediaFailure { return failure.description }
        return MediaFailure.unreachable(source).description
    }
}

/// One ordering, applied everywhere a list of entries is shown: live before offline, the biggest
/// audience first inside each, and the name as the tiebreak so a refresh with identical numbers
/// does not shuffle the board under the cursor.
public enum MediaRank {
    public static func byAudience(_ entries: [MediaEntry]) -> [MediaEntry] {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.id).inserted }
        return unique.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            let leftViewers = left.stream?.viewers ?? -1
            let rightViewers = right.stream?.viewers ?? -1
            if leftViewers != rightViewers { return leftViewers > rightViewers }
            return left.channel.name.localizedCaseInsensitiveCompare(right.channel.name)
                == .orderedAscending
        }
    }
}
