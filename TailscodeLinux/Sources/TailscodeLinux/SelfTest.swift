import CAdw
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
            let checks = try checkTable()
            report("table: \(checks) widths measure the height they draw")
        } catch {
            report("table: \(error)")
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

        let runFailures = WorkflowRunCheck.run()
        if runFailures.isEmpty {
            report("workflow run: every ending is read, holds still, and the tempo is thirty")
        } else {
            report("workflow run: \(runFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkSubagentCard()
            report("subagent card: \(checks) claims hold — the line reads the errand, not the week")
        } catch {
            report("subagent card: \(error)")
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
            let checks = try checkAnalyticsShare()
            report("analytics share: \(checks) claims hold — words, card and PNG")
        } catch {
            report("analytics share: \(error)")
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

        do {
            let checks = try checkDeepSeekBalance()
            report("deepseek balance: \(checks) claims hold — money, never a bar")
        } catch {
            report("deepseek balance: \(error)")
            failures += 1
        }

        do {
            let checks = try checkUsageGlance()
            report("usage glance: \(checks) states say only what each needs to")
        } catch {
            report("usage glance: \(error)")
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

        let forgeFailures = ForgeBoardCheck.run()
        if forgeFailures.isEmpty {
            report("video forge: the graph, the frames, the job's walk and the board all hold")
        } else {
            report("video forge: \(forgeFailures.joined(separator: " · "))")
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

        /// A quick ask is the same box, so it answers the same grammar — except that the chat it
        /// mints has no turns for a transcript command to read, and no project for a repository's
        /// own commands to come from.
        let offered = CommandCatalogStore.forQuickAsk(commands)
        try expect(!offered.contains { $0.name == "compact" }, "a quick ask offers no compaction")
        try expect(offered.count == commands.count - 2, "only the transcript words are dropped")
        try expect(
            QuickAskSend.decide(
                text: "/flyr HEL to ICN", commands: commands, resolvesFromPromptText: false
            ).kind == .command(commands[3], arguments: "HEL to ICN"),
            "a typed command runs as a command")
        try expect(
            QuickAskSend.decide(
                text: "/compact", commands: commands, resolvesFromPromptText: false).kind
                == .prompt, "compaction never survives the quick ask's own catalog")
        try expect(
            QuickAskSend.decide(
                text: "/flyr", commands: commands, resolvesFromPromptText: true).kind == .prompt,
            "an agent that reads its own slash grammar gets the prompt untouched")
        try expect(
            SlashPresentation.noMatchWording("commit", hasProject: false)
                != SlashPresentation.noMatchWording("commit", hasProject: true),
            "a word missing for want of a project says so")
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
        try expect(
            action(set, chord("p"), .normal) == .toggleProjectScope, "p scopes to the project")
        try expect(
            action(set, chord("a", shift: true), .normal) == nil,
            "A is spent on a shortcut the machine-wide chord already covers, and the composer's "
                + "vim wants it")
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
            case .varies:
                try expect(false, "\(capability.rawValue) resolves to one answer for this copy")
            }
        }
        return checks
    }

    /// The prepaid balance's own claims, proved without a network: the snapshot carries money and
    /// no cap, an empty account reads as the wall it is, and the renderer's recognition — `usedUSD`
    /// with no `limitUSD` — is what the quota surfaces skip bars for.
    private static func checkDeepSeekBalance() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("deepseek balance: \(label)") }
            checks += 1
        }
        let topped = DeepSeekBalance.snapshot(
            for: DeepSeekBalance.Reading(
                total: 13.42, toppedUp: 11.0, granted: 2.42, currency: "CNY",
                isAvailable: true))
        let gauge = try requireOne(topped.gauges)
        try expect(gauge.usedUSD == 13.42 && gauge.limitUSD == nil, "money without a cap")
        try expect(gauge.fraction == 0 && gauge.resetsAt == nil, "no invented wall or reset")
        try expect(
            DeepSeekBalance.amount(for: gauge) == "¥13.42", "CNY reads with its own symbol")
        try expect(
            topped.details.contains { $0.key == "Topped up" && $0.value == "¥11.00" },
            "the top-up split is a fact")
        try expect(
            topped.details.contains { $0.key == "Granted" && $0.value == "¥2.42" },
            "the granted split is a fact")

        let empty = DeepSeekBalance.snapshot(
            for: DeepSeekBalance.Reading(
                total: 0, toppedUp: 0, granted: 0, currency: "CNY", isAvailable: false))
        let emptyGauge = try requireOne(empty.gauges)
        try expect(emptyGauge.fraction >= 1, "an empty balance is a wall")
        try expect(
            DeepSeekBalance.amount(for: emptyGauge) == "Empty",
            "the wall reads as empty, not as a number")

        let usd = DeepSeekBalance.money(4.5, nil)
        try expect(usd == "$4.50", "USD reads with its own symbol")
        return checks
    }

    private static func requireOne<T>(_ items: [T]) throws -> T {
        guard items.count == 1, let only = items.first else {
            throw SelfTestFailure("deepseek balance: expected exactly one gauge")
        }
        return only
    }

    /// The footer strip's states, proved as data: a wall owns the strip and is answered by what is
    /// still open, warm windows read one line each only while nothing is at the wall, a quiet
    /// account still says which window is closest to mattering, and every line the client draws
    /// with a bar carries the fraction to draw it from.
    private static func checkUsageGlance() throws -> Int {
        var checks = 0
        let now = Date()
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("usage glance: \(label)") }
            checks += 1
        }
        func quota(_ provider: String, _ windows: [(String, Double)], live: Bool = true)
            -> UsageQuota
        {
            UsageQuota(
                providerName: provider, subtitle: "", source: "test", live: live,
                gauges: windows.map {
                    UsageQuota.Gauge(
                        key: $0.0.lowercased(), label: $0.0, fraction: $0.1,
                        resetsAt: now.addingTimeInterval(7_200), trustedReset: true)
                },
                details: [])
        }
        func balance(_ total: Double, _ fraction: Double) -> UsageQuota {
            UsageQuota(
                providerName: "DeepSeek", subtitle: "", source: "api.deepseek.com", live: true,
                gauges: [
                    UsageQuota.Gauge(
                        key: "balance", label: "Balance", fraction: fraction, resetsAt: nil,
                        trustedReset: false, usedUSD: total, limitUSD: nil, currency: "USD")
                ],
                details: [])
        }
        func glance(_ reports: [(String, UsageQuota)], answeredAt: Date? = nil) -> QuotaGlance {
            QuotaGlance.make(from: reports, answeredAt: answeredAt ?? now, now: now)
        }

        let quiet = glance([("", quota("Claude", [("Weekly", 0.3), ("5-hour session", 0.1)]))])
        try expect(quiet.lines.count == 1, "a quiet account is one line")
        try expect(
            quiet.lines[0].tone == .ok && quiet.lines[0].text.contains(Localized.text("Quotas clear")),
            "the quiet line says what it means")
        try expect(
            quiet.lines[0].text.contains("Weekly") && quiet.lines[0].trailing == "30%"
                && quiet.lines[0].fraction == 0.3,
            "and names the window closest to mattering, with the bar to draw it")

        let warm = glance([
            ("", quota("Claude", [("Weekly", 0.85), ("5-hour session", 0.3)])),
            ("", quota("Grok", [("Weekly credits", 0.7)])),
        ])
        try expect(warm.lines.count == 2, "warm windows read one line each, the healthy stay home")
        try expect(
            warm.lines[0].tone == .warn && warm.lines[0].trailing == "85%", "the tightest leads")
        try expect(!warm.lines[0].text.contains("5-hour"), "a quiet window is not news")

        let wall = glance([
            ("", quota("Claude", [("Weekly", 1.0), ("5-hour session", 0.2)])),
            ("", quota("Grok", [("Weekly credits", 0.9)])),
        ])
        try expect(wall.lines.count == 2, "a wall, and the one line that makes it actionable")
        try expect(
            wall.lines[0].tone == .danger && wall.lines[0].trailing == Localized.text("Used up")
                && wall.lines[0].text.contains("Weekly"),
            "the wall names what ran out")
        try expect(
            wall.lines[1].tone == .ok && wall.lines[1].text.contains("Grok"),
            "and the strip says where there is still room")

        let crowded = glance([
            ("", quota("opencode go", [("Weekly", 1.0)])),
            ("", quota("Claude", [("5-hour session", 0.63), ("Weekly", 0.42)])),
            ("", quota("Grok", [("Monthly spend", 0.14)])),
        ])
        try expect(
            crowded.lines.contains { $0.text.contains("Claude") && $0.trailing == "63%" },
            "a wall names every provider still open, never only the roomiest")

        let shut = glance([
            ("", quota("Claude", [("Weekly", 1.0)])),
            ("", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        try expect(
            shut.lines.last?.tone == .danger
                && shut.lines.last?.text == Localized.text("Nothing left to send with"),
            "nowhere to go is a state, not a missing line")

        let manyWalls = glance([
            ("", quota("Claude", [("Weekly", 1.0), ("5-hour session", 1.0), ("Opus weekly", 1.0)])),
            ("", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        try expect(
            manyWalls.lines.contains {
                $0.kind == .notice && $0.text.contains("1")
            },
            "a wall past the strip's room is counted, never dropped")

        let emptyBalance = glance([("", balance(0, 1.0))])
        try expect(
            emptyBalance.lines.count == 1 && emptyBalance.lines[0].tone == .danger
                && emptyBalance.lines[0].trailing == Localized.text("Empty"),
            "an empty balance reads as the wall it is")

        let wallWithBalance = glance([
            ("", quota("Claude", [("Weekly", 1.0)])),
            ("", balance(13.42, 0)),
        ])
        try expect(
            wallWithBalance.lines.last?.kind == .balance
                && wallWithBalance.lines.last?.trailing == "$13.42",
            "the balance keeps its own line whatever the walls are doing")
        try expect(
            wallWithBalance.lines.allSatisfy { $0.kind != .balance || $0.fraction == nil },
            "money has no ceiling, so it draws no bar")

        let cached = glance(
            [("", quota("opencode go", [("Weekly", 0.4)], live: false))],
            answeredAt: now.addingTimeInterval(-900))
        try expect(
            cached.lines.first?.kind == .notice && cached.lines.first?.tone == .warn,
            "a reading nobody could refresh says so before it says anything else")

        let checking = QuotaGlance.make(from: [], answeredAt: nil, now: now)
        try expect(
            checking.lines.count == 1 && checking.lines[0].tone == .quiet,
            "a first poll still out is a state, not an empty strip")
        try expect(
            QuotaGlance.make(from: [], answeredAt: now, now: now).isEmpty,
            "nothing reported is nothing shown")
        try expect(!quiet.tooltip.isEmpty, "the whole picture is one hover away")
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

    /// The height a table hands the transcript has to be the height it will draw at.
    ///
    /// A grid whose columns hug their content is measured by the box above it for the width of the
    /// whole pane and then allocated only its own natural width, so the two heights have to agree.
    /// A cell that asks for extra space — a rule spanning the columns is the tempting one — makes
    /// `GtkGrid` measure a distribution it never allocates, every wrapping cell comes out a line
    /// short, and the last rows are drawn over the paragraph beneath the table.
    private static func checkTable() throws -> Int {
        let table = MarkdownTable(
            header: ["Tab", "Mod", "Download"],
            alignments: [.leading, .leading, .leading],
            rows: [
                ["102", "Free Flight", "**Main-102-1-1** (v1.1, main)"],
                [
                    "16", "Retro Sound Pack",
                    "**Spyro Reignited Retro Sound Pack-0-1-1568225269** (main, 2nd)",
                ],
                [
                    "4", "Intro Movie Remover",
                    "**Intro Movie Remover** (skip Credits_Remover optional unless you want it)",
                ],
                ["233", "60fps Cutscenes", "**Reignited Interpolated 60fps Cutscenes** (2.1GB .rar)"],
            ])
        guard gtk_init_check() != 0 else { return 0 }
        let widget = TranscriptRow.table(table)
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        defer { g_object_unref(UnsafeMutableRawPointer(widget)) }

        func measure(_ orientation: GtkOrientation, for size: Int32) -> Int32 {
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(widget, orientation, size, &minimum, &natural, nil, nil)
            return natural
        }

        let width = measure(GTK_ORIENTATION_HORIZONTAL, for: -1)
        guard width > 0 else { throw SelfTestFailure("a table with cells asks for no width") }
        let drawn = measure(GTK_ORIENTATION_VERTICAL, for: width)
        var checks = 0
        for pane in [width - 120, width, width + 200, width + 900] where pane > 0 {
            let allocated = min(width, pane)
            let asked = measure(GTK_ORIENTATION_VERTICAL, for: pane)
            let needed = measure(GTK_ORIENTATION_VERTICAL, for: allocated)
            guard asked >= needed else {
                throw SelfTestFailure(
                    "a table measured \(asked) tall for a \(pane) pane draws \(needed) at the "
                        + "\(allocated) it is given — the rows past that fall on the words below")
            }
            checks += 1
        }
        guard drawn > 0 else { throw SelfTestFailure("a table with rows asks for no height") }
        return checks + 1
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
            ("published at https://x.dev/p now", ["<a href=\"https://x.dev/p\">"], "bare link"),
            (
                "[docs](https://x.dev) and https://y.dev",
                ["<a href=\"https://x.dev\">", "<a href=\"https://y.dev\">"], "both link forms"
            ),
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

        try expect(
            CascadePainter.renderedText(of: "a row with <b>no closer") == nil,
            "markup the parser refuses has no rendered text, and no reveal may claim to show it")
        var gated = LiveCascade()
        let abandonedToken = "the rest is behind an *opener"
        try expect(
            gated.renderable(row: "row", abandonedToken, sealed: false, at: 0).count
                < abandonedToken.count,
            "a token still in flight holds the renderer")
        try expect(
            gated.renderable(row: "row", abandonedToken, sealed: false, at: 4) == abandonedToken,
            "a token that never closes must stop holding the rest of the answer back")
        checks += 4

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
        return try checks + checkReveal(expect)
    }

    /// The regression the screenshots kept showing: a turn that ends while the reveal is nine
    /// characters into a sentence, and a row that keeps those nine characters for good.
    ///
    /// Everything here happens on a real label, because every earlier fix to this was proved
    /// against arithmetic that was already right. The paint is a prefix on purpose; what is asserted
    /// is that the row is whole again the moment the wave lets go, that the wave knows it is owed
    /// text until somebody proves otherwise, and that a settle nobody could make reports a failure
    /// instead of a repair.
    private static func checkReveal(_ expect: (Bool, String) throws -> Void) throws -> Int {
        let sentence = "Good. Net changes on the host: `1920x1200@89` and the rest of the answer."
        let palette = MatrixTheme.palette
        let markup = PangoMarkdown.render(
            sentence, dim: palette.textDim, code: palette.info, accent: palette.accent,
            cache: false)
        guard let whole = CascadePainter.renderedText(of: markup) else {
            throw SelfTestFailure("the sentence under test does not render")
        }
        guard gtk_init_check() != 0 else { return 0 }
        let label = Gtk.label("", css: "agent-prose", selectable: true)
        let painter = CascadePainter()
        painter.focus(
            "row:part", markup: markup, sealed: false, ultracode: false, clock: nil)
        try expect(painter.isActive, "the wave must take a row it was pointed at")
        try expect(painter.owes, "a row nobody has painted yet is owed to the reader")
        try expect(painter.paint(label), "the wave must paint the label it was given")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == whole,
            "a reveal must lay the whole paragraph out and hide the tail, never cut it")

        painter.release()
        try expect(
            painter.settle(label, markup: markup),
            "a settle onto a live label must land, and must say that it did")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == whole,
            "a row the wave let go of must be holding every word it has")
        try expect(
            !painter.settle(label, markup: "an <b>unclosed row"),
            "a settle that could not be rendered must report a failure, not a repair")

        // One emoji is one Swift Character and two code points, and Pango indexes code points. A
        // reveal counted in the wrong unit saturates before the end of the paragraph, reports a
        // settled row, and leaves the last characters unpainted until something rebuilds the row.
        let withEmoji = "Ready ⚠️ now — done ✅ and the sentence carries on past the mark."
        let emojiMarkup = PangoMarkdown.render(
            withEmoji, dim: palette.textDim, code: palette.info, accent: palette.accent,
            cache: false)
        guard let emojiText = CascadePainter.renderedText(of: emojiMarkup) else {
            throw SelfTestFailure("the emoji sentence does not render")
        }
        try expect(
            emojiText.count != emojiText.unicodeScalars.count,
            "this check is only meaningful while the sentence counts differently in each unit")
        let paced = CascadePainter()
        paced.focus(
            "row:emoji", markup: emojiMarkup, sealed: false, ultracode: false, clock: nil)
        var settledAt = 0.0
        while paced.owes, settledAt < 40 {
            settledAt += 1.0 / 120
            paced.advance(to: settledAt)
            _ = paced.paint(label)
        }
        try expect(
            !paced.owes && paced.revealed == emojiText.unicodeScalars.count,
            "the reveal must land on every code point the painter can index, not one short")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == emojiText,
            "a settled row must be holding every character of its sentence")

        // A streamed row is painted through Pango's parser, which has no anchor, so the painter
        // dresses a link as the span it looks like. Settling writes through GtkLabel's own road,
        // and only `<a href>` becomes something a click can follow there. One markup fed both
        // paths once, and every answer carrying an address spent the rest of the chat looking
        // touchable and doing nothing.
        let linked =
            "Read it at https://example.com/warranty and the rest of the answer."
        let linkMarkup = PangoMarkdown.render(
            linked, dim: palette.textDim, code: palette.info, accent: palette.accent, cache: false)
        try expect(
            linkMarkup.contains("<a href=\"https://example.com/warranty\">"),
            "the markdown renderer must lift a bare address into an anchor")
        let linkRow = TranscriptRow(
            key: "row:links", kind: .agentProse(text: linked, markup: linkMarkup))
        try expect(
            ChatPane.cascadeMarkup(for: linkRow)?.contains("<a href=\"") == false,
            "the painter's markup carries a link's ink, never its anchor")
        try expect(
            ChatPane.settleMarkup(for: linkRow)?.contains("<a href=\"") == true,
            "the markup a row settles with must keep the anchor GtkLabel turns into a link")
        return 12
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
                palette.brandDeepseek,
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

    /// The share card is Core geometry painted by the shim: a demo ledger must yield words, a
    /// stable filename, and a non-empty PNG whose signature is a real image — not a layout that
    /// only looks right once someone opens the panel by hand.
    private static func checkAnalyticsShare() throws -> Int {
        guard
            let analytics = UsageAnalytics(
                servers: [("demo", DemoWorld.demoAnalytics())], missingServers: [])
        else { throw SelfTestFailure("demo analytics produced nothing to share") }
        let package = AnalyticsShare(analytics)
        guard package.plainText.contains(analytics.totalMoney) else {
            throw SelfTestFailure("plain text lost the total")
        }
        guard package.markdown.contains(analytics.totalMoney) else {
            throw SelfTestFailure("markdown lost the total")
        }
        guard package.filename.hasSuffix(".png"), package.filename.hasPrefix("tailscode-month-")
        else { throw SelfTestFailure("filename: \(package.filename)") }
        guard package.card.height > 400, AnalyticsShare.Card.width == 1080 else {
            throw SelfTestFailure("card geometry drifted")
        }
        guard let png = AnalyticsCardRenderer.png(package, scale: 1), png.count > 800 else {
            throw SelfTestFailure("renderer produced no PNG")
        }
        let signature = [UInt8](png.prefix(8))
        guard signature == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw SelfTestFailure("PNG signature missing")
        }
        return 5
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

        let read = Date()
        let todoAgent = SubagentSummary(
            id: "a", title: "port the renderer", updatedAt: read, isActive: true,
            startedAt: read.addingTimeInterval(-95), toolCount: 4,
            currentTool: "Bash swift build", todosDone: 2, todosTotal: 5,
            currentTodo: "port the disclosure rows")
        let todoLine = StatusFacts.liveDetail(todoAgent, at: read, under: .going)
        guard todoLine.hasPrefix("2/5 · port the disclosure rows"), todoLine.hasSuffix("1m 35s")
        else {
            throw SelfTestFailure("todo agent line: \(todoLine)")
        }
        let toolAgent = SubagentSummary(
            id: "b", title: "sweep the band", updatedAt: read, isActive: true,
            toolCount: 7, currentTool: "Edit StatusBand.swift")
        let toolLine = StatusFacts.liveDetail(toolAgent, at: read, under: .going)
        guard toolLine.contains("7"), toolLine.contains("Edit StatusBand.swift") else {
            throw SelfTestFailure("tool agent line: \(toolLine)")
        }
        let quietAgent = SubagentSummary(id: "c", title: "quiet", updatedAt: read, isActive: true)
        guard StatusFacts.liveDetail(quietAgent, at: read, under: .going)
            == Localized.text("working")
        else {
            throw SelfTestFailure("quiet agent line")
        }
        let aWeekOn = read.addingTimeInterval(604_800)
        guard StatusFacts.liveDetail(todoAgent, at: aWeekOn, under: .going).hasSuffix("10081m 35s")
        else { throw SelfTestFailure("a line under work still open stopped counting") }
        let held = StatusFacts.liveDetail(todoAgent, at: aWeekOn, under: .over(at: nil))
        guard held.hasSuffix("1m 35s") else {
            throw SelfTestFailure("a line under work that is over counts on: \(held)")
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
        return 11
    }

    /// A subagent card's live line is a clock, and it has to read the errand rather than the days
    /// since. The agent handed here is deliberately left claiming to be active, because that is the
    /// one shape the fault lives in: a sidecar goes on reporting itself out for as long as its
    /// window lasts, so a call that is over holding an agent that still says it is working is what
    /// a real fan-out delivers, and a check that settled the record by hand would never once build
    /// it. Read off the widget rather than off the vocabulary, and read twice — at the moment the
    /// card was built and a week later — because a clock that grows is only ever caught by asking
    /// a second time.
    private static func checkSubagentCard() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let now = Date()
        let aWeekOn = now.addingTimeInterval(604_800)
        var call = ToolCall(
            id: "task-1", name: "Task", status: .running,
            input: .object(["description": .string("port the renderer")]))
        let agent = SubagentSummary(
            id: "s1", title: "port the renderer", agentType: "explore", toolUseID: call.id,
            updatedAt: now.addingTimeInterval(-12), isActive: true,
            startedAt: now.addingTimeInterval(-252), toolCount: 4, currentTool: "Bash swift build")
        let context = TranscriptContext()
        context.agentFacts[call.id] = agent

        guard drawn(call, at: now, in: context) == "live=4 tools · Bash swift build · 4m 12s" else {
            throw SelfTestFailure("a live card's line: \(drawn(call, at: now, in: context))")
        }
        let counting = drawn(call, at: aWeekOn, in: context)
        guard counting.hasSuffix("10084m 12s") else {
            throw SelfTestFailure("a card under a running call stopped counting: \(counting)")
        }

        call.status = .completed
        let settled = drawn(call, at: now, in: context)
        guard settled.hasSuffix("4m 0s") else {
            throw SelfTestFailure("a card under an ended call: \(settled)")
        }
        guard drawn(call, at: aWeekOn, in: context) == settled else {
            throw SelfTestFailure(
                "a card under an ended call kept counting a week later: "
                    + drawn(call, at: aWeekOn, in: context))
        }

        call.background = BackgroundOutcome(
            taskID: "task-1", status: .completed, summary: "the errand ended",
            reportedAt: now.addingTimeInterval(-100))
        let credited = drawn(call, at: aWeekOn, in: context)
        guard credited.hasSuffix("2m 32s") else {
            throw SelfTestFailure(
                "a stale sidecar is credited with work past the report: \(credited)")
        }

        context.agentFacts[call.id] = nil
        guard drawn(call, at: now, in: context) == "live=none" else {
            throw SelfTestFailure("a card with no live agent wears a clock anyway")
        }
        return 5
    }

    /// The card as this transcript would draw it at that moment: the pass stamps the clock, exactly
    /// as the pane's own passes do, and the line is read back off the widget it built.
    private static func drawn(_ call: ToolCall, at now: Date, in context: TranscriptContext)
        -> String
    {
        context.liveNow = now
        let card = SubagentRowView.make(call, key: "sub", context: context)
        return SubagentRowView.liveReading(of: card)
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
        let live = WorkflowRunAssembly.runs(messages: [launch], agents: agents)
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
        guard run.activityIcon.motion == .turning else {
            throw SelfTestFailure("a live run's mark does not turn")
        }

        for (status, expected) in [
            (BackgroundOutcome.Status.completed, ActivityIcon.finished),
            (.stopped, ActivityIcon.stopped),
            (.failed, ActivityIcon.failed),
        ] {
            let ended = try reported(status, on: call, launch: launch, agents: agents, now: now)
            guard !ended.isLive, ended.activityIcon == expected,
                ended.activityIcon.motion == .still
            else {
                throw SelfTestFailure("a \(status.rawValue) run keeps moving: \(ended.state)")
            }
            guard ended.elapsed(at: now.addingTimeInterval(9_000)) == 120 else {
                throw SelfTestFailure(
                    "a \(status.rawValue) run's clock kept climbing: "
                        + "\(ended.elapsed(at: now.addingTimeInterval(9_000)) ?? -1)")
            }
            guard ended.result == (status == .completed ? "# The answer" : nil) else {
                throw SelfTestFailure(
                    "a \(status.rawValue) run's answer: \(ended.result ?? "nil")")
            }
        }

        let marks = try checkWorkflowCardMark(
            call: call, live: run, launch: launch, agents: agents, now: now)

        let notification = ChatMessage(
            id: "m2", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "p2",
                    kind: .text(
                        "<task-notification><task-id>task-1</task-id><result>\"# The answer\"</result></task-notification>"
                    ))
            ], createdAt: now.addingTimeInterval(120))
        let done = WorkflowRunAssembly.runs(messages: [launch, notification], agents: agents)
        guard let finished = done.first, done.count == 1 else {
            throw SelfTestFailure("the finished run vanished")
        }
        guard !finished.isLive, finished.state == .finished, finished.progress == 1 else {
            throw SelfTestFailure("finished state: \(finished.state)")
        }
        guard finished.result == "# The answer" else {
            throw SelfTestFailure("answer not folded in: \(finished.result ?? "nil")")
        }
        guard finished.headline(at: now) == finished.headline(at: now.addingTimeInterval(604_800))
        else {
            throw SelfTestFailure(
                "a run settled by prose alone measures itself against whoever is reading: "
                    + finished.headline(at: now.addingTimeInterval(604_800)))
        }

        return 26 + marks
    }

    /// Everything the card says about a run's ending, read off the widget rather than off the
    /// vocabulary: the header's mark, every agent row's mark, and the phase rail.
    ///
    /// A run reaching an ending is only half of a mark that stops. The label also has to come off
    /// the frame clock and be left showing the ending's own glyph — otherwise the card keeps
    /// whichever frame of the sweep it was holding when the report landed, which is a still picture
    /// of work still going. Both roads a pane takes are walked here, because the fault lived in the
    /// seam rather than in either end: a stop or a fault is restated into the card already on
    /// screen, while an answer arriving changes the card's shape and earns a rebuild.
    ///
    /// The rows and the rail are walked on the same trip because a header that settled while the
    /// card under it went on sweeping and claiming finished phases is the same lie one view lower.
    /// The agents this is handed are deliberately left claiming to be active, which is exactly what
    /// a fan-out delivers for half an hour after the harness that held it died — a check that
    /// settled them by hand would never once build the shape the fault lives in.
    private static func checkWorkflowCardMark(
        call: ToolCall, live: WorkflowRun, launch: ChatMessage, agents: [SubagentSummary], now: Date
    ) throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let context = TranscriptContext()
        context.liveNow = now
        context.workflowRuns[call.id] = live
        context.expanded.set("wf", open: true)
        var card = WorkflowCardView.make(call, key: "wf", context: context)
        guard WorkflowCardView.markReading(of: card).contains("moving=1") else {
            throw SelfTestFailure(
                "a live card's mark holds still: \(WorkflowCardView.markReading(of: card))")
        }
        let planned = WorkflowCardView.phaseReading(of: card)
        guard planned == rail(live) else {
            throw SelfTestFailure("a live card's rail is not the plan: \(planned)")
        }
        guard WorkflowCardView.agentReading(of: card).contains(":moving") else {
            throw SelfTestFailure(
                "no agent is out on a live card: \(WorkflowCardView.agentReading(of: card))")
        }
        let atLaunch = WorkflowCardView.agentClockReading(of: card)
        guard atLaunch == clocks(of: live, at: now) else {
            throw SelfTestFailure("a live card's row clocks: \(atLaunch)")
        }
        card = try restated(card, call: call, context: context, at: now.addingTimeInterval(9_000))
        let anHourOn = WorkflowCardView.agentClockReading(of: card)
        guard anHourOn == clocks(of: live, at: now.addingTimeInterval(9_000)),
            anHourOn != atLaunch
        else {
            throw SelfTestFailure("a live card's rows stopped counting: \(anHourOn)")
        }
        card = try restated(card, call: call, context: context, at: now)

        var claims = 5
        var rails: [String: String] = [:]
        for status in [BackgroundOutcome.Status.stopped, .failed, .completed] {
            let ended = try reported(
                status, on: call, launch: launch, agents: agents, now: now)
            context.workflowRuns[call.id] = ended
            if !WorkflowCardView.restate(card, call: call, context: context) {
                card = WorkflowCardView.make(call, key: "wf", context: context)
            }
            let reading = WorkflowCardView.markReading(of: card)
            guard reading == "mark=\(ended.activityIcon.glyph) moving=0" else {
                throw SelfTestFailure("a \(status.rawValue) card's mark: \(reading)")
            }
            let rows = WorkflowCardView.agentReading(of: card)
            guard rows == settledRows(of: ended) else {
                throw SelfTestFailure("a \(status.rawValue) card's agent rows: \(rows)")
            }
            let drawn = WorkflowCardView.phaseReading(of: card)
            guard drawn == rail(ended) else {
                throw SelfTestFailure("a \(status.rawValue) card's rail: \(drawn)")
            }
            rails[status.rawValue] = drawn
            let stopped = WorkflowCardView.agentClockReading(of: card)
            guard stopped == clocks(of: ended, at: now) else {
                throw SelfTestFailure("a \(status.rawValue) card's row clocks: \(stopped)")
            }
            card = try restated(
                card, call: call, context: context, at: now.addingTimeInterval(604_800))
            let aWeekOn = WorkflowCardView.agentClockReading(of: card)
            guard aWeekOn == stopped else {
                throw SelfTestFailure(
                    "a \(status.rawValue) card's rows kept counting a week later: \(aWeekOn)")
            }
            card = try restated(card, call: call, context: context, at: now)
            claims += 5
        }
        guard rails["stopped"] != rails["completed"], rails["failed"] != rails["completed"],
            rails["stopped"] != planned
        else {
            throw SelfTestFailure(
                "a killed run's rail reads as a finished one: \(rails["stopped"] ?? "none")")
        }
        return claims + 1
    }

    /// The rail this run may honestly draw, spelled the way the widget spells it, from the standing
    /// the vocabulary hands back rather than from a second reading of the run invented here.
    private static func rail(_ run: WorkflowRun) -> String {
        let standing = run.phaseStanding
        return "phases="
            + run.phases.map { _ in "\(standing.glyph):\(standing.css)" }.joined(separator: ",")
    }

    /// The card moved on to another moment, by whichever road it would take in the app: restated in
    /// place while its shape holds, rebuilt when it no longer does. Reading a clock at a second
    /// moment is the only way to catch one that grows, and a check that only ever read the card at
    /// the instant it was built would never once ask the question.
    private static func restated(
        _ card: UnsafeMutablePointer<GtkWidget>, call: ToolCall, context: TranscriptContext,
        at now: Date
    ) throws -> UnsafeMutablePointer<GtkWidget> {
        context.liveNow = now
        if WorkflowCardView.restate(card, call: call, context: context) { return card }
        return WorkflowCardView.make(call, key: "wf", context: context)
    }

    /// The clock every row of this run may honestly show at that moment, spelled the way the widget
    /// spells it, from the vocabulary that decides it rather than from a second reading of the run
    /// invented here.
    private static func clocks(of run: WorkflowRun, at now: Date) -> String {
        "clocks="
            + run.agents.map { $0.elapsed(at: now, in: run).map(WorkflowRun.duration) ?? "" }
            .joined(separator: ",")
    }

    /// Every agent row of an ended run, which is every row holding perfectly still: the one that
    /// reported finishing keeps its tick and the ones the harness died holding wear the ended mark,
    /// whatever their own records still claim.
    private static func settledRows(of run: WorkflowRun) -> String {
        "agents="
            + run.agents.map { "\(ActivityIcon.workflowAgent($0, in: run).glyph):still" }
            .joined(separator: ",")
    }

    /// The same launch, ended the way the harness ends one: its report seated back on the call that
    /// started it. This is the only road a real backend delivers an ending on — the prose road
    /// above survives for a server that says less — so it is the one an ending has to be proved
    /// against, or a card can be shipped that never stops moving on the only backend that has
    /// workflows.
    private static func reported(
        _ status: BackgroundOutcome.Status, on call: ToolCall, launch: ChatMessage,
        agents: [SubagentSummary], now: Date
    ) throws -> WorkflowRun {
        var ended = call
        ended.status = .completed
        ended.background = BackgroundOutcome(
            taskID: "task-1", status: status, summary: "the run ended",
            result: status == .completed ? "# The answer" : nil,
            reportedAt: now.addingTimeInterval(120))
        let message = ChatMessage(
            id: launch.id, role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(ended))], createdAt: launch.createdAt)
        let runs = WorkflowRunAssembly.runs(messages: [message], agents: agents)
        guard let run = runs.first, runs.count == 1 else {
            throw SelfTestFailure("one ended launch is not one run")
        }
        return run
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
