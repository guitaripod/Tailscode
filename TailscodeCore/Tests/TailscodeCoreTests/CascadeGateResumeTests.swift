import Foundation
import Testing

@testable import TailscodeCore

/// The gate picks up a growing row where its last reading stopped. Whatever the text and however it
/// arrives, the answer has to be the one a reading from the first character gives.
@Suite struct CascadeGateResumeTests {
    /// Markdown's punctuation, the characters that decide what it means, and the clusters an append
    /// can change: a combining accent, a joiner and the emoji after it, a flag's second half, the
    /// line feed that turns a carriage return into one character.
    private static let alphabet: [String] = [
        "*", "*", "_", "_", "~", "`", "[", "]", "(", ")", " ", " ", "a", "b", "7", "\n", "\r",
        "\u{2014}", "e", "\u{301}", "\u{1F468}", "\u{200D}", "\u{1F469}", "\u{1F1EB}", "\u{1F1EE}",
    ]

    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func expected(_ text: String, sealed: Bool) -> CascadeGate.Reading {
        let count = text.count
        return CascadeGate.Reading(
            count: count, cut: CascadeGate.safeCut(text, at: count, sealed: sealed))
    }

    @Test func aRowReadAsItArrivesReadsLikeTheWholeRow() {
        var generator = Generator(state: 0x5EED)
        for _ in 0..<300 {
            var text = ""
            var memo: CascadeGate.Memo?
            for _ in 0..<(1 + generator.next(40)) {
                for _ in 0..<(1 + generator.next(12)) {
                    text += Self.alphabet[generator.next(Self.alphabet.count)]
                }
                #expect(CascadeGate.read(text, memo: &memo) == expected(text, sealed: false))
            }
            #expect(CascadeGate.read(text, sealed: true, memo: &memo) == expected(text, sealed: true))
        }
    }

    /// A row the server rewrote is not the last one grown longer, and is read from the start.
    @Test func aRewrittenRowIsReadFromTheStart() {
        var memo: CascadeGate.Memo?
        _ = CascadeGate.read("an open **marker and more words", memo: &memo)
        let rewritten = "a closed **marker** and more words"
        #expect(CascadeGate.read(rewritten, memo: &memo) == expected(rewritten, sealed: false))
        let shorter = "an open **mar"
        #expect(CascadeGate.read(shorter, memo: &memo) == expected(shorter, sealed: false))
    }

    /// The live row hands the renderer the same prefix it always did, now found from the end.
    @Test func theLiveRowStillHoldsBackAnOpenToken() {
        var live = LiveCascade()
        let held = live.renderable(row: "r", "Some words and **bold", sealed: false, at: 0)
        #expect(held == "Some words and ")
        let closed = live.renderable(row: "r", "Some words and **bold** \u{1F468}\u{200D}\u{1F469} done", sealed: false, at: 0.1)
        #expect(closed == "Some words and **bold** \u{1F468}\u{200D}\u{1F469} done")
    }
}
