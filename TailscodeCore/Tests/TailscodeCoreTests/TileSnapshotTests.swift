import Foundation
import Testing

@testable import TailscodeCore

/// What schema 1 could read, decoded the way schema 1 decoded it: the older reader a downgrade
/// hands a schema 2 snapshot to.
private struct LegacySnapshot: Decodable {
    let layout: SplitLayout
    let sessions: [String: SplitPaneSession]
    let videos: [String: String]?
    let pages: [String: String]?
    let draws: [String: String]?
}

/// The snapshot is the one value both desktops persist, and two builds of different ages read
/// it, so its compatibility in both directions is pinned: old snapshots migrate, new snapshots
/// still restore in an old build, unknown kinds degrade to empty, and broken ones are refused.
@Suite("Tile snapshot")
struct TileSnapshotTests {

    private func object(_ snapshot: SplitSnapshot) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func text(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("A schema 1 snapshot decodes into schema 2 contents")
    func legacySnapshotMigrates() throws {
        let layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let ids = layout.paneIDs
        let layoutData = try JSONEncoder().encode(layout)
        let legacy: [String: Any] = [
            "layout": try JSONSerialization.jsonObject(with: layoutData),
            "sessions": [ids[0].raw: ["profileID": "p", "sessionID": "s"]],
            "videos": [ids[1].raw: VideoTarget.twitch("kamet0").address],
            "pages": [ids[2].raw: "https://swift.org"],
        ]
        let decoded = try #require(SplitSnapshot.decode(try text(legacy)))

        #expect(decoded.schema == 2)
        #expect(decoded.content(for: ids[0]) == .chat(SplitPaneSession(profileID: "p", sessionID: "s")))
        #expect(decoded.content(for: ids[1]) == .video(VideoTarget.twitch("kamet0").address))
        #expect(decoded.content(for: ids[2]) == .web("https://swift.org"))
        #expect(decoded.content(for: ids[3]) == .empty)
        #expect(decoded.session(for: ids[0])?.sessionID == "s")
        #expect(decoded.video(for: ids[1]) == .twitch("kamet0"))
        #expect(decoded.page(for: ids[2]) != nil)
        #expect(decoded.draws.isEmpty)
        #expect(decoded.pinned.isEmpty)
    }

    @Test("A kind from a newer build decodes as an empty pane, not a refusal")
    func unknownKindIsEmpty() throws {
        let layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let ids = layout.paneIDs
        var stored = try object(
            SplitSnapshot(layout: layout, contents: [ids[0]: .web("example.com")].keyedByRaw))
        stored["contents"] = [
            ids[0].raw: ["kind": "web", "address": "example.com"],
            ids[1].raw: ["kind": "hologram", "address": "somewhere"],
        ]
        let decoded = try #require(SplitSnapshot.decode(try text(stored)))
        #expect(decoded.content(for: ids[0]) == .web("example.com"))
        #expect(decoded.content(for: ids[1]) == .empty)
    }

    @Test("Schema 2 still restores in a schema 1 build, through the dual-written dictionaries")
    func dualWriteFeedsTheOlderReader() throws {
        let layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let ids = layout.paneIDs
        let snapshot = SplitSnapshot(
            layout: layout,
            contents: [
                ids[0]: .chat(SplitPaneSession(profileID: "p", sessionID: "s")),
                ids[1]: .video("twitch.tv/kamet0"), ids[2]: .web("https://swift.org"),
                ids[3]: .draw("http://box:8188\tprompt"),
            ].keyedByRaw, pinned: [ids[1].raw])
        let encoded = try #require(snapshot.encoded)
        let old = try JSONDecoder().decode(LegacySnapshot.self, from: Data(encoded.utf8))

        #expect(old.layout == layout)
        #expect(old.sessions == [ids[0].raw: SplitPaneSession(profileID: "p", sessionID: "s")])
        #expect(old.videos == [ids[1].raw: "twitch.tv/kamet0"])
        #expect(old.pages == [ids[2].raw: "https://swift.org"])
        #expect(old.draws == [ids[3].raw: "http://box:8188\tprompt"])

        let again = try #require(SplitSnapshot.decode(encoded))
        #expect(again == snapshot)
        #expect(again.isPinned(ids[1]))
        #expect(!again.isPinned(ids[0]))
        #expect(again.draw(for: ids[3]) == "http://box:8188\tprompt")
    }

    @Test("The schema 1 initializer keeps one content per pane, slots before chats")
    func legacyInitializerPicksOneContent() throws {
        let layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let ids = layout.paneIDs
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [ids[0].raw: SplitPaneSession(profileID: "p", sessionID: "s")],
            videos: [ids[0].raw: "twitch.tv/a"], pages: [ids[1].raw: "example.com"],
            draws: [ids[1].raw: "http://box:8188"])
        #expect(snapshot.content(for: ids[0]) == .video("twitch.tv/a"))
        #expect(snapshot.content(for: ids[1]) == .draw("http://box:8188"))
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.pages.isEmpty)
    }

    @Test("More than twelve panes keeps the first twelve in reading order and says how many went")
    func ceilingTruncates() throws {
        var layout = try #require(SplitEven.arrange(ids: (0..<15).map { _ in PaneID() }, as: .sideBySide))
        let ids = layout.paneIDs
        layout.focus(ids[2])
        layout.focus(ids[14])
        var contents: [String: PaneContent] = [:]
        for (index, id) in ids.enumerated() {
            contents[id.raw] = .chat(SplitPaneSession(profileID: "p", sessionID: "s\(index)"))
        }
        let snapshot = SplitSnapshot(layout: layout, contents: contents, pinned: [ids[13].raw, ids[1].raw])
        let encoded = try #require(snapshot.encoded)
        let decoded = try #require(SplitSnapshot.decodeReporting(encoded))

        #expect(decoded.droppedPanes == 3)
        #expect(decoded.snapshot.layout.paneIDs == Array(ids.prefix(12)))
        #expect(decoded.snapshot.layout.isValid)
        #expect(decoded.snapshot.layout.focusedPane == ids[2])
        #expect(decoded.snapshot.contents.count == 12)
        #expect(decoded.snapshot.session(for: ids[12]) == nil)
        #expect(decoded.snapshot.pinned == [ids[1].raw])
        #expect(SplitSnapshot.decode(encoded)?.layout.paneCount == 12)

        let small = SplitSnapshot(layout: try #require(SplitEven.layout(count: 3, as: .grid)), contents: [:])
        let smallText = try #require(small.encoded)
        #expect(SplitSnapshot.decodeReporting(smallText)?.droppedPanes == 0)
    }

    @Test("A corrupt snapshot is discarded whole")
    func corruptIsDiscarded() throws {
        let layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let ids = layout.paneIDs
        let good = try object(SplitSnapshot(layout: layout, contents: [:]))
        #expect(SplitSnapshot.decode(try text(good)) != nil)

        #expect(SplitSnapshot.decode("not json") == nil)
        #expect(SplitSnapshot.decode("{}") == nil)
        #expect(SplitSnapshot.decode("{\"schema\":2,\"contents\":{}}") == nil)

        var tree = try #require(good["layout"] as? [String: Any])
        var duplicate = good
        tree["root"] = [
            "split": [
                "id": "x", "axis": "horizontal", "ratio": 0.5,
                "first": ["pane": ["_0": ids[0].raw]], "second": ["pane": ["_0": ids[0].raw]],
            ]
        ]
        duplicate["layout"] = tree
        #expect(SplitSnapshot.decode(try text(duplicate)) == nil)

        var unknownFocus = good
        var focusTree = try #require(good["layout"] as? [String: Any])
        focusTree["focusedPane"] = "nobody"
        unknownFocus["layout"] = focusTree
        #expect(SplitSnapshot.decode(try text(unknownFocus)) == nil)

        var badRatio = good
        var ratioTree = try #require(good["layout"] as? [String: Any])
        var root = try #require(ratioTree["root"] as? [String: Any])
        var split = try #require(root["split"] as? [String: Any])
        split["ratio"] = 1.5
        root["split"] = split
        ratioTree["root"] = root
        badRatio["layout"] = ratioTree
        #expect(SplitSnapshot.decode(try text(badRatio)) == nil)
    }

    @Test("A pane's content survives its own round trip, and a broken one is empty")
    func paneContentCodable() throws {
        let cases: [PaneContent] = [
            .empty, .chat(SplitPaneSession(profileID: "p", sessionID: "s")), .web("example.com"),
            .video("twitch.tv/x"), .draw("http://box:8188"),
        ]
        for content in cases {
            let data = try JSONEncoder().encode(content)
            #expect(try JSONDecoder().decode(PaneContent.self, from: data) == content)
        }
        let chat = try JSONEncoder().encode(PaneContent.chat(SplitPaneSession(profileID: "p", sessionID: "s")))
        let chatText = try #require(String(data: chat, encoding: .utf8))
        #expect(chatText.contains("\"kind\":\"chat\""))
        for broken in [
            "{\"kind\":\"chat\",\"profileID\":\"p\"}", "{\"kind\":\"web\"}", "{\"kind\":\"later\"}",
            "{}",
        ] {
            #expect(try JSONDecoder().decode(PaneContent.self, from: Data(broken.utf8)) == .empty)
        }
        #expect(PaneContent.video("x").kind == .video)
    }
}

extension Dictionary where Key == PaneID, Value == PaneContent {
    var keyedByRaw: [String: PaneContent] {
        Dictionary<String, PaneContent>(uniqueKeysWithValues: map { ($0.key.raw, $0.value) })
    }
}
