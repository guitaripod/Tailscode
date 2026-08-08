import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `tailscode --selftest` drives the whole chain with no window: tailnet reading, profile and
/// secret stores, every configured server's health and session list, then the newest session's
/// stream until a transcript lands.
///
/// This is how the Linux client is validated in a build loop — and on a headless box it is the
/// only way, since there is no display to render into and no Secret Service to answer.
public enum SelfTest {
    public static var isRequested: Bool { Arguments.contains("--selftest") }

    /// The pass over the servers keeps one loaded conversation aside as the two-observer subject:
    /// a conversation with words in it makes the stronger subject, and an empty one only stands in
    /// when every server's newest chat is empty.
    public static func run() async -> Never {
        startWatchdog()
        var failures = 0

        let tailnet = TailnetStatusLinux.read()
        report("tailnet: \(tailnet.address ?? "no address") · \(tailnet.peers.count) peers")

        do {
            try await checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVim()
            report("vim: \(checks) commands behave")
        } catch {
            report("vim: \(error)")
            failures += 1
        }

        do {
            let checks = try checkMarkup()
            report("markup: \(checks) shapes render")
        } catch {
            report("markup: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSyntax()
            report("syntax: \(checks) claims hold — code colours and never becomes markup")
        } catch {
            report("syntax: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCascade()
            report("cascade: \(checks) prefixes reveal cleanly")
        } catch {
            report("cascade: \(error)")
            failures += 1
        }

        do {
            let checks = try checkInterruption()
            report("interruption: \(checks) marker shapes")
        } catch {
            report("interruption: \(error)")
            failures += 1
        }

        do {
            let checks = try checkWorkflowCard()
            report("workflow card: \(checks) run shapes read correctly")
        } catch {
            report("workflow card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkStatusBand()
            report("status band: \(checks) states say the right thing")
        } catch {
            report("status band: \(error)")
            failures += 1
        }

        do {
            let checks = try checkGit()
            report("git: \(checks) claims hold — the tree reads, the patch colours, the classes exist")
        } catch {
            report("git: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSpend()
            report("spend: \(checks) numbers hold, and the panel can be built")
        } catch {
            report("spend: \(error)")
            failures += 1
        }

        do {
            try checkActivityMotion()
            report("activity: \(ActivityKind.everyState.count) states move as they mean")
        } catch {
            report("activity: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCompletion()
            report("completion: \(checks) queries rank and gate")
        } catch {
            report("completion: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShortcuts()
            report("shortcuts: \(checks) keys resolve, rebind and stay conflict-free")
        } catch {
            report("shortcuts: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPaneDrop()
            report("pane drop: \(checks) drags land where they are aimed")
        } catch {
            report("pane drop: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVideoSlot()
            report("video slot: \(checks) answers, player \(SelfTest.playerState)")
        } catch {
            report("video slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrowserSlot()
            report("browser slot: \(checks) answers, engine \(SelfTest.engineState)")
        } catch {
            report("browser slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkParity()
            report("parity: \(checks) capabilities answered")
        } catch {
            report("parity: \(error)")
            failures += 1
        }

        let chooserFailures = PaneChooserCheck.run()
        if chooserFailures.isEmpty {
            report("pane chooser: servers, chats and keys behave")
        } else {
            report("pane chooser: \(chooserFailures.joined(separator: " · "))")
            failures += 1
        }

        let boardFailures = WatchChooserCheck.run()
        if boardFailures.isEmpty {
            report("watch board: sections compact, sources report, keys leave the box alone")
        } else {
            report("watch board: \(boardFailures.joined(separator: " · "))")
            failures += 1
        }

        let accountFailures = WatchAccountsCheck.run()
        if accountFailures.isEmpty {
            report("watch accounts: rows state a fact first, and the flow shows one code")
        } else {
            report("watch accounts: \(accountFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkWatchAccounts()
            report("watch sign-in: \(checks) states, tokens kept where secrets go")
        } catch {
            report("watch sign-in: \(error)")
            failures += 1
        }

        do {
            let checks = try checkWatchDirectory()
            report("watch directory: \(checks) shapes read into rows")
        } catch {
            report("watch directory: \(error)")
            failures += 1
        }

        let modelFailures = ModelChooserCheck.run()
        if modelFailures.isEmpty {
            report("model chooser: providers fold, ranking holds, keys behave")
        } else {
            report("model chooser: \(modelFailures.joined(separator: " · "))")
            failures += 1
        }

        let newChatFailures = NewChatChooserCheck.run()
        if newChatFailures.isEmpty {
            report("new chat: folders rank, servers cycle, both modes behave")
        } else {
            report("new chat: \(newChatFailures.joined(separator: " · "))")
            failures += 1
        }

        let selectionFailures = ChatSelectionCheck.run()
        if selectionFailures.isEmpty {
            report("chat selection: marks key on the server, prune, and say what they did")
        } else {
            report("chat selection: \(selectionFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            try checkSettingsFile()
            report("settings file: survives a reinstall")
        } catch {
            report("settings file: \(error)")
            failures += 1
        }

        let radarFailures = checkRadar()
        if radarFailures.isEmpty {
            report("tailnet radar: the dial laps, lights and settles")
        } else {
            report("tailnet radar: \(radarFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkPalettes()
            report("themes: \(checks) themes read in both appearances")
        } catch {
            report("themes: \(error)")
            failures += 1
        }

        do {
            try checkImageCache()
            report("image cache: pictures round-trip and stay keyed to their file")
        } catch {
            report("image cache: \(error)")
            failures += 1
        }

        await ServerDirectory.shared.reload()
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        var warmed: (backend: any CodingAgentBackend, session: AgentSession)?
        var warmedIsEmpty = true
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report("\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = Self.observable(in: sessions) else { continue }
                let state = try await firstState(of: newest, on: backend)
                report("  \(newest.title.prefix(50)): \(state.messages.count) messages")
                guard state.hasLoadedTranscript else {
                    report("  transcript never loaded")
                    failures += 1
                    continue
                }
                if warmed == nil || (warmedIsEmpty && !state.messages.isEmpty) {
                    warmed = (backend, newest)
                    warmedIsEmpty = state.messages.isEmpty
                }
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }

        let (entries, unreachable) = await ServerDirectory.shared.entries()
        report("list: \(entries.count) entries, \(unreachable.count) unreachable")

        #if !HAS_VTE
            let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
            if shellOutput.contains("tailscode-shell-ok") {
                report("shell: ok (one command at a time; install vte4 for a full terminal)")
            } else {
                report("shell: no output")
                failures += 1
            }
        #else
            report("shell: vte4 terminal")
        #endif

        if let warmed {
            do {
                let count = try await checkTwoObservers(
                    backend: warmed.backend, session: warmed.session)
                report("two observers: agree on \(count) messages")
            } catch {
                report("two observers: \(error)")
                failures += 1
            }
        } else {
            report("two observers: no loaded session to observe")
            failures += 1
        }

        if ProcessInfo.processInfo.environment["TAILSCODE_SELFTEST_SEND"] == "1" {
            do {
                try await checkRoundTrip(profiles)
                report("send: ok")
            } catch {
                report("send: \(error)")
                failures += 1
            }
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// The stores are exercised against a throwaway directory rather than the real one: a self-test
    /// that rewrites the user's server list is not a test.
    private static func checkStores() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let secrets = FileSecretStore(url: scratch.appendingPathComponent("secrets.json"))
        try secrets.setValue("hunter2", for: "probe")
        guard try secrets.value(for: "probe") == "hunter2" else {
            throw SelfTestFailure("secret did not round-trip")
        }
        try secrets.removeValue(for: "probe")
        guard try secrets.value(for: "probe") == nil else {
            throw SelfTestFailure("secret survived removal")
        }

        let store = LinuxProfileStore(
            secrets: secrets, url: scratch.appendingPathComponent("profiles.json"))
        let profile = ConnectionProfile(
            id: "probe", name: "probe", backend: .claudeCode,
            baseURL: URL(string: "http://127.0.0.1:4098")!, username: "claude")
        try store.save(profile, password: "pw")
        guard try store.profiles().count == 1, try store.password(for: "probe") == "pw" else {
            throw SelfTestFailure("profile did not round-trip")
        }
        try store.delete(id: "probe")
        guard try store.profiles().isEmpty else {
            throw SelfTestFailure("profile survived deletion")
        }
    }

    /// The composer's vim mode, driven the way a person drives it: a starting buffer, a string of
    /// keys, and the text that must come out. It runs in the same `--selftest` as everything else
    /// because a headless box can check an editor perfectly well, and an editor that quietly eats
    /// the wrong word is worse than no editor.
    private static func checkCompletion() throws -> Int {
        let commands = ["steam-add-game", "usage", "update-zeroclaw", "flyr", "compact"].map {
            AgentCommand(name: $0, details: "", source: .skill)
        }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("completion case failed: \(label)") }
            checks += 1
        }
        try expect(SlashCompletion.query(in: "/st") == "st", "query reads the word")
        try expect(SlashCompletion.query(in: "/") == "", "bare slash asks for everything")
        try expect(SlashCompletion.query(in: "/goal clear") == nil, "arguments end the query")
        try expect(SlashCompletion.query(in: "plain text") == nil, "prose is not a query")
        try expect(
            SlashCompletion.matches(commands, query: "u").map(\.name) == [
                "update-zeroclaw", "usage",
            ], "prefix matches sort alphabetically")
        try expect(
            SlashCompletion.matches(commands, query: "add").map(\.name) == ["steam-add-game"],
            "a match inside the name still surfaces")
        try expect(
            SlashCompletion.matches(commands, query: "").first?.name == "compact",
            "everything, alphabetically, for a bare slash")
        try expect(
            SlashCompletion.matches(commands, query: "zzz").isEmpty, "no match means no list")
        return checks
    }

    /// The whole keyboard system without a window: the shipped table resolves, canonicalisation
    /// folds keypad and shifted keys, sequences pend and land, the terminal keeps the shell's
    /// chords, approvals win only while one waits, and the rebinding file's grammar applies,
    /// unbinds and reports nonsense.
    private static func checkShortcuts() throws -> Int {
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
        try expect(
            set.issues.isEmpty, "shipped defaults carry no conflicts: \(set.issues)")

        let parsed = KeySpec.parse("ctrl+shift+h")
        try expect(
            parsed?.chords == [chord("h", control: true, shift: true)].compactMap { $0 },
            "ctrl+shift+h parses to one canonical chord")
        try expect(parsed?.chords.first?.display == "^H", "^H displays as itself")
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
        try expect(action(set, chord("x"), .normal) == .deleteSelected, "x deletes")
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
            action(set, chord("j", control: true, shift: true), .terminal)
                == .focus(.terminal), "^⇧J focuses panes from the terminal")
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

    /// A chat dragged onto a pane, checked as arithmetic: the payload survives the trip, the
    /// middle of a pane fills it, each edge claims its own side, a pane too narrow to halve only
    /// ever fills, and the highlight covers exactly the half the split will hand over.
    private static func checkPaneDrop() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pane drop: \(label)") }
            checks += 1
        }

        let payload = PaneDragPayload(profileID: "srv-1", sessionID: "ses-9")
        try expect(PaneDragPayload.decode(payload.encoded) == payload, "a payload round-trips")
        try expect(PaneDragPayload.decode("ses-9") == nil, "a bare word is not a chat")
        try expect(
            PaneDragPayload.decode("tailscode-chat\tsrv-1") == nil, "a truncated payload refuses")
        try expect(
            !payload.encoded.contains(" "), "the payload carries no spaces to be split on")

        let wide = (width: 1200.0, height: 800.0)
        func zone(_ x: Double, _ y: Double, _ size: (width: Double, height: Double) = wide)
            -> PaneDropZone
        {
            PaneDropTarget.zone(x: x, y: y, width: size.width, height: size.height)
        }
        try expect(zone(600, 400) == .fill, "the middle opens here")
        try expect(zone(20, 400) == .split(.left), "the left edge splits left")
        try expect(zone(1180, 400) == .split(.right), "the right edge splits right")
        try expect(zone(600, 20) == .split(.top), "the top edge splits above")
        try expect(zone(600, 780) == .split(.bottom), "the bottom edge splits below")
        try expect(zone(10, 10) == .split(.left), "a corner resolves to one edge")
        try expect(
            zone(600, 400, (width: 500, height: 800)) == .fill,
            "a pane with no room to halve only fills")
        try expect(
            zone(10, 400, (width: 500, height: 800)) == .fill,
            "its edges do not offer a split either")
        try expect(
            zone(600, 10, (width: 500, height: 800)) == .split(.top),
            "the axis with room still splits")
        try expect(zone(.nan, 400) == .fill, "a pointer nowhere fills")
        try expect(zone(600, 400, (width: 0, height: 0)) == .fill, "an unallocated pane fills")

        try expect(PaneDropEdge.left.axis == .horizontal, "left halves side by side")
        try expect(PaneDropEdge.bottom.axis == .vertical, "bottom stacks")
        try expect(
            PaneDropEdge.left.placesArrivalFirst && PaneDropEdge.top.placesArrivalFirst,
            "left and top hand the arrival the first half")
        try expect(
            !PaneDropEdge.right.placesArrivalFirst && !PaneDropEdge.bottom.placesArrivalFirst,
            "right and bottom hand it the second")

        let highlight = PaneDropTarget.highlight(
            for: .split(.right), width: 1200, height: 800)
        try expect(
            highlight == SplitRect(x: 600, y: 0, width: 600, height: 800),
            "the highlight covers the half it promises")
        try expect(
            PaneDropTarget.highlight(for: .fill, width: 1200, height: 800)
                == SplitRect(x: 0, y: 0, width: 1200, height: 800),
            "filling highlights the whole pane")
        try expect(
            PaneDropZone.split(.left).caption("port the renderer").contains("port the renderer"),
            "the caption names the chat")
        try expect(
            PaneDropZone.fill.caption(nil) == PaneDropZone.fill.verb,
            "an unnamed chat still says what will happen")

        var layout = SplitLayout()
        let original = layout.focusedPane
        guard
            let arrival = layout.split(original, axis: .horizontal, placingNewFirst: true)
        else { throw SelfTestFailure("pane drop: the tree refused to split") }
        let frames = layout.frames()
        guard let arrived = frames[arrival], let stayed = frames[original] else {
            throw SelfTestFailure("pane drop: the split lost a pane")
        }
        try expect(arrived.x < stayed.x, "a drop on the left edge lands on the left")
        try expect(layout.focusedPane == arrival, "the arriving pane takes the focus")
        try expect(layout.isValid, "the tree stays well formed")
        guard let second = layout.split(arrival, axis: .vertical) else {
            throw SelfTestFailure("pane drop: the tree refused a second split")
        }
        let stacked = layout.frames()
        try expect(
            (stacked[second]?.y ?? 0) > (stacked[arrival]?.y ?? 0),
            "the keyboard's own split still opens second")
        return checks
    }

    /// Whether this build can actually put a stream in a pane, said plainly: a machine without
    /// libmpv still runs the app, and the slot has to explain itself rather than pretend.
    static var engineState: String {
        tailscode_web_available() != 0 ? "WebKitGTK" : "missing WebKitGTK"
    }

    static var playerState: String {
        tailscode_mpv_available() != 0 ? "available" : "missing libmpv"
    }

    /// What the board owes its clients, proved on the payloads the two sources actually send
    /// rather than on the network: the shapes are pinned here so a site changing one is a failing
    /// selftest instead of a pane that quietly shows nothing.
    /// That an account survives being written and read back through the same store a server
    /// password uses, and that a signed-out box is signed out rather than half-signed-in. Runs
    /// against a throwaway file so the box's own accounts are never touched.
    private static func checkWatchAccounts() throws -> Int {
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

    private static func checkWatchDirectory() throws -> Int {
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

    private static func checkVideoSlot() throws -> Int {
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
    private static func checkBrowserSlot() throws -> Int {
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

    private static func checkParity() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("parity: \(label)") }
            checks += 1
        }
        try expect(
            CapabilityRegistry.missingDefinitions.isEmpty, "every capability has a spec")
        for capability in AppCapability.allCases {
            switch ParityManifest.evidence(for: capability) {
            case .implemented(let anchor):
                try expect(!anchor.isEmpty, "\(capability.rawValue) names its anchor")
            case .partial(let anchor, let missing):
                try expect(
                    !anchor.isEmpty && !missing.isEmpty,
                    "\(capability.rawValue) names its anchor and its debt")
            case .gap(let reason), .notApplicable(let reason):
                try expect(!reason.isEmpty, "\(capability.rawValue) states its reason")
            }
        }
        return checks
    }

    private static func checkVim() throws -> Int {
        let cases: [(text: String, keys: String, expected: String, label: String)] = [
            ("hello world", "dw", "world", "dw"),
            ("hello world", "wdw", "hello ", "wdw"),
            ("hello world", "x", "ello world", "x"),
            ("hello world", "wciwthere", "hello there", "ciw"),
            ("say \"a thing\" now", "f\"ci\"other", "say \"other\" now", "ci\""),
            ("call(one, two)", "f(di(", "call()", "di("),
            ("alpha\nbeta\ngamma", "jdd", "alpha\ngamma", "dd"),
            ("alpha\nbeta", "yyp", "alpha\nalpha\nbeta", "yy then p"),
            ("alpha beta", "vey", "alpha beta", "visual yank leaves text"),
            ("alpha beta", "vlld", "ha beta", "visual delete"),
            ("alpha", "A!", "alpha!", "A"),
            ("alpha", "ohi", "alpha\nhi", "o"),
            ("alpha", "Ihi ", "hi alpha", "I"),
            ("one two three", "d2w", "three", "count with operator"),
            ("indent", ">>", "    indent", ">>"),
            ("    indent", "<<", "indent", "<<"),
            ("alpha", "xu", "alpha", "undo"),
            ("alpha beta", "wD", "alpha ", "D"),
            ("alpha", "~", "Alpha", "~"),
            ("one\ntwo", "J", "one two", "J"),
            ("abc", "ra", "abc", "r same character"),
            ("abc", "rz", "zbc", "r"),
            ("first\nsecond\nthird", "Gdd", "first\nsecond\n", "G then dd"),
            ("hello", "$x", "hell", "$x"),
            ("alpha bravo charlie", "2dw", "charlie", "count before operator"),
            ("one, two", "dt,", ", two", "dt"),
            ("one, two", "df,", " two", "df"),
            ("alpha bravo", "wyiwP", "alpha bravobravo", "yiw then P"),
            ("keep {this} out", "f{da{", "keep  out", "da{"),
            ("first\nsecond", "Vd", "second", "visual-line delete"),
            ("first\nsecond", "jVd", "first\n", "visual-line delete of last line"),
            ("alpha", "veU", "ALPHA", "visual gU shortcut via U"),
            ("a b c d", "2x", "b c d", "count with x"),
            ("hello", "ggx", "ello", "gg"),
            ("word here", "ebx", "ord here", "b"),
        ]
        var checked = 0
        for testCase in cases {
            let engine = VimEngine()
            engine.reset(to: testCase.text, cursor: 0, mode: .normal)
            var text = testCase.text
            var cursor = 0
            for character in testCase.keys {
                let outcome = engine.handle(VimKey(character: character), text: text, cursor: cursor)
                if case .passThrough = outcome {
                    var characters = Array(text)
                    characters.insert(character, at: min(cursor, characters.count))
                    text = String(characters)
                    cursor += 1
                    engine.syncFromEditor(text: text, cursor: cursor)
                } else {
                    text = engine.document.text
                    cursor = engine.document.cursor
                }
            }
            guard text == testCase.expected else {
                throw SelfTestFailure(
                    "\(testCase.label): expected \(testCase.expected.debugDescription), got \(text.debugDescription)")
            }
            checked += 1
        }

        let engine = VimEngine()
        engine.reset(to: "alpha beta", cursor: 0, mode: .normal)
        let midCommand: [(Character, Bool, String)] = [
            ("d", true, "an operator waits"),
            ("i", true, "a text object waits"),
            ("w", false, "diw completes"),
            ("3", true, "a count waits"),
            ("x", false, "the count is spent"),
            ("f", true, "f waits for its key"),
            ("z", false, "f lands"),
            ("g", true, "g waits for its key"),
            ("g", false, "gg completes"),
        ]
        for (character, expected, label) in midCommand {
            _ = engine.handle(
                VimKey(character: character), text: engine.document.text,
                cursor: engine.document.cursor)
            guard engine.awaitsMore == expected else {
                throw SelfTestFailure("awaitsMore: \(label)")
            }
            checked += 1
        }
        checked += try checkVimRouting()
        return checked
    }

    /// Who owns a keystroke in the composer: the shortcut table, or vim. The two rules worth
    /// pinning are the ones that were wrong — the second key of `ctrl+w v` is a split and not
    /// visual mode, and `?` opens the cheatsheet from visual mode because vim binds no `?`.
    private static func checkVimRouting() throws -> Int {
        let cases: [(mode: VimMode, key: VimKey, plain: Bool, pending: Bool, claims: Bool, label: String)] = [
            (.normal, VimKey(character: "v"), true, true, false, "ctrl+w v splits"),
            (.normal, VimKey(character: "o"), true, true, false, "ctrl+w o zooms"),
            (.normal, VimKey(character: "v"), true, false, true, "v alone enters visual"),
            (.normal, VimKey(character: "i"), true, false, true, "i alone enters insert"),
            (.normal, VimKey(character: "j"), true, false, false, "j scrolls the transcript"),
            (.normal, VimKey(character: "?"), true, false, false, "? opens the cheatsheet"),
            (.visual, VimKey(character: "?"), true, false, false, "? from visual too"),
            (.visual, VimKey(character: "d"), true, false, true, "d still deletes the selection"),
            (.visual, VimKey(character: "j"), true, false, true, "j still moves in visual"),
            (.visualLine, VimKey(character: "y"), true, false, true, "y still yanks the lines"),
            (.visual, VimKey(character: "w", control: true), false, false, false, "ctrl+w from visual"),
            (.visual, VimKey(isEscape: true), true, false, true, "escape leaves visual"),
        ]
        for testCase in cases {
            let engine = VimEngine()
            engine.reset(to: "alpha beta", cursor: 0, mode: testCase.mode)
            let claims = engine.claims(
                testCase.key, plain: testCase.plain, chordPending: testCase.pending)
            guard claims == testCase.claims else {
                throw SelfTestFailure("vim routing: \(testCase.label)")
            }
        }
        return cases.count
    }

    /// The transcript's markdown, checked as text rather than as pixels: a mis-escaped `<` is a
    /// Pango parse error that blanks a whole message, which is the failure worth catching early.
    /// The Escape seam: the CLI's `[Request interrupted …]` user lines become markers, the text
    /// the person actually typed survives, and an ordinary prompt passes through untouched.
    private static func checkInterruption() throws -> Int {
        let cases: [(input: String, interrupted: Bool, remainder: String, label: String)] = [
            ("[Request interrupted by user]", true, "", "bare escape"),
            ("[Request interrupted by user for tool use]", true, "", "tool rejection"),
            (
                "[Request interrupted by user for tool use] Continue from where you left off.",
                true, "Continue from where you left off.", "rejection with a prompt"
            ),
            ("deploy the fix", false, "deploy the fix", "an ordinary prompt"),
            ("[Request interrupted", true, "", "truncated marker"),
        ]
        for (input, interrupted, remainder, label) in cases {
            let result = TranscriptRow.strippedInterruption(input)
            guard result.interrupted == interrupted, result.remainder == remainder else {
                throw SelfTestFailure("interruption case failed: \(label) → \(result)")
            }
        }
        let message = ChatMessage(
            id: "m", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "p",
                    kind: .text("[Request interrupted by user for tool use] keep going"))
            ],
            createdAt: Date())
        let rows = TranscriptRow.rows(for: message)
        guard rows.count == 2, case .interruption = rows[0].kind,
            case .userText("keep going") = rows[1].kind
        else {
            throw SelfTestFailure("interruption rows wrong: \(rows.map(\.kind))")
        }
        return cases.count + 1
    }

    /// Pango markup is a string, so a code block is one escape away from a parse error that empties
    /// the label: a `<` in a C++ template or an `&&` in a shell line has to arrive as text. Colour
    /// is checked in the same pass, because a block that escapes correctly and colours nothing is
    /// also a failure.
    private static func checkSyntax() throws -> Int {
        var checks = 0
        let palette = MatrixTheme.palette
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("syntax case failed: \(label)") }
            checks += 1
        }
        func render(_ source: String, _ language: String?) -> String {
            PangoSyntax.render(source, language: language, palette: palette)
        }

        let keyword = SyntaxPalette.hex(.keyword, in: palette)
        let swift = render("let a = 1", "swift")
        try expect(swift.contains("<span foreground=\"\(keyword)\">let</span>"), "a keyword is a span")

        let templated = render("std::vector<int> v; a && b;", "cpp")
        try expect(templated.contains("&lt;"), "a template's opening angle is text")
        try expect(templated.contains("&gt;"), "a template's closing angle is text")
        try expect(templated.contains("&amp;&amp;"), "an ampersand pair is text")
        try expect(!templated.contains("<int>"), "no run of code becomes a tag")

        let shell = render("grep -r 'a<b' $SRC && cp ${DEST}/x .", "bash")
        try expect(shell.contains("&lt;"), "a shell comparison is text")
        try expect(
            shell.contains(SyntaxPalette.hex(.attribute, in: palette)), "a variable is marked")

        let unknown = render("<not code>", "brainfuck")
        try expect(unknown == "&lt;not code&gt;", "an unknown language is escaped and left plain")

        let comment = render("# just a note", "python")
        try expect(
            comment.contains(SyntaxPalette.hex(.comment, in: palette)), "a comment is quiet")

        guard let addedGround = SyntaxPalette.diffLineBackground(.added, in: palette),
            let removedGround = SyntaxPalette.diffLineBackground(.removed, in: palette)
        else { throw SelfTestFailure("syntax case failed: a diff line has no ground") }
        let diff = render("-old\n+new", "diff")
        try expect(diff.contains("background=\"\(addedGround)\""), "an addition wears its wash")
        try expect(diff.contains("background=\"\(removedGround)\""), "a removal wears its wash")
        try expect(
            diff.contains(SyntaxPalette.hex(.added, in: palette, on: addedGround)),
            "the marker is affirmed on its wash")

        let headed = render("+++ b/App.swift\n+let a = 1", "diff")
        try expect(
            headed.contains(SyntaxPalette.hex(.keyword, in: palette, on: addedGround)),
            "a headed diff lexes its body by the file's language")
        try expect(
            SyntaxHighlighter.displayName(for: "diff", source: "+++ b/App.swift\n+let a = 1")
                == "diff · swift",
            "a headed diff names both facts")

        let toolLine = PangoSyntax.diffLine(
            prefix: "+", body: "let a = 1", kind: .added, language: "swift", palette: palette)
        try expect(
            !toolLine.contains("background="),
            "a tool diff line leaves its wash to CSS, which paints the full row")
        try expect(
            toolLine.contains(SyntaxPalette.hex(.keyword, in: palette, on: addedGround)),
            "a tool diff line is lexed against its wash")
        try expect(parsesAsMarkup(headed), "a diff's markup is legal Pango")
        try expect(parsesAsMarkup(toolLine), "a tool diff line is legal Pango")
        let padded = render("-old\n+new is longer", "diff")
        try expect(
            padded.contains(String(repeating: " ", count: 10) + "</span>"),
            "washes are padded to one straight right edge")
        let hostile = render("+++ b/x.cpp\n+std::vector<int> v && w\n-a < b", "diff")
        try expect(parsesAsMarkup(hostile), "a hostile diff still escapes on its way in")

        try expect(SyntaxHighlighter.displayName(for: "rs") == "rust", "a fence tag is resolved")
        return checks
    }

    private static func checkMarkup() throws -> Int {
        let cases: [(input: String, contains: [String], label: String)] = [
            ("**bold** here", ["<b>bold</b>"], "bold"),
            ("some *italic* text", ["<i>italic</i>"], "italic"),
            ("a `snippet` inline", ["<tt>snippet</tt>"], "inline code"),
            ("~~gone~~", ["<s>gone</s>"], "strikethrough"),
            ("## Heading", ["weight=\"bold\"", "Heading"], "heading"),
            ("- first\n- second", ["•", "first", "second"], "bullets"),
            ("1. one", ["1.", "one"], "numbered"),
            ("> quoted", ["<i>quoted</i>"], "quote"),
            ("[docs](https://x.dev)", ["<a href=\"https://x.dev\">"], "link"),
            ("a < b && c > d", ["&lt;", "&amp;&amp;", "&gt;"], "escaping"),
            ("`<div>`", ["&lt;div&gt;"], "escaped code"),
            ("2 * 3 * 4 = 24", ["24"], "bare asterisks survive"),
        ]
        for testCase in cases {
            let rendered = PangoMarkdown.render(
                testCase.input, dim: "#777777", code: "#67e8f9", accent: "#4ade80")
            for needle in testCase.contains where !rendered.contains(needle) {
                throw SelfTestFailure(
                    "\(testCase.label): \(rendered.debugDescription) lacks \(needle.debugDescription)")
            }
        }
        let literal: [(input: String, poison: String, label: String)] = [
            ("`gtk_box_append` per row", "<i>", "underscores inside code stay code"),
            ("2 * 3 * 4 = 24", "<i>", "arithmetic never italicizes"),
            ("snake_case and more_snake here", "<i>", "intra-word underscores stay literal"),
            ("`a * b` times `c * d`", "<i>", "asterisks inside code stay code"),
        ]
        for testCase in literal {
            let rendered = PangoMarkdown.render(
                testCase.input, dim: "#777777", code: "#67e8f9", accent: "#4ade80")
            if rendered.contains(testCase.poison) {
                throw SelfTestFailure("\(testCase.label): \(rendered.debugDescription)")
            }
        }
        return cases.count + literal.count
    }

    /// The one thing a paced reveal can break that no unit test in the Kit can see: markup.
    ///
    /// Every frame of a streamed answer hands Pango a *prefix* of a markdown paragraph, and a
    /// prefix that ends inside a tag is not slightly wrong — `gtk_label_set_markup` rejects it and
    /// the row goes blank mid-sentence. So every cut the gate is willing to stop at is rendered
    /// and parsed by Pango itself, which is the only authority on whether the markup is legal.
    private static func checkCascade() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let palette = MatrixTheme.palette
        let source = """
            Here is **bold** text, some *italic*, a `snippet`, a [link](https://x.dev), \
            and ~~struck~~ words with a & b < c.

            - first bullet with `code`
            - second bullet with **weight**

            ## A heading arrives
            1. numbered with _emphasis_
            > quoted with [another](https://y.dev)
            """
        var checks = 0
        let characters = Array(source)
        for cut in 0...characters.count {
            let safe = LiveCascade.renderable(String(characters[..<cut]), sealed: false)
            let markup = PangoMarkdown.render(
                safe, dim: palette.textDim, code: palette.info, accent: palette.accent,
                cache: false)
            try expect(
                parsesAsMarkup(markup),
                "prefix \(cut) renders unbalanced markup: \(markup.debugDescription)")
            guard let rendered = CascadePainter.renderedText(of: pangoOnly(markup)) else {
                throw SelfTestFailure("prefix \(cut) has no rendered text: \(markup)")
            }
            for marker in ["**", "~~", "`"] {
                try expect(
                    !rendered.contains(marker),
                    "prefix \(cut) leaked \(marker): \(rendered.debugDescription)")
            }
            checks += 1
        }

        let sealedCut = CascadeGate.safeCut(Array("an open **marker"), at: 15, sealed: true)
        try expect(sealedCut == 15, "a sealed turn must stop holding an unmatched marker")

        let written = "The transcript should read as writing, not as a paste."
        var live = LiveCascade()
        live.focus("row", rendered: written, sealed: false, at: 0)
        try expect(live.revealed == 0, "a row born under our eyes starts empty")
        var time = 0.0
        var last = 0
        while time < 30, !live.isSettled {
            time += 1.0 / 120
            live.focus("row", rendered: written, sealed: false, at: time)
            live.advance(to: time)
            try expect(live.revealed >= last, "the reveal went backwards")
            try expect(live.revealed <= written.count, "the reveal ran past what had arrived")
            last = live.revealed
        }
        try expect(live.revealed == written.count, "the reveal never landed on its source")

        var adopted = LiveCascade()
        adopted.focus("history", rendered: source, sealed: false, at: 0)
        try expect(
            adopted.revealed == source.count,
            "a row that arrives already written is adopted rather than replayed")
        checks += 3

        let edge = CascadeTint.edge(for: palette, ultracode: false, phase: 0.5)
        try expect(edge == palette.accent, "a plain turn leads with the theme's accent")
        let rainbow = CascadeTint.edge(for: palette, ultracode: true, phase: 0.5)
        try expect(rainbow.count == 7 && rainbow.hasPrefix("#"), "ultracode leads with a colour")
        let spark = CascadeTint.spark(for: palette, edge: edge)
        let inks = CascadeTint.Inks(settled: palette.text, edge: edge, spark: spark)
        for distance in 0..<StreamCascade.span {
            let painted = CascadeTint.paint(
                StreamCascade.sample(distance: distance, phase: 0.3), inks: inks)
            try expect(painted.alpha >= 1, "a glyph must never be painted invisible")
            try expect(painted.rgb <= 0xff_ffff, "the wave produced a colour outside 24 bits")
            checks += 1
        }
        let settled = CascadeTint.paint(
            StreamCascade.sample(distance: StreamCascade.span * 4, phase: 0.3), inks: inks)
        try expect(
            settled.alpha == 65535, "a glyph the wave has passed must be fully opaque again")
        checks += 1
        return checks
    }

    /// GtkLabel resolves `<a href>` itself and never hands it to Pango, so the check makes the
    /// same substitution the label does before asking Pango whether the rest of the markup is
    /// legal — otherwise every prefix carrying a finished link would read as broken.
    private static func parsesAsMarkup(_ markup: String) -> Bool {
        let text = pangoOnly(markup)
        var failure: UnsafeMutablePointer<GError>?
        let parsed = pango_parse_markup(text, -1, 0, nil, nil, nil, &failure) != 0
        if let failure { g_error_free(failure) }
        return parsed
    }

    /// The same substitution the live row makes: GtkLabel resolves `<a href>` itself and never
    /// hands it to Pango, so the check has to dress a link the way the painter does before asking
    /// Pango whether the rest of the markup is legal.
    private static func pangoOnly(_ markup: String) -> String {
        var text = markup.replacingOccurrences(of: "</a>", with: "</span>")
        while let open = text.range(of: "<a href=\""),
            let close = text[open.upperBound...].range(of: "\">")
        {
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: "<span>")
        }
        return text
    }

    /// The durable half of the settings: written to a file, wiped from the in-memory defaults the
    /// way a reinstall wipes them, and read back. Sizes, panes, bookmarks and drafts all ride on
    /// this, so the round trip is worth asserting rather than assuming.
    private static func checkSettingsFile() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "tailscode.selftest.flag", "tailscode.selftest.number", "tailscode.selftest.text",
            "tailscode.selftest.data",
        ]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous { SettingsFile.set(value, forKey: key) }
        }

        SettingsFile.set(true, forKey: keys[0])
        SettingsFile.set(1234, forKey: keys[1])
        SettingsFile.set("kept", forKey: keys[2])
        SettingsFile.set(Data("bytes".utf8), forKey: keys[3])

        for key in keys { defaults.removeObject(forKey: key) }
        SettingsFile.load()

        guard defaults.bool(forKey: keys[0]) else { throw SelfTestFailure("a switch was lost") }
        guard defaults.integer(forKey: keys[1]) == 1234 else {
            throw SelfTestFailure("a size was lost")
        }
        guard defaults.string(forKey: keys[2]) == "kept" else {
            throw SelfTestFailure("a draft was lost")
        }
        guard defaults.data(forKey: keys[3]) == Data("bytes".utf8) else {
            throw SelfTestFailure("saved chats would be lost")
        }
    }

    /// Every theme in the catalog, in both of its appearances, checked as data: every slot a real
    /// color that clears its contrast contract *after* correction, no two signals collapsed into
    /// one, the stylesheet actually carrying it, and the markup cache returning palette-true
    /// renderings — a stale cache would paint light-mode prose in dark-mode colors, which no
    /// compiler catches. A theme that cannot be made readable fails the build rather than shipping
    /// as a pretty palette nobody can use.
    /// The scan's picture, checked as arithmetic: a machine keeps the place its name gives it, the
    /// sweep laps without a step at the seam, a blip is brightest under the arm and never dark
    /// behind it, and a finished scan reports itself settled so the clock can stop.
    private static func checkRadar() -> [String] {
        var failures: [String] = []
        let key = "macbook|claudeCode"
        let angle = TailnetRadar.angle(for: key)
        if angle != TailnetRadar.angle(for: key) { failures.append("a place that moves") }
        if TailnetRadar.angle(for: "arch|openCode") == angle { failures.append("two machines in one place") }
        let start = TailnetRadar.frame(at: 0, blips: [], scanning: true)
        let lap = TailnetRadar.frame(at: TailnetRadar.sweepPeriod, blips: [], scanning: true)
        if abs(start.sweep - lap.sweep) > 0.0001 { failures.append("a step at the seam") }
        let blip = RadarBlip(key: key, tone: .ready, bornAt: -10)
        let under = TailnetRadar.frame(
            at: angle / (2 * Double.pi) * TailnetRadar.sweepPeriod, blips: [blip], scanning: true)
        let behind = TailnetRadar.frame(
            at: (angle / (2 * Double.pi) + 0.45) * TailnetRadar.sweepPeriod, blips: [blip],
            scanning: true)
        if under.sparks.first.map({ $0.light }) ?? 0 <= behind.sparks.first.map({ $0.light }) ?? 1 {
            failures.append("the arm lights nothing")
        }
        if (behind.sparks.first?.light ?? 0) < TailnetRadar.rest - 0.0001 {
            failures.append("a blip that goes dark")
        }
        let done = TailnetRadar.frame(at: 12, blips: [blip], scanning: false)
        if !done.settled || done.sweepLight != 0 { failures.append("a finished scan that still moves") }
        if !TailnetRadar.frame(at: 12, blips: [blip], scanning: true, reducedMotion: true).settled {
            failures.append("motion a calm desk did not ask for")
        }
        return failures
    }

    private static func checkPalettes() throws -> Int {
        var ids = Set<String>()
        var names = Set<String>()
        for theme in AppTheme.all {
            guard ids.insert(theme.id).inserted else {
                throw SelfTestFailure("two themes answer to \(theme.id)")
            }
            guard names.insert(theme.name).inserted else {
                throw SelfTestFailure("two themes are called \(theme.name)")
            }
            guard !theme.blurb.isEmpty, AppTheme.named(theme.id) == theme else {
                throw SelfTestFailure("\(theme.id) does not come back from the catalog")
            }
        }
        guard AppTheme.named("no-such-theme") == AppTheme.fallback,
            AppTheme.named(nil) == AppTheme.fallback
        else { throw SelfTestFailure("an unknown theme does not fall back") }

        for theme in AppTheme.all {
            guard MatrixTheme.palette(for: theme.id, dark: true).name == theme.dark.name,
                MatrixTheme.palette(for: theme.id, dark: false).name == theme.light.name
            else { throw SelfTestFailure("choosing \(theme.id) does not reach its palettes") }
        }
        guard MatrixTheme.palette(for: "no-such-theme", dark: true).name
            == AppTheme.fallback.dark.name
        else { throw SelfTestFailure("an unknown saved theme does not fall back on screen") }

        for palette in AppTheme.all.flatMap({ [$0.dark.corrected(), $0.light.corrected()] }) {
            guard palette.isDark == ((Contrast.luminance(palette.canvas) ?? 1) < 0.18) else {
                throw SelfTestFailure("\(palette.name): its canvas disagrees with isDark")
            }
            let slots = [
                palette.canvas, palette.canvasRaised, palette.rule, palette.text,
                palette.textDim, palette.accent, palette.accentDim, palette.warn,
                palette.danger, palette.info, palette.special, palette.codeBg,
                palette.subagentBg, palette.findHit, palette.onAccent,
                palette.brandClaude, palette.brandOpencode, palette.brandGrok,
            ]
            for slot in slots {
                guard slot.hasPrefix("#"), slot.count == 7,
                    slot.dropFirst().allSatisfy(\.isHexDigit)
                else { throw SelfTestFailure("\(palette.name): \(slot) is not a color") }
            }
            for rule in palette.contrastContract {
                guard let ratio = Contrast.ratio(rule.color, on: rule.against) else {
                    throw SelfTestFailure("\(palette.name): \(rule.slot) is not measurable")
                }
                guard ratio >= rule.ratio else {
                    throw SelfTestFailure(
                        String(
                            format: "%@: %@ reads at %.2f:1, needs %.1f:1",
                            palette.name, rule.slot, ratio, rule.ratio))
                }
            }
            try checkSignalsAreDistinct(palette)
            let css = MatrixTheme.css(for: palette)
            guard css.contains(palette.canvas), css.contains(palette.accent),
                css.contains(palette.findHit), !css.contains("Optional(")
            else { throw SelfTestFailure("\(palette.name): css does not carry the palette") }
            try checkLabelSemantics(css, palette)
        }
        let sample = "**bold** and `code` and *soft*"
        func render(_ palette: Palette) -> String {
            PangoMarkdown.render(
                sample, dim: palette.textDim, code: palette.info, accent: palette.accent)
        }
        let night = AppTheme.fallback.dark.corrected()
        let day = AppTheme.fallback.light.corrected()
        let first = render(night)
        let again = render(night)
        let light = render(day)
        guard first == again, first != light, light.contains(day.info) else {
            throw SelfTestFailure("markup cache does not respect the palette")
        }
        return AppTheme.all.count
    }

    /// Two meanings that wear the same colour are one meaning to a reader. Every signal slot has
    /// to be told apart from every other one at a glance, so no two may sit inside 1.6:1 of each
    /// other — which is what catches a palette edit that quietly makes "running" and "needs you"
    /// the same amber again.
    private static func checkSignalsAreDistinct(_ palette: Palette) throws {
        let signals = [
            ("accent", palette.accent), ("warn", palette.warn), ("danger", palette.danger),
            ("info", palette.info), ("special", palette.special), ("textDim", palette.textDim),
        ]
        for (index, one) in signals.enumerated() {
            for other in signals.dropFirst(index + 1) {
                guard one.1 != other.1 else {
                    throw SelfTestFailure(
                        "\(palette.name): \(one.0) and \(other.0) are the same colour")
                }
            }
        }
    }

    /// The label contract, asserted against the stylesheet the app actually loads: a running turn
    /// and a turn waiting on the reader must not draw from the same slot, an offline row must not
    /// borrow the failure colour, and no brand may be hardcoded past the palette.
    private static func checkLabelSemantics(_ css: String, _ palette: Palette) throws {
        let required = [
            ".glyph-running { color: \(palette.accent); }",
            ".glyph-needs { color: \(palette.warn); }",
            ".seg-live { color: \(palette.accent); }",
            ".seg-warn { color: \(palette.warn); }",
            ".seg-error { color: \(palette.danger); }",
            ".brand-claude { color: \(palette.brandClaude); }",
        ]
        for rule in required where !css.contains(rule) {
            throw SelfTestFailure("\(palette.name): missing label rule — \(rule)")
        }
        for token in StatusFacts.Segment.allCSS where !css.contains(".\(token) {") {
            throw SelfTestFailure("\(palette.name): the band can wear .\(token) and nothing styles it")
        }
        guard !css.contains(".seg-offline { color: \(palette.danger)") else {
            throw SelfTestFailure("\(palette.name): offline is drawn as a failure")
        }
        for kind in ActivityKind.everyState {
            let icon = kind.icon
            guard css.contains(".\(icon.glyphCSS) {") else {
                throw SelfTestFailure(
                    "\(palette.name): \(kind) draws .\(icon.glyphCSS) and nothing styles it")
            }
            guard css.contains(".\(icon.bandCSS) {") else {
                throw SelfTestFailure(
                    "\(palette.name): \(kind) bands .\(icon.bandCSS) and nothing styles it")
            }
        }
    }

    /// What a conversation cost is money on a screen, so the arithmetic is asserted rather than
    /// eyeballed: the bars are relative to the priciest turn, the tiers add up to the total, and
    /// an estimate says so in the badge itself.
    /// The repository surface, asserted where GTK can actually lose it: the shared reading of a
    /// working tree, the Pango markup a diff becomes, and — the failure mode unique to this
    /// toolkit — every class the panel puts on a widget having a rule in the stylesheet. A class
    /// nobody styles is invisible ink, and no build catches it.
    private static func checkGit() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("git: \(label)") }
            checks += 1
        }
        let snapshot = GitSnapshot(
            root: "/home/dev/project", branch: "master", head: "abc12345",
            upstream: "origin/master", ahead: 2, behind: 1, stashes: 1, operation: "rebase",
            remote: "git@github.com:acme/project.git",
            changes: [
                GitChange(
                    path: "Sources/App/Main.swift", index: "M", worktree: "M", insertions: 3,
                    deletions: 1, stagedInsertions: 8, stagedDeletions: 2),
                GitChange(
                    path: "build/", worktree: "?", untracked: true, directory: true, contains: 12),
                GitChange(path: "Package.swift", index: "U", worktree: "U", conflicted: true),
            ],
            commits: [
                GitCommitSummary(
                    hash: "deadbeefcafe", short: "deadbeef", subject: "a change", author: "dev",
                    at: Date(timeIntervalSince1970: 1_700_000_000), refs: ["HEAD -> master"])
            ], changedTotal: 3)
        let state = GitState(snapshot: snapshot)
        try expect(
            state.sections.map(\.kind) == [.conflicts, .staged, .changed, .untracked],
            "sections triage in order")
        try expect(state.alert?.contains("Rebase") == true, "an unfinished rebase leads the header")
        try expect(
            state.badge.contains("↑2") && state.badge.contains("↓1"),
            "the chip carries both drifts")
        try expect(
            state.facts.contains { $0.value == "acme/project" },
            "the remote is named the way a person names it")

        let markup = GitDiffWindow.markup(
            """
            diff --git a/a.swift b/a.swift
            @@ -10,2 +10,2 @@
             kept
            -gone
            +arrived
            """)
        let palette = MatrixTheme.palette
        try expect(markup.contains(palette.accent), "an added line is not drawn in the accent")
        try expect(markup.contains(palette.danger), "a removed line is not drawn in the danger")
        try expect(
            markup.contains("+ arrived") && markup.contains("− gone"),
            "both sides of the change are drawn")
        try expect(!markup.contains("<span foreground=\'\'>"), "a colour resolved to nothing")

        let css = MatrixTheme.css(for: palette)
        for tone in GitTone.allCases {
            try expect(css.contains(".\(tone.css) {"), "\(tone.rawValue) has no rule to draw with")
        }
        let badge = GitState(snapshot: snapshot).badgeParts
        try expect(badge.first?.tone == .neutral, "the branch is not a state")
        try expect(
            Set(badge.map(\.tone)).count >= 4, "the chip's marks do not carry their own meanings")
        try expect(
            badge.map(\.text).joined(separator: " ") == GitState(snapshot: snapshot).badge,
            "the runs and the plain chip say different things")
        for name in ["git-row", "git-alert", "git-diff", "git-neutral-ink"] {
            try expect(css.contains(".\(name) {"), "\(name) has no rule to draw with")
        }
        return checks
    }

    private static func checkSpend() throws -> Int {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        func turn(_ minute: Int, _ cost: Double, output: Int = 1000) -> SessionSpendReport.Turn {
            SessionSpendReport.Turn(
                at: start.addingTimeInterval(Double(minute) * 60), seconds: 30,
                model: "claude-opus-5", calls: 2,
                tokens: SessionSpendReport.Tokens(output: output, cacheRead: output * 40),
                costUSD: cost, prompt: "turn \(minute)")
        }
        let turns = [turn(0, 1), turn(30, 4), turn(90, 1)]
        var tokens = SessionSpendReport.Tokens()
        for item in turns {
            tokens.output += item.tokens.output
            tokens.cacheRead += item.tokens.cacheRead
        }
        let spend = SessionSpend(
            report: SessionSpendReport(
                costUSD: 6, tokens: tokens, turns: turns,
                byModel: [
                    SessionSpendReport.ModelShare(
                        model: "claude-opus-5", turns: 3, tokens: tokens, costUSD: 6)
                ],
                startedAt: turns.first?.at, endedAt: turns.last?.at))

        guard spend.badge == "~$6.00" else { throw SelfTestFailure("badge: \(spend.badge)") }
        guard spend.turns.map(\.share) == [0.25, 1, 0.25] else {
            throw SelfTestFailure("bars are not relative to the priciest turn")
        }
        let tierMoney = spend.tiers.reduce(0) { $0 + $1.costUSD }
        guard abs(tierMoney - spend.costUSD) < 0.0001 else {
            throw SelfTestFailure("tiers add up to \(tierMoney), not \(spend.costUSD)")
        }
        guard spend.priciest?.costUSD == 4, spend.turnCount == 3 else {
            throw SelfTestFailure("the expensive turn is not the one that cost most")
        }
        guard let rate = spend.perHourUSD, abs(rate - 4) < 0.0001 else {
            throw SelfTestFailure("an hour and a half of six dollars is not \(spend.perHourUSD ?? 0)")
        }
        guard !spend.headline.isEmpty, spend.source.contains(Localized.text("Estimated")) else {
            throw SelfTestFailure("the panel does not say where its numbers came from")
        }
        return spend.turns.count + spend.tiers.count + spend.headline.count
    }

    /// The moving half of the same contract: work has to move, an answer the agent is waiting for
    /// has to move differently, and anything settled has to hold perfectly still — stillness is
    /// how a reader tells a stopped turn from a slow one. Asserted here rather than left to the
    /// eye, because a glyph that quietly stops breathing looks exactly like a session that ended.
    private static func checkActivityMotion() throws {
        for kind in ActivityKind.everyState where kind.isInFlight {
            guard kind.icon.motion.isAnimated else {
                throw SelfTestFailure("\(kind) is in flight and holds still")
            }
        }
        for kind in [ActivityKind.failed, .offline, .queued(2)] where kind.icon.motion.isAnimated {
            throw SelfTestFailure("\(kind) is settled and moves anyway")
        }
        guard ActivityKind.working.icon.motion != ActivityKind.needsApproval.icon.motion else {
            throw SelfTestFailure("a running turn and one waiting on the reader move alike")
        }
        for kind in ActivityKind.everyState
        where kind.icon.motion.honoring(reduceMotion: true) != .still {
            throw SelfTestFailure("\(kind) keeps moving when the desk asked for no motion")
        }
        let spread = stride(from: 0.0, to: ActivityTuning.sweepPeriod, by: 0.02)
            .map { ActivityKind.compacting.icon.glyph(at: $0) }
        guard Set(spread) == Set(ActivityIcon.sweepCycle) else {
            throw SelfTestFailure("a sweep does not reach every frame it owns")
        }
        guard SessionRowState.live.activity == .working,
            SessionRowState.idle.activity == nil
        else { throw SelfTestFailure("a row's state and its activity disagree") }
    }

    /// A picture must come back byte-identical, keyed to its server file — and two different
    /// files must never collide into one cache slot.
    private static func checkImageCache() throws {
        let first = FileReference(path: "/tmp/selftest/a.png", mime: "image/png", filename: "a.png")
        let second = FileReference(path: "/tmp/selftest/b.png", mime: "image/png", filename: "b.png")
        guard let one = ImageCache.identity(for: first), let two = ImageCache.identity(for: second),
            one != two
        else { throw SelfTestFailure("two files share one identity") }
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        ImageCache.save(bytes, for: first)
        guard ImageCache.load(first) == bytes else {
            throw SelfTestFailure("bytes did not round-trip")
        }
        guard ImageCache.load(second) == nil else {
            throw SelfTestFailure("an unsaved file loaded")
        }
        guard ImageCache.identity(for: FileReference()) == nil else {
            throw SelfTestFailure("an unidentifiable file got an identity")
        }
    }

    /// The band over the prompt box: a status that shows every field always is a status nobody
    /// reads, so what is asserted here is mostly what is *absent*. Compact by default — the
    /// agents band counts while its popover names, and the goal is a glyph until it is asked
    /// about, its words living in the popover. Twenty agents spawned with one preamble must not
    /// read as twenty copies of the preamble.
    private static func checkStatusBand() throws -> Int {
        func text(_ facts: StatusFacts) -> String {
            facts.segments.map(\.text).joined(separator: " | ")
        }

        let todoAgent = SubagentSummary(
            id: "a", title: "port the renderer", updatedAt: Date(), isActive: true,
            startedAt: Date().addingTimeInterval(-95), toolCount: 4,
            currentTool: "Bash swift build", todosDone: 2, todosTotal: 5,
            currentTodo: "port the disclosure rows")
        let todoLine = StatusFacts.liveDetail(todoAgent)
        guard todoLine.hasPrefix("2/5 · port the disclosure rows") else {
            throw SelfTestFailure("todo agent line: \(todoLine)")
        }
        let toolAgent = SubagentSummary(
            id: "b", title: "sweep the band", updatedAt: Date(), isActive: true,
            toolCount: 7, currentTool: "Edit StatusBand.swift")
        let toolLine = StatusFacts.liveDetail(toolAgent)
        guard toolLine.contains("7"), toolLine.contains("Edit StatusBand.swift") else {
            throw SelfTestFailure("tool agent line: \(toolLine)")
        }
        let quietAgent = SubagentSummary(id: "c", title: "quiet", updatedAt: Date(), isActive: true)
        guard StatusFacts.liveDetail(quietAgent) == Localized.text("working") else {
            throw SelfTestFailure("quiet agent line")
        }

        var idle = StatusFacts()
        guard text(idle) == "ready" else { throw SelfTestFailure("idle band: \(text(idle))") }

        idle.phase = .working
        idle.elapsed = 72
        idle.runningTool = "Bash"
        guard text(idle).contains("1m 12s"), text(idle).contains("Bash") else {
            throw SelfTestFailure("working band: \(text(idle))")
        }

        let now = Date()
        idle.agents = [
            SubagentSummary(
                id: "a", title: "map the theme", agentType: "explore", toolUseID: "t1",
                updatedAt: now, isActive: true),
            SubagentSummary(
                id: "b", title: "check the diff", agentType: "review", toolUseID: "t2",
                updatedAt: now.addingTimeInterval(-30), isActive: true),
            SubagentSummary(
                id: "c", title: "verify", agentType: "verify", toolUseID: "t3",
                updatedAt: now.addingTimeInterval(-90), isCompleted: true),
        ]
        guard text(idle).contains("▸ 2 · 1✓"), !text(idle).contains("explore") else {
            throw SelfTestFailure("agents band is not compact: \(text(idle))")
        }
        guard let agentSegment = idle.segments.first(where: { $0.text.hasPrefix("▸") }),
            agentSegment.rows.count == 3,
            agentSegment.rows.first?.title.contains("explore") == true,
            agentSegment.rows.first?.detail?.contains("working") == true,
            agentSegment.rows.last?.detail?.contains("done") == true,
            agentSegment.rows.first?.action == .agent("t1")
        else { throw SelfTestFailure("agents popover does not list the agents") }

        idle.contextTokens = 320_000
        guard text(idle).contains("~320.0k"),
            idle.segments.contains(where: { $0.css == "seg-warn" })
        else { throw SelfTestFailure("context band: \(text(idle))") }

        idle.lastCostUSD = 0.38
        guard text(idle).contains("$0.38") else { throw SelfTestFailure("cost: \(text(idle))") }

        idle.goal = "ship it"
        guard text(idle).contains("⦿"), !text(idle).contains("ship it") else {
            throw SelfTestFailure("goal is not compact: \(text(idle))")
        }
        guard let goalSegment = idle.segments.first(where: { $0.css == "seg-goal" }),
            goalSegment.rows.first?.title == "ship it",
            goalSegment.rows.last?.action == .goal
        else { throw SelfTestFailure("goal popover does not carry the goal") }
        idle.goalMet = true
        guard text(idle).contains("✓") else { throw SelfTestFailure("goal met: \(text(idle))") }

        var failed = StatusFacts()
        failed.phase = .failed("the bridge said no")
        guard text(failed).contains("the bridge said no"), failed.segments.count == 1 else {
            throw SelfTestFailure("failure band: \(text(failed))")
        }

        var approval = StatusFacts()
        approval.phase = .awaitingApproval
        guard approval.segments.first?.action == .scrollToPending else {
            throw SelfTestFailure("approval segment is not actionable")
        }

        var fanOut = StatusFacts()
        fanOut.agents = (0..<4).map { index in
            SubagentSummary(
                id: "f\(index)", title: "In /home/marcus/Dev/iOS/Tailscode, verify claim number \(index) about the diff",
                agentType: "workflow-subagent", toolUseID: "ft\(index)",
                updatedAt: now.addingTimeInterval(Double(-index)), isCompleted: true)
        }
        guard let fanRows = fanOut.segments.first(where: { $0.id == "agents" })?.rows,
            fanRows.allSatisfy({ $0.title.contains("…") }),
            fanRows[0].title.contains("0"), fanRows[1].title.contains("1"),
            !fanRows[0].title.contains("/home/marcus")
        else { throw SelfTestFailure("fan-out titles keep their shared preamble") }
        return 9
    }

    /// A workflow launched in a transcript has to become one card carrying the run: its name, the
    /// phases its script declares, the agents fanned out under it, and — once the task reports back
    /// — the answer. The row kind is what decides whether the card is drawn at all.
    private static func checkWorkflowCard() throws -> Int {
        let now = Date()
        let script = """
            export const meta = {
              name: 'kaytetty-best',
              description: 'Best used buy in Finland',
              phases: [
                { title: 'Scope', detail: 'classify the request' },
                { title: 'Hunt', detail: 'pull live listings', model: 'claude-haiku-4-5-20251001' },
                { title: 'Appraise', detail: 'compute the fair band' },
              ],
            }
            """
        let call = ToolCall(
            id: "wf-call", name: "Workflow", status: .running,
            input: .object(["script": .string(script)]),
            output: "Workflow launched in background. Task ID: task-1\nRun ID: wf_abc")
        let launch = ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(call))], createdAt: now)

        let rows = TranscriptRow.rows(for: [launch])
        guard case .workflow(let rowCall)? = rows.first?.kind, rowCall.id == call.id else {
            throw SelfTestFailure("a Workflow call is not a workflow row")
        }

        var agents: [SubagentSummary] = []
        for index in 0..<3 {
            let offset = Double(index)
            agents.append(
                SubagentSummary(
                    id: "a\(index)", title: "agent \(index)",
                    agentType: WorkflowRunAssembly.agentType,
                    updatedAt: now.addingTimeInterval(offset + 1),
                    isActive: index > 0, isCompleted: index == 0,
                    startedAt: now.addingTimeInterval(offset)))
        }
        let live = WorkflowRunAssembly.runs(
            messages: [launch], agents: agents, now: now.addingTimeInterval(90))
        guard let run = live.first, live.count == 1 else {
            throw SelfTestFailure("one launch is not one run")
        }
        guard run.name == "kaytetty-best", run.phases.count == 3 else {
            throw SelfTestFailure("run identity: \(run.name) \(run.phases.count) phases")
        }
        guard run.phases[1].model == "claude-haiku-4-5-20251001" else {
            throw SelfTestFailure("phase model lost")
        }
        guard run.agents.count == 3, run.doneCount == 1, run.runningCount == 2 else {
            throw SelfTestFailure("agent counts: \(run.doneCount)/\(run.agents.count)")
        }
        guard run.isLive, run.launch.runID == "wf_abc" else {
            throw SelfTestFailure("live state: \(run.state)")
        }

        let notification = ChatMessage(
            id: "m2", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "p2",
                    kind: .text(
                        "<task-notification><task-id>task-1</task-id><result>\"# The answer\"</result></task-notification>"
                    ))
            ], createdAt: now.addingTimeInterval(120))
        let done = WorkflowRunAssembly.runs(
            messages: [launch, notification], agents: agents, now: now.addingTimeInterval(130))
        guard let finished = done.first, done.count == 1 else {
            throw SelfTestFailure("the finished run vanished")
        }
        guard !finished.isLive, finished.state == .finished, finished.progress == 1 else {
            throw SelfTestFailure("finished state: \(finished.state)")
        }
        guard finished.result == "# The answer" else {
            throw SelfTestFailure("answer not folded in: \(finished.result ?? "nil")")
        }

        return 12
    }

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    private static func checkTwoObservers(
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> Int {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        async let first = settled(conversation)
        async let second = settled(conversation)
        let (a, b) = try await (first, second)

        guard a == b else {
            throw SelfTestFailure("observers diverged: \(a.count) vs \(b.count) messages")
        }
        return a.count
    }

    /// Bounded from outside the stream: a `for await` whose server never answers receives no
    /// state to check a deadline against, so the deadline must not live inside the loop.
    private static func settled(_ conversation: AgentConversation) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                for await state in await conversation.states() {
                    if state.hasLoadedTranscript { return state.messages.map(\.id) }
                }
                throw SelfTestFailure("observer stream ended before a transcript")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(25))
                throw SelfTestFailure("observer never loaded a transcript in 25s")
            }
            guard let first = try await group.next() else {
                throw SelfTestFailure("no observer outcome")
            }
            group.cancelAll()
            return first
        }
    }

    /// Sends a real prompt through the same path the composer uses and waits for the answer, in a
    /// throwaway session in a throwaway directory. Opt-in, because it spends tokens and starts a
    /// turn on the user's own machine.
    private static func checkRoundTrip(_ profiles: [ConnectionProfile]) async throws {
        guard let profile = profiles.first,
            let backend = await ServerDirectory.shared.backend(for: profile)
        else { throw SelfTestFailure("no backend to send through") }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = try await backend.createSession(
            title: "selftest", directory: scratch.path)
        defer { Task { try? await backend.deleteSession(session.id) } }

        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        let states = await conversation.states()
        try await conversation.send("Reply with the single word PONG and nothing else.")

        let deadline = Date().addingTimeInterval(90)
        for await state in states {
            let answered = state.messages.contains {
                $0.role == .assistant && $0.text.uppercased().contains("PONG")
            }
            if answered { return }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("no answer within the deadline")
    }

    /// Bounded the same way as ``settled(_:)``: the deadline lives outside the stream, and it is
    /// generous — a bridge mid-turn on a large transcript legitimately takes tens of seconds
    /// today, and this test is about correctness, not the latency the sync plan will buy.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        return await withTaskGroup(of: ConversationState?.self) { group in
            group.addTask {
                for await state in await conversation.states() where state.hasLoadedTranscript {
                    return state
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ConversationState()
        }
    }

    /// The newest session that is not mid-turn. An active session's transcript can be enormous
    /// and its server busy running it — that is the wrong subject for a bounded smoke test, and
    /// the two-observer check does not care which conversation it observes.
    private static func observable(in sessions: [AgentSession]) -> AgentSession? {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.first { !$0.isWorking } ?? sorted.first
    }

    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(150))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
