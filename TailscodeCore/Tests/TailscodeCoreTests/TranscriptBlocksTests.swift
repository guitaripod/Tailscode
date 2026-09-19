import Testing
@testable import TailscodeCore

@Suite struct TranscriptBlocksTests {
    private func lines(_ n: Int) -> String { (1...n).map { "line \($0)" }.joined(separator: "\n") }

    @Test func shortBlockIsDrawnWholeWithNoButton() {
        let fold = TranscriptBlocks.fold(lines(3), expanded: false)
        #expect(fold.shown == lines(3))
        #expect(fold.shownLines == 3)
        #expect(!fold.foldable)
        #expect(fold.toggleLabel == nil)
        #expect(fold.spokenState == nil)
    }

    @Test func blockAtTheLimitIsNotFolded() {
        let fold = TranscriptBlocks.fold(lines(TranscriptBlocks.inlineLines), expanded: false)
        #expect(!fold.foldable)
        #expect(!fold.isFolded)
    }

    @Test func longBlockShowsItsFirstLinesAndNamesTheRest() {
        let fold = TranscriptBlocks.fold(lines(140), expanded: false)
        #expect(fold.shownLines == TranscriptBlocks.inlineLines)
        #expect(fold.totalLines == 140)
        #expect(fold.hiddenLines == 140 - TranscriptBlocks.inlineLines)
        #expect(fold.shown == lines(TranscriptBlocks.inlineLines))
        #expect(fold.toggleLabel == "Show all 140 lines")
        #expect(fold.spokenState == "114 more lines")
    }

    @Test func openedBlockShowsEverythingAndOffersToFoldBack() {
        let fold = TranscriptBlocks.fold(lines(140), expanded: true)
        #expect(fold.shown == lines(140))
        #expect(!fold.isFolded)
        #expect(fold.foldable)
        #expect(fold.toggleLabel == "Show first 26 lines")
    }

    @Test func ownLimitIsHonoured() {
        let fold = TranscriptBlocks.fold(lines(20), expanded: false, limit: 14)
        #expect(fold.shownLines == 14)
        #expect(fold.toggleLabel == "Show all 20 lines")
    }

    @Test func gutterIsPaddedToTheWidestNumberOfTheWholeBlock() {
        let fold = TranscriptBlocks.fold(lines(140), expanded: false)
        let gutter = TranscriptBlocks.lineNumbers(fold).components(separatedBy: "\n")
        #expect(gutter.count == TranscriptBlocks.inlineLines)
        #expect(gutter.first == "  1")
        #expect(gutter.last == " 26")
        #expect(TranscriptBlocks.lineNumbers(TranscriptBlocks.fold("", expanded: false)) == "")
    }

    @Test func trailingNewlineCountsAsAnEmptyLastLine() {
        #expect(TranscriptBlocks.lineCount("a\nb\n") == 3)
        #expect(TranscriptBlocks.fold("a\nb\n", expanded: false, limit: 2).shown == "a\nb")
    }
}
