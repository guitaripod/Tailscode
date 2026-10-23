import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the board owes its clients, proved on the payloads the two sources actually send
    /// rather than on the network: the shapes are pinned here so a site changing one is a failing
    /// selftest instead of a pane that quietly shows nothing.
    /// That an account survives being written and read back through the same store a server
    /// password uses, and that a signed-out box is signed out rather than half-signed-in. Runs
    /// against a throwaway file so the box's own accounts are never touched.
    static func checkWatchAccounts() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("watch sign-in: \(label)") }
            checks += 1
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secrets = FileSecretStore(url: scratch.appendingPathComponent("secrets.json"))
        MediaAccounts.install(secrets)
        defer { MediaAccounts.install(FileSecretStore()) }

        let source = MediaSource.twitch
        MediaAccounts.signOut(source)
        try expect(!MediaAccounts.isSignedIn(source), "a fresh box is signed out")
        try expect(MediaAccounts.account(for: source) == nil, "and names nobody")

        let tokens = OAuthTokens(
            access: "a", refresh: "r", expiresAt: Date().addingTimeInterval(3600), scope: "s")
        let account = MediaAccount(source: source, name: "Marcus", handle: "marcus")
        MediaAccounts.remember(tokens, account)
        try expect(MediaAccounts.isSignedIn(source), "remembering signs it in")
        try expect(MediaAccounts.account(for: source)?.name == "Marcus", "and names the account")
        try expect(MediaAccounts.tokens(for: source)?.access == "a", "with a token that reads back")
        try expect(
            try secrets.value(for: "tailscode.watch.oauth.twitch") != nil,
            "kept where this box keeps a secret, not in the settings file")
        try expect(
            UserDefaults.standard.string(forKey: "tailscode.watch.oauth.twitch") == nil,
            "and never in plain defaults")

        MediaAccounts.signOut(source)
        try expect(!MediaAccounts.isSignedIn(source), "signing out signs it out")
        try expect(
            try secrets.value(for: "tailscode.watch.oauth.twitch") == nil,
            "and takes the token with it")

        let rows = WatchAccounts.rows()
        try expect(rows.count == 2, "settings offers both sites")
        try expect(
            rows.first { $0.source == .twitch }?.action == .signIn(.twitch),
            "Twitch is signable in with nothing configured")
        try expect(
            WatchAccounts.summary == Localized.text("Not signed in to either site"),
            "and a signed-out box says so plainly")
        return checks
    }

    static func checkWatchDirectory() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("watch directory: \(label)") }
            checks += 1
        }

        let twitch = """
            {"login":"caedrel","displayName":"Caedrel","profileImageURL":"https://cdn/a.png",\
            "stream":{"title":"LCK","viewersCount":36579,"createdAt":"2026-08-07T07:30:10Z",\
            "game":{"name":"League of Legends"},"previewImageURL":"https://cdn/p.jpg",\
            "freeformTags":[{"name":"English"}]}}
            """
        let user = try JSONSerialization.jsonObject(with: Data(twitch.utf8)) as? [String: Any]
        try expect(user != nil, "a Twitch channel is JSON")
        let entry = TwitchDirectory.entry(from: user ?? [:], now: Date())
        try expect(entry?.channel.name == "Caedrel", "and reads into a named channel")
        try expect(entry?.isLive == true, "that is live")
        try expect(entry?.badge == "37K", "wearing its audience")
        try expect(entry?.stream?.thumbnail != nil, "with a picture to draw")
        try expect(entry?.target == .twitch("caedrel"), "opening the channel it names")

        let youtube = """
            {"c":{"videoRenderer":{"videoId":"abc","title":{"runs":[{"text":"radio"}]},\
            "ownerText":{"runs":[{"text":"Lofi Girl"}]},\
            "viewCountText":{"runs":[{"text":"12,304"},{"text":" watching"}]},\
            "badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW"}}],\
            "thumbnail":{"thumbnails":[{"url":"https://i/big.jpg"}]}}}}
            """
        let page = try JSONSerialization.jsonObject(with: Data(youtube.utf8)) as? [String: Any]
        let found = YouTubeDirectory.rows(in: page ?? [:], limit: 4)
        try expect(found.count == 1, "a YouTube page gives up its live row")
        try expect(found.first?.stream?.viewers == 12304, "with the count it printed")

        let channel = MediaChannel(source: .twitch, handle: "caedrel", name: "Caedrel")
        var board = WatchChooser(watchlist: [channel], followed: [channel])
        try expect(board.rows.count == 1, "the list this device owns is a board on its own")
        board.filled(live: MediaFeed(entries: [entry].compactMap { $0 }))
        try expect(board.sections.first?.id == WatchChooser.liveID, "and what is on leads it")
        try expect(board.rows.first?.thumbnail != nil, "carrying the picture a row draws")

        let summary = WatchSummary(feed: MediaFeed(entries: [entry].compactMap { $0 }), followed: 1)
        var chooser = PaneChooser(
            servers: [
                PaneChooserServer(
                    profileID: "p", name: "arch", backend: .claudeCode, address: "100.0.0.1:4098")
            ], entries: [])
        chooser.watchSummary = summary
        let watchRow = chooser.rows.first { $0.action == .watch }
        try expect(watchRow?.detail == summary.detail, "and the pane row says the same thing")
        try expect(watchRow?.note == VideoNotice.splitCostLine, "without losing what it costs")
        return checks
    }

    static func checkVideoSlot() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("video slot: \(label)") }
            checks += 1
        }

        try expect(VideoTarget.classify("kamet0") == .twitch("kamet0"), "a bare word is a channel")
        try expect(
            VideoTarget.classify("https://www.twitch.tv/kamet0") == .twitch("kamet0"),
            "a channel link is that channel")
        try expect(
            VideoTarget.classify("@LofiGirl") == .youtube("@LofiGirl"), "a handle is a channel")
        try expect(
            VideoTarget.classify("lofi hip hop") == .search("lofi hip hop"), "words are a search")
        try expect(VideoTarget.classify("  ") == nil, "nothing typed points nowhere")
        for target: VideoTarget in [
            .twitch("kamet0"), .youtube("@LofiGirl"), .search("two words"), .link("/tmp/a.mp4"),
        ] {
            try expect(
                VideoTarget.classify(target.address) == target, "\(target.address) round-trips")
        }

        var slot = VideoSlot()
        try expect(slot.isAsking, "an empty slot asks")
        slot.point(at: .twitch("kamet0"))
        try expect(slot.phase == .loading && slot.title == "kamet0", "a pointed slot opens")
        slot.loaded(title: "Kamet0 · LEC")
        try expect(slot.phase == .playing && slot.title == "Kamet0 · LEC", "the stream names it")
        try expect(
            slot.subtitle.hasSuffix(VideoNotice.splitCostTag),
            "a playing slot says what it costs the grid")
        slot.paused = true
        try expect(
            !slot.subtitle.contains(VideoNotice.splitCostTag),
            "a paused slot costs nothing and stops saying so")
        slot.paused = false
        try expect(!slot.notice.isEmpty, "an empty slot has the whole of it to read")
        slot.ask()
        try expect(
            slot.isAsking && slot.draft == "kamet0",
            "changing it offers the channel back, not the stream's own title")

        var layout = SplitLayout()
        let first = layout.focusedPane
        guard let second = layout.split(first, axis: .horizontal) else {
            throw SelfTestFailure("video slot: the layout would not split")
        }
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [:], videos: [second.raw: VideoTarget.twitch("kamet0").address]
        )
        guard let encoded = snapshot.encoded, let restored = SplitSnapshot.decode(encoded) else {
            throw SelfTestFailure("video slot: the layout would not persist")
        }
        try expect(restored.video(for: second) == .twitch("kamet0"), "a restart reopens the slot")
        try expect(restored.video(for: first) == nil, "a chat pane restores as a chat")

        guard let space = KeyChord.canonical(keyval: 0x20, state: 0),
            let controlM = KeyChord.canonical(keyval: 0x6D, state: KeyChord.controlMask)
        else { throw SelfTestFailure("video slot: a keystroke would not resolve") }
        try expect(VideoCommand.command(for: space) == .playPause, "space pauses")
        try expect(VideoCommand.command(for: controlM) == nil, "a control chord stays the app's")
        return checks
    }

    /// A page is a pane, so what it holds has to read back the same after a restart, and a browsing
    /// pane must leave the keyboard to the page except for the chords a browser owns.
    static func checkBrowserSlot() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("browser slot: \(label)") }
            checks += 1
        }

        try expect(WebTarget.classify("swift.org") == .page("https://swift.org"), "a host is a page")
        try expect(WebTarget.classify(":3000") == .page("http://localhost:3000"), "a port is local")
        try expect(
            WebTarget.classify("localhost:8080/health") == .page("http://localhost:8080/health"),
            "a local path is kept")
        try expect(
            WebTarget.classify("how to split a pane") == .search("how to split a pane"),
            "words are a search")
        try expect(WebTarget.classify("  ") == nil, "nothing typed points nowhere")
        try expect(
            WebTarget.search("two words").url.hasPrefix("https://duckduckgo.com/?q="),
            "a search is a real page")

        var slot = WebSlot()
        try expect(slot.isAsking, "an empty slot asks")
        slot.point(at: .page("https://swift.org"))
        slot.arrived(url: "https://www.swift.org/", title: "Swift Programming Language")
        try expect(slot.phase == .showing, "a landed page shows")
        try expect(slot.title == "Swift Programming Language", "the page names the pane")
        slot.ask()
        try expect(slot.draft == "https://www.swift.org/", "the address bar opens on where it is")

        var layout = SplitLayout()
        let first = layout.focusedPane
        guard let second = layout.split(first, axis: .vertical) else {
            throw SelfTestFailure("browser slot: the layout would not split")
        }
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [:], videos: [:],
            pages: [second.raw: "https://swift.org/documentation/"])
        guard let encoded = snapshot.encoded, let restored = SplitSnapshot.decode(encoded) else {
            throw SelfTestFailure("browser slot: the layout would not persist")
        }
        try expect(
            restored.page(for: second) == .page("https://swift.org/documentation/"),
            "a restart reopens the page")

        guard let plain = KeyChord.canonical(keyval: 0x61, state: 0),
            let address = KeyChord.canonical(keyval: 0x6C, state: KeyChord.controlMask),
            let back = KeyChord.canonical(keyval: 0xFF51, state: KeyChord.altMask)
        else { throw SelfTestFailure("browser slot: a keystroke would not resolve") }
        try expect(WebCommand.command(for: plain) == nil, "a letter belongs to the page")
        try expect(WebCommand.command(for: address) == .address, "ctrl+l opens the address bar")
        try expect(WebCommand.command(for: back) == .back, "alt+left goes back")
        return checks
    }

    /// The dial drawn, not only decided: pinned pairs carry their meter, the ladder turns into a
    /// preview off this chat's model and says what a level will become, ⇥ hands the arrows to the
    /// ladder before focus traversal can take the key, a search that finds nothing is a message no
    /// cursor lands on, and a pick hands over the level the ladder showed.
    static func checkModelDial() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("model dial: \(label)") }
            checks += 1
        }
        let picked = PickBox()
        let dial = ModelDialPopover(
            makeState: { DialDemo.state() },
            onPick: { pick, effort, _ in picked.value = (pick.modelName, effort) },
            onEffort: { _ in }, onOpenCatalog: {})
        dial.fill()
        guard let opened = dial.current else { throw SelfTestFailure("model dial: no state") }
        try expect(dial.drawnRows == opened.rows.count, "every row is drawn, in order")
        try expect(
            opened.rows.first?.section != nil && opened.rows.first?.level?.word == "high",
            "the pinned pair leads under its heading with its level as a meter")
        try expect(opened.focused?.isCurrent == true, "it opens on what the chat runs")
        try expect(
            dial.drawsPreview == opened.ladderIsPreview, "the ladder says whether it is live or a preview")

        _ = dial.press(keyval: Keymap.down)
        guard let sonnet = dial.current else { throw SelfTestFailure("model dial: lost state") }
        try expect(sonnet.focused?.preset != nil && sonnet.ladderIsPreview, "down walks to a pair")
        try expect(dial.drawsPreview, "the ladder previews another model's levels")
        try expect(sonnet.ladderEffort == "low", "and lights the level the pair would take")

        _ = dial.press(keyval: Keymap.tab)
        try expect(
            dial.current?.column == .ladder && dial.activeColumnIsLadder,
            "tab hands the arrows to the ladder and the ladder wears it")
        _ = dial.press(keyval: Keymap.up)
        try expect(dial.current?.ladderEffort == "high", "up on the ladder steps the preview")
        _ = dial.press(keyval: Keymap.enter)
        try expect(
            picked.value?.0 == "Sonnet" && picked.value?.1 == .set("high"),
            "the pick carries the level the ladder showed")

        dial.fill()
        var walks = 0
        while dial.current?.carryNotice == nil, walks < 12 {
            _ = dial.press(keyval: Keymap.down)
            walks += 1
        }
        try expect(dial.current?.carryNotice != nil, "a row whose model lacks high says so first")

        dial.search("zzzz-no-model")
        guard let empty = dial.current else { throw SelfTestFailure("model dial: lost state") }
        try expect(empty.rows.first?.isMessage == true, "nothing found is a message row")
        try expect(empty.focused?.isMessage != true, "and no cursor lands on it")
        try expect(dial.drawnRows == empty.rows.count, "the message is drawn with the rest")
        return checks
    }

    final class PickBox: @unchecked Sendable {
        var value: (String, EffortAsk)?
    }

    /// What a resting pointer is offered, proved without a screen: which message a vertical position
    /// is on, what its plate says and offers (the time, Copy as words without thoughts, Undo only
    /// on a prompt a server can wind back to), which way a chat row's verbs would go, and that the
    /// two floating widgets take a place and give it back.
    static func checkPointerFeedback() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pointer feedback: \(label)") }
            checks += 1
        }
        let rows: [(owner: String?, span: ClosedRange<Double>)] = [
            ("u1", 0...40), (nil, 50...60), ("a1", 70...100), ("a1", 110...150), (nil, 160...170),
            ("u2", 180...220),
        ]
        func hit(_ y: Double) -> PointerRows.Hit? {
            PointerRows.message(
                atY: y, count: rows.count, span: { rows[$0].span }, owner: { rows[$0].owner })
        }
        try expect(hit(20) == PointerRows.Hit(owner: "u1", rows: 0...0), "a prompt is found")
        try expect(hit(55) == nil, "the room between a prompt and the work under it is nobody's")
        try expect(
            hit(85)?.rows == 2...3 && hit(105)?.rows == 2...3,
            "an answer's rows are one message, and the room inside it is still on it")
        try expect(hit(165) == nil, "a tool row is not a message")
        try expect(hit(500) == nil && hit(-3) == nil, "off either end finds nothing")
        try expect(
            PointerRows.row(atY: 120, count: rows.count, span: { rows[$0].span }) == 3,
            "a position finds its row")

        let now = Date()
        let prompt = ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("do it"))], createdAt: now)
        let answer = ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(id: "t", kind: .text("First **part**.")),
                MessagePart(id: "r", kind: .reasoning("a thought")),
                MessagePart(id: "u", kind: .text("Second.")),
            ], createdAt: now)
        let winding = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false, supportsRevert: true)
        let fixed = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false)
        try expect(
            MessageHover.words(of: answer) == "First **part**.\n\nSecond.",
            "Copy is the words as written, thoughts left out")
        try expect(
            MessageHover.verbs(for: prompt, isPrompt: true, capabilities: winding, now: now).undo,
            "a prompt on a server that can wind back offers Undo")
        try expect(
            !MessageHover.verbs(
                for: prompt, isPrompt: true, capabilities: fixed, now: now).undo,
            "a server that cannot wind back offers none")
        try expect(
            !MessageHover.verbs(for: answer, isPrompt: false, capabilities: winding, now: now).undo,
            "an answer is never wound back to")
        try expect(
            MessageHover.stamp(now, now: now) == now.formatted(date: .omitted, time: .shortened),
            "today is the time alone")
        try expect(
            MessageHover.stamp(now.addingTimeInterval(-3 * 86_400), now: now).count
                > MessageHover.stamp(now, now: now).count,
            "an older message says which day")

        let off = ChatRowVerbState(pinned: false, saved: false, archived: false)
        let on = ChatRowVerbState(pinned: true, saved: true, archived: true)
        try expect(
            ChatRowVerb.allCases.map { off.title($0) } == ["Pin", "Save", "Archive", "More"],
            "an unmarked chat's verbs say what they would do")
        try expect(
            ChatRowVerb.allCases.map { on.title($0) } == ["Unpin", "Unsave", "Unarchive", "More"],
            "a marked chat's verbs read as the way out")
        try expect(
            ChatRowVerb.allCases.map { on.isOn($0) } == [true, true, true, false],
            "the verbs in force are lit and the menu never is")
        try expect(
            ChatRowVerbStrip.icon(.save, on: true) != ChatRowVerbStrip.icon(.save, on: false),
            "a saved chat's star is filled")

        guard gtk_init_check() != 0 else { return checks }
        let overlay = gtk_overlay_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(overlay))
        defer { g_object_unref(UnsafeMutableRawPointer(overlay)) }
        let bar = MessageHoverBar()
        gtk_overlay_add_overlay(op(overlay), bar.widget)
        let verbs = MessageHover.verbs(
            for: prompt, isPrompt: true, capabilities: winding, now: now)
        bar.present(messageID: "u", verbs: verbs, right: 600, top: 10, ceiling: 2)
        try expect(bar.shownID == "u" && gtk_widget_get_visible(bar.widget) != 0, "the plate comes up")
        try expect(
            gtk_widget_get_margin_top(bar.widget) == 2
                && gtk_widget_get_margin_start(bar.widget) > 2
                && gtk_widget_get_margin_start(bar.widget) < 600,
            "it hangs from the message's corner and never above its ceiling")
        try expect(gtk_widget_get_can_focus(bar.widget) == 0, "it adds no focus stop")
        bar.present(messageID: "u", verbs: verbs, right: 600, top: 300, ceiling: 2)
        let first = gtk_widget_get_margin_top(bar.widget)
        bar.present(messageID: "u", verbs: verbs, right: 700, top: 500, ceiling: 2)
        try expect(
            gtk_widget_get_margin_top(bar.widget) - first == 200
                && gtk_widget_get_margin_start(bar.widget) > 400,
            "moving it again lands where asked — its own margins are never read back as its size")
        bar.dismiss()
        try expect(bar.shownID == nil && gtk_widget_get_can_target(bar.widget) == 0, "and goes")

        let strip = ChatRowVerbStrip()
        gtk_overlay_add_overlay(op(overlay), strip.widget)
        strip.present(key: "k", state: on, right: 300, bottom: 60)
        try expect(strip.shownKey == "k" && strip.state == on, "the verbs come up on a row")
        try expect(
            gtk_widget_has_css_class(strip.button(for: .pin)!, "row-verb-on") != 0
                && gtk_widget_has_css_class(strip.button(for: .more)!, "row-verb-on") == 0,
            "a pinned chat's pin is lit")
        strip.present(key: "k", state: off, right: 300, bottom: 60)
        try expect(
            gtk_widget_has_css_class(strip.button(for: .pin)!, "row-verb-on") == 0,
            "and goes out when the state does")
        strip.dismiss()
        try expect(strip.shownKey == nil, "the strip lets go")
        return checks
    }
}
