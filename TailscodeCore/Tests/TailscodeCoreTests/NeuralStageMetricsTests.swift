import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural stage metrics")
struct NeuralStageMetricsTests {
    typealias M = NeuralStageMetrics

    private func make(_ width: Double, _ density: ChatDensity = .comfortable) -> M {
        M.make(width: width, density: density)
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

    @Test("under 560 the stage is the row's full width, capped at 760, with the readout below as a strip")
    func stacked() {
        for width in [380.0, 459, 460, 559] {
            let metrics = make(width)
            #expect(metrics.arrangement == .stacked)
            #expect(metrics.stage.x == 0 && metrics.stage.y == 0)
            #expect(metrics.stage.width == width)
            #expect(metrics.readout.y >= metrics.stage.maxY)
            #expect(metrics.readout.width == width)
            #expect(metrics.readout.height == M.stripHeight)
            #expect(!metrics.hasLeader)
            #expect(metrics.leaderAnchor(forNodeAt: NeuralPoint(300, 200)) == nil)
            #expect(metrics.leaderTab(forNodeAt: NeuralPoint(300, 200)) == nil)
            #expect(metrics.readoutExpanded.height == 340)
            #expect(metrics.readoutExpanded.y == metrics.readout.y)
            #expect(metrics.footer.y >= metrics.readout.maxY)
            #expect(metrics.stageHover == metrics.stage)
            #expect(metrics.pinnedRowHeight > metrics.rowHeight)
        }
    }

    @Test("from 560 the stage and the readout sit side by side")
    func split() {
        for width in [560.0, 700, 859, 860, 1100, 1300, 1600] {
            let metrics = make(width)
            #expect(metrics.arrangement == .split)
            #expect(metrics.stage.x == 0)
            #expect(metrics.readout.x == metrics.stage.maxX + M.gutter)
            #expect(metrics.readout.maxX <= width + 1e-9)
            #expect(metrics.hasLeader)
            #expect(metrics.readout.y == 0)
            #expect(metrics.readoutExpanded == metrics.readout)
            #expect(metrics.footer.y > metrics.readout.maxY)
            #expect(metrics.footer.width == width)
            #expect(metrics.rowHeight == metrics.footer.maxY)
        }
    }

    @Test("the stage keeps the head's trimmed 576 by 420 aspect exactly at every width")
    func aspect() {
        for width in widths {
            for density in [ChatDensity.comfortable, .compact] {
                let metrics = make(width, density)
                #expect(abs(metrics.stage.height * 576 - metrics.stage.width * 420) < 1e-9)
                #expect(abs(metrics.designScale * 576 - metrics.stage.width) < 1e-9)
            }
        }
    }

    @Test("the stage is 54 percent of the row between 420 and 720 from 860, and 760 at most")
    func stageWidth() {
        #expect(abs(make(860).stage.width - 464.4) < 1e-9)
        #expect(abs(make(1100).stage.width - 594) < 1e-9)
        #expect(make(1300).stage.width == 716)
        #expect(make(1600).stage.width == 760)
        for width in widths where width >= 860 {
            let stage = make(width).stage.width
            #expect(stage >= 420 && stage <= 760)
        }
    }

    @Test("in the middle band the stage is half the row and the readout never drops under 300")
    func middleBand() {
        #expect(make(700).stage.width == 350)
        #expect(make(859).stage.width == 429.5)
        #expect(make(700).readoutType == .stepDown)
        #expect(make(860).readoutType == .regular)
        for width in stride(from: 560.0, through: 859, by: 1) {
            let metrics = make(width)
            #expect(metrics.readout.width >= 300 - 1e-9)
            #expect(metrics.stage.width <= width * 0.5 + 1e-9)
        }
    }

    @Test("the readout is at least 300 and at most 560 wide wherever it sits beside the stage")
    func readoutWidth() {
        for width in stride(from: 560.0, through: 2400, by: 4) {
            let metrics = make(width)
            #expect(metrics.readout.width >= 300 - 1e-9, "at \(width)")
            #expect(metrics.readout.width <= 560 + 1e-9, "at \(width)")
        }
        #expect(make(1300).readout.width == 560)
        #expect(make(1600).readout.width == 560)
    }

    @Test("the readout is as tall as the stage in a split, and never under 420, which the row is too")
    func readoutHeight() {
        for width in widths where width >= 560 {
            let metrics = make(width)
            #expect(metrics.readout.height == max(metrics.stage.height, 420))
            #expect(metrics.readout.height >= 420)
            #expect(metrics.footer.y > metrics.readout.maxY)
            #expect(metrics.rowHeight > 420)
        }
        #expect(make(1100).readout.height == make(1100).stage.height)
        #expect(make(1100).stage.height > 420)
        #expect(make(700).readout.height == 420)
        #expect(make(860).readout.height == 420)
        #expect(M.readoutMinHeight == 420 && make(700).readoutMinHeight == 420)
    }

    @Test("output is eight lines in a readout 480 wide or more and five under it")
    func outputLines() {
        #expect(make(1300).readout.width == 560)
        #expect(make(1300).outputLinesShown == 8)
        #expect(make(1000).readout.width < 480)
        #expect(make(1000).outputLinesShown == 5)
        #expect(make(700).outputLinesShown == 5)
        #expect(make(400).outputLinesShown == 5)
        #expect(M.readoutFade == 16)
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

    @Test("the stage grows with the row inside each arrangement and never past its cap")
    func monotonic() {
        for range in [(380.0, 559.0), (560, 859), (860, 2400)] {
            var previous = 0.0
            for width in stride(from: range.0, through: range.1, by: 1) {
                let stage = make(width).stage.width
                #expect(stage >= previous - 1e-9, "at \(width)")
                #expect(stage <= 760 + 1e-9)
                previous = stage
            }
        }
    }

    @Test("the gutter belongs to the stage for hover, and the readout owns only its own rectangle")
    func hoverGutter() {
        let metrics = make(1100)
        #expect(metrics.stageHover.maxX == metrics.readout.x)
        #expect(metrics.stageHover.width == metrics.stage.width + M.gutter)
        #expect(metrics.stageHover.height == metrics.stage.height)
        #expect(!metrics.readout.contains(NeuralPoint(metrics.stage.maxX + 10, 10)))
        #expect(metrics.stageHover.contains(NeuralPoint(metrics.stage.maxX + 10, 10)))
    }

    @Test("a design point maps onto the stage through the crop, and back")
    func mapping() {
        let metrics = make(1100)
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

    @Test("a pointer hit goes through the crop")
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
        #expect(abs(metrics.point(forDesign: bottom).y - (metrics.readout.maxY - 48)) < 1e-9)
    }

    @Test("the geometry the transition reads carries the picture, the row heights and the readout's slide")
    func geometry() {
        let wide = make(1100)
        #expect(wide.cardGeometry.picture == wide.card.picture)
        #expect(wide.cardGeometry.rowHeight == 112)
        #expect(wide.stageGeometry.picture == wide.stage)
        #expect(wide.stageGeometry.rowHeight == wide.rowHeight)
        #expect(wide.stageGeometry.readoutTravel == NeuralPoint(24, 0))
        #expect(make(400).stageGeometry.readoutTravel == NeuralPoint(0, 24))
        #expect(make(400).cardGeometry.picture.width == 100)
    }

    @Test("a zero or negative width does not trap")
    func degenerate() {
        #expect(make(0).stage.width == 0)
        #expect(make(-10).width == 0)
    }
}
