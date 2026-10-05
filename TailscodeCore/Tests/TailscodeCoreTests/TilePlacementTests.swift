import Foundation
import Testing

@testable import TailscodeCore

/// Placement is the only geometry a host draws from, so its promises are pinned as properties
/// over random trees: the rects and seams tile the container, nothing is squeezed below its
/// minimum, what hides is what was least recently used, and a solve never edits the tree.
@Suite("Tile placement")
struct TilePlacementTests {
    private let epsilon = 1e-6

    @Test("Rects and seams tile the container with no gap, no overlap and no pane below its minimum")
    func placementTilesAndRespectsMinimums() {
        for seed in 0..<200 {
            var random = TileRandom(seed: seed)
            var layout = TileFixtures.layout(&random)
            if random.chance(0.15) { layout.toggleZoom(random.pick(layout.paneIDs)) }
            let minimums = TileFixtures.minimums(for: layout, &random)
            let size = SplitSize(
                width: Double(random.int(60...2600)), height: Double(random.int(60...1600)))
            let placement = layout.placement(in: size) { minimums[$0]! }
            check(placement, of: layout, in: size, minimums: minimums, seed: seed)
        }
    }

    @Test("A solve never writes a ratio, and growing the container back restores every rect")
    func solveIsPureAndGrowthRestores() {
        for seed in 0..<200 {
            var random = TileRandom(seed: seed &+ 1000)
            let layout = TileFixtures.layout(&random)
            let minimums = TileFixtures.minimums(for: layout, &random)
            let before = layout
            let large = SplitSize(
                width: Double(random.int(1200...3000)), height: Double(random.int(900...2000)))
            let small = SplitSize(
                width: Double(random.int(100...800)), height: Double(random.int(80...500)))
            let original = layout.placement(in: large) { minimums[$0]! }
            _ = layout.placement(in: small) { minimums[$0]! }
            let restored = layout.placement(in: large) { minimums[$0]! }

            #expect(layout == before, "seed \(seed): a solve changed the layout")
            #expect(
                TileFixtures.ratios(layout.root) == TileFixtures.ratios(before.root),
                "seed \(seed)")
            #expect(restored == original, "seed \(seed): growing back changed the rects")
        }
    }

    @Test("Device-pixel snapping keeps integral sizes on the grid at scale 1 and 2")
    func snappingStaysOnTheGrid() {
        for seed in 0..<200 {
            var random = TileRandom(seed: seed &+ 2000)
            let layout = TileFixtures.layout(&random)
            let scale: Double = random.chance(0.5) ? 1 : 2
            let size = SplitSize(
                width: Double(random.int(400...2400)), height: Double(random.int(300...1400)))
            let placement = layout.placement(in: size, scale: scale)
            for rect in placement.frames.values {
                for value in [rect.x, rect.y, rect.width, rect.height] {
                    let scaled = value * scale
                    #expect(abs(scaled - scaled.rounded()) < 1e-9, "seed \(seed): \(value) off grid")
                }
            }
        }
    }

    @Test("A narrow window hides the least recently focused pane and brings it back on growth")
    func narrowWindowHidesLeastRecent() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .sideBySide))
        let ids = layout.paneIDs
        layout.focus(ids[0])
        layout.focus(ids[2])
        layout.focus(ids[1])

        let narrow = layout.placement(in: SplitSize(width: 500, height: 600))
        #expect(narrow.hidden == [ids[0]])
        #expect(narrow.hiddenReason == .noRoom)
        #expect(narrow.stripNeeded)
        #expect(narrow.strip == SplitRect(x: 0, y: 572, width: 500, height: 28))
        #expect(narrow.bounds.height == 572)
        #expect(narrow.frames[ids[1]] != nil && narrow.frames[ids[2]] != nil)

        let wide = layout.placement(in: SplitSize(width: 1500, height: 600))
        #expect(wide.hidden.isEmpty)
        #expect(!wide.stripNeeded)
        #expect(wide.strip == nil)
        #expect(wide.frames.count == 3)
    }

    @Test("A window too small for anything still shows the focused pane, alone")
    func tinyWindowKeepsTheFocusedPane() throws {
        var layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let focused = layout.paneIDs[3]
        layout.focus(focused)
        let placement = layout.placement(in: SplitSize(width: 120, height: 100))

        #expect(Array(placement.frames.keys) == [focused])
        #expect(placement.hidden.count == 3)
        #expect(placement.frames[focused] == placement.bounds)
        #expect(placement.dividers.isEmpty)
    }

    @Test("A zoom gives one pane the container and names the rest as zoomed away")
    func zoomHidesTheRest() throws {
        var layout = try #require(SplitEven.layout(count: 3, as: .stacked))
        let middle = layout.paneIDs[1]
        layout.toggleZoom(middle)
        let placement = layout.placement(in: SplitSize(width: 800, height: 600))

        #expect(placement.frames == [middle: SplitRect(x: 0, y: 0, width: 800, height: 572)])
        #expect(placement.hidden == [layout.paneIDs[0], layout.paneIDs[2]])
        #expect(placement.hiddenReason == .zoomed)
        #expect(placement.stripNeeded)
        #expect(placement.dividers.isEmpty)
    }

    @Test("A divider carries its seam, its grab band, its parent and its travel")
    func dividerGeometry() throws {
        let layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let placement = layout.placement(in: SplitSize(width: 1001, height: 600))
        let divider = try #require(placement.dividers.first)

        #expect(divider.axis == .horizontal)
        #expect(divider.position == 500)
        #expect(divider.line == SplitRect(x: 500, y: 0, width: 1, height: 600))
        #expect(divider.hit == SplitRect(x: 496, y: 0, width: 9, height: 600))
        #expect(divider.parent == SplitRect(x: 0, y: 0, width: 1001, height: 600))
        #expect(divider.lowest == 200)
        #expect(divider.highest == 800)
        #expect(placement.frames[layout.paneIDs[1]] == SplitRect(x: 501, y: 0, width: 500, height: 600))
    }

    @Test("A host's larger minimum is honoured by max")
    func hostMinimumCombines() throws {
        let layout = try #require(SplitEven.layout(count: 2, as: .sideBySide))
        let draw = layout.paneIDs[0]
        let reported = PaneSizing.draw.combined(with: PaneMinimum(width: 420, height: 100))
        #expect(reported == PaneMinimum(width: 420, height: 300))
        var tight = layout
        tight.setRatio(0.1, of: TileFixtures.splitIDs(layout.root)[0])
        let placement = tight.placement(in: SplitSize(width: 1000, height: 600)) {
            $0 == draw ? reported : PaneSizing.chatGlance
        }
        #expect(placement.frames[draw]?.width == 420)
    }

    @Test("Full density follows the room, with hysteresis on the way back up")
    func fullDensityHysteresis() {
        #expect(PaneSizing.allowsFull(width: 280, height: 200, wasFull: true))
        #expect(!PaneSizing.allowsFull(width: 279, height: 200, wasFull: true))
        #expect(!PaneSizing.allowsFull(width: 290, height: 210, wasFull: false))
        #expect(PaneSizing.allowsFull(width: 296, height: 216, wasFull: false))
        #expect(PaneSizing.minimum(kind: .chat, density: .full) == PaneMinimum(width: 280, height: 200))
        #expect(PaneSizing.minimum(kind: .chat, density: .glance) == PaneMinimum(width: 200, height: 88))
        #expect(PaneSizing.minimum(kind: .video, density: .parked) == PaneMinimum(width: 280, height: 158))
        #expect(PaneSizing.minimum(kind: .empty, density: .full) == PaneMinimum(width: 240, height: 160))
        #expect(PaneSizing.layoutMinimum(kind: .chat) == PaneSizing.chatGlance)
        #expect(PaneSizing.layoutMinimum(kind: .draw) == PaneMinimum(width: 360, height: 300))
        #expect(PaneSizing.gutter == 1 && PaneSizing.dividerHit == 9 && PaneSizing.stripHeight == 28)
    }

    private func check(
        _ placement: PanePlacement, of layout: SplitLayout, in size: SplitSize,
        minimums: [PaneID: PaneMinimum], seed: Int
    ) {
        let ids = layout.paneIDs
        let placed = Set(placement.frames.keys)
        let hidden = Set(placement.hidden)
        #expect(placed.isDisjoint(with: hidden), "seed \(seed)")
        #expect(placed.union(hidden) == Set(ids), "seed \(seed)")
        #expect(placement.hidden == ids.filter(hidden.contains), "seed \(seed): hidden out of order")
        #expect(placement.stripNeeded == !hidden.isEmpty, "seed \(seed)")

        let bounds = placement.bounds
        let expectedHeight = placement.stripNeeded ? max(0, size.height - 28) : size.height
        #expect(abs(bounds.height - expectedHeight) < epsilon, "seed \(seed)")
        #expect(bounds.width == size.width, "seed \(seed)")

        if let zoomed = layout.zoomedPane {
            #expect(placement.frames == [zoomed: bounds], "seed \(seed)")
            #expect(placement.hiddenReason == (ids.count > 1 ? .zoomed : nil), "seed \(seed)")
            return
        }
        #expect(placed.contains(layout.focusedPane), "seed \(seed): the focused pane hid")
        let order = layout.recency.filter { $0 != layout.focusedPane }
        #expect(
            Set(order.prefix(hidden.count)) == hidden,
            "seed \(seed): hid a pane used more recently than one it kept")
        #expect(placement.hiddenReason == (hidden.isEmpty ? nil : .noRoom), "seed \(seed)")

        let pieces = Array(placement.frames.values) + placement.dividers.map(\.line)
        let area = pieces.reduce(0.0) { $0 + $1.width * $1.height }
        #expect(
            abs(area - bounds.width * bounds.height) < epsilon * max(1, bounds.width * bounds.height),
            "seed \(seed): rects and seams leave a gap")
        for piece in pieces {
            #expect(piece.x >= -epsilon && piece.maxX <= bounds.maxX + epsilon, "seed \(seed)")
            #expect(piece.y >= -epsilon && piece.maxY <= bounds.maxY + epsilon, "seed \(seed)")
        }
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                #expect(
                    TileFixtures.overlap(pieces[i], pieces[j]) < epsilon,
                    "seed \(seed): pieces overlap")
            }
        }
        #expect(placement.dividers.count == max(0, placed.count - 1), "seed \(seed)")

        if placed.count > 1 {
            for (id, rect) in placement.frames {
                let minimum = minimums[id]!
                #expect(rect.width >= minimum.width - epsilon, "seed \(seed): too narrow")
                #expect(rect.height >= minimum.height - epsilon, "seed \(seed): too short")
            }
        }
        for divider in placement.dividers {
            #expect(divider.lowest <= divider.position + epsilon, "seed \(seed)")
            #expect(divider.position <= divider.highest + epsilon, "seed \(seed)")
            #expect(abs(divider.hit.extent(along: divider.axis) - 9) < epsilon, "seed \(seed)")
        }
    }
}
