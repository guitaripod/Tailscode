import Testing

@testable import TailscodeCore

@Suite struct MarkdownTableTests {
    @Test func parsesPipedTable() {
        let text = """
            Before.

            | Trophy | Goal | Pts |
            |---|---|---|
            | First words | Send a first turn | 5 |
            | A hundred turns | 100 turns in a month | 10 |

            After.
            """
        let segments = MessageSegment.split(text)
        #expect(segments.count == 3)
        guard case .table(let table) = segments[1] else {
            Issue.record("expected a table segment")
            return
        }
        #expect(table.header == ["Trophy", "Goal", "Pts"])
        #expect(table.rows.count == 2)
        #expect(table.cells(in: 0) == ["First words", "Send a first turn", "5"])
        #expect(table.alignment(of: 1) == .leading)
    }

    @Test func parsesEdgelessRowsAndAlignment() {
        let scanned = MarkdownTable.scan(
            ["Name | Count | Share", ":--- | :---: | ---:", "alpha | 3 | 60%"], from: 0)
        #expect(scanned?.table.alignments == [.leading, .center, .trailing])
        #expect(scanned?.table.rows == [["alpha", "3", "60%"]])
        #expect(scanned?.end == 3)
    }

    @Test func raggedRowsPadToHeader() {
        let scanned = MarkdownTable.scan(
            ["| a | b | c |", "|---|---|---|", "| 1 | 2 |", "| 1 | 2 | 3 | 4 |"], from: 0)
        #expect(scanned?.table.cells(in: 0) == ["1", "2", ""])
        #expect(scanned?.table.cells(in: 1) == ["1", "2", "3"])
    }

    @Test func pipeInsideBackticksStaysText() {
        let cells = MarkdownTable.columns("| `a | b` | c |")
        #expect(cells == ["`a | b`", "c"])
        let escaped = MarkdownTable.columns("| a \\| b | c |")
        #expect(escaped == ["a | b", "c"])
    }

    @Test func delimiterNeedsDashes() {
        #expect(MarkdownTable.delimiterRow("|---|:--:|--:|") == [.leading, .center, .trailing])
        #expect(MarkdownTable.delimiterRow("| a | b |") == nil)
        #expect(MarkdownTable.delimiterRow("---") == nil)
        #expect(MarkdownTable.delimiterRow("|::|--|") == nil)
    }

    @Test func headerWithoutDelimiterStaysProse() {
        let segments = MessageSegment.split("| a | b |\n| 1 | 2 |")
        #expect(segments == [.prose("| a | b |\n| 1 | 2 |")])
    }

    @Test func widthMismatchStaysProse() {
        let segments = MessageSegment.split("| a | b |\n|---|---|---|")
        #expect(segments == [.prose("| a | b |\n|---|---|---|")])
    }

    @Test func tableEndsAtProse() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\nplain words"
        let segments = MessageSegment.split(text)
        #expect(segments.count == 2)
        guard case .table(let table) = segments[0] else {
            Issue.record("expected a table segment")
            return
        }
        #expect(table.rows == [["1", "2"]])
        #expect(segments[1] == .prose("plain words"))
    }

    @Test func partialTrailingRowJoinsTheTable() {
        let segments = MessageSegment.split("| a | b |\n|---|---|\n| First words | Send")
        guard case .table(let table)? = segments.first else {
            Issue.record("expected a table segment")
            return
        }
        #expect(table.cells(in: 0) == ["First words", "Send"])
    }

    @Test func quotedPipesAreNotRows() {
        #expect(MarkdownTable.columns("> a | b") == nil)
    }
}

@Suite struct MessageSegmentSpacingTests {
    @Test func collapsesBlankRuns() {
        let segments = MessageSegment.split("one\n\n\n\ntwo")
        #expect(segments == [.prose("one\n\ntwo")])
    }

    /// The row identity every client builds from these is `part:seg<index>`, so a paragraph that
    /// keeps its index keeps its cell. An opening fence with nothing behind it yet must therefore
    /// leave the prose it follows exactly where it was, and add no row of its own.
    @Test func openingAFenceLeavesTheProseAtItsIndex() {
        #expect(MessageSegment.split("abc") == [.prose("abc")])
        #expect(MessageSegment.split("abc\n```") == [.prose("abc")])
        #expect(MessageSegment.split("abc\n```\n") == [.prose("abc")])
        #expect(MessageSegment.split("abc\n```swift\n") == [.prose("abc")])
        #expect(
            MessageSegment.split("abc\n```swift\nlet a = 1")
                == [.prose("abc"), .code(language: "swift", body: "let a = 1")])
    }

    @Test func fencesSurviveAroundTables() {
        let text = "```swift\nlet a = 1\n\n\nlet b = 2\n```\n| a | b |\n|---|---|"
        let segments = MessageSegment.split(text)
        #expect(segments.count == 2)
        #expect(segments[0] == .code(language: "swift", body: "let a = 1\n\n\nlet b = 2"))
        guard case .table = segments[1] else {
            Issue.record("expected a table segment")
            return
        }
    }
}

@Suite("Table layout")
struct TableLayoutTests {
    @Test("Columns keep their natural measure when the table fits")
    func natural() {
        let widths = TableLayout.widths(natural: [100, 200, 80], fitting: 1000)
        #expect(widths == [100, 200, 80])
        #expect(TableLayout.width(of: widths) == 100 + 200 + 80 + 32)
        #expect(!TableLayout.overflows(widths, fitting: 1000))
    }

    @Test("The widest column gives way first, and never past the floor")
    func squeeze() {
        let widths = TableLayout.widths(natural: [90, 400, 90], fitting: 400)
        #expect(widths[0] == 90 && widths[2] == 90)
        #expect(widths[1] < 400)
        #expect(TableLayout.width(of: widths) <= 400.5)
        // A pane so narrow that even the floor will not fit is not folded at all: the table is
        // going to be scrolled either way, and short beats marginally narrower.
        let hopeless = TableLayout.widths(natural: [300, 300, 300], fitting: 100)
        #expect(hopeless == [300, 300, 300])
        #expect(TableLayout.overflows(hopeless, fitting: 100))
        let floored = TableLayout.widths(
            natural: [300, 300, 300], fitting: TableLayout.minimumColumn * 3, gap: 0)
        #expect(floored.allSatisfy { $0 == TableLayout.minimumColumn })
    }

    @Test("A column never narrows while the table is still being written")
    func settled() {
        let first = TableLayout.widths(natural: [100, 200], fitting: 1000)
        let next = TableLayout.widths(natural: [80, 260], fitting: 1000)
        #expect(TableLayout.settled(next, since: first) == [100, 260])
        #expect(TableLayout.settled([50], since: []) == [50])
        #expect(TableLayout.settled([50, 60], since: [70]) == [70, 60])
    }
}

@Suite("Tables while they are being written")
struct StreamingTableTests {
    @Test("A row still being typed is not a row")
    func partialRowIsHeldBack() {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4"
        guard case .table(let live)? = MessageSegment.split(table, sealed: false).first else {
            Issue.record("no table")
            return
        }
        #expect(live.rows.count == 1)
        guard case .table(let done)? = MessageSegment.split(table, sealed: true).first else {
            Issue.record("no table")
            return
        }
        #expect(done.rows.count == 2)
    }

    @Test("A completed row lands whole")
    func completedRowLands() {
        guard case .table(let live)? = MessageSegment.split(
            "| a | b |\n|---|---|\n| 1 | 2 |\n", sealed: false
        ).first else {
            Issue.record("no table")
            return
        }
        #expect(live.rows.count == 1)
    }

    @Test("A header with no delimiter yet is not a line of pipes on the page")
    func headerWaitsForItsDelimiter() {
        #expect(MessageSegment.split("Here you go:\n| a | b |", sealed: false) == [.prose("Here you go:")])
        #expect(MessageSegment.split("Here you go:\n| a | b |\n", sealed: false) == [.prose("Here you go:")])
        #expect(
            MessageSegment.split("Here you go:\n| a | b |", sealed: true)
                == [.prose("Here you go:\n| a | b |")])
    }

    @Test("A finished table is unchanged by the streaming rule")
    func sealedIsTheOldBehaviour() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        #expect(MessageSegment.split(text) == MessageSegment.split(text, sealed: true))
    }
}

@Suite("Columns of numbers")
struct NumericColumnTests {
    @Test("A column of figures is figures, and a column of words is not")
    func numeric() {
        let table = MarkdownTable(
            header: ["Model", "Tokens", "Cost", "Share"],
            alignments: [.leading, .trailing, .trailing, .trailing],
            rows: [
                ["Opus 5", "1,204", "$3.40", "42%"],
                ["Sonnet 5", "980", "$0.12", "31%"],
                ["qwen3-14b", "12ms", "—", "27%"],
            ])
        #expect(!table.isNumeric(column: 0))
        #expect(table.isNumeric(column: 1))
        #expect(table.isNumeric(column: 2))
        #expect(table.isNumeric(column: 3))
        #expect(table.column(1) == ["Tokens", "1,204", "980", "12ms"])
    }

    @Test("An empty column is not a column of numbers")
    func empties() {
        let table = MarkdownTable(
            header: ["a", "b"], alignments: [.leading, .leading], rows: [["", ""], ["", "x"]])
        #expect(!table.isNumeric(column: 0))
        #expect(!table.isNumeric(column: 1))
    }
}

@Suite("Fences while they are being written")
struct StreamingFenceTests {
    @Test("A shell pipeline is not held back for looking like a table")
    func fenceLinesAreNeverHeld() {
        let text = "```bash\nps aux | grep swift"
        #expect(
            MessageSegment.split(text, sealed: false)
                == [.code(language: "bash", body: "ps aux | grep swift")])
        let more = "Run:\n```bash\ncat a.txt | sort | uniq -c"
        guard case .code(_, let body)? = MessageSegment.split(more, sealed: false).last else {
            Issue.record("no code")
            return
        }
        #expect(body == "cat a.txt | sort | uniq -c")
    }

    @Test("A table after a fence still holds its half-written row")
    func tableAfterFence() {
        let text = "```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4"
        let segments = MessageSegment.split(text, sealed: false)
        guard case .table(let table)? = segments.last else {
            Issue.record("no table")
            return
        }
        #expect(table.rows.count == 1)
    }
}

@Suite("What a column holds")
struct ColumnKindTests {
    private static let wifi = MarkdownTable.scan(
        [
            "| Band | BSSID | Ch | Freq | Rate | Sig | Security |",
            "|---|---|---|---|---|---|---|",
            "| 2.4 | `92:30:66:5E:BF:4D` | 6 | 2437 MHz | 130 Mb/s | 94 | WPA2+WPA3 (PSK+SAE) |",
            "| 5 (hidden) | `8C:30:66:5E:BF:4E` | 128 | 5640 MHz | 1170 Mb/s | 92 | WPA2 (PSK) |",
        ], from: 0)!.table

    @Test("A column of addresses is code, a column of readings is figures, prose is prose")
    func kinds() {
        #expect(Self.wifi.kinds == [.text, .code, .number, .number, .number, .number, .text])
    }

    @Test("A column the author never placed lands under its own last digit")
    func undeclaredNumbersGoRight() {
        #expect(Self.wifi.alignment(of: 5) == .leading)
        #expect(Self.wifi.effectiveAlignment(of: 5) == .trailing)
        #expect(Self.wifi.effectiveAlignment(of: 0) == .leading)
        #expect(Self.wifi.effectiveAlignment(of: 6) == .leading)
    }

    @Test("A column the author did place stays exactly where they put it")
    func declaredAlignmentIsNeverArguedWith() {
        let table = MarkdownTable.scan(
            ["| n | m |", "| :--- | ---: |", "| 12 | 13 |"], from: 0)!.table
        #expect(table.isDeclared(0))
        #expect(table.effectiveAlignment(of: 0) == .leading)
        #expect(table.effectiveAlignment(of: 1) == .trailing)
        #expect(table.markdown.contains(":--"))
        #expect(MarkdownTable.scan(table.markdown.split(separator: "\n").map(String.init), from: 0)?
            .table == table)
    }

    @Test("A reading with a unit in it is never folded in half")
    func rigidity() {
        #expect(Self.wifi.rigidColumns == [true, true, true, true, true, true, false])
    }

    @Test("A key-first table names its rows, a grid of numbers does not")
    func namedRows() {
        #expect(Self.wifi.namesItsRows)
        let figures = MarkdownTable(
            header: ["q1", "q2"], alignments: [.leading, .leading],
            rows: [["1", "2"], ["3", "4"]])
        #expect(!figures.namesItsRows)
    }
}

@Suite("Room for the columns that can use it")
struct RigidWidthTests {
    @Test("A column with nothing to break keeps its measure and the prose pays")
    func rigidColumnsAreNotSqueezed() {
        let widths = TableLayout.widths(
            natural: [60, 60, 400], fitting: 300, gap: 0, minimum: 20,
            rigid: [true, true, false])
        #expect(widths[0] == 60)
        #expect(widths[1] == 60)
        #expect(widths[2] == 180)
    }

    @Test("A narrow column is its own measure, not the squeeze floor")
    func narrowColumnsAreNotGrown() {
        let widths = TableLayout.widths(natural: [27, 37, 51], fitting: 1000, gap: 0)
        #expect(widths == [27, 37, 51])
    }

    @Test("A table that will scroll whatever happens is not also folded")
    func foldingMustEarnItsHeight() {
        let hopeless = TableLayout.widths(
            natural: [200, 200, 400], fitting: 300, gap: 0, minimum: 40,
            rigid: [true, true, false])
        #expect(hopeless == [200, 200, 400])
        let worthwhile = TableLayout.widths(
            natural: [100, 100, 400], fitting: 300, gap: 0, minimum: 40,
            rigid: [true, true, false])
        #expect(worthwhile == [100, 100, 100])
    }

    @Test("Nothing rigid is the arithmetic it always was")
    func withoutRigidityNothingChanges() {
        let natural = [40.0, 120, 300]
        #expect(
            TableLayout.widths(natural: natural, fitting: 320, gap: 0, minimum: 20)
                == TableLayout.widths(
                    natural: natural, fitting: 320, gap: 0, minimum: 20,
                    rigid: [false, false, false]))
    }

    @Test("A table of nothing but rigid columns is handed back whole, to be scrolled")
    func allRigidOverflows() {
        let widths = TableLayout.widths(
            natural: [200, 200, 200], fitting: 300, gap: 0, minimum: 20,
            rigid: [true, true, true])
        #expect(widths == [200, 200, 200])
        #expect(TableLayout.overflows(widths, fitting: 300, gap: 0))
    }
}
