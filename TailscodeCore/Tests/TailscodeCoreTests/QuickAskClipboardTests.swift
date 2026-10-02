import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Quick ask clipboard", .serialized)
    struct QuickAskClipboardTests {

        private let seeing = ModelAbilities(attachments: true, vision: true)
        private let blind = ModelAbilities(attachments: true, vision: false)

        private func withCleanMemory(_ body: () -> Void) {
            let key = "tailscode.quickask.copied"
            let previous = UserDefaults.standard.string(forKey: key)
            QuickAskClipboardMemory.clear()
            body()
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                QuickAskClipboardMemory.clear()
            }
        }

        @Test("Copied words are offered to any model, and only the word errands")
        func wordsGoAnywhere() {
            let offered = QuickAskClipboard.errands(for: .text("a line"), abilities: .words)
            #expect(!offered.isEmpty)
            #expect(offered.allSatisfy { $0.takes == .text })
            #expect(offered.map(\.id).first == "copied.explain")
        }

        @Test("Blank words are nothing to offer, and undetected words still are")
        func blankWords() {
            #expect(QuickAskClipboard.errands(for: .text(" \n\t"), abilities: seeing).isEmpty)
            #expect(!QuickAskClipboard.errands(for: .text(nil), abilities: seeing).isEmpty)
        }

        @Test("A picture is offered only to a model that sees")
        func pictureNeedsVision() {
            #expect(QuickAskClipboard.errands(for: .picture, abilities: blind).isEmpty)
            let offered = QuickAskClipboard.errands(for: .picture, abilities: seeing)
            #expect(offered.map(\.id) == ["copied.describe", "copied.transcribe", "copied.explainPicture"])
        }

        @Test("Files are offered only to a model that takes files")
        func filesNeedAttachments() {
            #expect(QuickAskClipboard.errands(for: .files(["/tmp/a.pdf"]), abilities: .words).isEmpty)
            #expect(!QuickAskClipboard.errands(for: .files(["/tmp/a.pdf"]), abilities: blind).isEmpty)
        }

        @Test("Words open under the instruction; a picture or a file rides as a chip")
        func opening() {
            let explain = QuickAskClipboard.all.first { $0.id == "copied.explain" }!
            #expect(explain.opening == explain.prompt + "\n\n")
            let describe = QuickAskClipboard.all.first { $0.id == "copied.describe" }!
            #expect(describe.opening == describe.prompt)
        }

        @Test("The headline is specific where the thing was read")
        func headlines() {
            #expect(QuickAskClipboard.headline(for: .text("one")) == "Copied text · 1 word")
            #expect(QuickAskClipboard.headline(for: .text("two  words\nhere")) == "Copied text · 3 words")
            #expect(QuickAskClipboard.headline(for: .text(nil)) == "Copied text")
            #expect(QuickAskClipboard.headline(for: .picture) == "Copied picture")
            #expect(QuickAskClipboard.headline(for: .files(["/x/report.pdf"])) == "Copied file · report.pdf")
            #expect(QuickAskClipboard.headline(for: .files(["/a", "/b"])) == "Copied 2 files")
            #expect(QuickAskClipboard.headline(for: .files([])) == "Copied files")
        }

        @Test("The glimpse spends its room on words, and cuts at a word")
        func preview() {
            #expect(
                QuickAskClipboard.preview(for: .text("  func a() {\n\treturn 1\n}  "))
                    == "func a() { return 1 }")
            let long = String(repeating: "word ", count: 100)
            let cut = QuickAskClipboard.preview(for: .text(long), limit: 22)
            #expect(cut == "word word word word…")
            #expect(QuickAskClipboard.preview(for: .picture) == nil)
            #expect(QuickAskClipboard.preview(for: .text(nil)) == nil)
        }

        @Test("A fingerprint is the same for the same bytes and differs for others")
        func fingerprints() {
            #expect(QuickAskClipboard.fingerprint(text: "hello") == QuickAskClipboard.fingerprint(text: "hello"))
            #expect(QuickAskClipboard.fingerprint(text: "hello") != QuickAskClipboard.fingerprint(text: "hellp"))
            #expect(
                QuickAskClipboard.fingerprint(kind: "picture", bytes: Data([1, 2]))
                    != QuickAskClipboard.fingerprint(kind: "text", bytes: Data([1, 2])))
            #expect(QuickAskClipboard.fingerprint(text: "") == "text:cbf29ce484222325:0")
        }

        @Test("What was copied is news until it is settled, and new copying makes it news again")
        func news() {
            withCleanMemory {
                let first = QuickAskClipboard.fingerprint(text: "first")
                #expect(
                    QuickAskClipboard.reading(holding: .text("first"), fingerprint: first, abilities: .words)
                        != nil)
                QuickAskClipboardMemory.settle(first)
                #expect(
                    QuickAskClipboard.reading(holding: .text("first"), fingerprint: first, abilities: .words)
                        == nil)
                let second = QuickAskClipboard.fingerprint(text: "second")
                let card = QuickAskClipboard.reading(
                    holding: .text("second"), fingerprint: second, abilities: .words)
                #expect(card?.headline == "Copied text · 1 word")
                #expect(card?.preview == "second")
            }
        }

        @Test("Nothing this model can take is no card at all")
        func nothingToTake() {
            withCleanMemory {
                #expect(
                    QuickAskClipboard.reading(
                        holding: .picture, fingerprint: "picture:1", abilities: blind) == nil)
            }
        }

        @Test("A clipboard read whole is held the way a paste would take it")
        func holdingOfOffer() {
            let files = QuickAskClipboard.holding(
                of: ClipboardOffer(paths: ["/a.txt"], image: Data([1]), text: "x"))
            #expect(files?.holding == .files(["/a.txt"]))
            let picture = QuickAskClipboard.holding(of: ClipboardOffer(image: Data([1]), text: "x"))
            #expect(picture?.holding == .picture)
            #expect(picture?.fingerprint.hasPrefix("picture:") == true)
            let words = QuickAskClipboard.holding(of: ClipboardOffer(text: "hello"))
            #expect(words?.holding == .text("hello"))
            #expect(words?.fingerprint == QuickAskClipboard.fingerprint(text: "hello"))
            #expect(QuickAskClipboard.holding(of: ClipboardOffer(text: "  \n")) == nil)
            #expect(QuickAskClipboard.holding(of: ClipboardOffer()) == nil)
        }

        @Test("Starter glyphs are distinct, so a text client can tell the rows apart")
        func distinctGlyphs() {
            let glyphs = QuickAskStarters.all.map(\.glyph)
            #expect(Set(glyphs).count == glyphs.count)
        }
    }
}
