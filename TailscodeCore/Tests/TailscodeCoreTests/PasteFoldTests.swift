import Foundation
import Testing

@testable import TailscodeCore

@Suite("Paste fold")
struct PasteFoldTests {
    private let able = ModelAbilities(attachments: true, vision: true)

    private static func lines(_ count: Int, _ word: String = "line") -> String {
        (1...count).map { "\(word) \($0)" }.joined(separator: "\n")
    }

    @Test("A short paste stays words; a long one folds, by lines or by length")
    func threshold() {
        #expect(!PasteFold.folds("a few words"))
        #expect(!PasteFold.folds(Self.lines(PasteFold.lineLimit)))
        #expect(!PasteFold.folds(Self.lines(PasteFold.lineLimit) + "\n"))
        #expect(PasteFold.folds(Self.lines(PasteFold.lineLimit + 1)))
        #expect(!PasteFold.folds(String(repeating: "x", count: PasteFold.characterLimit)))
        #expect(PasteFold.folds(String(repeating: "x", count: PasteFold.characterLimit + 1)))
    }

    @Test("Intake folds only for a composer that asked, and an overlong paste is still a file")
    func intake() {
        let long = Self.lines(40)
        let folded = PasteIntake.plan(for: ClipboardOffer(text: long), abilities: able, folding: true)
        #expect(folded.fold?.text == long)
        #expect(folded.text == nil)
        #expect(folded.attachments.isEmpty)
        #expect(!folded.isEmpty)
        let plain = PasteIntake.plan(for: ClipboardOffer(text: long), abilities: able)
        #expect(plain.text == long)
        #expect(plain.fold == nil)
        let short = PasteIntake.plan(
            for: ClipboardOffer(text: "short"), abilities: able, folding: true)
        #expect(short.text == "short")
        #expect(short.fold == nil)
        let overlong = Self.lines(PasteIntake.inlineLineLimit + 1)
        let file = PasteIntake.plan(
            for: ClipboardOffer(text: overlong), abilities: able, folding: true)
        #expect(file.attachments.count == 1)
        #expect(file.fold == nil)
        let wordsOnly = PasteIntake.plan(
            for: ClipboardOffer(text: overlong), abilities: .words, folding: true)
        #expect(wordsOnly.fold?.text == overlong)
        #expect(wordsOnly.attachments.isEmpty)
    }

    @Test("A fold says how long it is and what it starts with")
    func reading() {
        let paste = FoldedPaste(text: "\n   \n  Traceback (most recent call last):\n" + Self.lines(30) + "\n")
        #expect(paste.lines == 33)
        #expect(paste.glimpse == "Traceback (most recent call last):")
        #expect(paste.label.contains("33"))
        let wide = FoldedPaste(text: String(repeating: "y", count: 2_000))
        #expect(wide.lines == 1)
        #expect(wide.size.contains("2000"))
        #expect(wide.glimpse.count == PasteFold.glimpseLength + 1)
        #expect(wide.glimpse.hasSuffix("…"))
        #expect(FoldedPaste(text: "").lines == 0)
    }

    @Test("The words lead and each block follows, so the first line is still the person's")
    func wrap() {
        let first = FoldedPaste(text: "alpha\nbeta")
        let second = FoldedPaste(text: "gamma")
        let sent = PasteFold.wrap("  what is wrong here?\n", pastes: [first, second])
        #expect(
            sent == "what is wrong here?\n\n<pasted-text>\nalpha\nbeta\n</pasted-text>\n\n"
                + "<pasted-text>\ngamma\n</pasted-text>")
        #expect(PasteFold.wrap("words", pastes: []) == "words")
        #expect(PasteFold.wrap("", pastes: [second]) == "<pasted-text>\ngamma\n</pasted-text>")
    }

    @Test("A sent message reads back as the words and its folds, in order, with stable ids")
    func split() {
        let paste = Self.lines(20)
        let sent = PasteFold.wrap("fix this", pastes: [FoldedPaste(text: paste)])
        let reading = PasteFold.split(sent, id: "m1:p0")
        #expect(reading.isFolded)
        #expect(reading.words == "fix this")
        #expect(reading.pastes.map(\.text) == [paste])
        #expect(reading.pastes.first?.id == "m1:p0:0")
        #expect(PasteFold.split(sent, id: "m1:p0") == reading)
        #expect(reading.plain == "fix this\n\n" + paste)
        #expect(reading.glance.hasPrefix("fix this [Pasted"))

        let around = "before\n<pasted-text>\none\n</pasted-text>\nafter"
        let pieces = PasteFold.split(around).pieces
        #expect(pieces.count == 3)
        #expect(pieces.first == .words("before"))
        #expect(pieces.last == .words("after"))
    }

    @Test("Text without a block, or with a broken or inline one, stays words")
    func notBlocks() {
        for text in [
            "plain words",
            "mentions <pasted-text> in a sentence </pasted-text>",
            "<pasted-text>\nnever closed",
            "<pasted-text>no newline\n</pasted-text>",
            "<pasted-textual>\nx\n</pasted-text>",
            "<pasted-text>\nx\n</pasted-text> trailing",
        ] {
            let reading = PasteFold.split(text)
            #expect(!reading.isFolded, "\(text)")
            #expect(PasteFold.plain(text) == text)
            #expect(PasteFold.glance(text) == text)
        }
        #expect(!PasteFold.mayHold(""))
    }

    @Test("A paste that holds the closing tag itself comes back exactly as pasted")
    func escaping() {
        for body in [
            "a\n</pasted-text>\nb",
            "<\\/pasted-text>",
            "<\\\\/pasted-text> and </pasted-text>",
            "<pasted-text>\nnested\n</pasted-text>",
            "ends with a carriage return\r",
            "crlf\r\nlines\r\n",
            "",
            "\n\n",
        ] {
            let sent = PasteFold.wrap("w", pastes: [FoldedPaste(text: body)])
            let back = PasteFold.split(sent).pastes
            #expect(back.map(\.text) == [body], "\(body.debugDescription)")
        }
    }

    @Test("A kept draft hands back the same box: its exact keystrokes and its folds")
    func draft() {
        let pastes = [FoldedPaste(text: Self.lines(15)), FoldedPaste(text: Self.lines(12, "row"))]
        for raw in ["", "typed", "  indented\n", "two\n\nparagraphs\n\n"] {
            let kept = PasteFold.draft(raw, pastes: pastes)
            let back = PasteFold.undraft(kept)
            #expect(back.words == raw, "\(raw.debugDescription)")
            #expect(back.pastes.map(\.text) == pastes.map(\.text))
        }
        #expect(PasteFold.draft("only words", pastes: []) == "only words")
        #expect(PasteFold.undraft("only words").pastes.isEmpty)
        let sent = PasteFold.wrap("question", pastes: pastes)
        let edited = PasteFold.undraft(sent)
        #expect(edited.words == "question")
        #expect(edited.pastes.count == 2)
    }

    @Test("A carried first message folds its pastes inside the words the carry leaves")
    func underCarry() {
        let brief = ConversationBrief(
            source: "Old chat", body: "User: hi", kept: 1, total: 1, pictures: 0)
        let words = PasteFold.wrap("go on", pastes: [FoldedPaste(text: Self.lines(14))])
        let first = brief.wrapped(with: words)
        let rest = CarryMark.split(first)?.rest ?? ""
        let reading = PasteFold.split(rest)
        #expect(reading.words == "go on")
        #expect(reading.pastes.first?.lines == 14)
    }

    @Test("Tags the person typed are words, never a fold, and come back exactly as typed")
    func typedTags() {
        let typed = "look:\n<pasted-text>\nfoo\n</pasted-text>"
        let sent = PasteFold.wrap(typed, pastes: [])
        #expect(!PasteFold.split(sent).isFolded)
        #expect(PasteFold.split(sent).words == typed)
        #expect(PasteFold.plain(sent) == typed)
        #expect(PasteFold.undraft(PasteFold.draft(typed, pastes: [])).words == typed)

        let paste = FoldedPaste(text: Self.lines(12))
        let above = "<pasted-text>\nnote"
        let kept = PasteFold.undraft(PasteFold.draft(above, pastes: [paste]))
        #expect(kept.words == above)
        #expect(kept.pastes.map(\.text) == [paste.text])
        let reading = PasteFold.split(PasteFold.wrap(above, pastes: [paste]))
        #expect(reading.words == above)
        #expect(reading.pastes.map(\.text) == [paste.text])
        #expect(PasteFold.wrap("plain", pastes: []) == "plain")
    }

    @Test("Carriage returns count as line ends and never fuse a glimpse or a draft")
    func lineEnds() {
        let crlf = (["  Traceback (most recent call last):"] + (1...39).map { "  File a.py, line \($0)" })
            .joined(separator: "\r\n")
        let folded = FoldedPaste(text: crlf)
        #expect(folded.lines == 40)
        #expect(folded.glimpse == "Traceback (most recent call last):")
        let classic = (1...30).map { "row \($0)" }.joined(separator: "\r")
        #expect(PasteFold.lineCount(classic) == 30)
        #expect(PasteFold.folds(classic))
        #expect(PasteFold.lineCount("a\r\nb\r\n") == 2)
        let long = (1...(PasteIntake.inlineLineLimit + 5)).map { "r\($0)" }.joined(separator: "\r\n")
        let plan = PasteIntake.plan(for: ClipboardOffer(text: long), abilities: able, folding: true)
        #expect(plan.attachments.count == 1)
        let paste = FoldedPaste(text: Self.lines(12))
        for raw in ["x\r", "x\r\n", "\r"] {
            #expect(PasteFold.undraft(PasteFold.draft(raw, pastes: [paste])).words == raw, "\(raw.debugDescription)")
        }
    }

    @Test("A command or a brief takes the words and the pastes as plain text")
    func inline() {
        let paste = FoldedPaste(text: "a\nb")
        #expect(PasteFold.inline(" /compact keep it ", pastes: [paste]) == "/compact keep it\n\na\nb")
        #expect(PasteFold.inline("", pastes: [paste]) == "a\nb")
        #expect(PasteFold.inline("words", pastes: []) == "words")
    }

    @Test("Ask later edits the words and keeps the fold behind them")
    func askLater() {
        let paste = FoldedPaste(text: Self.lines(20))
        var sheet = AskLaterSheet(text: PasteFold.wrap("why?", pastes: [paste]), machine: "arch")
        #expect(sheet.words == "why?")
        #expect(sheet.pastesLine == paste.label)
        sheet.words = "why now?"
        #expect(sheet.text == PasteFold.wrap("why now?", pastes: [paste]))
        let plain = AskLaterSheet(text: "just words", machine: "arch")
        #expect(plain.words == "just words" && plain.pastesLine == nil)
    }

    @Test("A queued message shows each paste by its label")
    func queueTitle() {
        let text = PasteFold.wrap("look", pastes: [FoldedPaste(text: Self.lines(30))])
        let row = QueueRow(
            id: "q", text: text, isCommand: false, attachmentCount: 0, holder: .server,
            canEdit: true)
        #expect(!row.title.contains("<pasted-text"))
        #expect(row.title.hasPrefix("look [Pasted"))
    }
}
