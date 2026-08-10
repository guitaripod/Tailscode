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
