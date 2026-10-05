import Foundation
import Testing

@testable import TailscodeCore

/// The new verbs are pure mutations of the one tree all three clients share, so random sequences
/// of them must leave it whole: valid, every surviving pane still there, focus on a pane that
/// exists, and the focus history a faithful record of panes that exist.
@Suite("Tile verbs")
struct TileVerbTests {

    @Test("Random verb sequences keep the tree valid, the ids, the focus and the history")
    func randomSequencesKeepInvariants() {
        for seed in 0..<200 {
            var random = TileRandom(seed: seed &+ 5000)
            var layout = SplitLayout()
            var expected: Set<PaneID> = [layout.focusedPane]
            for step in 0..<40 {
                let size = SplitSize(
                    width: Double(random.int(300...2400)), height: Double(random.int(200...1400)))
                let placement = layout.placement(in: size)
                let ids = layout.paneIDs
                let a = random.pick(ids)
                let b = random.pick(ids)
                let zoomBefore = layout.zoomedPane
                var clearsZoom = false
                switch random.int(0...15) {
                case 0, 1:
                    if layout.paneCount < 10,
                        let fresh = layout.split(a, axis: random.chance(0.5) ? .horizontal : .vertical)
                    {
                        expected.insert(fresh)
                    }
                case 2:
                    if layout.close(a) != nil { expected.remove(a) }
                case 3: clearsZoom = layout.swap(a, b)
                case 4: clearsZoom = layout.promote(a)
                case 5: clearsZoom = layout.rotate(forward: random.chance(0.5))
                case 6:
                    clearsZoom = layout.move(a, onto: b, edge: random.pick(PaneDropEdge.allCases))
                case 7:
                    clearsZoom = layout.moveToEdge(a, edge: random.pick(SplitDirection.allCases))
                case 8:
                    let arrangement = random.pick(SplitArrangement.allCases)
                    layout.arrange(arrangement, order: ids.shuffledDeterministically(&random))
                    #expect(layout.zoomedPane == zoomBefore, "seed \(seed) step \(step)")
                case 9: layout.toggleZoom(a)
                case 10:
                    layout.nudge(
                        a, toward: random.pick(SplitDirection.allCases),
                        by: Double(random.int(-80...80)), in: placement)
                case 11:
                    if let divider = placement.dividers.first {
                        layout.drag(
                            divider.id, to: Double(random.int(-200...2600)), in: placement)
                    }
                case 12: layout.cycleFocus(forward: random.chance(0.5), skipping: placement)
                case 13: layout.focus(a)
                case 14:
                    layout.resize(a, random.pick(SplitDirection.allCases), in: placement)
                default:
                    layout.exchange(a)
                    layout.equalize()
                }
                if clearsZoom {
                    #expect(layout.zoomedPane == nil, "seed \(seed) step \(step): kept the zoom")
                }
                #expect(layout.isValid, "seed \(seed) step \(step)")
                #expect(Set(layout.paneIDs) == expected, "seed \(seed) step \(step)")
                #expect(layout.contains(layout.focusedPane), "seed \(seed) step \(step)")
                let history = layout.focusHistory
                #expect(history.last == layout.focusedPane, "seed \(seed) step \(step)")
                #expect(Set(history).count == history.count, "seed \(seed) step \(step)")
                #expect(history.allSatisfy(layout.contains), "seed \(seed) step \(step)")
            }
        }
    }

    @Test("Swap exchanges two leaves anywhere and leaves ids, focus and history alone")
    func swapExchangesLeaves() throws {
        var layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let ids = layout.paneIDs
        layout.focus(ids[1])
        let history = layout.focusHistory
        layout.toggleZoom(ids[1])

        let outcome1 = layout.swap(ids[0], ids[3])
        #expect(outcome1)
        #expect(layout.paneIDs == [ids[3], ids[1], ids[2], ids[0]])
        #expect(layout.focusedPane == ids[1])
        #expect(layout.focusHistory == history)
        #expect(layout.zoomedPane == nil)
        let outcome2 = layout.swap(ids[0], ids[0])
        #expect(!outcome2)
        let outcome3 = layout.swap(ids[0], PaneID())
        #expect(!outcome3)
    }

    @Test("Promote puts a pane in the main slot, and promoting main swaps with the next")
    func promoteUsesTheMainSlot() throws {
        var layout = try #require(SplitEven.arrange(ids: (0..<4).map { _ in PaneID() }, as: .mainStack))
        let ids = layout.paneIDs
        #expect(layout.masterPane == ids[0])

        layout.focus(ids[2])
        let outcome4 = layout.promote(ids[2])
        #expect(outcome4)
        #expect(layout.paneIDs == [ids[2], ids[1], ids[0], ids[3]])
        #expect(layout.focusedPane == ids[2])

        let outcome5 = layout.promote(ids[2])
        #expect(outcome5)
        #expect(layout.paneIDs == [ids[1], ids[2], ids[0], ids[3]])
        #expect(layout.focusedPane == ids[1])

        var lone = SplitLayout()
        #expect(lone.masterPane == nil)
        let outcome6 = lone.promote(lone.focusedPane)
        #expect(!outcome6)
    }

    @Test("Rotate cycles the panes through the same shape and the same ratios")
    func rotateKeepsShape() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .grid))
        let ids = layout.paneIDs
        let ratios = TileFixtures.ratios(layout.root)
        let splits = TileFixtures.splitIDs(layout.root)

        layout.rotate(forward: true)
        #expect(layout.paneIDs == [ids[2], ids[0], ids[1]])
        layout.rotate(forward: false)
        #expect(layout.paneIDs == ids)
        #expect(TileFixtures.ratios(layout.root) == ratios)
        #expect(TileFixtures.splitIDs(layout.root) == splits)
    }

    @Test("Move takes a pane out and splits the target on the edge it was dropped on")
    func moveSplitsTheTarget() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .sideBySide))
        let ids = layout.paneIDs

        let outcome7 = layout.move(ids[2], onto: ids[0], edge: .top)
        #expect(outcome7)
        #expect(layout.paneIDs == [ids[2], ids[0], ids[1]])
        #expect(layout.focusedPane == ids[2])
        let frames = layout.frames()
        #expect(frames[ids[2]]!.y < frames[ids[0]]!.y)
        #expect(frames[ids[2]]!.x == frames[ids[0]]!.x)
        let outcome8 = layout.move(ids[1], onto: ids[1], edge: .left)
        #expect(!outcome8)
    }

    @Test("Move to edge gives a pane the whole far side with one pane's share")
    func moveToEdgeTakesTheFarSide() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .sideBySide))
        let ids = layout.paneIDs

        let outcome9 = layout.moveToEdge(ids[0], edge: .down)
        #expect(outcome9)
        let frames = layout.frames()
        #expect(abs(frames[ids[0]]!.width - 1) < 1e-9)
        #expect(abs(frames[ids[0]]!.height - 0.5) < 1e-9)
        #expect(abs(frames[ids[0]]!.y - 0.5) < 1e-9)
        #expect(layout.focusedPane == ids[0])

        let outcome10 = layout.moveToEdge(ids[2], edge: .left)
        #expect(outcome10)
        #expect(layout.paneIDs.first == ids[2])
        #expect(abs(layout.frames()[ids[2]]!.width - 0.5) < 1e-9)
        var lone = SplitLayout()
        let outcome11 = lone.moveToEdge(lone.focusedPane, edge: .left)
        #expect(!outcome11)
    }

    @Test("Arrange rebuilds the shape and keeps ids, focus, zoom and history")
    func arrangeKeepsIdentity() throws {
        var layout = try #require(SplitEven.layout(count: 5, as: .sideBySide))
        let ids = layout.paneIDs
        layout.focus(ids[3])
        layout.toggleZoom(ids[3])
        let history = layout.focusHistory

        let outcome12 = layout.arrange(.mainStack, order: [ids[3]])
        #expect(outcome12)
        #expect(layout.paneIDs == [ids[3], ids[0], ids[1], ids[2], ids[4]])
        #expect(layout.focusedPane == ids[3])
        #expect(layout.zoomedPane == ids[3])
        #expect(layout.focusHistory == history)
        #expect(SplitEven.shape(of: layout) == .mainStack)
        let outcome13 = layout.arrange(.grid)
        #expect(outcome13)
        #expect(Set(layout.paneIDs) == Set(ids))
        #expect(SplitEven.shape(of: layout) == .grid)
    }

    @Test("Cycling focus walks reading order and skips panes hidden for want of room")
    func cycleFocusWalksReadingOrder() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .sideBySide))
        let ids = layout.paneIDs
        layout.focus(ids[0])

        let outcome14 = layout.cycleFocus(forward: true)
        #expect(outcome14 == ids[1])
        let outcome15 = layout.cycleFocus(forward: true)
        #expect(outcome15 == ids[2])
        let outcome16 = layout.cycleFocus(forward: true)
        #expect(outcome16 == ids[0])
        let outcome17 = layout.cycleFocus(forward: false)
        #expect(outcome17 == ids[2])

        layout.focus(ids[1])
        layout.focus(ids[2])
        let crowded = layout.placement(in: SplitSize(width: 450, height: 600))
        #expect(crowded.hidden == [ids[0]])
        let outcome18 = layout.cycleFocus(forward: true, skipping: crowded)
        #expect(outcome18 == ids[1])
        let outcome19 = layout.cycleFocus(forward: true, skipping: crowded)
        #expect(outcome19 == ids[2])

        layout.toggleZoom(ids[2])
        let zoomed = layout.placement(in: SplitSize(width: 1500, height: 600))
        let outcome20 = layout.cycleFocus(forward: true, skipping: zoomed)
        #expect(outcome20 == ids[0])
        #expect(layout.zoomedPane == nil)
    }

    @Test("A drag clamps at both ends, never squeezes a pane, and is idempotent")
    func dragClampsAndIsIdempotent() throws {
        var layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let size = SplitSize(width: 1001, height: 600)
        let split = TileFixtures.splitIDs(layout.root)[0]

        let outcome21 = layout.drag(split, to: -50, in: layout.placement(in: size))
        #expect(outcome21)
        #expect(layout.placement(in: size).dividers[0].position == 200)
        layout.drag(split, to: 5000, in: layout.placement(in: size))
        #expect(layout.placement(in: size).dividers[0].position == 800)
        let outcome22 = layout.drag(SplitID(), to: 300, in: layout.placement(in: size))
        #expect(!outcome22)
        let outcome23 = layout.drag(split, to: .nan, in: layout.placement(in: size))
        #expect(!outcome23)

        for seed in 0..<200 {
            var random = TileRandom(seed: seed &+ 7000)
            var base = TileFixtures.layout(&random)
            let size = SplitSize(
                width: Double(random.int(400...2400)), height: Double(random.int(300...1400)))
            let placement = base.placement(in: size)
            guard let divider = placement.dividers.first else { continue }
            let target = Double(random.int(-300...2700))
            base.drag(divider.id, to: target, in: placement)
            var twice = base
            twice.drag(divider.id, to: target, in: twice.placement(in: size))
            #expect(twice == base, "seed \(seed): a second drag to the same point moved it")
            let after = base.placement(in: size)
            if after.frames.count > 1 {
                for rect in after.frames.values {
                    #expect(rect.width >= 200 - 1e-6 && rect.height >= 88 - 1e-6, "seed \(seed)")
                }
            }
        }
    }

    @Test("Nudge and resize move the divider on the pane's edge by the step")
    func nudgeAndResizeMoveTheEdge() throws {
        var layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let ids = layout.paneIDs
        let size = SplitSize(width: 1001, height: 600)

        let outcome24 = layout.nudge(ids[0], toward: .right, by: 16, in: layout.placement(in: size))
        #expect(outcome24)
        #expect(layout.placement(in: size).dividers[0].position == 516)
        let outcome25 = layout.nudge(ids[1], toward: .right, by: 16, in: layout.placement(in: size))
        #expect(outcome25)
        #expect(layout.placement(in: size).dividers[0].position == 532)
        let outcome26 = layout.nudge(ids[1], toward: .down, by: 16, in: layout.placement(in: size))
        #expect(!outcome26)

        let outcome27 = layout.resize(ids[1], .right, in: layout.placement(in: size))
        #expect(outcome27)
        #expect(layout.placement(in: size).dividers[0].position == 516)
        let outcome28 = layout.resize(ids[0], .left, step: PaneSizing.keyboardStepLarge, in: layout.placement(in: size))
        #expect(outcome28)
        #expect(layout.placement(in: size).dividers[0].position == 452)
    }

    @Test("A split is refused only where a half could not hold a glance")
    func canSplitFollowsTheGlanceMinimum() throws {
        let lone = SplitLayout()
        let roomy = lone.placement(in: SplitSize(width: 1000, height: 600))
        #expect(lone.canSplit(lone.focusedPane, axis: .horizontal, in: roomy))
        #expect(lone.canSplit(lone.focusedPane, axis: .vertical, in: roomy))

        let narrow = lone.placement(in: SplitSize(width: 400, height: 176))
        #expect(!lone.canSplit(lone.focusedPane, axis: .horizontal, in: narrow))
        #expect(!lone.canSplit(lone.focusedPane, axis: .vertical, in: narrow))
        #expect(lone.canSplit(lone.focusedPane, axis: .horizontal, in: lone.placement(in: SplitSize(width: 401, height: 177))))
        #expect(!lone.canSplit(PaneID(), axis: .horizontal, in: roomy))
    }
}

extension Array {
    func shuffledDeterministically(_ random: inout TileRandom) -> [Element] {
        var items = self
        guard items.count > 1 else { return items }
        for index in stride(from: items.count - 1, to: 0, by: -1) {
            items.swapAt(index, random.int(0...index))
        }
        return items
    }
}
