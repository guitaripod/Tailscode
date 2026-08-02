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
    public static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

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
            let checks = try checkInterruption()
            report("interruption: \(checks) marker shapes")
        } catch {
            report("interruption: \(error)")
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
            try checkSettingsFile()
            report("settings file: survives a reinstall")
        } catch {
            report("settings file: \(error)")
            failures += 1
        }

        do {
            try checkPalettes()
            report("palettes: solarized light and rosé pine both style every slot")
        } catch {
            report("palettes: \(error)")
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
                // A conversation with words in it makes the stronger two-observer subject; an
                // empty one only stands in when every server's newest chat is empty.
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
        return checked
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

    /// Both appearances, checked as data: every slot a real color, the stylesheet actually
    /// carrying it, and the markup cache returning palette-true renderings — a stale cache would
    /// paint light-mode prose in dark-mode colors, which no compiler catches.
    private static func checkPalettes() throws {
        for palette in [Palette.rosePine, .solarizedLight] {
            let slots = [
                palette.canvas, palette.canvasRaised, palette.rule, palette.text,
                palette.textDim, palette.accent, palette.accentDim, palette.warn,
                palette.danger, palette.info, palette.special, palette.codeBg,
                palette.subagentBg, palette.findHit, palette.onAccent,
            ]
            for slot in slots {
                guard slot.hasPrefix("#"), slot.count == 7,
                    slot.dropFirst().allSatisfy(\.isHexDigit)
                else { throw SelfTestFailure("\(palette.name): \(slot) is not a color") }
            }
            let css = MatrixTheme.css(for: palette)
            guard css.contains(palette.canvas), css.contains(palette.accent),
                css.contains(palette.findHit), !css.contains("Optional(")
            else { throw SelfTestFailure("\(palette.name): css does not carry the palette") }
        }
        let sample = "**bold** and `code` and *soft*"
        func render(_ palette: Palette) -> String {
            PangoMarkdown.render(
                sample, dim: palette.textDim, code: palette.info, accent: palette.accent)
        }
        let first = render(.rosePine)
        let again = render(.rosePine)
        let light = render(.solarizedLight)
        guard first == again, first != light, light.contains(Palette.solarizedLight.info) else {
            throw SelfTestFailure("markup cache does not respect the palette")
        }
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
    /// reads, so what is asserted here is mostly what is *absent*.
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
        // Compact by default: the band counts, the popover names.
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

        // The goal is a glyph until it is asked about — its words live in the popover.
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

        // Twenty agents spawned with one preamble must not read as twenty copies of the preamble.
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
