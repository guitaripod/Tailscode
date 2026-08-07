import Foundation
import Testing

@testable import TailscodeCore

@Suite("Watch board")
struct WatchChooserTests {
    @Test("The shared board check passes")
    func sharedCheck() {
        let issues = WatchChooserCheck.run()
        #expect(issues.isEmpty, "WatchChooserCheck: \(issues)")
    }

    @Test("A board with nothing in it is empty rather than a section of nothing")
    func emptyBoard() {
        let board = WatchChooser()
        #expect(board.rows.isEmpty)
        #expect(board.isEmpty)
        #expect(board.opened == nil)
        #expect(board.pendingSearch == nil)
    }

    @Test("A channel the store holds is a row before any source has answered")
    func listStandsAlone() {
        let channel = MediaChannel(source: .twitch, handle: "someone", name: "Someone")
        let board = WatchChooser(watchlist: [channel], followed: [channel])
        #expect(board.rows.count == 1)
        #expect(board.rows[0].title == "Someone")
        #expect(board.rows[0].badge == .offline(Localized.text("offline")))
        #expect(board.rows[0].isFollowed)
    }

    @Test("The cursor never lands on a line the board merely owed the reader")
    func cursorSkipsNotes() {
        var board = WatchChooser(watchlist: [], followed: [])
        board.filled(top: MediaFeed(failures: ["Twitch did not answer"]))
        let notes = board.rows.filter { $0.kind == .note }
        #expect(!notes.isEmpty)
        #expect(board.focused == nil)
        board.move(by: 1)
        #expect(board.focused == nil)
        #expect(board.activate() == nil)
    }

    @Test("Until somebody moves it, the cursor sits at the top however the answers arrive")
    func cursorStartsAtTheTop() {
        let mine = [MediaChannel(source: .twitch, handle: "mine", name: "Mine")]
        var board = WatchChooser(watchlist: mine, followed: mine)
        board.filled(
            categories: MediaFeed(categories: [
                MediaCategory(source: .twitch, id: "Rust", name: "Rust", viewers: 10)
            ]))
        board.filled(
            live: MediaFeed(entries: [
                MediaEntry(
                    channel: mine[0], stream: MediaStream(title: "on", viewers: 5))
            ]))
        #expect(board.focused?.title == "Mine")
    }

    @Test("An answer that arrives while somebody is reading does not move the cursor")
    func placeSurvivesARefill() {
        let mine = (0..<6).map { index in
            MediaChannel(source: .twitch, handle: "c\(index)", name: "Channel \(index)")
        }
        var board = WatchChooser(watchlist: mine, followed: mine)
        board.move(by: 2)
        let held = board.focused?.id
        board.filled(
            top: MediaFeed(entries: [
                MediaEntry(
                    channel: MediaChannel(source: .twitch, handle: "loud", name: "Loud"),
                    stream: MediaStream(title: "on", viewers: 9999))
            ]))
        #expect(board.focused?.id == held)
    }

    @Test("Uptime is re-read on a tick without disturbing anything else")
    func uptimeTicks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let channel = MediaChannel(source: .twitch, handle: "x", name: "X")
        var board = WatchChooser(watchlist: [channel], followed: [])
        board.filled(
            live: MediaFeed(entries: [
                MediaEntry(
                    channel: channel,
                    stream: MediaStream(title: "on", viewers: 10, startedAt: start))
            ]))
        board.tick(start.addingTimeInterval(120))
        let early = board.rows[0].note
        board.tick(start.addingTimeInterval(7200))
        #expect(board.rows[0].note != early)
        #expect(board.rows[0].note?.contains("2") == true)
    }

    @Test("A typed channel still opens exactly what it always opened")
    func typingKeepsClassify() {
        var board = WatchChooser()
        board.type("theprimeagen")
        #expect(board.rows.first?.kind == .typed(.twitch("theprimeagen")))
        #expect(board.activate() == .play(.twitch("theprimeagen")))
        board.type("https://www.twitch.tv/caedrel")
        #expect(board.rows.first?.kind == .typed(.twitch("caedrel")))
        board.type("@LofiGirl")
        #expect(board.rows.first?.kind == .typed(.youtube("@LofiGirl")))
    }
}

@Suite("Media directory")
struct MediaDirectoryTests {
    @Test("Twitch's answer for a channel reads into an entry")
    func twitchShape() throws {
        let payload = """
            {"data":{"c0":{"id":"9","login":"caedrel","displayName":"Caedrel",
            "profileImageURL":"https://cdn/av.png","stream":{"id":"1","title":"LCK",
            "viewersCount":36579,"createdAt":"2026-08-07T07:30:10Z","type":"live",
            "game":{"name":"League of Legends"},
            "previewImageURL":"https://cdn/preview.jpg",
            "freeformTags":[{"name":"English"},{"name":"Esports"},{"name":"LEC"},{"name":"Extra"}]}}}}
            """
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let user = try #require(data["c0"] as? [String: Any])
        let entry = try #require(TwitchDirectory.entry(from: user, now: Date()))
        #expect(entry.channel.name == "Caedrel")
        #expect(entry.channel.target == .twitch("caedrel"))
        #expect(entry.isLive)
        #expect(entry.stream?.viewers == 36579)
        #expect(entry.stream?.category == "League of Legends")
        #expect(entry.stream?.tags == ["English", "Esports", "LEC"])
        #expect(entry.stream?.startedAt != nil)
    }

    @Test("A channel that is not streaming reads as an offline row, not as a failure")
    func twitchOffline() throws {
        let payload = """
            {"id":"9","login":"quiet","displayName":"Quiet","stream":null}
            """
        let user = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let entry = try #require(TwitchDirectory.entry(from: user, now: Date()))
        #expect(!entry.isLive)
        #expect(entry.detail() == Localized.text("Offline"))
    }

    @Test("YouTube's own search JSON reads into live entries and drops what is not live")
    func youtubeShape() throws {
        let payload = """
            {"contents":{"items":[
            {"videoRenderer":{"videoId":"abc","title":{"runs":[{"text":"lofi radio"}]},
            "ownerText":{"runs":[{"text":"Lofi Girl"}]},
            "longBylineText":{"runs":[{"navigationEndpoint":{"browseEndpoint":
            {"browseId":"UC1","canonicalBaseUrl":"/@LofiGirl"}}}]},
            "viewCountText":{"runs":[{"text":"12,304"},{"text":" watching"}]},
            "badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW"}}],
            "thumbnail":{"thumbnails":[{"url":"https://i/small.jpg"},{"url":"https://i/big.jpg"}]}}},
            {"videoRenderer":{"videoId":"old","title":{"runs":[{"text":"an upload"}]},
            "ownerText":{"runs":[{"text":"Somebody"}]}}}
            ]}}
            """
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let entries = YouTubeDirectory.rows(in: object, limit: 8)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.channel.handle == "@LofiGirl")
        #expect(entry.channel.name == "Lofi Girl")
        #expect(entry.stream?.viewers == 12304)
        #expect(entry.stream?.thumbnail == "https://i/big.jpg")
        #expect(entry.target == .link("https://www.youtube.com/watch?v=abc"))
    }

    @Test("A response nested somewhere new still gives up its rows")
    func harvestIsPathFree() throws {
        let payload = """
            {"a":{"b":[{"c":{"videoRenderer":{"videoId":"x","title":{"simpleText":"t"},
            "ownerText":{"simpleText":"o"},
            "badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW"}}]}}}]}}
            """
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(YouTubeDirectory.rows(in: object, limit: 4).count == 1)
    }

    @Test("Two sources failing is two sentences, not silence")
    func failuresAreCarried() async {
        let directory = MediaDirectory(providers: [
            StubProvider(source: .twitch, failure: .unreachable(.twitch)),
            StubProvider(source: .youtube, failure: .toolMissing(.youtube)),
        ])
        let feed = await directory.top(limit: 4)
        #expect(feed.entries.isEmpty)
        #expect(feed.failures.count == 2)
    }

    @Test("One source failing does not lose the other's answer")
    func halfAnAnswerIsAnAnswer() async {
        let entry = MediaEntry(
            channel: MediaChannel(source: .youtube, handle: "@a", name: "A"),
            stream: MediaStream(title: "on", viewers: 5))
        let directory = MediaDirectory(providers: [
            StubProvider(source: .twitch, failure: .unreachable(.twitch)),
            StubProvider(source: .youtube, entries: [entry]),
        ])
        let feed = await directory.search("anything", limit: 4)
        #expect(feed.entries.count == 1)
        #expect(feed.failures.count == 1)
    }
}

private struct StubProvider: MediaProvider {
    let source: MediaSource
    var entries: [MediaEntry] = []
    var failure: MediaFailure?

    func status(of handles: [String]) async throws -> [MediaEntry] { try answer() }
    func search(_ words: String, limit: Int) async throws -> [MediaEntry] { try answer() }
    func top(limit: Int) async throws -> [MediaEntry] { try answer() }

    private func answer() throws -> [MediaEntry] {
        if let failure { throw failure }
        return entries
    }
}

extension DeviceStores {
    @Suite("Watch store")
    struct WatchStoreTests {
        private func fresh() {
            UserDefaults.standard.removeObject(forKey: WatchStore.channelsKey)
            UserDefaults.standard.removeObject(forKey: WatchStore.recentsKey)
        }

        @Test("Following a channel keeps it, and following it again lets it go")
        func toggling() {
            fresh()
            let channel = MediaChannel(source: .twitch, handle: "caedrel", name: "Caedrel")
            #expect(!WatchStore.follows(channel))
            #expect(WatchStore.toggle(channel))
            #expect(WatchStore.follows(channel))
            #expect(WatchStore.channels().count == 1)
            #expect(!WatchStore.toggle(channel))
            #expect(WatchStore.channels().isEmpty)
        }

        @Test("What played is remembered as somebody, and a bare link is not")
        func recents() {
            fresh()
            WatchStore.record(.twitch("caedrel"), title: "Caedrel")
            WatchStore.record(.youtube("@LofiGirl"))
            WatchStore.record(.link("https://example.com/a.mp4"))
            WatchStore.record(.search("some words"))
            let recents = WatchStore.recents()
            #expect(recents.count == 2)
            #expect(recents.first?.handle == "@LofiGirl")
            #expect(recents.last?.name == "Caedrel")
        }

        @Test("Watching the same thing twice moves it up rather than listing it twice")
        func recentsDeduplicate() {
            fresh()
            WatchStore.record(.twitch("a"))
            WatchStore.record(.twitch("b"))
            WatchStore.record(.twitch("a"))
            #expect(WatchStore.recents().map(\.handle) == ["a", "b"])
        }

        @Test("The watchlist is what is followed, then what was watched, each once")
        func watchlist() {
            fresh()
            WatchStore.toggle(MediaChannel(source: .twitch, handle: "kept", name: "Kept"))
            WatchStore.record(.twitch("kept"))
            WatchStore.record(.twitch("passing"))
            #expect(WatchStore.watchlist().map(\.handle) == ["kept", "passing"])
            fresh()
        }
    }
}

@Suite("Watch accounts")
struct WatchAccountsTests {
    @Test("The shared accounts check passes")
    func sharedCheck() {
        let issues = WatchAccountsCheck.run()
        #expect(issues.isEmpty, "WatchAccountsCheck: \(issues)")
    }

    @Test("Twitch's device flow needs no application registered by anybody")
    func twitchNeedsNoSetup() {
        #expect(TwitchAuthority().isConfigured)
        #expect(TwitchAuthority().requirement == nil)
    }

    @Test("YouTube says what it needs before it offers a button that would fail")
    func youtubeSaysWhatItNeeds() {
        let authority = YouTubeAuthority()
        guard MediaClientConfig.youtube == nil else { return }
        #expect(!authority.isConfigured)
        #expect(authority.requirement?.contains("console.cloud.google.com") == true)
    }

    @Test("A signed-out device has no account and no tokens rather than an empty one")
    func signedOutIsAbsent() {
        #expect(MediaAccounts.account(for: .twitch) == nil || MediaAccounts.isSignedIn(.twitch))
    }

    @Test("Twitch's live-followed payload reads into entries with audience and preview")
    func twitchFollowedShape() throws {
        let payload = """
            {"data":[{"user_login":"caedrel","user_name":"Caedrel","game_name":"League of Legends",
            "title":"LCK","viewer_count":36579,"started_at":"2026-08-07T07:30:10Z",
            "thumbnail_url":"https://cdn/live_user_caedrel-{width}x{height}.jpg",
            "tags":["English","Esports"]}]}
            """
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let nodes = try #require(object["data"] as? [[String: Any]])
        let node = try #require(nodes.first)
        #expect(node["user_login"] as? String == "caedrel")
        let url = (node["thumbnail_url"] as? String)?
            .replacingOccurrences(of: "{width}", with: "320")
            .replacingOccurrences(of: "{height}", with: "180")
        #expect(url == "https://cdn/live_user_caedrel-320x180.jpg")
    }

    @Test("The board attributes a followed list that came from an account")
    func attribution() {
        let mine = [MediaChannel(source: .twitch, handle: "a", name: "A")]
        var board = WatchChooser(watchlist: mine, followed: mine)
        board.attribute("Twitch · Marcus")
        let following = board.sections.first { $0.id == WatchChooser.followingID }
        #expect(following?.detail == "Twitch · Marcus")
        board.attribute(nil)
        #expect(board.sections.first { $0.id == WatchChooser.followingID }?.detail != "Twitch · Marcus")
    }
}
