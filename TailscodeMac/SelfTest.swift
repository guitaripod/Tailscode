import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `TailscodeMac --selftest` drives the whole chain with no window: the markdown renderer, the
/// slash completion, the shared shortcut registry, the composer's vim mode and the local stores
/// first — pure logic a headless box checks perfectly well — then every configured server's
/// health, its session list, and the newest session's stream until a transcript lands.
///
/// A Mac reached over ssh has no window server, so a screenshot cannot prove the app works from a
/// build loop. This can.
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() async -> Never {
        startWatchdog()
        var failures = 0

        do {
            let checks = try checkMarkup()
            report("markup: \(checks) shapes render")
        } catch {
            report("markup: \(error)")
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
            let checks = try checkVim()
            report("vim: \(checks) commands behave")
        } catch {
            report("vim: \(error)")
            failures += 1
        }

        do {
            try checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        do {
            try checkImageStore()
            report("image store: pictures round-trip and stay keyed to their file")
        } catch {
            report("image store: \(error)")
            failures += 1
        }

        let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
        if shellOutput.contains("tailscode-shell-ok") {
            report("shell: ok (one command at a time in a login shell)")
        } else {
            report("shell: no output")
            failures += 1
        }

        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report(
                    "\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = sessions.first else { continue }
                let state = try await firstState(of: newest, on: backend)
                report(
                    "  \(newest.title): \(state.messages.count) messages · \(state.connection)")
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }
        do {
            let count = try await checkTwoObservers(profiles)
            report("two observers: agree on \(count) messages")
        } catch {
            report("two observers: \(error)")
            failures += 1
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// The transcript's markdown, checked as attributes rather than as pixels: emphasis must
    /// carry its trait, code its monospace, a link its URL — and arithmetic, snake_case and
    /// asterisks inside code spans must survive untouched, which is the failure a renderer grows
    /// quietly.
    private static func checkMarkup() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("markup case failed: \(label)") }
            checks += 1
        }
        func attributes(
            in rendered: NSAttributedString, over needle: String
        ) -> [NSAttributedString.Key: Any]? {
            let range = (rendered.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return rendered.attributes(at: range.location, effectiveRange: nil)
        }
        func font(_ attributes: [NSAttributedString.Key: Any]?) -> NSFont? {
            attributes?[.font] as? NSFont
        }
        func weight(_ font: NSFont?) -> CGFloat {
            let traits =
                font?.fontDescriptor.object(forKey: .traits)
                as? [NSFontDescriptor.TraitKey: Any]
            return traits?[.weight] as? CGFloat ?? 0
        }
        func hasItalic(_ rendered: NSAttributedString) -> Bool {
            var found = false
            rendered.enumerateAttribute(
                .font, in: NSRange(location: 0, length: rendered.length)
            ) { value, _, _ in
                if let font = value as? NSFont,
                    font.fontDescriptor.symbolicTraits.contains(.italic)
                {
                    found = true
                }
            }
            return found
        }

        let bold = MacMarkdown.render("**bold** here")
        try expect(
            weight(font(attributes(in: bold, over: "bold")))
                > weight(font(attributes(in: bold, over: "here"))),
            "bold carries more weight than its neighbours")
        try expect(!bold.string.contains("*"), "the asterisks are consumed")

        let italic = MacMarkdown.render("some *italic* text")
        try expect(
            font(attributes(in: italic, over: "italic"))?.fontDescriptor.symbolicTraits
                .contains(.italic) == true, "italic carries the trait")
        try expect(!italic.string.contains("*"), "the emphasis marks are consumed")

        let arithmetic = MacMarkdown.render("2 * 3 * 4 = 24")
        try expect(
            !hasItalic(arithmetic) && arithmetic.string.contains("2 * 3 * 4 = 24"),
            "arithmetic never italicizes")
        let snake = MacMarkdown.render("snake_case and more_snake here")
        try expect(
            !hasItalic(snake) && snake.string.contains("snake_case"),
            "intra-word underscores stay literal")

        let code = MacMarkdown.render("a `snippet` inline")
        try expect(
            font(attributes(in: code, over: "snippet"))?.fontDescriptor.symbolicTraits
                .contains(.monoSpace) == true, "a code span renders monospaced")
        try expect(!code.string.contains("`"), "the backticks are consumed")
        let codeStars = MacMarkdown.render("`a * b` times `c * d`")
        try expect(
            !hasItalic(codeStars) && codeStars.string.contains("a * b"),
            "asterisks inside code stay code")
        let codeUnderscore = MacMarkdown.render("`gtk_box_append` per row")
        try expect(
            !hasItalic(codeUnderscore) && codeUnderscore.string.contains("gtk_box_append"),
            "underscores inside code stay code")

        let heading = MacMarkdown.render("## Heading")
        let headingFont = font(attributes(in: heading, over: "Heading"))
        let bodyFont = font(attributes(in: MacMarkdown.render("plain words"), over: "plain"))
        try expect(
            (headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? .greatestFiniteMagnitude)
                && weight(headingFont) > weight(bodyFont),
            "a heading is larger and heavier than body text")

        let link = MacMarkdown.render("[docs](https://x.dev)")
        try expect(
            (attributes(in: link, over: "docs")?[.link] as? URL)?.absoluteString
                == "https://x.dev", "a link carries its URL")
        try expect(!link.string.contains("]("), "the link markup is consumed")
        return checks
    }

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
    /// unbinds and reports nonsense — the same cases the Linux desktop asserts, because the
    /// registry is the same table.
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

    /// The composer's vim mode, driven the way a person drives it: a starting buffer, a string
    /// of keys, and the text that must come out — plus the pending-command flag the key monitor
    /// leans on to keep `3x` and `diw` landing mid-command.
    private static func checkVim() throws -> Int {
        let cases: [(text: String, keys: String, expected: String, label: String)] = [
            ("hello world", "dw", "world", "dw"),
            ("hello world", "x", "ello world", "x"),
            ("hello world", "wciwthere", "hello there", "ciw"),
            ("say \"a thing\" now", "f\"ci\"other", "say \"other\" now", "ci\""),
            ("call(one, two)", "f(di(", "call()", "di("),
            ("alpha\nbeta\ngamma", "jdd", "alpha\ngamma", "dd"),
            ("alpha\nbeta", "yyp", "alpha\nalpha\nbeta", "yy then p"),
            ("alpha beta", "vlld", "ha beta", "visual delete"),
            ("alpha", "A!", "alpha!", "A"),
            ("alpha", "ohi", "alpha\nhi", "o"),
            ("one two three", "d2w", "three", "count with operator"),
            ("indent", ">>", "    indent", ">>"),
            ("alpha", "xu", "alpha", "undo"),
            ("one\ntwo", "J", "one two", "J"),
            ("first\nsecond", "Vd", "second", "visual-line delete"),
            ("hello", "$x", "hell", "$x"),
            ("one, two", "dt,", ", two", "dt"),
            ("hello", "ggx", "ello", "gg"),
        ]
        var checked = 0
        for testCase in cases {
            let engine = VimEngine()
            engine.reset(to: testCase.text, cursor: 0, mode: .normal)
            var text = testCase.text
            var cursor = 0
            for character in testCase.keys {
                let outcome = engine.handle(
                    VimKey(character: character), text: text, cursor: cursor)
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
                    "\(testCase.label): expected \(testCase.expected.debugDescription), got \(text.debugDescription)"
                )
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

    /// The local stores, exercised with probe identities and put back exactly as found: every
    /// toggle is its own inverse, so a self-test run leaves the user's saved, archived and seen
    /// state untouched. The stores speak to the real defaults — they accept no scratch suite —
    /// which is precisely why the round trip must net to zero.
    private static func checkStores() throws {
        let probeProfile = "selftest-\(UUID().uuidString)"
        let probeSession = "selftest-\(UUID().uuidString)"

        guard ArchivedChatStore.toggle(profileID: probeProfile, sessionID: probeSession) else {
            throw SelfTestFailure("archiving reported the wrong direction")
        }
        guard ArchivedChatStore.contains(profileID: probeProfile, sessionID: probeSession) else {
            throw SelfTestFailure("an archived chat did not round-trip")
        }
        guard !ArchivedChatStore.toggle(profileID: probeProfile, sessionID: probeSession),
            !ArchivedChatStore.contains(profileID: probeProfile, sessionID: probeSession)
        else { throw SelfTestFailure("an archived chat survived its unarchive") }

        let session = AgentSession(
            id: probeSession, agentType: .claudeCode, title: "selftest probe",
            directory: "/tmp/selftest", createdAt: Date(), updatedAt: Date())
        let entry = SessionEntry(
            profileID: probeProfile, profileName: "probe", host: "probe",
            backendType: .claudeCode, session: session)
        guard SavedChatStore.toggle(entry), SavedChatStore.contains(entry) else {
            throw SelfTestFailure("a saved chat did not round-trip")
        }
        guard
            let saved = SavedChatStore.all().first(where: { $0.sessionID == probeSession }),
            saved.title == "selftest probe", saved.directory == "/tmp/selftest",
            saved.backend == .claudeCode
        else { throw SelfTestFailure("the bookmark lost its snapshot") }
        guard !SavedChatStore.toggle(entry), !SavedChatStore.contains(entry) else {
            throw SelfTestFailure("a saved chat survived its unsave")
        }

        let updatedAt = Date()
        SessionSeenStore.markUnread(probeSession, updatedAt: updatedAt)
        guard SessionSeenStore.unreadEvaluator()(probeSession, updatedAt) else {
            throw SelfTestFailure("marking unread did not badge the row")
        }
        SessionSeenStore.markSeen(probeSession)
        guard !SessionSeenStore.unreadEvaluator()(probeSession, updatedAt) else {
            throw SelfTestFailure("marking seen did not clear the badge")
        }
        let defaults = UserDefaults.standard
        if var seen = defaults.dictionary(forKey: "tailscode.seen.sessions") as? [String: Double] {
            seen[probeSession] = nil
            defaults.set(seen, forKey: "tailscode.seen.sessions")
        }
    }

    /// A picture must come back byte-identical, keyed to its server file — and two different
    /// files must never collide into one cache slot.
    private static func checkImageStore() throws {
        let scratch = "/tmp/tailscode-selftest-\(UUID().uuidString)"
        let first = FileReference(path: "\(scratch)/a.png", mime: "image/png", filename: "a.png")
        let second = FileReference(path: "\(scratch)/b.png", mime: "image/png", filename: "b.png")
        guard let one = ImageDisk.identity(for: first),
            let two = ImageDisk.identity(for: second), one != two
        else { throw SelfTestFailure("two files share one identity") }
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        ImageDisk.save(bytes, for: first)
        guard ImageDisk.load(first) == bytes else {
            throw SelfTestFailure("bytes did not round-trip")
        }
        guard ImageDisk.load(second) == nil else {
            throw SelfTestFailure("an unsaved file loaded")
        }
        guard ImageDisk.identity(for: FileReference()) == nil else {
            throw SelfTestFailure("an unidentifiable file got an identity")
        }
    }

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    private static func checkTwoObservers(_ profiles: [ConnectionProfile]) async throws -> Int {
        guard let profile = profiles.first,
            let backend = ServerDirectory.shared.backend(for: profile),
            let session = try await backend.listSessions().max(by: { $0.updatedAt < $1.updatedAt })
        else { throw SelfTestFailure("nothing to observe") }

        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        async let first = settled(conversation)
        async let second = settled(conversation)
        let (a, b) = try await (first, second)

        guard !a.isEmpty else { throw SelfTestFailure("first observer saw nothing") }
        guard a == b else {
            throw SelfTestFailure("observers diverged: \(a.count) vs \(b.count) messages")
        }
        return a.count
    }

    private static func settled(_ conversation: AgentConversation) async throws -> [String] {
        let deadline = Date().addingTimeInterval(20)
        for await state in await conversation.states() {
            if state.hasLoadedTranscript { return state.messages.map(\.id) }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("observer never loaded a transcript")
    }

    /// The first snapshot that has actually loaded a transcript, or whatever arrived within the
    /// deadline — a stream that never delivers is the failure this is looking for.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        var latest = ConversationState()
        let deadline = Date().addingTimeInterval(15)
        for await state in await conversation.states() {
            latest = state
            if state.hasLoadedTranscript || Date() > deadline { break }
        }
        return latest
    }

    /// A self-test that hangs is worse than one that fails: it stalls the build loop on a machine
    /// nobody is looking at.
    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
