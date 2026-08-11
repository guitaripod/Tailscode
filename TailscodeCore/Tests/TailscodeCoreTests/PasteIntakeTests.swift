import Foundation
import Testing

@testable import TailscodeCore

@Suite("Paste intake")
struct PasteIntakeTests {
    private let able = QuickAskAbilities(attachments: true, vision: true)

    @Test("Words are words")
    func words() {
        let plan = PasteIntake.plan(
            for: ClipboardOffer(text: "the airspeed velocity"), abilities: able)
        #expect(plan.text == "the airspeed velocity")
        #expect(plan.attachments.isEmpty)
        #expect(plan.notices.isEmpty)
    }

    @Test("A picture on the clipboard becomes a chip, named so two pastes never collide")
    func picture() {
        let first = PasteIntake.plan(
            for: ClipboardOffer(image: Data([0x89, 0x50])), abilities: able)
        #expect(first.attachments.count == 1)
        #expect(first.attachments.first?.name == "pasted-1.png")
        #expect(first.text == nil)
        let second = PasteIntake.plan(
            for: ClipboardOffer(image: Data([0x89]), imageMime: "image/jpeg"), abilities: able,
            alreadyNamed: first.named)
        #expect(second.attachments.first?.name == "pasted-2.jpg")
    }

    @Test("A picture too big to send says so instead of failing on the other machine")
    func oversizePicture() {
        let plan = PasteIntake.plan(
            for: ClipboardOffer(image: Data(count: AttachmentIntake.byteCap + 1)),
            abilities: able)
        #expect(plan.attachments.isEmpty)
        #expect(plan.notices.count == 1)
        #expect(plan.notices.first?.contains("8 MB") == true)
    }

    @Test("What the model cannot read is refused by name rather than dropped")
    func refusals() {
        let blind = QuickAskAbilities(attachments: true, vision: false)
        let picture = PasteIntake.plan(for: ClipboardOffer(image: Data([1])), abilities: blind)
        #expect(picture.attachments.isEmpty)
        #expect(picture.notices.count == 1)
        let wordsOnly = PasteIntake.plan(
            for: ClipboardOffer(paths: ["/tmp/x.png"]), abilities: .words)
        #expect(wordsOnly.attachments.isEmpty)
        #expect(wordsOnly.notices.count == 1)
    }

    @Test("Files on the clipboard are read at paste time, and one bad path does not lose the rest")
    func files() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: good)
        let plan = PasteIntake.plan(
            for: ClipboardOffer(paths: [
                good.path, directory.appendingPathComponent("gone.txt").path,
            ]), abilities: able)
        #expect(plan.attachments.count == 1)
        #expect(plan.attachments.first?.name == "notes.txt")
        #expect(plan.notices.count == 1)
    }

    @Test("A paste the size of a document becomes the document it already is")
    func overlongText() {
        let long = String(repeating: "line\n", count: PasteIntake.inlineLineLimit + 1)
        let plan = PasteIntake.plan(for: ClipboardOffer(text: long), abilities: able)
        #expect(plan.text == nil)
        #expect(plan.attachments.first?.name == "pasted-1.txt")
        #expect(plan.attachments.first?.mime == "text/plain")
        #expect(plan.notices.count == 1)
        let ordinary = String(repeating: "line\n", count: 40)
        #expect(PasteIntake.plan(for: ClipboardOffer(text: ordinary), abilities: able).text != nil)
        let wide = String(repeating: "x", count: PasteIntake.inlineCharacterLimit + 1)
        #expect(PasteIntake.plan(for: ClipboardOffer(text: wide), abilities: able).text == nil)
    }

    @Test("A composer that cannot attach still takes the words")
    func overlongTextWithoutAttachments() {
        let long = String(repeating: "line\n", count: PasteIntake.inlineLineLimit + 1)
        let plan = PasteIntake.plan(for: ClipboardOffer(text: long), abilities: .words)
        #expect(plan.text == long)
        #expect(plan.attachments.isEmpty)
    }

    @Test("An empty clipboard plans nothing and says nothing")
    func empty() {
        let plan = PasteIntake.plan(for: ClipboardOffer(), abilities: able)
        #expect(plan.isEmpty)
        #expect(plan.notices.isEmpty)
        #expect(ClipboardOffer().isEmpty)
    }
}
