import Foundation
import Testing

@testable import TailscodeCore

@Suite("A table is drawn once it is whole")
struct TableDraftTests {
    @Test("A table at the end of an unfinished message is still being written")
    func growing() {
        #expect(TableDraft.isGrowing(segment: 1, of: 2, sealed: false))
        #expect(!TableDraft.isGrowing(segment: 0, of: 2, sealed: false))
        #expect(!TableDraft.isGrowing(segment: 1, of: 2, sealed: true))
    }

    @Test("A backend that stamps nothing still has a turn that is open")
    func sealing() {
        // opencode: the record answers for itself.
        #expect(!MessageSegment.isSealed(streaming: true, isNewest: false, turnOpen: false))
        // The Claude bridge: the record says nothing, so the conversation answers.
        #expect(!MessageSegment.isSealed(streaming: false, isNewest: true, turnOpen: true))
        #expect(MessageSegment.isSealed(streaming: false, isNewest: true, turnOpen: false))
        #expect(MessageSegment.isSealed(streaming: false, isNewest: false, turnOpen: true))
    }

    @Test("The card counts what landed and claims nothing before that")
    func words() {
        let empty = MarkdownTable.scan(["| a | b |", "|---|---|"], from: 0)!.table
        #expect(TableDraft(empty).rowCount == 0)
        #expect(TableDraft(empty).detail == nil)
        let one = MarkdownTable.scan(["| a | b |", "|---|---|", "| 1 | 2 |"], from: 0)!.table
        #expect(TableDraft(one).detail == "1 row")
        #expect(TableDraft(columnCount: 2, rowCount: 9).detail == "9 rows")
        #expect(TableDraft(one).reading.contains("1 row"))
    }

    @Test("The wash runs top-down, lands on every band, and then it is over")
    func entrance() {
        #expect(TableEntrance.opacity(band: 0, of: 8, elapsed: 0) == 0)
        let early = TableEntrance.opacity(band: 0, of: 8, elapsed: 0.1)
        let late = TableEntrance.opacity(band: 7, of: 8, elapsed: 0.1)
        #expect(early > late, "the header has to lead")
        for band in 0..<8 {
            #expect(TableEntrance.opacity(band: band, of: 8, elapsed: TableEntrance.span) == 1)
        }
        #expect(TableEntrance.isFinished(TableEntrance.span))
        #expect(!TableEntrance.isFinished(TableEntrance.span - 0.01))
    }

    @Test("However many rows, the same beat")
    func beatIsFixed() {
        let short = (0..<4).map { TableEntrance.opacity(band: $0, of: 4, elapsed: 0.3) }
        let long = (0..<40).map { TableEntrance.opacity(band: $0, of: 40, elapsed: 0.3) }
        #expect(short.first == long.first)
        #expect(abs(short.last! - long.last!) < 0.0001)
        #expect(short.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("A single band is not made to wait for itself")
    func lonelyBand() {
        #expect(TableEntrance.opacity(band: 0, of: 1, elapsed: TableEntrance.duration) == 1)
        #expect(TableEntrance.opacity(band: 3, of: 0, elapsed: 0) == 1)
    }
}
