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

    @Test("the card is 112 tall with a 148 by 97 picture when comfortable, 84 and 112 by 73 when compact")
    func card() {
        let comfortable = make(700)
        #expect(comfortable.cardHeight == 112)
        #expect(comfortable.card.picture.width == 148)
        #expect(comfortable.card.picture.height == 97)
        #expect(comfortable.card.edge == 3)
        let compact = make(700, .compact)
        #expect(compact.cardHeight == 84)
        #expect(compact.card.picture.width == 112)
        #expect(compact.card.picture.height == 73)
        for metrics in [comfortable, compact] {
            let picture = metrics.card.picture
            #expect(picture.x >= metrics.card.edge)
            #expect(picture.y >= 0 && picture.maxY <= metrics.cardHeight)
            #expect(metrics.card.text.x >= picture.maxX)
            #expect(metrics.card.text.maxX <= metrics.width)
        }
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
            #expect(metrics.readoutExpanded.height == M.readoutMin)
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
            #expect(metrics.readout.y == 0)
            #expect(metrics.readoutExpanded == metrics.readout)
            #expect(metrics.footer.y > metrics.readout.maxY)
            #expect(metrics.footer.width == width)
            #expect(metrics.rowHeight == metrics.footer.maxY)
        }
    }

    @Test("the stage keeps the head's 640 by 420 aspect exactly at every width")
    func aspect() {
        for width in widths {
            for density in [ChatDensity.comfortable, .compact] {
                let metrics = make(width, density)
                #expect(abs(metrics.stage.height * 640 - metrics.stage.width * 420) < 1e-9)
                #expect(abs(metrics.designScale * 640 - metrics.stage.width) < 1e-9)
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

    @Test("the readout is as tall as the stage in a split, and never under 300")
    func readoutHeight() {
        for width in widths where width >= 560 {
            let metrics = make(width)
            #expect(metrics.readout.height == max(metrics.stage.height, 300))
            #expect(metrics.readout.height >= M.readoutMin)
        }
        #expect(make(1100).readout.height == make(1100).stage.height)
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

    @Test("a design point maps onto the stage and the leader anchor sits on the readout's left edge")
    func mapping() {
        let metrics = make(1100)
        let corner = metrics.point(forDesign: NeuralPoint(640, 420))
        #expect(abs(corner.x - metrics.stage.maxX) < 1e-9)
        #expect(abs(corner.y - metrics.stage.maxY) < 1e-9)
        let anchor = metrics.leaderAnchor()
        #expect(anchor.x > 640)
        let back = metrics.point(forDesign: anchor)
        #expect(abs(back.x - metrics.readout.x) < 1e-9)
        #expect(abs(back.y - (metrics.readout.y + 14)) < 1e-9)
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
    }

    @Test("a zero or negative width does not trap")
    func degenerate() {
        #expect(make(0).stage.width == 0)
        #expect(make(-10).width == 0)
    }
}
