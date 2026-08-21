import Foundation
import Testing

@testable import TailscodeCore

/// A slot is a pane, so what it holds has to survive a restart and read back to the same thing.
/// These pin the reading of a typed line and the round trip through a layout snapshot.
@Suite("Video slot")
struct VideoSlotTests {

    @Test("A bare word is the channel someone meant to type")
    func bareWordIsTwitch() {
        #expect(VideoTarget.classify("zackrawrr") == .twitch("zackrawrr"))
        #expect(VideoTarget.classify("  Kamet0 ") == .twitch("kamet0"))
        #expect(VideoTarget.classify("tw:xQc") == .twitch("xqc"))
    }

    @Test("Words are words, and go to a search the player can open on its own")
    func wordsBecomeSearch() {
        #expect(VideoTarget.classify("lofi hip hop radio") == .search("lofi hip hop radio"))
        #expect(
            VideoTarget.classify("lofi hip hop")?.playbackURL == "ytdl://ytsearch1:lofi hip hop")
    }

    @Test("A channel link is a channel, a video link is just a link")
    func linksReadForWhatTheyAre() {
        #expect(VideoTarget.classify("https://www.twitch.tv/kamet0") == .twitch("kamet0"))
        #expect(
            VideoTarget.classify("https://twitch.tv/videos/2836323989")
                == .link("https://twitch.tv/videos/2836323989"))
        #expect(VideoTarget.classify("https://www.youtube.com/@LofiGirl") == .youtube("@LofiGirl"))
        #expect(VideoTarget.classify("@LofiGirl") == .youtube("@LofiGirl"))
        #expect(
            VideoTarget.classify("https://youtu.be/dQw4w9WgXcQ")
                == .link("https://youtu.be/dQw4w9WgXcQ"))
    }

    @Test("A YouTube channel opens its live broadcast")
    func youtubeChannelPlaysLive() {
        #expect(
            VideoTarget.youtube("@LofiGirl").playbackURL == "https://www.youtube.com/@LofiGirl/live")
        #expect(VideoTarget.twitch("kamet0").playbackURL == "https://www.twitch.tv/kamet0")
    }

    @Test("Nothing typed points at nothing")
    func emptyIsNoTarget() {
        #expect(VideoTarget.classify("") == nil)
        #expect(VideoTarget.classify("   ") == nil)
    }

    @Test("Every target's address reads back to the same target")
    func addressRoundTrips() {
        let targets: [VideoTarget] = [
            .twitch("kamet0"),
            .youtube("@LofiGirl"),
            .search("lofi hip hop radio"),
            .link("https://twitch.tv/videos/2836323989"),
            .link("/home/marcus/clip.mp4"),
        ]
        for target in targets {
            #expect(VideoTarget.classify(target.address) == target)
        }
    }

    @Test("The slot asks, opens, then names the stream itself")
    func phasesFollowTheStream() {
        var slot = VideoSlot()
        #expect(slot.isAsking)
        #expect(slot.title == Localized.text("Watch"))

        slot.point(at: .twitch("kamet0"))
        #expect(slot.phase == .loading)
        #expect(slot.title == "kamet0")

        slot.loaded(title: "Kamet0 · LEC Summer")
        #expect(slot.phase == .playing)
        #expect(slot.title == "Kamet0 · LEC Summer")

        slot.failed("nothing there")
        #expect(slot.phase == .failed("nothing there"))
        #expect(slot.subtitle == "nothing there")
    }

    @Test("Changing the target puts what it was watching back in the box")
    func askKeepsTheOldTargetToEdit() {
        var slot = VideoSlot(target: .twitch("kamet0"))
        slot.ask()
        #expect(slot.isAsking)
        #expect(slot.draft == "kamet0")
    }

    @Test("A layout snapshot carries the slots and restores them")
    func snapshotCarriesSlots() throws {
        var layout = SplitLayout()
        let first = layout.focusedPane
        let split = layout.split(first, axis: .horizontal)
        let second = try #require(split)
        let snapshot = SplitSnapshot(
            layout: layout,
            sessions: [first.raw: SplitPaneSession(profileID: "p", sessionID: "s")],
            videos: [second.raw: VideoTarget.twitch("kamet0").address])
        let encoded = try #require(snapshot.encoded)
        let restored = try #require(SplitSnapshot.decode(encoded))

        #expect(restored.video(for: second) == .twitch("kamet0"))
        #expect(restored.video(for: first) == nil)
        #expect(restored.session(for: first)?.sessionID == "s")
    }

    @Test("A layout written before slots existed still restores")
    func oldSnapshotsStillDecode() throws {
        var layout = SplitLayout()
        _ = layout.split(layout.focusedPane, axis: .vertical)
        let legacy = SplitSnapshot(layout: layout, sessions: [:])
        let encoded = try #require(legacy.encoded)
        let parsed = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        var object = try #require(parsed as? [String: Any])
        object.removeValue(forKey: "videos")
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = try #require(String(data: data, encoding: .utf8))

        let restored = try #require(SplitSnapshot.decode(text))
        #expect(restored.videos.isEmpty)
    }

    @Test("The keys a slot answers are the same on both desktops")
    func keysMapToVerbs() {
        func chord(_ scalar: Unicode.Scalar) -> KeyChord {
            KeyChord(keyval: scalar.value, control: false, shift: false, alt: false)
        }
        #expect(VideoCommand.command(for: chord(" ")) == .playPause)
        #expect(VideoCommand.command(for: chord("m")) == .mute)
        #expect(VideoCommand.command(for: chord("e")) == .change)
        #expect(VideoCommand.command(for: chord("l")) == .seekForward)
        #expect(
            VideoCommand.command(
                for: KeyChord(keyval: 0x6D, control: true, shift: false, alt: false)) == nil)
        #expect(VideoCommand.playPause.mpvCommand == ["cycle", "pause"])
    }

    @Test("The chooser offers a slot beside the servers, and says what it costs")
    func chooserOffersWatching() {
        var chooser = PaneChooser(
            servers: [
                PaneChooserServer(
                    profileID: "a", name: "one", backend: .claudeCode, address: "1.2.3.4")
            ], entries: [])
        #expect(chooser.rows.contains { $0.action == .watch })
        #expect(chooser.rows.first { $0.action == .watch }?.note == VideoNotice.splitCostLine)
        #expect(chooser.rows.first { $0.action == .newChat(profileID: "a") }?.note == nil)
        #expect(chooser.activate(.watch) == .watch)
    }

    @Test("A slot says what a stream costs the grid, before and while it plays")
    func slotStatesItsSplitCost() {
        var slot = VideoSlot()
        #expect(slot.notice == VideoNotice.splitCost)
        #expect(!slot.subtitle.contains(VideoNotice.splitCostTag))

        slot.point(at: .twitch("kamet0"))
        #expect(!slot.subtitle.contains(VideoNotice.splitCostTag))

        slot.loaded(title: "Kamet0 · LEC")
        #expect(slot.subtitle == "twitch · \(VideoNotice.splitCostTag)")

        slot.muted = true
        #expect(slot.subtitle.contains(Localized.text("%@ · muted", "twitch")))
        #expect(slot.subtitle.hasSuffix(VideoNotice.splitCostTag))

        slot.paused = true
        #expect(!slot.subtitle.contains(VideoNotice.splitCostTag))

        slot.failed("nothing there")
        #expect(slot.subtitle == "nothing there")
    }

    @Test("An address is read the way people type one")
    func addressesReadNaturally() {
        #expect(WebTarget.classify("swift.org") == .page("https://swift.org"))
        #expect(WebTarget.classify("https://swift.org/x") == .page("https://swift.org/x"))
        #expect(WebTarget.classify(":3000") == .page("http://localhost:3000"))
        #expect(WebTarget.classify("localhost:8080/health") == .page("http://localhost:8080/health"))
        #expect(WebTarget.classify("how do I split a pane") == .search("how do I split a pane"))
        #expect(WebTarget.classify("  ") == nil)
    }

    @Test("A search becomes a real page, and a page round-trips through a snapshot")
    func searchesAndSnapshots() throws {
        let search = try #require(WebTarget.classify("split pane"))
        #expect(search.url.hasPrefix("https://duckduckgo.com/?q="))

        var layout = SplitLayout()
        let first = layout.focusedPane
        let split = layout.split(first, axis: .vertical)
        let second = try #require(split)
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [:], videos: [:],
            pages: [second.raw: "https://swift.org/documentation/"])
        let encoded = try #require(snapshot.encoded)
        let restored = try #require(SplitSnapshot.decode(encoded))
        #expect(restored.page(for: second) == .page("https://swift.org/documentation/"))
        #expect(restored.page(for: first) == nil)
    }

    @Test("A browsing pane claims only the chords a browser owns")
    func onlyBrowserChordsAreClaimed() throws {
        let plainA = try #require(KeyChord.canonical(keyval: 0x61, state: 0))
        let ctrlL = try #require(KeyChord.canonical(keyval: 0x6C, state: KeyChord.controlMask))
        let altLeft = try #require(KeyChord.canonical(keyval: 0xFF51, state: KeyChord.altMask))
        #expect(WebCommand.command(for: plainA) == nil)
        #expect(WebCommand.command(for: ctrlL) == .address)
        #expect(WebCommand.command(for: altLeft) == .back)
        #expect(WebCommand.zoom(1, .zoomIn) == 1.1)
        #expect(WebCommand.zoom(0.4, .zoomOut) == 0.4)
        #expect(WebCommand.zoom(2, .zoomReset) == 1)
    }

    @Test("The slot names itself by the page, then explains a refusal")
    func slotFollowsThePage() {
        var slot = WebSlot()
        #expect(slot.isAsking)
        slot.point(at: .page("https://swift.org"))
        #expect(slot.phase == .loading(0))
        slot.progress(0.5)
        slot.arrived(url: "https://www.swift.org/", title: "Swift Programming Language")
        #expect(slot.phase == .showing)
        #expect(slot.title == "Swift Programming Language")
        slot.ask()
        #expect(slot.draft == "https://www.swift.org/")
        slot.failed("no route to host")
        #expect(slot.subtitle == "no route to host")
    }

    @Test("The chooser offers a page beside the servers")
    func chooserOffersBrowsing() {
        var chooser = PaneChooser(
            servers: [
                PaneChooserServer(
                    profileID: "a", name: "one", backend: .claudeCode, address: "1.2.3.4")
            ], entries: [])
        #expect(chooser.rows.contains { $0.action == .browse })
        #expect(chooser.activate(.browse) == .browse)
    }
}

@Suite("Pane chooser capabilities")
struct PaneChooserCapabilityTests {
    private var servers: [PaneChooserServer] {
        [
            PaneChooserServer(
                profileID: "a", name: "studio", backend: .claudeCode, address: "studio:4098"),
            PaneChooserServer(
                profileID: "b", name: "homelab", backend: .openCode, address: "homelab:4096"),
        ]
    }

    @Test("A client that cannot open a slot is never offered one, at either step")
    func hidesRowsItCannotOpen() {
        var chooser = PaneChooser(servers: servers, entries: [])
        chooser.offersWatching = false
        chooser.offersBrowsing = false
        #expect(!chooser.rows.contains { $0.action == .watch })
        #expect(!chooser.rows.contains { $0.action == .browse })
        _ = chooser.activate(.chooseServer("a"))
        #expect(!chooser.rows.contains { $0.action == .watch })
        #expect(!chooser.rows.contains { $0.action == .browse })
    }

    @Test("A fresh listing does not put back a row the client has no slot for")
    func restateKeepsCapabilities() {
        var chooser = PaneChooser(servers: servers, entries: [])
        chooser.offersWatching = false
        chooser.offersBrowsing = false
        let next = chooser.restated(servers: servers, entries: [])
        #expect(!next.offersWatching)
        #expect(!next.offersBrowsing)
        #expect(!next.rows.contains { $0.action == .watch })
        #expect(!next.rows.contains { $0.action == .browse })
    }
}
