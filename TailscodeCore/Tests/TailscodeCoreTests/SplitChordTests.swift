import Foundation
import Testing

@testable import TailscodeCore

/// The registered pane chords reach the tree through one function, so both desktops dispatch
/// identically; these pin what each chord does, what it leaves alone, and how a divider key moves.
@Suite("Split chords")
struct SplitChordTests {
    private let size = SplitSize(width: 1200, height: 800)

    private func four() -> SplitLayout {
        let ids = (0..<4).map { _ in PaneID() }
        var layout = SplitEven.arrange(ids: ids, as: .sideBySide)!
        layout.focus(ids[2])
        return layout
    }

    @Test("The arrange chord walks columns, rows, grid, main and stack, keeping every pane and the focus")
    func arrangeWalksTheCycle() {
        var layout = four()
        let ids = layout.paneIDs
        let focus = layout.focusedPane
        var seen: [SplitArrangement] = [SplitEven.shape(of: layout)]
        for _ in 0..<4 {
            let effect = layout.perform(.arrangeSplits, placement: layout.placement(in: size))
            #expect(effect == .restructured)
            #expect(layout.isValid)
            #expect(Set(layout.paneIDs) == Set(ids))
            #expect(layout.focusedPane == focus)
            seen.append(SplitEven.shape(of: layout))
        }
        #expect(seen == [.sideBySide, .stacked, .grid, .mainStack, .sideBySide])
    }

    @Test("Main on top steps back into the cycle at columns")
    func mainTopRejoinsTheCycle() {
        var layout = four()
        layout.choose(.mainTop)
        #expect(SplitEven.shape(of: layout) == .mainTop)
        layout.perform(.arrangeSplits, placement: layout.placement(in: size))
        #expect(SplitEven.shape(of: layout) == .sideBySide)
    }

    @Test("A lone pane has nothing to arrange, promote, rotate or move")
    func loneWindowIsLeftAlone() {
        var layout = SplitLayout()
        let before = layout
        let placement = layout.placement(in: size)
        for action in [
            KeyAction.arrangeSplits, .promoteSplit, .rotateSplits(true), .rotateSplits(false),
            .moveSplitToEdge(.left), .resizeSplit(.right), .cycleSplit(true),
        ] {
            #expect(layout.perform(action, placement: placement) == nil)
        }
        #expect(layout == before)
    }

    @Test("Promote, rotate and edge moves restructure and keep the focus on its pane")
    func structuralChordsKeepTheFocus() {
        for action in [
            KeyAction.promoteSplit, .rotateSplits(true), .rotateSplits(false),
            .moveSplitToEdge(.left), .moveSplitToEdge(.down), .moveSplitToEdge(.up),
            .moveSplitToEdge(.right),
        ] {
            var layout = four()
            let ids = Set(layout.paneIDs)
            let focus = layout.focusedPane
            #expect(layout.perform(action, placement: layout.placement(in: size)) == .restructured)
            #expect(layout.isValid)
            #expect(Set(layout.paneIDs) == ids)
            #expect(layout.focusedPane == focus)
        }
    }

    @Test("A structural chord unzooms, as a swap does")
    func structuralChordsUnzoom() {
        var layout = four()
        layout.toggleZoom(layout.focusedPane)
        layout.perform(.rotateSplits(true), placement: layout.placement(in: size))
        #expect(layout.zoomedPane == nil)
    }

    @Test("The resize chords move the nearest divider sixteen points and report only ratios")
    func resizeChordsMoveSixteen() {
        var layout = four()
        let focus = layout.focusedPane
        let before = layout.placement(in: size).frames[focus]!
        #expect(layout.perform(.resizeSplit(.right), placement: layout.placement(in: size)) == .resized)
        let wider = layout.placement(in: size).frames[focus]!
        #expect(abs((wider.width - before.width) - PaneSizing.keyboardStep) <= 1)
        #expect(layout.perform(.resizeSplit(.left), placement: layout.placement(in: size)) == .resized)
        let back = layout.placement(in: size).frames[focus]!
        #expect(abs(back.width - before.width) <= 1)
    }

    @Test("Resizing along an axis with no divider does nothing")
    func resizeWithoutADividerIsNil() {
        var layout = four()
        #expect(layout.perform(.resizeSplit(.down), placement: layout.placement(in: size)) == nil)
    }

    @Test("Held down, a resize chord stops where the neighbour reaches its minimum")
    func resizeNeverSqueezes() {
        var layout = four()
        for _ in 0..<200 {
            layout.perform(.resizeSplit(.right), placement: layout.placement(in: size))
        }
        let placement = layout.placement(in: size)
        for frame in placement.frames.values {
            #expect(frame.width >= PaneSizing.chatGlance.width - 1e-6)
        }
        for _ in 0..<200 {
            layout.perform(.resizeSplit(.left), placement: layout.placement(in: size))
        }
        for frame in layout.placement(in: size).frames.values {
            #expect(frame.width >= PaneSizing.chatGlance.width - 1e-6)
        }
    }

    @Test("The cycle chord moves focus and reports it")
    func cycleChordRefocuses() {
        var layout = four()
        let start = layout.focusedPane
        #expect(layout.perform(.cycleSplit(true), placement: layout.placement(in: size)) == .refocused)
        #expect(layout.focusedPane != start)
    }

    @Test("A divider key steps sixteen, sixty-four with shift, and Home and End reach the extremes")
    func dividerKeysStep() throws {
        var layout = SplitLayout()
        layout.split(layout.focusedPane, axis: .horizontal)
        let id = try #require(layout.placement(in: size).dividers.first).id
        func divider() -> DividerPlacement { layout.placement(in: size).divider(id)! }
        func step(_ key: DividerKey) -> Bool {
            let placement = layout.placement(in: size)
            return layout.move(id, by: key, in: placement)
        }
        let start = divider().position
        #expect(step(.forward(large: false)))
        #expect(abs(divider().position - (start + 16)) <= 1)
        #expect(step(.back(large: true)))
        #expect(abs(divider().position - (start + 16 - 64)) <= 1)
        #expect(step(.lowest))
        #expect(abs(divider().position - divider().lowest) <= 1)
        #expect(step(.highest))
        #expect(abs(divider().position - divider().highest) <= 1)
    }

    @Test("A divider the placement does not hold ignores keys")
    func unknownDividerIgnoresKeys() {
        var layout = four()
        let placement = layout.placement(in: size)
        let moved = layout.move(SplitID(), by: .lowest, in: placement)
        #expect(!moved)
    }

    @Test("A divider names the panes on its two sides")
    func sidesNameThePanes() throws {
        let layout = four()
        let ids = layout.paneIDs
        let first = try #require(layout.placement(in: size).dividers.first)
        let sides = try #require(layout.sides(of: first.id))
        #expect(sides.first == [ids[0]])
        #expect(sides.second == Array(ids.dropFirst()))
        #expect(layout.sides(of: SplitID()) == nil)
    }

    @Test("Every divider is listed once, outermost first")
    func splitIDsListEveryDivider() {
        let layout = SplitEven.arrange(ids: four().paneIDs, as: .grid)!
        let listed = layout.splitIDs
        #expect(listed.count == 3)
        #expect(Set(listed).count == 3)
        #expect(Set(listed) == Set(layout.placement(in: size).dividers.map(\.id)))
        #expect(SplitLayout().splitIDs.isEmpty)
    }

    @Test("A divider reads as a percentage between its extremes")
    func dividerReadsAsAPercentage() {
        func divider(position: Double) -> DividerPlacement {
            DividerPlacement(
                id: SplitID(), axis: .horizontal, line: .unit, hit: .unit, parent: .unit,
                position: position, lowest: 100, highest: 300)
        }
        #expect(DividerReading.percent(divider(position: 100)) == 0)
        #expect(DividerReading.percent(divider(position: 200)) == 50)
        #expect(DividerReading.percent(divider(position: 300)) == 100)
        #expect(DividerReading.percent(divider(position: 9000)) == 100)
    }

    @Test("The menu names only verbs the registry has, and each is a tree verb")
    func menuVerbsAreRegistered() {
        for group in SplitMenu.groups {
            #expect(!group.shortcutIDs.isEmpty)
            for id in group.shortcutIDs {
                let definition = SplitMenu.definition(id)
                #expect(definition != nil, "\(id)")
                var layout = SplitEven.arrange(ids: four().paneIDs, as: .grid)!
                let placement = layout.placement(in: size)
                #expect(
                    definition.flatMap { layout.perform($0.action, placement: placement) } != nil,
                    "\(id)")
            }
        }
    }
}
