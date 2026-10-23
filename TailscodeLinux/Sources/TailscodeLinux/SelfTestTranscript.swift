import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    static func checkVim() throws -> Int {
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
    static func checkVimRouting() throws -> Int {
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
    static func checkInterruption() throws -> Int {
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
            case .userText("keep going", messageID: "m") = rows[1].kind
        else {
            throw SelfTestFailure("interruption rows wrong: \(rows.map(\.kind))")
        }
        return cases.count + 1
    }

    /// A note is a fact the server wrote for the reader, never a message: this proves it reads the
    /// right sentence and face for a model switch (with the name this client already shows, not
    /// the bare id) and for the demo's own background-command line, that it is never mistaken for
    /// answer text, and that it folds into exactly one quiet, unpromoted, searchable row.
    static func checkTranscriptNotes() throws -> Int {
        let openAI = ModelSelection(providerID: "openai", modelID: "gpt-5.1-codex")
        let anthropic = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
        let names: [ModelSelection: String] = [openAI: "GPT-5.1 Codex", anthropic: "Sonnet 5"]
        let modelNote = TranscriptNote(
            .model(openAI, effort: "high", previous: anthropic))
        let line = TranscriptNoteReading.read(modelNote) { names[$0] }
        guard line.text == "Switched from Sonnet 5 to GPT-5.1 Codex at high effort" else {
            throw SelfTestFailure("a model switch names both models: \(line.text)")
        }
        guard line.tone == .quiet, !line.glyph.isEmpty, !line.symbol.isEmpty else {
            throw SelfTestFailure("a model switch is quiet, not an alarm")
        }
        guard line.spoken == Localized.text("Note: %@", line.text) else {
            throw SelfTestFailure("a note tells a screen reader it is a note: \(line.spoken)")
        }

        let message = ChatMessage(
            id: "note-msg", role: .system, agentType: .openCode,
            parts: [MessagePart(id: "note", kind: .note(modelNote))], createdAt: Date())
        guard TranscriptNoteReading.note(in: message) == modelNote else {
            throw SelfTestFailure("a system message carrying a note part reads back as one")
        }
        guard message.parts.first?.text == nil else {
            throw SelfTestFailure("a note is never answer text")
        }

        let bareRows = TranscriptRow.rows(for: message)
        guard bareRows.count == 1, case .note(let bareLine) = bareRows[0].kind,
            bareLine.text.contains("gpt-5.1-codex")
        else {
            throw SelfTestFailure("with no catalog a note falls back to the model's own id")
        }
        guard !bareRows[0].isPromptBlock else {
            throw SelfTestFailure("a note never rises to the top with the prompt")
        }

        let namedRows = TranscriptRow.rows(for: message, modelName: { names[$0] })
        guard case .note(let namedLine) = namedRows.first?.kind,
            namedLine.text.contains("GPT-5.1 Codex")
        else {
            throw SelfTestFailure("the row builder resolves a note's model name from its catalog")
        }
        guard namedRows[0].searchText.contains("GPT-5.1 Codex") else {
            throw SelfTestFailure("a note is still searchable")
        }

        let finished = TranscriptNote(
            .workFinished(
                "go test ./internal/auth/...", work: .command, outcome: .completed))
        let finishedLine = TranscriptNoteReading.read(finished)
        guard finishedLine.text == "Background command finished: go test ./internal/auth/..." else {
            throw SelfTestFailure("a finished background command names itself: \(finishedLine.text)")
        }
        guard finishedLine.tone == .quiet else {
            throw SelfTestFailure("a command that finished cleanly is quiet")
        }

        let restarted = TranscriptNoteReading.read(TranscriptNote(.resumedAfterRestart))
        guard restarted.tone == .attention else {
            throw SelfTestFailure("a restart nobody asked for is worth attention")
        }

        return 8
    }

    /// The retry card cannot be produced by the demo (nothing here is actually rate-limited), so
    /// its whole contract is proved from a `TurnRetry` built by hand: the words, the countdown that
    /// wakes once at the exact moment they next change rather than every second, the remedy's own
    /// link, and that `.retrying` reads like every other in-flight state.
    static func checkProviderRetryCard() throws -> Int {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        guard ProviderRetryReading.read(nil) == nil else {
            throw SelfTestFailure("nothing standing reads as nothing")
        }
        let remedy = TurnRetry.Remedy(
            title: "Raise your rate limit", message: "This account is on the free tier.",
            label: "Open billing", link: "https://example.com/billing")
        let retry = TurnRetry(
            attempt: 3, reason: "Rate limited by the provider.",
            nextAttemptAt: now.addingTimeInterval(75), remedy: remedy)
        guard let card = ProviderRetryReading.read(retry, now: now) else {
            throw SelfTestFailure("a standing retry always reads into a card")
        }
        guard card.reason == "Rate limited by the provider." else {
            throw SelfTestFailure("the provider's own words lead the card")
        }
        guard card.attemptLine.contains("3"), card.attemptLine.contains("1 min") else {
            throw SelfTestFailure("the attempt line names the attempt and the wait: \(card.attemptLine)")
        }
        guard card.remedy?.label == "Open billing", card.remedy?.link?.absoluteString.isEmpty == false
        else {
            throw SelfTestFailure("a remedy carries its own link")
        }
        guard let next = ProviderRetryReading.nextChange(retry, now: now), next > now,
            next.timeIntervalSince(now) <= 2
        else {
            throw SelfTestFailure("the clock wakes at the next tick, not every second and not late")
        }
        let stillNever = TurnRetry(attempt: 1, reason: "waiting", nextAttemptAt: nil)
        guard ProviderRetryReading.nextChange(stillNever, now: now) == nil else {
            throw SelfTestFailure("a retry with no next attempt arms no timer")
        }
        guard ActivityKind.retrying(attempt: 3).icon.tone == .attention,
            ActivityKind.retrying(attempt: 3).icon.motion == .turning
        else {
            throw SelfTestFailure("a retrying turn reads like the other in-flight states")
        }

        let row = TranscriptRow(key: "retry:card", kind: .providerRetry(card))
        guard row.searchText.contains("Rate limited") else {
            throw SelfTestFailure("a retry card is searchable")
        }
        if gtk_init_check() != 0 {
            _ = row.makeWidget(context: TranscriptContext())
        }
        return 6
    }

    /// The revert banner's words, its "more files" line past the room it is given, and the
    /// restoring state this device wears on the button while its own press is on the wire, none
    /// of which the demo's own two-file undo ever exercises.
    static func checkRevertBanner() throws -> Int {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let files = (0..<9).map {
            SessionRevert.File(
                path: "internal/pkg\($0)/file.go", change: .modified, additions: $0 + 1,
                deletions: $0)
        }
        let revert = SessionRevert(messageID: "u2", files: files)
        let setAside = [
            ChatMessage(
                id: "u2", role: .user, agentType: .openCode,
                parts: [
                    MessagePart(
                        id: "t",
                        kind: .text("Refactor the auth module to async/await and add a test."))
                ], createdAt: now),
            ChatMessage(
                id: "a2", role: .assistant, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("On it."))], createdAt: now),
        ]
        guard let banner = RevertReading.read(revert, setAside: setAside) else {
            throw SelfTestFailure("a standing revert always reads into a banner")
        }
        guard banner.title == Localized.text("Wound back one message") else {
            throw SelfTestFailure("the title counts the prompts set aside: \(banner.title)")
        }
        guard banner.detail.contains("back as they were") else {
            throw SelfTestFailure("the detail names what happened to the files: \(banner.detail)")
        }
        let (shown, more) = banner.files(upTo: 6)
        guard shown.count == 6, more == Localized.text("%@ more files", "3") else {
            throw SelfTestFailure(
                "nine files past a limit of six show six and count three more: \(shown.count) shown, more=\(more ?? "nil")"
            )
        }
        guard
            RevertReading.prompt(in: setAside)
                == "Refactor the auth module to async/await and add a test."
        else {
            throw SelfTestFailure("the composer refill is the exact words wound back to")
        }
        let capabilities = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: true,
            supportsAttachments: true, supportsRevert: true)
        guard RevertReading.offersUndo(on: setAside[0], capabilities: capabilities) else {
            throw SelfTestFailure("a user message on a server that can revert offers undo")
        }
        guard !RevertReading.offersUndo(on: setAside[1], capabilities: capabilities) else {
            throw SelfTestFailure("an assistant message never offers undo")
        }

        let resting = TranscriptRow(key: "revert:u2", kind: .revertBanner(banner, restoring: false))
        let restoring = TranscriptRow(
            key: "revert:u2:restoring", kind: .revertBanner(banner, restoring: true))
        guard resting != restoring else {
            throw SelfTestFailure("a press in flight is a different row, so it redraws")
        }
        guard resting.searchText.contains("Wound back") else {
            throw SelfTestFailure("a revert banner is searchable")
        }
        if gtk_init_check() != 0 {
            _ = resting.makeWidget(context: TranscriptContext())
            _ = restoring.makeWidget(context: TranscriptContext())
        }
        return 7
    }

    /// Moving rows around a box must not free the ones that stay. The Software Updates window
    /// re-ordered its cards whenever a machine changed rank, by emptying the box and appending the
    /// same widgets again — the box held their only reference, so each card was freed on the way
    /// out and the next answer wrote into a dead label. Watched through weak pointers, so the
    /// claim is read without ever touching a widget that might be gone.
    static func checkReplaceChildren() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        g_object_ref_sink(UnsafeMutableRawPointer(box))
        defer { g_object_unref(UnsafeMutableRawPointer(box)) }
        let first = Gtk.label("first", selectable: false)
        let second = Gtk.label("second", selectable: false)
        gtk_box_append(ptr(box), first)
        gtk_box_append(ptr(box), second)

        let watches = UnsafeMutablePointer<gpointer?>.allocate(capacity: 2)
        defer { watches.deallocate() }
        watches[0] = UnsafeMutableRawPointer(first)
        watches[1] = UnsafeMutableRawPointer(second)
        g_object_add_weak_pointer(ptr(first), watches)
        g_object_add_weak_pointer(ptr(second), watches + 1)
        defer {
            if let alive = watches[0] { g_object_remove_weak_pointer(ptr(alive), watches) }
            if let alive = watches[1] { g_object_remove_weak_pointer(ptr(alive), watches + 1) }
        }

        Gtk.replaceChildren(of: box, with: [second, first])
        guard watches[0] != nil, watches[1] != nil else {
            throw SelfTestFailure("a row moved within its box is still alive afterwards")
        }
        guard gtk_widget_get_first_child(box) == second, gtk_widget_get_last_child(box) == first
        else {
            throw SelfTestFailure("the rows stand in the order asked for")
        }
        gtk_label_set_text(op(first), "drawn into after the move")

        Gtk.replaceChildren(of: box, with: [second])
        guard watches[0] == nil else {
            throw SelfTestFailure("a row left out is released rather than leaked")
        }
        guard watches[1] != nil, gtk_widget_get_first_child(box) == second else {
            throw SelfTestFailure("the row kept is still the box's only row")
        }
        return 4
    }
}
