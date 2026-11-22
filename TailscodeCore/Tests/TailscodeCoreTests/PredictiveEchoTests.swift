import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PredictiveEchoTests {
    private let now = Date(timeIntervalSince1970: 1000)

    @Test func theFirstKeyOfALineWaitsForItsEchoAndTheRestShowAtOnce() {
        var echo = PredictiveEcho()
        echo.typed("l", at: now)
        #expect(echo.shown.isEmpty)
        echo.typed("s", at: now)
        echo.heard(Data("l".utf8))
        #expect(echo.shown == Array("s".utf8))
        echo.typed(" -", at: now)
        #expect(echo.shown == Array("s -".utf8))
        echo.heard(Data("s -".utf8))
        #expect(echo.shown.isEmpty)
        #expect(echo.trusted)
    }

    @Test func aPasswordPromptNeverShowsWhatIsTyped() {
        var echo = PredictiveEcho()
        echo.typed("a", at: now)
        echo.heard(Data("a".utf8))
        echo.typed("\r", at: now)
        echo.heard(Data("\r\nPassword: ".utf8))
        for letter in "hunter2" { echo.typed(String(letter), at: now) }
        #expect(echo.shown.isEmpty)
        echo.expire(at: now.addingTimeInterval(3))
        #expect(echo.pending.isEmpty)
    }

    @Test func aContradictionDropsEveryGuessAndTheTrust() {
        var echo = PredictiveEcho()
        echo.typed("a", at: now)
        echo.heard(Data("a".utf8))
        echo.typed("bc", at: now)
        echo.heard(Data("b\u{1b}[K".utf8))
        #expect(echo.pending.isEmpty)
        #expect(!echo.trusted)
    }

    @Test func outputNobodyTypedTakesTheTrustAway() {
        var echo = PredictiveEcho()
        echo.typed("a", at: now)
        echo.heard(Data("a".utf8))
        echo.heard(Data("[1]+  Done".utf8))
        echo.typed("b", at: now)
        #expect(echo.shown.isEmpty)
    }

    @Test func onlyPrintableAsciiIsGuessed() {
        var echo = PredictiveEcho()
        echo.typed("a", at: now)
        echo.heard(Data("a".utf8))
        echo.typed("é", at: now)
        #expect(echo.pending.isEmpty && !echo.trusted)
    }

    @Test func guessesAreDrawnAfterTheCursorAndLeaveNoTrace() throws {
        let screen = try #require(TerminalScreen(cols: 20, rows: 4))
        screen.feed(Data("$ l".utf8))
        let first = screen.frame()
        let drawn = try #require(first.drawn(over: Array("s -la".utf8), stale: nil))
        #expect(drawn.frame.text(row: 0) == "$ ls -la")
        #expect(drawn.frame.cursor?.column == 8)
        #expect(drawn.frame.rowChanged(0))
        #expect(drawn.row == 0)
        let after = screen.frame()
        #expect(after.text(row: 0) == "$ l")
        let cleared = try #require(after.drawn(over: [], stale: 0))
        #expect(cleared.frame.rowChanged(0))
        #expect(cleared.row == nil)
    }

    @Test func nothingIsDrawnOverAFullScreenProgramOrPastTheEdge() throws {
        let screen = try #require(TerminalScreen(cols: 10, rows: 4))
        screen.feed(Data("12345678".utf8))
        let edge = try #require(screen.frame().drawn(over: Array("abcdef".utf8), stale: nil))
        #expect(edge.frame.text(row: 0) == "12345678a")
        screen.feed(Data("\u{1b}[?1049h".utf8))
        #expect(screen.frame().drawn(over: Array("x".utf8), stale: nil) == nil)
    }
}
