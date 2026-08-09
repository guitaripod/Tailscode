import Foundation
import Testing

@testable import TailscodeCore

/// The marked-chats split is one arrangement on three desks, so the tree it builds is pinned
/// here: what is offered for a count, the grid's shape, and the equal shares the panes end with.
@Suite("Split even")
struct SplitEvenTests {

    @Test("Offers fit the count")
    func offersFitTheCount() {
        #expect(SplitEven.offers(count: 1).isEmpty)
        #expect(SplitEven.offers(count: 2) == [.sideBySide, .stacked])
        #expect(SplitEven.offers(count: 3) == [.sideBySide, .stacked, .grid])
        #expect(SplitEven.offers(count: SplitEven.limit).count == 3)
        #expect(SplitEven.offers(count: SplitEven.limit + 1).isEmpty)
    }

    @Test("A grid spreads its remainder instead of dumping it")
    func gridSpreadsRemainder() {
        #expect(SplitEven.gridRows(3) == [2, 1])
        #expect(SplitEven.gridRows(4) == [2, 2])
        #expect(SplitEven.gridRows(5) == [3, 2])
        #expect(SplitEven.gridRows(6) == [3, 3])
        #expect(SplitEven.gridRows(7) == [3, 2, 2])
        #expect(SplitEven.gridRows(9) == [3, 3, 3])
    }

    @Test("Side by side is equal columns")
    func sideBySideIsEqualColumns() {
        let layout = SplitEven.layout(count: 4, as: .sideBySide)!
        let frames = layout.frames()

        #expect(layout.paneCount == 4)
        #expect(layout.focusedPane == layout.paneIDs[0])
        for id in layout.paneIDs {
            #expect(abs(frames[id]!.width - 0.25) < 1e-9)
            #expect(abs(frames[id]!.height - 1.0) < 1e-9)
        }
        let xs = layout.paneIDs.map { frames[$0]!.x }
        #expect(xs == xs.sorted())
    }

    @Test("Stacked is equal rows")
    func stackedIsEqualRows() {
        let layout = SplitEven.layout(count: 3, as: .stacked)!
        let frames = layout.frames()

        for id in layout.paneIDs {
            #expect(abs(frames[id]!.height - 1.0 / 3.0) < 1e-9)
            #expect(abs(frames[id]!.width - 1.0) < 1e-9)
        }
        let ys = layout.paneIDs.map { frames[$0]!.y }
        #expect(ys == ys.sorted())
    }

    @Test("A grid of four is two by two, in reading order")
    func gridOfFourIsTwoByTwo() {
        let layout = SplitEven.layout(count: 4, as: .grid)!
        let frames = layout.frames()

        for id in layout.paneIDs {
            #expect(abs(frames[id]!.width - 0.5) < 1e-9)
            #expect(abs(frames[id]!.height - 0.5) < 1e-9)
        }
        let order = layout.paneIDs.map { frames[$0]! }
        #expect(order[0].y == order[1].y)
        #expect(order[2].y == order[3].y)
        #expect(order[0].y < order[2].y)
        #expect(order[0].x < order[1].x)
    }

    @Test("A ragged grid still tiles the whole window")
    func raggedGridTilesWhole() {
        let layout = SplitEven.layout(count: 5, as: .grid)!
        let frames = layout.frames()
        let area = frames.values.reduce(0.0) { $0 + $1.width * $1.height }

        #expect(layout.paneCount == 5)
        #expect(abs(area - 1.0) < 1e-9)
        #expect(layout.isValid)
    }

    @Test("An arrangement the count does not earn builds nothing")
    func unearnedArrangementBuildsNothing() {
        #expect(SplitEven.layout(count: 2, as: .grid) == nil)
        #expect(SplitEven.layout(count: 1, as: .sideBySide) == nil)
        #expect(SplitEven.layout(count: SplitEven.limit + 1, as: .grid) == nil)
    }
}
