import Foundation
import Testing

@testable import TailscodeCore

@Suite struct TerminalScreenTests {
    private func screen(cols: Int = 40, rows: Int = 6) throws -> TerminalScreen {
        try #require(TerminalScreen(cols: cols, rows: rows))
    }

    private func feed(_ screen: TerminalScreen, _ text: String) {
        screen.feed(Data(text.utf8))
    }

    @Test func theEngineIsInThisBuild() {
        #expect(TerminalScreen.isAvailable)
    }

    @Test func textLandsWhereTheShellPutIt() throws {
        let screen = try screen()
        feed(screen, "hello\r\nsecond line")
        let frame = screen.frame()
        #expect(frame.cols == 40 && frame.rows == 6)
        #expect(frame.text(row: 0) == "hello")
        #expect(frame.text(row: 1) == "second line")
        #expect(frame.cursor?.column == 11 && frame.cursor?.row == 1)
        #expect(frame.everythingChanged)
    }

    @Test func coloursArriveFinal() throws {
        let screen = try screen()
        let colors = TerminalColors(
            foreground: 0xeeeeee, background: 0x111111, cursor: 0xff00ff,
            ansi: (0..<16).map { UInt32($0) * 0x101010 }, selectionForeground: 0xeeeeee,
            selectionBackground: 0x334455, isDark: true)
        screen.apply(colors)
        feed(screen, "a\u{1b}[31mb\u{1b}[0m\u{1b}[38;2;1;2;3;48;2;9;8;7mc\u{1b}[0m\u{1b}[7md\u{1b}[0m\u{1b}[1;4me")
        let cells = screen.frame().cells(row: 0)
        #expect(cells[0].fg == 0xeeeeee && cells[0].bg == 0x111111)
        #expect(cells[0].flags & UInt16(TS_CELL_FILLED) == 0)
        #expect(cells[1].fg == 0x101010)
        #expect(cells[2].fg == 0x010203 && cells[2].bg == 0x090807)
        #expect(cells[2].flags & UInt16(TS_CELL_FILLED) != 0)
        #expect(cells[3].fg == 0x111111 && cells[3].bg == 0xeeeeee)
        #expect(cells[4].flags & UInt16(TS_CELL_BOLD) != 0)
        #expect((cells[4].flags & UInt16(TS_CELL_UNDERLINE_MASK)) >> UInt16(TS_CELL_UNDERLINE_SHIFT) == UInt16(TS_UNDERLINE_SINGLE))
    }

    @Test func aWideCharacterTakesTwoCellsAndAnAccentJoinsItsLetter() throws {
        let screen = try screen()
        feed(screen, "日e\u{301}x")
        let frame = screen.frame()
        let cells = frame.cells(row: 0)
        #expect(cells[0].width == 2 && cells[1].width == 0)
        #expect(frame.text(of: cells[0], row: 0) == "日")
        #expect(cells[2].extra == 1)
        #expect(frame.text(of: cells[2], row: 0) == "e\u{301}")
        #expect(frame.text(row: 0) == "日e\u{301}x")
    }

    @Test func onlyTheRowsThatChangedAreReported() throws {
        let screen = try screen()
        feed(screen, "one\r\ntwo\r\nthree")
        _ = screen.frame()
        let quiet = screen.frame()
        #expect(!quiet.changed)
        feed(screen, "\u{1b}[1;1HONE")
        let frame = screen.frame()
        #expect(frame.changed && !frame.everythingChanged)
        #expect(frame.rowChanged(0))
        #expect(!frame.rowChanged(1))
        #expect(frame.text(row: 0) == "ONE")
        #expect(frame.text(row: 1) == "two")
    }

    @Test func aStatusQuestionIsAnswered() throws {
        let screen = try screen()
        feed(screen, "abc")
        let reply = screen.feed(Data("\u{1b}[6n".utf8))
        #expect(String(decoding: reply, as: UTF8.self) == "\u{1b}[1;4R")
    }

    @Test func keysBecomeWhatTheProgramAskedFor() throws {
        let screen = try screen()
        #expect(screen.bytes(for: TerminalKeyPress(key: .letter(0), text: "a", unshifted: "a")) == Data("a".utf8))
        #expect(screen.bytes(for: TerminalKeyPress(key: .letter(2), modifiers: .control, unshifted: "c")) == Data([0x03]))
        #expect(screen.bytes(for: TerminalKeyPress(key: .enter)) == Data("\r".utf8))
        #expect(screen.bytes(for: TerminalKeyPress(key: .arrowUp)) == Data("\u{1b}[A".utf8))
        feed(screen, "\u{1b}[?1h")
        #expect(screen.bytes(for: TerminalKeyPress(key: .arrowUp)) == Data("\u{1b}OA".utf8))
        #if !canImport(Darwin)
            #expect(screen.bytes(for: TerminalKeyPress(key: .letter(1), modifiers: .alt, text: "b", unshifted: "b")) == Data("\u{1b}b".utf8))
        #else
            #expect(screen.bytes(for: TerminalKeyPress(key: .letter(1), modifiers: .alt, text: "∫", unshifted: "b")) == Data("∫".utf8))
        #endif
        #expect(screen.bytes(for: TerminalKeyPress(key: .backspace)) == Data([0x7f]))
        #expect(screen.bytes(for: TerminalKeyPress(key: .tab, modifiers: .shift)) == Data("\u{1b}[Z".utf8))
    }

    @Test func aPasteIsBracketedOnlyWhenAsked() throws {
        let screen = try screen()
        #expect(screen.bytes(pasting: "ls") == Data("ls".utf8))
        #expect(screen.pasteIsRisky("rm -rf x\n"))
        #expect(!screen.pasteIsRisky("rm -rf x"))
        feed(screen, "\u{1b}[?2004h")
        #expect(screen.bytes(pasting: "ls") == Data("\u{1b}[200~ls\u{1b}[201~".utf8))
        #expect(!screen.pasteIsRisky("rm -rf x\n"))
        let smuggled = screen.bytes(pasting: "a\u{1b}[201~b")
        #expect(String(decoding: smuggled, as: UTF8.self).components(separatedBy: "\u{1b}[201~").count == 2)
    }

    @Test func scrollbackIsKeptAndTheWheelWalksIt() throws {
        let screen = try screen(cols: 20, rows: 4)
        for index in 1...20 { feed(screen, "line \(index)\r\n") }
        var frame = screen.frame()
        #expect(frame.text(row: 2) == "line 20")
        #expect(frame.rowsBelow == 0)
        #expect(screen.wheel(rows: -5, modifiers: [], x: 0, y: 0).isEmpty)
        frame = screen.frame()
        #expect(frame.rowsBelow == 5)
        #expect(frame.text(row: 0) == "line 13")
        screen.scrollToBottom()
        #expect(screen.frame().rowsBelow == 0)
        #expect(screen.text.contains("line 1\n"))
    }

    @Test func aFullScreenProgramGetsTheWheelAsKeys() throws {
        let screen = try screen()
        feed(screen, "\u{1b}[?1049h")
        #expect(screen.frame().raw.alternate_screen)
        #expect(screen.wheel(rows: 2, modifiers: [], x: 0, y: 0) == Data("\u{1b}[B\u{1b}[B".utf8))
        feed(screen, "\u{1b}[?1000h\u{1b}[?1006h")
        screen.setGeometry(cellWidth: 10, cellHeight: 20, paddingLeft: 0, paddingTop: 0, width: 400, height: 120)
        let press = screen.bytes(pointer: .press, button: .left, modifiers: [], x: 25, y: 45, anyPressed: true)
        #expect(String(decoding: press, as: UTF8.self) == "\u{1b}[<0;3;3M")
        #expect(screen.bytes(pointer: .press, button: .left, modifiers: .shift, x: 25, y: 45, anyPressed: true).isEmpty)
    }

    @Test func draggingSelectsAndTwoPressesTakeTheWord() throws {
        let screen = try screen()
        screen.setGeometry(cellWidth: 10, cellHeight: 20, paddingLeft: 0, paddingTop: 0, width: 400, height: 120)
        feed(screen, "hello brave world")
        #expect(!screen.hasSelection)
        screen.select(.press, x: 2, y: 5)
        screen.select(.drag, x: 46, y: 5)
        screen.select(.release, x: 46, y: 5)
        #expect(screen.selectionText == "hello")
        let cells = screen.frame().cells(row: 0)
        #expect(cells[0].flags & UInt16(TS_CELL_SELECTED) != 0)
        #expect(cells[6].flags & UInt16(TS_CELL_SELECTED) == 0)
        screen.clearSelection()
        #expect(!screen.hasSelection)
        screen.select(.press, x: 85, y: 5)
        screen.select(.release, x: 85, y: 5)
        screen.select(.press, x: 85, y: 5)
        screen.select(.release, x: 85, y: 5)
        #expect(screen.selectionText == "brave")
        screen.selectAll()
        #expect(screen.selectionText == "hello brave world")
    }

    @Test func aResetForgetsEverything() throws {
        let screen = try screen()
        feed(screen, "\u{1b}[?1049h\u{1b}[?2004hjunk")
        screen.reset()
        let frame = screen.frame()
        #expect(!frame.raw.alternate_screen)
        #expect(frame.text(row: 0).isEmpty)
        #expect(screen.bytes(pasting: "x") == Data("x".utf8))
    }

    @Test func resizingReflowsWhatWasWrapped() throws {
        let screen = try screen(cols: 10, rows: 4)
        feed(screen, "0123456789abcdef")
        #expect(screen.frame().text(row: 1) == "abcdef")
        screen.resize(cols: 20, rows: 4, cellWidth: 10, cellHeight: 20)
        let frame = screen.frame()
        #expect(frame.cols == 20)
        #expect(frame.text(row: 0) == "0123456789abcdef")
    }

    @Test func aThemeIsReadFromAPalette() {
        #expect(TerminalColors.rgb("#1e2a3b") == 0x1e2a3b)
        #expect(TerminalColors.rgb("abc") == 0xaabbcc)
        #expect(TerminalColors.rgb("#12") == nil)
        #expect(TerminalColors.mix(0xffffff, into: 0x000000, by: 0.5) == 0x808080)
    }
}
