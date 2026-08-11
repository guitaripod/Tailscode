import Testing

@testable import TailscodeCore

@Suite("Vim engine")
struct VimEngineTests {
    private func key(_ character: Character) -> VimKey { VimKey(character: character) }

    private func normal(_ text: String = "one two", cursor: Int = 0) -> VimEngine {
        let engine = VimEngine()
        engine.reset(to: text, cursor: cursor, mode: .normal)
        return engine
    }

    @Test("Every key that leaves normal mode belongs to the engine, shifted half included")
    func claimsEveryInsertEntry() {
        let engine = normal()
        for character in "iaIAoOvV" {
            #expect(
                engine.claims(key(character), plain: true, chordPending: false),
                "normal mode let \(character) fall through to the app's shortcut table")
        }
    }

    @Test("A appends at the end of the line rather than after the cursor")
    func appendAtEndOfLine() {
        let shifted = normal()
        let plain = normal()
        _ = shifted.handle(key("A"), text: "one two", cursor: 0)
        _ = plain.handle(key("a"), text: "one two", cursor: 0)
        #expect(shifted.mode == .insert)
        #expect(shifted.document.cursor == 7)
        #expect(plain.document.cursor == 1)
    }

    @Test("A stays on its own line rather than stepping over the newline")
    func appendStopsAtTheNewline() {
        let engine = normal("one\ntwo", cursor: 1)
        _ = engine.handle(key("A"), text: "one\ntwo", cursor: 1)
        #expect(engine.document.cursor == 3)
    }

    @Test("A chord already in flight outranks the engine's own keys")
    func chordPendingOutranks() {
        let engine = normal()
        #expect(!engine.claims(key("A"), plain: true, chordPending: true))
        #expect(!engine.claims(key("A"), plain: false, chordPending: false))
    }
}
