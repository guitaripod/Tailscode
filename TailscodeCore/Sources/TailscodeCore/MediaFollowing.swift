import Foundation

/// What an account adds to the board: the channels this person actually follows, rather than the
/// handful they thought to type in. Signing in is the only way either site will say who those are,
/// and it changes nothing else — every signed-out path keeps working exactly as it did, so an
/// account is an improvement to the board and never a condition of it.
extension TwitchDirectory {
    /// The followed channels that are live, in one request. Twitch answers this directly, which is
    /// the whole reason the signed-in path is cheaper than the signed-out one: no per-channel poll,
    /// no guessing, and the audience and category come back with it.
    public func live(with tokens: OAuthTokens, userID: String, limit: Int = 40) async throws
        -> [MediaEntry]
    {
        let answer = try await MediaHelix.get(
            "streams/followed", tokens: tokens,
            query: ["user_id": userID, "first": "\(min(limit, 100))"])
        let now = Date()
        return (answer["data"] as? [[String: Any]] ?? []).compactMap { node in
            guard let login = node["user_login"] as? String else { return nil }
            let channel = MediaChannel(
                source: .twitch, handle: login, name: node["user_name"] as? String ?? login)
            let preview = (node["thumbnail_url"] as? String)?
                .replacingOccurrences(of: "{width}", with: "320")
                .replacingOccurrences(of: "{height}", with: "180")
            let stream = MediaStream(
                title: node["title"] as? String ?? Localized.text("Live"),
                category: node["game_name"] as? String,
                viewers: node["viewer_count"] as? Int,
                startedAt: (node["started_at"] as? String).flatMap(MediaDate.parse),
                thumbnail: preview,
                tags: Array((node["tags"] as? [String] ?? []).prefix(3)))
            return MediaEntry(channel: channel, stream: stream, checkedAt: now)
        }
    }

    /// Everyone this account follows, live or not, so the board can list the quiet ones too. Paged
    /// because a long-standing account follows hundreds and the board only ever shows a few.
    public func following(with tokens: OAuthTokens, userID: String, limit: Int = 100) async throws
        -> [MediaChannel]
    {
        let answer = try await MediaHelix.get(
            "channels/followed", tokens: tokens,
            query: ["user_id": userID, "first": "\(min(limit, 100))"])
        return (answer["data"] as? [[String: Any]] ?? []).compactMap { node in
            guard let login = node["broadcaster_login"] as? String else { return nil }
            return MediaChannel(
                source: .twitch, handle: login,
                name: node["broadcaster_name"] as? String ?? login)
        }
    }
}

extension YouTubeDirectory {
    /// The channels this account subscribes to. Which of them are live is deliberately not asked
    /// here: the Data API charges a hundred units for each such question and answers it no better
    /// than the free path the signed-out board already uses.
    public func subscriptions(with tokens: OAuthTokens, limit: Int = 50) async throws
        -> [MediaChannel]
    {
        let answer = try await MediaGoogle.get(
            "subscriptions", tokens: tokens,
            query: [
                "part": "snippet", "mine": "true", "maxResults": "\(min(limit, 50))",
                "order": "relevance",
            ])
        return (answer["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let snippet = item["snippet"] as? [String: Any],
                let resource = snippet["resourceId"] as? [String: Any],
                let channelID = resource["channelId"] as? String
            else { return nil }
            let thumbnails = (snippet["thumbnails"] as? [String: Any])?["default"] as? [String: Any]
            return MediaChannel(
                source: .youtube, handle: channelID,
                name: snippet["title"] as? String ?? channelID,
                avatar: thumbnails?["url"] as? String)
        }
    }
}

/// Everything an account is worth on the board, gathered in one place so a client asks once and the
/// two sites' very different economics stay this file's problem rather than the pane's.
public struct MediaFollowing: Sendable {
    public let twitch = TwitchDirectory()
    public let youtube = YouTubeDirectory()

    public init() {}

    /// The channels the signed-in accounts follow, merged with the ones this device added by hand.
    /// A source that is signed out simply contributes nothing; a source whose account has gone bad
    /// contributes a reason.
    public func watchlist(local: [MediaChannel], limit: Int = 60) async -> MediaFeed {
        var channels = local
        var failures: [String] = []
        for source in MediaSource.allCases {
            guard MediaAccounts.isSignedIn(source) else { continue }
            guard let tokens = await MediaAccounts.usable(for: source) else {
                failures.append(MediaFailure.signedOut(source).description)
                continue
            }
            do {
                switch source {
                case .twitch:
                    guard let account = MediaAccounts.account(for: .twitch) else { continue }
                    let identity = try await Self.twitchUserID(account, tokens: tokens)
                    channels += try await twitch.following(with: tokens, userID: identity)
                case .youtube:
                    channels += try await youtube.subscriptions(with: tokens)
                }
            } catch {
                failures.append(MediaDirectory.reason(error, source))
            }
        }
        var seen = Set<String>()
        let unique = channels.filter { seen.insert($0.id).inserted }
        return MediaFeed(
            entries: Array(unique.prefix(limit)).map { MediaEntry(channel: $0) },
            failures: failures)
    }

    /// What is live right now, using each source's cheapest honest route: Twitch answers for a whole
    /// account in one request, YouTube has no such route and so is asked per channel through the
    /// same free path the signed-out board uses, capped so a board never waits on fifty lookups.
    public func live(local: [MediaChannel], youtubeCap: Int = 8) async -> MediaFeed {
        var entries: [MediaEntry] = []
        var failures: [String] = []

        if MediaAccounts.isSignedIn(.twitch), let tokens = await MediaAccounts.usable(for: .twitch),
            let account = MediaAccounts.account(for: .twitch)
        {
            do {
                let identity = try await Self.twitchUserID(account, tokens: tokens)
                entries += try await twitch.live(with: tokens, userID: identity)
            } catch {
                failures.append(MediaDirectory.reason(error, .twitch))
            }
        }

        var youtubeHandles = local.filter { $0.source == .youtube }.map(\.handle)
        if MediaAccounts.isSignedIn(.youtube), let tokens = await MediaAccounts.usable(for: .youtube) {
            do {
                youtubeHandles += try await youtube.subscriptions(with: tokens).map(\.handle)
            } catch {
                failures.append(MediaDirectory.reason(error, .youtube))
            }
        }

        let restTwitch = MediaAccounts.isSignedIn(.twitch)
            ? [] : local.filter { $0.source == .twitch }.map(\.handle)
        if !restTwitch.isEmpty {
            do {
                entries += try await twitch.status(of: restTwitch)
            } catch {
                failures.append(MediaDirectory.reason(error, .twitch))
            }
        }

        var seenHandles = Set<String>()
        let handles = youtubeHandles.filter { seenHandles.insert($0).inserted }.prefix(youtubeCap)
        if !handles.isEmpty {
            do {
                entries += try await youtube.status(of: Array(handles))
            } catch {
                failures.append(MediaDirectory.reason(error, .youtube))
            }
        }
        return MediaFeed(entries: MediaRank.byAudience(entries), failures: failures.sorted())
    }

    /// Twitch's own id for the signed-in account, which every followed-channel question is keyed on.
    /// Looked up from the account rather than stored, because it is derivable and one more stored
    /// field is one more thing that can disagree with the token beside it.
    private static func twitchUserID(_ account: MediaAccount, tokens: OAuthTokens) async throws
        -> String
    {
        let answer = try await MediaHelix.get("users", tokens: tokens, query: [:])
        guard let user = (answer["data"] as? [[String: Any]])?.first,
            let identity = user["id"] as? String
        else { throw MediaFailure.signedOut(.twitch) }
        return identity
    }
}
