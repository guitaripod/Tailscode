import Foundation
import Testing

@testable import TailscodeCore

/// Arrangements are shapes the same builder makes for a bulk open and for panes already open, so
/// every one is pinned for every count a person can hold: valid, fair, in the order given, and
/// read back as itself.
@Suite("Tile arrangements")
struct TileArrangementTests {

    @Test("Every arrangement for one to nine panes is valid, keeps the ids and is fair")
    func everyArrangementIsFair() throws {
        for count in 1...9 {
            for arrangement in SplitArrangement.allCases {
                let ids = (0..<count).map { _ in PaneID() }
                let layout = try #require(SplitEven.arrange(ids: ids, as: arrangement))
                #expect(layout.isValid)
                #expect(layout.paneIDs == ids, "\(arrangement) \(count)")
                #expect(layout.focusedPane == ids[0])
                #expect(layout.zoomedPane == nil)
                let frames = layout.frames()
                let area = frames.values.reduce(0.0) { $0 + $1.width * $1.height }
                #expect(abs(area - 1) < 1e-9)
                expectFair(arrangement, frames: frames, ids: ids)
            }
        }
    }

    @Test("A shape reads back as the arrangement that made it wherever the count tells them apart")
    func shapeRoundTrips() throws {
        for count in 3...9 {
            for arrangement in SplitArrangement.allCases {
                let layout = try #require(
                    SplitEven.arrange(ids: (0..<count).map { _ in PaneID() }, as: arrangement))
                #expect(SplitEven.shape(of: layout) == arrangement, "\(arrangement) \(count)")
            }
        }
        let two = try #require(SplitEven.arrange(ids: [PaneID(), PaneID()], as: .mainStack))
        #expect(SplitEven.shape(of: two) == .sideBySide)
        let mainTopTwo = try #require(SplitEven.arrange(ids: [PaneID(), PaneID()], as: .mainTop))
        #expect(SplitEven.shape(of: mainTopTwo) == .stacked)
    }

    @Test("A hand-built split right then down reads as main and stack")
    func handBuiltMainStack() {
        var layout = SplitLayout()
        let first = layout.focusedPane
        let second = layout.split(first, axis: .horizontal)!
        layout.split(second, axis: .vertical)
        #expect(SplitEven.shape(of: layout) == .mainStack)
        layout.split(first, axis: .vertical)
        #expect(SplitEven.shape(of: layout) == .grid)
    }

    @Test("The builder refuses no ids and duplicate ids")
    func builderRefusesBadIds() {
        let id = PaneID()
        #expect(SplitEven.arrange(ids: [], as: .grid) == nil)
        #expect(SplitEven.arrange(ids: [id, id], as: .sideBySide) == nil)
    }

    @Test("The arrange key walks columns, rows, grid, main and stack")
    func cycleOrder() {
        #expect(SplitArrangement.cycle == [.sideBySide, .stacked, .grid, .mainStack])
        #expect(SplitArrangement.sideBySide.nextInCycle == .stacked)
        #expect(SplitArrangement.grid.nextInCycle == .mainStack)
        #expect(SplitArrangement.mainStack.nextInCycle == .sideBySide)
        #expect(SplitArrangement.mainTop.nextInCycle == .sideBySide)
    }

    @Test("Every arrangement has words, a one-column glyph and a symbol")
    func everyArrangementIsNamed() {
        for arrangement in SplitArrangement.allCases {
            #expect(!arrangement.title.isEmpty)
            #expect(arrangement.glyph.count == 1)
            #expect(!arrangement.symbolName.isEmpty)
            #expect(arrangement.caption(count: 4).contains("4"))
            #expect(arrangement.accessibleLabel(count: 4).contains(arrangement.title.lowercased()))
        }
        #expect(Set(SplitArrangement.allCases.map(\.glyph)).count == SplitArrangement.allCases.count)
    }

    @Test("A bulk open builds the offered arrangement with fresh panes")
    func bulkOpenUsesTheBuilder() throws {
        let layout = try #require(SplitEven.layout(count: 6, as: .mainStack))
        #expect(layout.paneCount == 6)
        #expect(SplitEven.shape(of: layout) == .mainStack)
        #expect(SplitEven.layout(count: 2, as: .mainStack) == nil)
        #expect(SplitEven.layout(count: 3, as: .mainTop) == nil)
    }

    private func expectFair(
        _ arrangement: SplitArrangement, frames: [PaneID: SplitRect], ids: [PaneID]
    ) {
        let count = ids.count
        let rects = ids.map { frames[$0]! }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        switch arrangement {
        case .sideBySide:
            #expect(rects.allSatisfy { close($0.width, 1 / Double(count)) && close($0.height, 1) })
            #expect(rects.map(\.x) == rects.map(\.x).sorted())
        case .stacked:
            #expect(rects.allSatisfy { close($0.height, 1 / Double(count)) && close($0.width, 1) })
            #expect(rects.map(\.y) == rects.map(\.y).sorted())
        case .grid:
            let rows = SplitEven.gridRows(count)
            var start = 0
            for width in rows {
                let row = rects[start..<(start + width)]
                #expect(row.allSatisfy { close($0.height, 1 / Double(rows.count)) })
                #expect(row.allSatisfy { close($0.width, 1 / Double(width)) })
                start += width
            }
        case .mainStack, .mainTop:
            guard count > 1 else {
                #expect(close(rects[0].width, 1) && close(rects[0].height, 1))
                return
            }
            let main = arrangement == .mainStack ? rects[0].width : rects[0].height
            #expect(close(main, SplitEven.mainRatio))
            for rect in rects.dropFirst() {
                let share = arrangement == .mainStack ? rect.height : rect.width
                #expect(close(share, 1 / Double(count - 1)))
            }
        }
    }
}
