import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural stage metrics")
struct NeuralStageMetricsTests {
    typealias M = NeuralStageMetrics

    private func make(
        _ width: Double, _ density: ChatDensity = .comfortable, input: ChatInput = .pointer,
        zones: Int = 6
    ) -> M {
        M.make(width: width, density: density, input: input, zonesWithSteps: zones)
    }

    private let widths: [Double] = [380, 459, 460, 559, 560, 700, 859, 860, 1100, 1300, 1600]

    @Test("the card is 112 tall with a 132 by 96 picture when comfortable, 84 and 100 by 72 when compact")
    func card() {
        let comfortable = make(700)
        #expect(comfortable.cardHeight == 112)
        #expect(comfortable.card.layout == .wide)
        #expect(comfortable.card.picture.width == 132)
        #expect(comfortable.card.picture.height == 96)
        #expect(comfortable.card.picture.y == 8)
        #expect(comfortable.card.edge == 3)
        let compact = make(700, .compact)
        #expect(compact.cardHeight == 84)
        #expect(compact.card.picture.width == 100)
        #expect(compact.card.picture.height == 72)
        #expect(compact.card.picture.y == 6)
        for metrics in [comfortable, compact] {
            let picture = metrics.card.picture
            #expect(picture.x >= metrics.card.edge)
            #expect(picture.y >= 0 && picture.maxY <= metrics.cardHeight)
            #expect(metrics.card.text.x >= picture.maxX)
            #expect(metrics.card.text.maxX <= metrics.width)
        }
    }

    @Test("a narrow row uses the Compact picture and the narrow layout, whatever the density")
    func narrowCard() {
        for width in [380.0, 459] {
            let metrics = make(width)
            #expect(metrics.card.layout == .narrow)
            #expect(metrics.card.picture.width == 100)
            #expect(metrics.card.picture.height == 72)
            #expect(metrics.cardHeight == 112)
            #expect(metrics.card.picture.y == 20)
            #expect(M.cardLayout(width: width) == .narrow)
        }
        #expect(make(460).card.layout == .wide)
        #expect(make(460).card.picture.width == 132)
        #expect(make(380, .compact).card.picture.width == 100)
    }

    @Test("the crop is the head's bounds, design x 64 to 640, an aspect of 576 to 420")
    func crop() {
        #expect(M.designCrop == NeuralRect(x: 64, y: 0, width: 576, height: 420))
        #expect(M.designWidth == 576)
        #expect(abs(M.aspect - 420.0 / 576.0) < 1e-12)
    }

    @Test("the card's picture maps a design point through the same crop")
    func cardMapping() {
        let card = make(700).card
        let origin = card.point(forDesign: NeuralPoint(64, 0))
        #expect(origin.x == card.picture.x && origin.y == card.picture.y)
        let corner = card.point(forDesign: NeuralPoint(640, 420))
        #expect(abs(corner.x - card.picture.maxX) < 1e-9)
        #expect(abs(corner.y - card.picture.maxY) < 1e-9)
        #expect(abs(card.scale.x - 132.0 / 576.0) < 1e-12)
    }

    @Test("the numbers of the fourth pass's table hold: left column 346, 320, 360, 360 and the account the rest")
    func table() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.5 }
        let columns: [(Double, Double, Double)] = [(1280, 346, 910), (1100, 320, 756), (1440, 360, 1056), (1920, 360, 1536)]
        for (width, column, account) in columns {
            let metrics = make(width)
            #expect(metrics.arrangement == .split && metrics.filterStyle == .chips)
            #expect(metrics.column.width == column, "column at \(width)")
            #expect(metrics.stage.width == column && metrics.stage.x == 0)
            #expect(near(metrics.stage.height, column * 420 / 576))
            #expect(metrics.account.width == account && metrics.readout.width == account)
            #expect(metrics.account.x == column + 24)
            #expect(metrics.rowsShown == 9)
            #expect(metrics.filterPanel == nil)
        }
        #expect(near(make(1280).brainHeight, 610))
        #expect(near(make(1100).brainHeight, 591))
        #expect(near(make(1440).brainHeight, 620.5))
        #expect(near(make(1920).brainHeight, 620))
        let w860 = make(860)
        #expect(w860.arrangement == .split && w860.column.width == 320 && w860.account.width == 516)
        for width in [700.0, 520, 380] {
            let accordion = make(width)
            #expect(accordion.arrangement == .accordion && accordion.filterStyle == .chips)
            #expect(accordion.stage.width == 280 && near(accordion.stage.height, 204))
            #expect(accordion.column.width == width && accordion.readout == .zero)
            #expect(accordion.account == accordion.list && accordion.detail == nil)
            #expect(accordion.rowsShown == 8)
        }
        #expect(M.Arrangement.stacked == .accordion)
    }

    @Test("the left column is 27 percent of the row between 320 and 360 and the head is as wide as it, keeping its 576 to 420 aspect exactly")
    func head() {
        #expect(make(860).stage.width == 320)
        #expect(make(1000).stage.width == 320)
        #expect(make(1280).stage.width == 346)
        #expect(make(1300).stage.width == 351)
        #expect(make(1440).stage.width == 360)
        #expect(make(1920).stage.width == 360)
        for width in widths {
            for density in [ChatDensity.comfortable, .compact] {
                let metrics = make(width, density)
                #expect(abs(metrics.stage.height * 576 - metrics.stage.width * 420) < 1e-9)
                #expect(abs(metrics.designScale * 576 - metrics.stage.width) < 1e-9)
                #expect(metrics.stage.y == 0)
                #expect(M.aspect == 420.0 / 576.0)
            }
        }
        #expect(make(200).stage.width == 200)
        #expect(M.columnWidth(rowWidth: 1280) == 346 && M.headWidth(rowWidth: 1280) == 346)
    }

    @Test("in a split the head is the top of the left column, the leader's 24 points run to the account")
    func splitRegions() {
        for width in [860.0, 1000, 1280, 1600] {
            let metrics = make(width)
            #expect(metrics.stage.x == 0 && metrics.stage.maxX == metrics.column.width)
            #expect(metrics.readout.x == metrics.column.width + M.gutter)
            #expect(metrics.readout.y == 0 && metrics.readout.height == metrics.brainHeight)
            #expect(metrics.readout.maxX <= width + 1e-9)
            #expect(metrics.hasLeader)
            #expect(metrics.list.maxY <= metrics.brainHeight + 1e-9)
            #expect(metrics.filterChips!.y == metrics.stage.maxY + M.regionGap)
            #expect(metrics.list.y == metrics.filterChips!.y + M.chipsBlock)
            #expect(metrics.footer.y > metrics.brainHeight)
            #expect(metrics.footer.width == width)
            #expect(metrics.rowHeight == metrics.footer.maxY)
            #expect(metrics.filterPanel == nil)
        }
    }

    @Test("the account takes everything the left column and the gutter leave, never under 360")
    func accountWidth() {
        for width in stride(from: 860.0, through: 3000, by: 4) {
            let metrics = make(width)
            #expect(metrics.account.width >= 360)
            #expect(abs(metrics.account.width - (width - 24 - metrics.column.width)) < 1e-9)
            #expect(metrics.account == metrics.readout)
        }
        #expect(M.readoutWidth(rowWidth: 1280) == 910)
        #expect(M.accountMin == 360)
        #expect(make(3000).account.width == 3000 - 24 - 360)
    }

    @Test("the account is one column under 924 and two from it, the story 42 percent between 440 and 680")
    func accountLayout() {
        for (width, layout) in [(860.0, M.AccountLayout.single), (1100, .single), (1280, .single), (1290, .single), (1300, .split), (1310, .split), (1440, .split), (1920, .split)] {
            #expect(make(width).accountLayout == layout, "at \(width)")
        }
        #expect(M.splitAccountMin == 924)
        let wide = make(1440)
        #expect(wide.story.width == 444 && wide.detail?.width == 588)
        #expect(wide.detail!.x == wide.story.maxX + 24)
        #expect(wide.detail!.maxX == wide.account.maxX)
        let huge = make(1920)
        #expect(huge.story.width == 645 && huge.detail?.width == 867)
        for width in stride(from: 1300.0, through: 3000, by: 5) {
            let metrics = make(width)
            guard let detail = metrics.detail else { continue }
            #expect(metrics.story.width >= 440 && metrics.story.width <= 680)
            #expect(detail.width >= 460 - 1e-9)
            #expect(abs(metrics.story.width + 24 + detail.width - metrics.account.width) < 1e-9)
        }
        let single = make(1280)
        #expect(single.story.width == 760 && single.detail == nil)
        #expect(single.story.x == single.account.x && single.story.height == single.account.height)
        #expect(make(1100).story.width == 756)
        #expect(make(860).story.width == 516)
        #expect(M.storyWidth(accountWidth: 910) == 760 && M.storyWidth(accountWidth: 1056) == 444)
        #expect(M.accountLayout(accountWidth: 923.9) == .single && M.accountLayout(accountWidth: 924) == .split)
    }

    @Test("prose stops at 36 em, 540 points, about 78 characters, inside the story")
    func prose() {
        #expect(M.proseMeasure == 540 && M.proseMeasureCharacters == 78)
        #expect(make(1280).proseWidth == 540)
        #expect(make(1440).proseWidth == 444)
        #expect(make(380).proseWidth == 380)
        #expect(make(1920).proseWidth == 540)
    }

    @Test("the open brain is the head, a gap, the chips and the list block, never under 460")
    func brainHeight() {
        for width in [860.0, 1000, 1280, 1600] {
            let metrics = make(width)
            let block = M.listHeaderHeight + Double(metrics.rowsShown) * 28 + M.listFootPadding + M.listHintHeight
            let sum = metrics.stage.height + 8 + M.chipsBlock + block
            #expect(abs(metrics.brainHeight - max(460, sum)) < 1e-9)
            #expect(metrics.brainHeight >= 460)
            #expect(metrics.readout.height == metrics.brainHeight)
        }
        let few = M.make(width: 1000, density: .comfortable, rows: 3)
        #expect(few.brainHeight == 460)
        #expect(few.rowsShown == 3)
        #expect(M.readoutMinHeight == 460 && make(1000).readoutMinHeight == 460)
    }

    @Test("rows listed: 9 in a split, 8 in an accordion, or the viewport rule between 8 and 14")
    func rows() {
        #expect(make(1000).rowsShown == 9 && make(1280).rowsShown == 9 && make(859).rowsShown == 8)
        #expect(M.rows(forViewportHeight: 600, head: 204) == 8)
        #expect(M.rows(forViewportHeight: 1_000, head: 204) == 9)
        #expect(M.rows(forViewportHeight: 1_400, head: 204) == 14)
        #expect(M.rows(forViewportHeight: 4_000, head: 204) == 14)
        let tall = M.make(width: 1280, density: .comfortable, viewportHeight: 1_200)
        #expect(tall.rowsShown == M.rows(forViewportHeight: 1_200, head: tall.stage.height))
        #expect(tall.brainHeight > make(1280).brainHeight - 1e-9)
        #expect(M.make(width: 1000, density: .comfortable, rows: 12).rowsShown == 12)
        #expect(M.make(width: 1000, density: .comfortable, rows: 0).rowsShown == 1)
    }

    @Test("the list block: header 36, rows 28 or 32, foot 4, hint 24, short of the gutter by 12")
    func listBlock() {
        let metrics = make(1280)
        #expect(metrics.listHeader.height == 36)
        #expect(metrics.listRows.y == metrics.listHeader.maxY)
        #expect(metrics.listRows.height == 9 * 28)
        #expect(metrics.listRowHeight == 28)
        #expect(metrics.listHint?.height == 24)
        #expect(metrics.listHint?.y == metrics.listRows.maxY + 4)
        #expect(metrics.list.maxY == metrics.listHint?.maxY)
        #expect(metrics.list.width == metrics.column.width - 12)
        let touch = make(1280, input: .touch)
        #expect(touch.listRowHeight == 32 && touch.listRows.height == 9 * 32)
        #expect(M.listRowHeight(input: .pointer) == 28 && M.listRowHeight(input: .touch) == 32)
    }

    @Test("the key-cap hint is hidden under 520")
    func hint() {
        #expect(make(519).listHint == nil)
        #expect(make(380).listHint == nil)
        #expect(make(520).listHint != nil)
        #expect(make(1280).listHint != nil)
        #expect(make(380).list.height == 36 + 8 * 28 + 4)
    }

    @Test("an accordion list has the full width, at most 300 tall for a pointer and 340 for a finger")
    func accordionList() {
        for width in [380.0, 520, 700, 859] {
            let metrics = make(width)
            #expect(metrics.arrangement == .accordion)
            #expect(metrics.list.width == width && metrics.list.x == 0)
            #expect(metrics.list.y > metrics.filterChips!.maxY)
            #expect(metrics.filterChips?.width == width)
            #expect(metrics.stage.x == (width - 280) / 2)
            #expect(!metrics.hasLeader)
        }
        #expect(M.listMaxHeight(input: .pointer) == 300 && M.listMaxHeight(input: .touch) == 340)
        #expect(make(700).listMaxHeight == 300 && make(700, input: .touch).listMaxHeight == 340)
        let many = M.make(width: 700, density: .comfortable, rows: 14)
        #expect(many.rowsShown == 10 && many.listRows.height <= 300)
        let touchMany = M.make(width: 700, density: .comfortable, input: .touch, rows: 14)
        #expect(touchMany.rowsShown == 10 && touchMany.listRows.height <= 340)
        let wide = M.make(width: 1280, density: .comfortable, rows: 14)
        #expect(wide.rowsShown == 14)
    }

    @Test("an expanded accordion row carries the readout's content: the list's width less its edge and padding, 340 tall at most")
    func accordionContent() {
        let metrics = make(700)
        #expect(metrics.accordionContentWidth == 700 - 3 - 16)
        #expect(metrics.accordionContentMaxHeight == 340)
        #expect(metrics.pinnedRowHeight == metrics.rowHeight + 340)
        #expect(make(1000).pinnedRowHeight == make(1000).rowHeight)
        #expect(make(700).readoutContentWidth == 681)
        #expect(make(1000).readoutContentWidth == make(1000).story.width - 36)
    }

    @Test("the filter panel is gone: the zone chips sit under the head at every width, the failed toggle lives in the list header")
    func filterChips() {
        for width in [380.0, 700, 860, 1000, 1280, 1920] {
            let metrics = make(width)
            #expect(metrics.filterStyle == .chips)
            #expect(metrics.filterPanel == nil)
            let chips = metrics.filterChips
            #expect(chips != nil && chips?.height == 28)
            #expect(chips?.y == metrics.stage.maxY + 8)
            #expect(chips?.width == metrics.column.width)
            #expect(metrics.list.y == chips!.y + 34)
        }
        #expect(make(1280, zones: 2).filterStyle == .chips && make(1280, zones: 6).filterStyle == .chips)
    }

    @Test("output is eight lines in a card 480 wide or more and five under it")
    func outputLines() {
        #expect(make(1920).outputLinesShown == 8)
        #expect(make(1440).detail!.width == 588 && make(1440).outputLinesShown == 8)
        #expect(make(1280).outputLinesShown == 8)
        #expect(make(860).readoutContentWidth == 480 && make(860).outputLinesShown == 8)
        #expect(make(700).outputLinesShown == 8)
        #expect(make(520).outputLinesShown == 8)
        #expect(make(380).outputLinesShown == 5)
        #expect(M.readoutFade == 16)
        #expect(M.cardHang == 36)
    }

    @Test("the stage grows with the row inside each arrangement and never past its cap")
    func monotonic() {
        for range in [(380.0, 859.0), (860, 2400)] {
            var previous = 0.0
            var previousReadout = 0.0
            for width in stride(from: range.0, through: range.1, by: 1) {
                let metrics = make(width)
                #expect(metrics.stage.width >= previous - 1e-9, "at \(width)")
                #expect(metrics.stage.width <= 360 + 1e-9)
                #expect(metrics.readout.width >= previousReadout - 1e-9)
                previous = metrics.stage.width
                previousReadout = metrics.readout.width
            }
        }
    }

    @Test("the gutter belongs to the head for hover, and the readout owns only its own rectangle")
    func hoverGutter() {
        let metrics = make(1100)
        #expect(metrics.stageHover.x == metrics.stage.x)
        #expect(metrics.stageHover.maxX == metrics.readout.x)
        #expect(metrics.stageHover.width == metrics.stage.width + M.gutter)
        #expect(metrics.stageHover.height == metrics.stage.height)
        let beside = NeuralPoint(metrics.stage.maxX + 10, 10)
        #expect(!metrics.readout.contains(beside))
        #expect(metrics.stageHover.contains(beside))
        #expect(make(700).stageHover == make(700).stage)
    }

    @Test("the footer drops Close under 960 and Replay becomes its icon with the chips gone under 640")
    func footer() {
        let kinds = { (width: Double) in M.footerParts(width: width).map(\.kind) }
        #expect(kinds(1300) == [.replay, .scrubber, .time, .answerChips, .rows, .share, .close])
        #expect(kinds(960) == [.replay, .scrubber, .time, .answerChips, .rows, .share, .close])
        #expect(kinds(959) == [.replay, .scrubber, .time, .answerChips, .rows, .share])
        #expect(kinds(640) == [.replay, .scrubber, .time, .answerChips, .rows, .share])
        #expect(kinds(639) == [.replay, .scrubber, .time, .rows, .share])
        #expect(kinds(380) == [.replay, .scrubber, .time, .rows, .share])
        #expect(M.footerParts(width: 700).first == M.FooterPart(kind: .replay, isIcon: false))
        #expect(M.footerParts(width: 639).first == M.FooterPart(kind: .replay, isIcon: true))
        for width in [380.0, 700, 1300] {
            #expect(kinds(width).contains(.rows) && kinds(width).contains(.share))
            #expect(make(width).footerParts() == M.footerParts(width: width))
        }
    }

    @Test("a design point maps onto the head through the crop, and back")
    func mapping() {
        for width in [1100.0, 700] {
            let metrics = make(width)
            let origin = metrics.point(forDesign: NeuralPoint(64, 0))
            #expect(origin.x == metrics.stage.x && origin.y == metrics.stage.y)
            let corner = metrics.point(forDesign: NeuralPoint(640, 420))
            #expect(abs(corner.x - metrics.stage.maxX) < 1e-9)
            #expect(abs(corner.y - metrics.stage.maxY) < 1e-9)
            for design in [NeuralPoint(64, 0), NeuralPoint(300, 200), NeuralPoint(640, 420)] {
                let back = metrics.designPoint(forRow: metrics.point(forDesign: design))
                #expect(abs(back.x - design.x) < 1e-9 && abs(back.y - design.y) < 1e-9)
            }
            #expect(abs(metrics.designLength(forPoints: metrics.designScale * 7) - 7) < 1e-9)
        }
    }

    @Test("a pointer hit goes through the crop and the head's offset")
    func hitThroughCrop() throws {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let metrics = make(1100)
        for step in model.steps.prefix(6) {
            let design = try #require(model.point(of: step.id))
            let row = metrics.point(forDesign: design)
            #expect(model.hit(atRow: row, in: metrics, slopPoints: 0) == step.id)
            let near = NeuralPoint(row.x + metrics.designScale * NeuralDesign.nodeRadius + 2, row.y)
            #expect(model.hit(atRow: near, in: metrics, slopPoints: 0) != step.id)
            #expect(model.hit(atRow: near, in: metrics, slopPoints: 4) == step.id)
        }
    }

    @Test("the leader ends on the node's own row at the hairline, held inside the header and footer")
    func leaderAnchor() throws {
        let metrics = make(1100)
        let middle = NeuralPoint(300, 200)
        let anchor = try #require(metrics.leaderAnchor(forNodeAt: middle))
        #expect(anchor.x > 640)
        let landed = metrics.point(forDesign: anchor)
        #expect(abs(landed.x - metrics.readout.x) < 1e-9)
        #expect(abs(landed.y - metrics.point(forDesign: middle).y) < 1e-9)
        let tab = try #require(metrics.leaderTab(forNodeAt: middle))
        #expect(tab.width == 3 && tab.height == 24)
        #expect(abs((tab.y + 12) - landed.y) < 1e-9)
        #expect(tab.x <= metrics.readout.x && tab.maxX >= metrics.readout.x + 1)
        let top = try #require(metrics.leaderAnchor(forNodeAt: NeuralPoint(300, 0)))
        #expect(abs(metrics.point(forDesign: top).y - 56) < 1e-9)
        let bottom = try #require(metrics.leaderAnchor(forNodeAt: NeuralPoint(300, 420)))
        #expect(abs(metrics.point(forDesign: bottom).y - metrics.stage.maxY) < 1e-9)
        #expect(metrics.point(forDesign: bottom).y <= metrics.readout.maxY - 48)
        #expect(make(700).leaderAnchor(forNodeAt: middle) == nil)
        #expect(make(700).leaderTab(forNodeAt: middle) == nil)
    }

    @Test("the geometry the transition reads carries the head's rect, the list and panel, and the readout's slide")
    func geometry() {
        let wide = make(1100)
        #expect(wide.cardGeometry.picture == wide.card.picture)
        #expect(wide.cardGeometry.rowHeight == 112)
        #expect(wide.stageGeometry.picture == wide.stage)
        #expect(wide.stageGeometry.rowHeight == wide.rowHeight)
        #expect(wide.stageGeometry.readoutTravel == NeuralPoint(24, 0))
        #expect(wide.stageGeometry.list == wide.list)
        #expect(wide.stageGeometry.panel == wide.filterChips)
        #expect(make(400).stageGeometry.readoutTravel == NeuralPoint(0, 24))
        #expect(make(400).cardGeometry.picture.width == 100)
        #expect(make(400).stageGeometry.picture.x == (400 - 280) / 2)
    }

    @Test("a zero or negative width does not trap")
    func degenerate() {
        #expect(make(0).stage.width == 0)
        #expect(make(-10).width == 0)
    }
}
