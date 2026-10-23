import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The whole keyboard system without a window: the shipped table resolves, canonicalisation
    /// folds keypad and shifted keys, sequences pend and land, the terminal keeps the shell's
    /// chords, approvals win only while one waits, and the rebinding file's grammar applies,
    /// unbinds and reports nonsense — the same cases the Linux desktop asserts, because the
    /// registry is the same table.
    static func checkShortcuts() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shortcut case failed: \(label)") }
            checks += 1
        }
        func chord(
            _ character: Character, control: Bool = false, shift: Bool = false
        ) -> KeyChord? {
            var state: UInt32 = 0
            if control { state |= KeyChord.controlMask }
            if shift { state |= KeyChord.shiftMask }
            guard let scalar = character.unicodeScalars.first else { return nil }
            return KeyChord.canonical(keyval: UInt32(scalar.value), state: state)
        }
        func action(
            _ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext,
            pending: [KeyChord] = [], awaiting: Bool = false
        ) -> KeyAction? {
            guard let chord else { return nil }
            let outcome = set.resolve(
                chord, context: context, pending: pending, awaitingApproval: awaiting)
            if case .run(let found) = outcome { return found }
            return nil
        }
        func pends(_ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext) -> Bool {
            guard let chord else { return false }
            let outcome = set.resolve(
                chord, context: context, pending: [], awaitingApproval: false)
            if case .pending = outcome { return true }
            return false
        }

        let set = ShortcutSet.build(overrides: [:])
        try expect(set.issues.isEmpty, "shipped defaults carry no conflicts: \(set.issues)")

        let parsed = KeySpec.parse("ctrl+shift+h")
        try expect(
            parsed?.chords == [chord("h", control: true, shift: true)].compactMap { $0 },
            "ctrl+shift+h parses to one canonical chord")
        try expect(
            KeySpec.parse("normal,insert:ctrl+b")?.contexts == [.normal, .insert],
            "a context prefix limits a spec")
        try expect(
            KeySpec.parse("J")?.chords.first == chord("j", shift: true),
            "an uppercase letter folds to shift plus lowercase")
        try expect(KeySpec.parse("g g")?.chords.count == 2, "a sequence is two chords")
        try expect(KeySpec.parse("bogus+key") == nil, "nonsense refuses to parse")

        try expect(action(set, chord("j"), .normal) == .scrollDown, "j scrolls")
        try expect(action(set, chord("J", shift: true), .normal) == .selectNext, "J selects")
        try expect(action(set, chord("e"), .normal) == .archiveSelected, "e archives")
        try expect(
            action(set, chord("p"), .normal) == .toggleProjectScope, "p scopes to the project")
        try expect(
            action(set, chord("a", shift: true), .normal) == nil,
            "A is spent on a shortcut the machine-wide chord already covers, and the composer's "
                + "vim wants it")
        try expect(action(set, chord("x"), .normal) == .deleteSelected, "x deletes")
        try expect(action(set, chord(" "), .normal) == .toggleMarked, "space marks a chat")
        try expect(
            action(set, chord("a", control: true), .normal) == .toggleMarkAll,
            "ctrl+a marks every chat shown")
        try expect(
            action(set, KeyChord.canonical(keyval: Keymap.enter, state: 0), .normal)
                == .openSelected, "enter opens")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.keypadEnter, state: Keymap.control),
                .insert) == .send, "keypad enter folds into enter for ^⏎")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.shiftTab, state: Keymap.shift), .normal)
                == .cycleBackward, "shift+tab cycles backwards")

        try expect(pends(set, chord("g"), .normal), "g waits for a second key")
        let g = chord("g")
        try expect(
            action(set, g, .normal, pending: [g].compactMap { $0 }) == .scrollTop,
            "g g reaches the top")
        try expect(pends(set, chord("y"), .normal), "y waits for a second key")
        let y = chord("y")
        try expect(
            action(set, y, .normal, pending: [y].compactMap { $0 }) == .copySessionID,
            "y y copies the session id")
        try expect(
            action(set, chord("p"), .normal, pending: [y].compactMap { $0 })
                == .copyProjectPath, "y p copies the project path")

        try expect(action(set, chord("f"), .normal) == .findInConversation, "f finds")
        try expect(action(set, chord("f"), .insert) == nil, "bare f types in insert")
        try expect(
            action(set, chord("f", control: true), .insert) == .findInConversation,
            "^f finds while typing")
        try expect(
            action(set, chord("b", control: true), .terminal) == nil,
            "the terminal keeps ^b for the shell")
        try expect(
            action(set, chord("f", control: true), .terminal) == nil,
            "the terminal keeps ^f for the shell")
        try expect(
            action(set, chord("b", control: true, shift: true), .terminal) == .toggleSidebar,
            "^⇧B still toggles the chat list over a shell")
        try expect(
            action(set, KeyChord.canonical(keyval: 0xFFAD, state: Keymap.control), .terminal)
                == .zoomOut, "keypad minus folds into ^- zoom")

        try expect(
            action(set, chord("y"), .normal, awaiting: true) == .allowOnce,
            "y answers a waiting approval")
        try expect(
            action(set, chord("n"), .normal, awaiting: true) == .deny,
            "n denies a waiting approval")
        try expect(
            action(set, chord("n"), .normal) == .newChat,
            "n means a new chat once nothing waits")

        let rebound = ShortcutSet.build(overrides: ["chat.new": ["c"]])
        try expect(action(rebound, chord("c"), .normal) == .newChat, "a rebind lands")
        try expect(action(rebound, chord("n"), .normal) == nil, "a rebind frees the old key")
        let unbound = ShortcutSet.build(overrides: ["chat.new": []])
        try expect(
            action(unbound, chord("n"), .normal) == nil && unbound.issues.isEmpty,
            "an empty rebind unbinds cleanly")
        try expect(
            !ShortcutSet.build(overrides: ["chat.new": ["bogus+key"]]).issues.isEmpty,
            "an unreadable rebind is reported")
        try expect(
            !ShortcutSet.build(overrides: ["chat.filter": ["g"]]).issues.isEmpty,
            "shadowing a sequence's first key is reported")
        try expect(
            ShortcutSet.build(overrides: [:]).helpSections().contains {
                $0.rows.contains { $0.keys.contains("^⏎") }
            }, "the cheatsheet lists effective keys")
        return checks
    }

    #if !TAILSCODE_MAS
        /// A slot is a pane, so what it holds has to read back the same after a restart, and the keys
        /// it answers have to be the keys the other desktop answers.
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
            try expect(
                VideoTarget.search("two words").extractionArgument == "ytsearch1:two words",
                "a search is extracted as a search")

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
                layout: layout, sessions: [:],
                videos: [second.raw: VideoTarget.twitch("kamet0").address])
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

        /// The board an empty video slot draws, checked as the facts a row is rendered from: the badge
        /// it wears, the picture it offers, the star it earns, and the two rows — an expander and a
        /// note — that carry no picture at all. The keys matter as much as the rows here, because the
        /// same keystrokes are typing into the box above the board: a letter must never be the board's.
        static func checkWatchBoard() throws -> Int {
            var checks = 0
            func expect(_ condition: Bool, _ label: String) throws {
                guard condition else { throw SelfTestFailure("watch board: \(label)") }
                checks += 1
            }

            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let now = start.addingTimeInterval(3600)
            let caedrel = MediaChannel(source: .twitch, handle: "caedrel", name: "Caedrel")
            let quiet = MediaChannel(source: .twitch, handle: "quietone", name: "Quiet One")
            let live = MediaEntry(
                channel: caedrel,
                stream: MediaStream(
                    title: "LCK", category: "League of Legends", viewers: 36579, startedAt: start,
                    thumbnail: "https://example.dev/preview.jpg", tags: ["English"]),
                checkedAt: now)

            var board = WatchChooser(watchlist: [caedrel, quiet], followed: [caedrel])
            try expect(!board.heading.isEmpty, "the board names what it is showing")
            try expect(!board.hint.isEmpty, "and says which keys move it")
            try expect(
                board.notice == VideoNotice.splitCost, "and carries what a stream costs the grid")
            board.filled(live: MediaFeed(entries: [live]))
            board.tick(now)
            guard let onAir = board.sections.first, let row = onAir.rows.first else {
                throw SelfTestFailure("watch board: the board drew no rows")
            }
            try expect(row.title == "Caedrel", "the row is the channel, named as a person would")
            try expect(row.badge == .live("37K"), "a live row wears its audience")
            try expect(row.detail == "LCK", "the line under the name is what is on")
            try expect(
                row.note?.hasPrefix("League of Legends") == true,
                "and the dimmer line under that is the context, without the count said twice")
            try expect(row.thumbnail != nil, "a live row offers a picture to draw")
            try expect(row.isFollowed, "a followed channel earns its star")
            try expect(board.focused?.id == row.id, "the cursor starts on the first row it can press")

            guard board.sections.count > 1, let offAir = board.sections.last,
                let quietRow = offAir.rows.first
            else { throw SelfTestFailure("watch board: the offline half of the list vanished") }
            board.focus(section: offAir.id, offset: 0)
            try expect(
                board.focused?.id == quietRow.id,
                "a press maps through its section and its offset inside it")
            try expect(quietRow.badge == .offline(Localized.text("offline")), "an offline row says so")

            let popular = (0..<6).map { index in
                MediaEntry(
                    channel: MediaChannel(source: .twitch, handle: "t\(index)", name: "Top \(index)"),
                    stream: MediaStream(title: "on", viewers: 1000 - index))
            }
            board.filled(top: MediaFeed(entries: popular))
            let expanders = board.rows.filter { row in
                if case .expander = row.kind { return true }
                return false
            }
            guard let expander = expanders.first else {
                throw SelfTestFailure("watch board: a compacted section offered no expander")
            }
            try expect(expander.thumbnail == nil, "a row that stands for a list carries no picture")
            try expect(expander.badge == nil, "and no badge")
            try expect(expander.isActivatable, "but it is still a row to press")

            var failing = WatchChooser(watchlist: [caedrel], followed: [])
            failing.filled(live: MediaFeed(failures: ["Twitch did not answer"]))
            guard let note = failing.rows.first(where: { $0.kind == .note }) else {
                throw SelfTestFailure("watch board: a source that failed said nothing")
            }
            try expect(!note.isActivatable, "a note is text the board owed, not something to press")
            try expect(failing.focused?.id != note.id, "so the cursor never stops on one")

            var typed = WatchChooser(watchlist: [caedrel], followed: [])
            typed.type("kamet0")
            try expect(typed.rows.first?.isPrimary == true, "what was typed leads its own answer")
            try expect(
                typed.rows.first?.kind == .typed(.twitch("kamet0")),
                "and means exactly what the box has always meant")
            try expect(typed.pendingSearch == "kamet0", "the sources are owed a question")

            guard let letter = KeyChord.canonical(keyval: 0x61, state: 0),
                let down = KeyChord.canonical(keyval: Keymap.down, state: 0),
                let follow = KeyChord.canonical(keyval: 0x66, state: KeyChord.controlMask)
            else { throw SelfTestFailure("watch board: a keystroke would not resolve") }
            try expect(
                WatchChooser.command(for: letter) == nil, "a letter belongs to the box being typed in")
            try expect(WatchChooser.command(for: down) == .down, "the arrows belong to the board")
            try expect(WatchChooser.command(for: follow) == .follow, "ctrl+f follows what is focused")

            let first = "https://example.dev/one.jpg"
            let second = "https://example.dev/two.jpg"
            try expect(
                MediaThumbDisk.identity(for: first) != MediaThumbDisk.identity(for: second),
                "two pictures never share one cache slot")
            let bytes = Data((0..<256).map { UInt8($0 % 251) })
            MediaThumbDisk.save(bytes, for: first)
            try expect(MediaThumbDisk.load(first) == bytes, "a thumbnail round-trips on disk")
            try expect(MediaThumbDisk.load(second) == nil, "an unfetched picture loads nothing")
            return checks
        }

        /// The settings section and the sign-in sheet, checked as the facts they are drawn from: two
        /// rows in a stable order, each one a statement before it is a control, a Twitch that needs
        /// nothing registered, a YouTube that says at length what it needs when this build was given no
        /// application for it — and a flow whose heading, code and one button change together as it
        /// moves, because the sheet renders nothing else.
        static func checkWatchAccounts() throws -> Int {
            var checks = 0
            func expect(_ condition: Bool, _ label: String) throws {
                guard condition else { throw SelfTestFailure("watch accounts: \(label)") }
                checks += 1
            }

            try expect(
                MediaAccounts.isInstalled,
                "the Keychain is handed over before anything reads an account")
            try expect(
                !WatchAccounts.heading.isEmpty && !WatchAccounts.description.isEmpty,
                "the section says what signing in is for")
            try expect(!WatchAccounts.summary.isEmpty, "and states in one line who is signed in")

            let rows = WatchAccounts.rows()
            try expect(rows.count == MediaSource.allCases.count, "one row per site")
            try expect(rows.map(\.source) == [.twitch, .youtube], "in the order the sites are listed")
            try expect(
                rows.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.actionTitle.isEmpty },
                "each row names itself, states itself, and titles its own button")

            guard let twitch = rows.first(where: { $0.source == .twitch }),
                let youtube = rows.first(where: { $0.source == .youtube })
            else { throw SelfTestFailure("watch accounts: a site drew no row") }
            try expect(
                MediaAccounts.authority(for: .twitch).isConfigured,
                "Twitch's device flow needs no application registered")
            try expect(twitch.note == nil, "so its row owes no explanation under it")
            try expect(
                twitch.isSignedIn || twitch.action == .signIn(.twitch),
                "and a signed-out Twitch offers the one button that fixes that")
            if MediaAccounts.authority(for: .youtube).isConfigured {
                try expect(youtube.note == nil, "a configured YouTube explains nothing either")
            } else {
                try expect(
                    youtube.action == .configure(.youtube),
                    "an unregistered YouTube says what it needs rather than offering a button that fails")
                try expect(youtube.note?.isEmpty == false, "and says it at length")
                try expect(
                    youtube.note?.contains("TAILSCODE_YOUTUBE_CLIENT_ID") == true,
                    "naming the variables the alert's Copy button hands over")
            }

            var flow = WatchSignIn(source: .twitch)
            try expect(flow.step == .starting && !flow.isFinished, "a flow starts by asking")
            try expect(flow.code == nil && flow.link == nil, "with no code to print and nothing to open")
            try expect(flow.instruction?.isEmpty == false, "but says what it is doing meanwhile")
            let prompt = DevicePrompt(
                deviceCode: "device", userCode: "WXYZ-1234",
                verificationURL: "https://www.twitch.tv/activate?device-code=WXYZ-1234", interval: 5,
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
            flow.began(prompt)
            try expect(flow.code == "WXYZ-1234", "then prints the code the site will ask for")
            try expect(flow.link == prompt.verificationURL, "and opens where it is confirmed")
            try expect(
                flow.actionTitle == Localized.text("Open %@", MediaSource.twitch.label),
                "which is what the one button is titled")
            flow.granted(MediaAccount(source: .twitch, name: "Marcus", handle: "marcus"))
            try expect(flow.isFinished, "granting finishes it")
            try expect(
                flow.heading == Localized.text("Signed in as %@", "Marcus"), "and names the account")
            try expect(flow.code == nil, "taking the code back down")
            try expect(
                flow.actionTitle == Localized.text("Done"), "and leaving one button, which closes")
            var refused = WatchSignIn(source: .youtube)
            refused.failed("Google would not answer")
            try expect(refused.detail == "Google would not answer", "a failure states its own reason")
            try expect(refused.isFinished, "with no polling left running behind it")
            try expect(
                refused.actionTitle == Localized.text("Try again"), "and one button that asks again")

            let sheet = WatchSignInSheet(source: .twitch, onFinished: {})
            guard let content = sheet.contentView else {
                throw SelfTestFailure("watch accounts: the sign-in sheet draws a window")
            }
            try expect(
                systemIndicator(in: content) == nil,
                "and waits without an indicator AppKit spins at a rate this app cannot read")
            guard let waiting = agentBadge(in: content) else {
                throw SelfTestFailure("watch accounts: the sheet wears a mark while it waits")
            }
            try expect(
                waiting.icon == .openWork,
                "it wears the same open-work mark a transcript wears while a site has not answered")
            try expect(
                waiting.icon?.motion == .turning,
                "which turns at the one tempo everything else in this window keeps")
            return checks
        }
    #endif
}
