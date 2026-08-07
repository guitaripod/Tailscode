import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one place this app talks to a media site. Every request is a POST of JSON that answers JSON,
/// so the whole surface is one function; a non-2xx, a timeout or an unparseable body all come back
/// as a `MediaFailure` naming the source rather than as a Foundation error nobody can read.
enum MediaFetch {
    static let timeout: TimeInterval = 8

    static func json(
        _ address: String, body: [String: Any], headers: [String: String] = [:],
        source: MediaSource
    ) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw MediaFailure.unreachable(source) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MediaFailure.unreachable(source)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaFailure.refused(
                source,
                Localized.text("%@ answered %@", source.label, "\(http.statusCode)"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaFailure.unreachable(source)
        }
        return object
    }

    /// Every dictionary anywhere in a response that carries a given key, in the order the document
    /// lists them. Both sites nest their payloads differently from one week to the next, so a
    /// fixed path is a promise neither of them made; the shape of one row is the stable part.
    static func harvest(_ key: String, from root: Any, cap: Int = 400) -> [[String: Any]] {
        var found: [[String: Any]] = []
        var stack: [Any] = [root]
        while let next = stack.popLast(), found.count < cap {
            if let object = next as? [String: Any] {
                if let hit = object[key] as? [String: Any] { found.append(hit) }
                stack.append(contentsOf: object.values)
            } else if let list = next as? [Any] {
                stack.append(contentsOf: list)
            }
        }
        return found
    }

    static func text(_ node: Any?) -> String? {
        guard let object = node as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        guard let runs = object["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// A count as one of these sites writes it: "12,304", "1.2M watching", "3 456". Read as the
    /// number a person would say, or nothing at all — a wrong number is worse than no badge.
    static func count(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        var digits = ""
        var multiplier = 1
        for character in cleaned {
            if character.isNumber || character == "." {
                digits.append(character)
            } else if character == "K" || character == "k" {
                multiplier = 1000
                break
            } else if character == "M" || character == "m" {
                multiplier = 1_000_000
                break
            } else if !digits.isEmpty {
                break
            }
        }
        guard let value = Double(digits) else { return nil }
        return Int(value * Double(multiplier))
    }
}

/// Twitch, read the way its own web client reads it. The public GraphQL endpoint answers a channel's
/// live state, a search, the top of the directory and the categories in one round trip each, with
/// no account and no key to paste — which is the difference between a pane that shows what is on
/// and a pane that first asks somebody to go and register an application.
///
/// Every request is a plain query rather than a persisted hash, because a hash is a version of
/// somebody else's client and goes stale silently; a query that stops parsing fails loudly instead.
public struct TwitchDirectory: MediaProvider {
    public let source = MediaSource.twitch
    public static let endpoint = "https://gql.twitch.tv/gql"
    public static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    private static let streamFields = """
        id title viewersCount createdAt type game{name} \
        previewImageURL(width:320,height:180) freeformTags{name}
        """
    private static let userFields = """
        id login displayName profileImageURL(width:70) stream{\(streamFields)}
        """

    public init() {}

    public func status(of handles: [String]) async throws -> [MediaEntry] {
        let logins = handles.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !logins.isEmpty else { return [] }
        let fields = logins.enumerated()
            .map { index, login in "c\(index):user(login:\(Self.quoted(login))){...F}" }
            .joined(separator: " ")
        let query = "fragment F on User{\(Self.userFields)} query{\(fields)}"
        let payload = try await ask(query)
        let now = Date()
        return logins.indices.compactMap { index in
            guard let user = payload["c\(index)"] as? [String: Any] else {
                return MediaEntry(
                    channel: MediaChannel(
                        source: .twitch, handle: logins[index], name: logins[index]),
                    checkedAt: now)
            }
            return Self.entry(from: user, now: now)
        }
    }

    public func search(_ words: String, limit: Int) async throws -> [MediaEntry] {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = """
            fragment F on User{\(Self.userFields)} \
            query{searchFor(userQuery:\(Self.quoted(trimmed)),platform:"web",\
            target:{index:CHANNEL},options:{}){channels{items{...F}}}}
            """
        let payload = try await ask(query)
        let items =
            ((payload["searchFor"] as? [String: Any])?["channels"] as? [String: Any])?["items"]
            as? [[String: Any]] ?? []
        let now = Date()
        return items.prefix(limit).compactMap { Self.entry(from: $0, now: now) }
    }

    public func top(limit: Int) async throws -> [MediaEntry] {
        let query = """
            query{streams(first:\(limit)){edges{node{\(Self.streamFields) \
            broadcaster{id login displayName profileImageURL(width:70)}}}}}
            """
        let payload = try await ask(query)
        return Self.entries(fromEdges: (payload["streams"] as? [String: Any]))
    }

    public func categories(limit: Int) async throws -> [MediaCategory] {
        let query = "query{games(first:\(limit)){edges{node{displayName viewersCount boxArtURL(width:80,height:106)}}}}"
        let payload = try await ask(query)
        let edges = (payload["games"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any],
                let name = node["displayName"] as? String
            else { return nil }
            return MediaCategory(
                source: .twitch, id: name, name: name, viewers: node["viewersCount"] as? Int,
                art: node["boxArtURL"] as? String)
        }
    }

    public func inside(_ categoryID: String, limit: Int) async throws -> [MediaEntry] {
        let query = """
            query{game(name:\(Self.quoted(categoryID))){streams(first:\(limit)){edges{node{\
            \(Self.streamFields) broadcaster{id login displayName profileImageURL(width:70)}}}}}}
            """
        let payload = try await ask(query)
        return Self.entries(fromEdges: (payload["game"] as? [String: Any])?["streams"] as? [String: Any])
    }

    private func ask(_ query: String) async throws -> [String: Any] {
        let object = try await MediaFetch.json(
            Self.endpoint, body: ["query": query],
            headers: ["Client-ID": Self.clientID], source: .twitch)
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let reason = errors.first?["message"] as? String
            throw MediaFailure.refused(
                .twitch, reason ?? Localized.text("Twitch refused the question"))
        }
        guard let data = object["data"] as? [String: Any] else {
            throw MediaFailure.unreachable(.twitch)
        }
        return data
    }

    private static func entries(fromEdges container: [String: Any]?) -> [MediaEntry] {
        let edges = container?["edges"] as? [[String: Any]] ?? []
        let now = Date()
        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any],
                let broadcaster = node["broadcaster"] as? [String: Any],
                let login = broadcaster["login"] as? String
            else { return nil }
            let channel = MediaChannel(
                source: .twitch, handle: login,
                name: broadcaster["displayName"] as? String ?? login,
                avatar: broadcaster["profileImageURL"] as? String)
            return MediaEntry(channel: channel, stream: stream(from: node), checkedAt: now)
        }
    }

    /// One channel, read out of the payload Twitch's own client receives. Public because the
    /// shape is the fragile part of this whole feature and each client pins it from its own
    /// selftest — a site that changes it should fail loudly rather than draw an empty board.
    public static func entry(from user: [String: Any], now: Date) -> MediaEntry? {
        guard let login = user["login"] as? String else { return nil }
        let channel = MediaChannel(
            source: .twitch, handle: login, name: user["displayName"] as? String ?? login,
            avatar: user["profileImageURL"] as? String)
        return MediaEntry(
            channel: channel, stream: stream(from: user["stream"] as? [String: Any]), checkedAt: now)
    }

    private static func stream(from node: [String: Any]?) -> MediaStream? {
        guard let node else { return nil }
        let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (node["freeformTags"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        return MediaStream(
            title: (title?.isEmpty ?? true) ? Localized.text("Live") : title!,
            category: (node["game"] as? [String: Any])?["name"] as? String,
            viewers: node["viewersCount"] as? Int,
            startedAt: (node["createdAt"] as? String).flatMap(MediaDate.parse),
            thumbnail: node["previewImageURL"] as? String,
            tags: Array(tags.prefix(3)))
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}

/// YouTube, read two ways because it answers two questions at two speeds. Discovery — a search, the
/// live rows on the front of it — comes from the same JSON its own web player asks for, which needs
/// no key and lands in about a second. A single channel's live state does not: the pages that would
/// answer it change shape constantly, so that one question goes to yt-dlp, which is already the
/// thing a slot plays a YouTube page through and is the honest dependency for it.
public struct YouTubeDirectory: MediaProvider {
    public let source = MediaSource.youtube
    public static let endpoint = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
    /// The filter the site's own "Live" tab sends. Without it a search answers uploads, and a board
    /// of week-old videos is not a board of what is on.
    public static let liveFilter = "EgJAAQ%3D%3D"

    public init() {}

    public func search(_ words: String, limit: Int) async throws -> [MediaEntry] {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let payload = try await MediaFetch.json(
            Self.endpoint,
            body: ["context": Self.context, "query": trimmed, "params": Self.liveFilter],
            source: .youtube)
        return Self.rows(in: payload, limit: limit)
    }

    public func top(limit: Int) async throws -> [MediaEntry] {
        try await search(Localized.text("live now"), limit: limit)
    }

    /// One channel at a time, because that is what the tool answers. The handles are asked
    /// concurrently and a channel that is simply offline answers an offline row rather than an
    /// error — only a missing tool is a failure worth reporting.
    public func status(of handles: [String]) async throws -> [MediaEntry] {
        let wanted = handles.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }
        #if os(macOS) || os(Linux)
            guard VideoResolver.tool() != nil else { throw MediaFailure.toolMissing(.youtube) }
            return await withTaskGroup(of: MediaEntry?.self) { group in
                for handle in wanted {
                    group.addTask { await Self.probe(handle) }
                }
                var found: [MediaEntry] = []
                for await entry in group {
                    if let entry { found.append(entry) }
                }
                return found
            }
        #else
            throw MediaFailure.toolMissing(.youtube)
        #endif
    }

    static var context: [String: Any] {
        [
            "client": [
                "clientName": "WEB", "clientVersion": "2.20240101.00.00", "hl": "en", "gl": "US",
            ]
        ]
    }

    /// Every live row a response carries, read from the one renderer shape that has outlived every
    /// redesign. A row with no live badge is dropped rather than shown as though it were on. Public
    /// for the same reason Twitch's reader is: the shape is what breaks, so it is what is pinned.
    public static func rows(in payload: [String: Any], limit: Int) -> [MediaEntry] {
        let now = Date()
        var found: [MediaEntry] = []
        for renderer in MediaFetch.harvest("videoRenderer", from: payload) {
            guard found.count < limit else { break }
            guard let videoID = renderer["videoId"] as? String, isLive(renderer) else { continue }
            guard let title = MediaFetch.text(renderer["title"]) else { continue }
            let owner = MediaFetch.text(renderer["ownerText"]) ?? Localized.text("YouTube")
            let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let channel = MediaChannel(
                source: .youtube, handle: handle(in: renderer) ?? owner, name: owner)
            let stream = MediaStream(
                title: title, category: nil,
                viewers: MediaFetch.count(MediaFetch.text(renderer["viewCountText"])),
                thumbnail: thumbnails?.last?["url"] as? String,
                link: "https://www.youtube.com/watch?v=\(videoID)")
            found.append(MediaEntry(channel: channel, stream: stream, checkedAt: now))
        }
        return found
    }

    private static func isLive(_ renderer: [String: Any]) -> Bool {
        let badges = renderer["badges"] as? [[String: Any]] ?? []
        for badge in badges {
            let style = (badge["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String
            if style == "BADGE_STYLE_TYPE_LIVE_NOW" { return true }
        }
        return false
    }

    private static func handle(in renderer: [String: Any]) -> String? {
        let runs = (renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let endpoint = (runs?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
            as? [String: Any]
        guard let base = endpoint?["canonicalBaseUrl"] as? String else {
            return endpoint?["browseId"] as? String
        }
        let trimmed = base.hasPrefix("/") ? String(base.dropFirst()) : base
        if trimmed.hasPrefix("@") { return trimmed }
        if trimmed.hasPrefix("channel/") { return String(trimmed.dropFirst("channel/".count)) }
        return trimmed
    }

    #if os(macOS) || os(Linux)
        /// What the tool says about a channel's `/live` page: a video when it is on, nothing when it
        /// is not. Runs off the calling thread because it is a subprocess and a page fetch.
        private static func probe(_ handle: String) async -> MediaEntry? {
            let channel = MediaChannel(source: .youtube, handle: handle, name: handle)
            guard let tool = VideoResolver.tool() else { return MediaEntry(channel: channel) }
            let address = VideoTarget.youtube(handle).playbackURL
            let output = await Task.detached(priority: .utility) { () -> Data? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = [
                    "--quiet", "--no-warnings", "--ignore-config", "--flat-playlist",
                    "--playlist-items", "1", "-J", address,
                ]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard (try? process.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            }.value
            guard let output,
                let payload = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
            else { return MediaEntry(channel: channel) }
            let named = MediaChannel(
                source: .youtube, handle: handle,
                name: payload["channel"] as? String ?? handle,
                avatar: nil)
            guard payload["live_status"] as? String == "is_live" else {
                return MediaEntry(channel: named)
            }
            let stream = MediaStream(
                title: payload["title"] as? String ?? Localized.text("Live"),
                viewers: payload["concurrent_view_count"] as? Int,
                startedAt: nil,
                thumbnail: payload["thumbnail"] as? String,
                link: payload["webpage_url"] as? String)
            return MediaEntry(channel: named, stream: stream)
        }
    #endif
}

/// The one timestamp shape these sources send, read without dragging a formatter through every
/// parse. `ISO8601DateFormatter` is not `Sendable` on either toolchain, so it is built where it is
/// used rather than shared.
enum MediaDate {
    static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let parsed = formatter.date(from: raw) { return parsed }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
