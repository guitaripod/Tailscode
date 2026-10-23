import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The composer's vim mode, driven the way a person drives it: a starting buffer, a string
    /// of keys, and the text that must come out — plus the pending-command flag the key monitor
    /// leans on to keep `3x` and `diw` landing mid-command.
    static func checkVim() throws -> Int {
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
    static func checkStores() throws {
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

    /// Type size is per area: making the agent's answers bigger moves the answers and nothing
    /// else, what you type has a size of its own, the terminal is sized by nothing but itself, and a size put back to normal is the size
    /// the window started at. The person's own sizes are restored when the check is done.
    static func checkTypeAreas() throws {
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("type case failed: \(label)") }
        }
        let kept = TypeScaleStore.current()
        defer { TypeScaleStore.set(kept) }
        TypeScaleStore.set(TypeScale())
        let answer = MacTheme.Ramp.font(.answer).pointSize
        let row = MacTheme.Ramp.font(.rowTitle).pointSize
        let code = MacTheme.Ramp.font(.code).pointSize
        let shell = MacTheme.Ramp.font(.code, in: .terminal).pointSize
        try expect(shell == code, "an untouched terminal is sized like the code above it")

        let prompt = MacTheme.Ramp.font(.prompt).pointSize
        TypeScaleStore.set(.answer, to: 1.5)
        let grown = MacTheme.Ramp.font(.answer).pointSize
        try expect(abs(grown - answer * 1.5) < 0.01, "answers at 150% are \(grown)pt, not \(answer * 1.5)pt")
        try expect(MacTheme.Ramp.font(.prompt).pointSize == prompt, "your messages moved with the agent's")
        try expect(MacTheme.Ramp.font(.rowTitle).pointSize == row, "the chat list moved with the answers")
        try expect(MacTheme.Ramp.font(.code).pointSize == code, "code moved with the answers")

        func markdownSize() -> CGFloat {
            MacMarkdown.invalidate()
            let font = MacMarkdown.render("An answer.").attribute(.font, at: 0, effectiveRange: nil)
            return (font as? NSFont)?.pointSize ?? 0
        }
        TypeScaleStore.set(.answer, to: 1.0)
        let written = markdownSize()
        TypeScaleStore.set(.answer, to: 1.5)
        try expect(
            abs(markdownSize() - written * 1.5) < 0.01,
            "a written answer did not follow the agent-responses size")

        TypeScaleStore.set(.prompt, to: 1.25)
        try expect(
            abs(MacTheme.Ramp.font(.prompt).pointSize - prompt * 1.25) < 0.01,
            "your messages did not follow their own size")
        try expect(abs(MacTheme.Ramp.font(.answer).pointSize - grown) < 0.01, "answers moved with your messages")

        TypeScaleStore.set(.terminal, to: 2.0)
        try expect(
            abs(MacTheme.Ramp.font(.code, in: .terminal).pointSize - shell * 2) < 0.01,
            "the terminal did not follow its own size")
        try expect(MacTheme.Ramp.font(.code).pointSize == code, "code moved with the terminal")

        TypeScaleStore.set(TypeScale())
        try expect(MacTheme.Ramp.font(.answer).pointSize == answer, "normal is not where it began")
    }

    /// A toast is a sentence in a capsule, not a pill: the width it asks for must be the width of
    /// the sentence, because a wrapping label left to Auto Layout collapses to nothing and every
    /// confirmation in the app becomes a blank circle.
    static func checkToastWidth() throws {
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("toast case failed: \(label)") }
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let sentence = "Pin a model and level with ⌃S in the model dial"
        let label = NSTextField(wrappingLabelWithString: sentence)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let wanted = label.attributedStringValue.size().width
        let asked = ToastPresenter.width(of: label, in: host)
        try expect(asked >= wanted - 1, "a sentence \(wanted)pt long was given \(asked)pt")
        try expect(asked < host.bounds.width, "a sentence was given more than the pane has")
        let long = String(repeating: "word ", count: 120)
        label.stringValue = long
        let capped = ToastPresenter.width(of: label, in: host)
        try expect(capped < host.bounds.width, "a long sentence was not held to the pane")
    }

    /// A picture must come back byte-identical, keyed to its server file — and two different
    /// files must never collide into one cache slot.
    static func checkImageStore() throws {
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
    static func checkTwoObservers(_ profiles: [ConnectionProfile]) async throws -> Int {
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
}
