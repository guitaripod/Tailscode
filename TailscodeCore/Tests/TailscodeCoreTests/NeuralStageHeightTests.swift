import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural stage height in a short pane")
struct NeuralStageHeightTests {
    typealias M = NeuralStageMetrics

    private let widths: [Double] = [380, 520, 700, 859, 860, 900, 1000, 1280, 1600]
    private let densities: [ChatDensity] = [.comfortable, .compact]
    private let panes = Array(stride(from: 300.0, through: 1600.0, by: 20.0))

    private func open(_ width: Double, _ density: ChatDensity, pane: Double?) -> M {
        M.make(width: width, density: density, viewportHeight: pane)
    }

    private func floor(_ width: Double, _ density: ChatDensity) -> Double {
        M.make(width: width, density: density, rows: M.rowsFloor, viewportHeight: 0).openHeight
    }

    private func smallest(_ width: Double, _ density: ChatDensity) -> Double {
        M.make(width: width, density: density, rows: 1, viewportHeight: 0).openHeight
    }

    @Test("the open row is never taller than 72 percent of the pane or its floor, whichever is larger")
    func capped() {
        for width in widths {
            for density in densities {
                let least = floor(width, density)
                for pane in panes {
                    let metrics = open(width, density, pane: pane)
                    let bound = max(least, pane * M.openHeightShare)
                    #expect(
                        metrics.openHeight <= bound + 1e-9,
                        "\(width) \(density) pane \(pane): \(metrics.openHeight) over \(bound)")
                }
            }
        }
    }

    @Test("a pane too short for the floor gets the shortest row that fits it, never taller than itself")
    func neverPastThePane() {
        for width in widths {
            for density in densities {
                let least = smallest(width, density)
                for pane in panes where pane >= least {
                    let metrics = open(width, density, pane: pane)
                    #expect(
                        metrics.openHeight <= pane + 1e-9,
                        "\(width) \(density) pane \(pane): \(metrics.openHeight)")
                }
            }
        }
    }

    @Test("the row only grows with the pane, and a tall pane keeps the old rule")
    func monotone() {
        for width in widths {
            for density in densities {
                var last = 0.0
                for pane in panes {
                    let height = open(width, density, pane: pane).openHeight
                    #expect(height >= last - 1e-9, "\(width) \(density) pane \(pane)")
                    last = height
                }
            }
        }
        let tall = open(1280, .comfortable, pane: 1_600)
        #expect(tall.rowsShown == M.rows(forViewportHeight: 1_600, head: tall.stage.height))
    }

    @Test("the list gives up rows to the cap, to the floor of four, and the readout follows the column")
    func rowsAndReadout() {
        let short = open(1280, .comfortable, pane: 640)
        #expect(short.rowsShown == M.rowsFloor)
        #expect(short.readout.height == short.brainHeight)
        #expect(short.brainHeight == short.list.maxY)
        let middle = open(1280, .comfortable, pane: 900)
        #expect(middle.rowsShown > M.rowsFloor && middle.rowsShown < M.rowsMin + 4)
        #expect(middle.openHeight <= 900 * M.openHeightShare)
        #expect(middle.brainHeight < M.readoutMinHeight + 200)
        let before = M.make(width: 1280, density: .comfortable, zonesWithSteps: 6)
        let none = open(1280, .comfortable, pane: nil)
        #expect(none == before)
    }

    @Test("with no viewport nothing is capped and an accordion's account is 62 percent of 700")
    func unmeasured() {
        let narrow = open(700, .comfortable, pane: nil)
        #expect(narrow.narrowAccountHeight == 434)
        #expect(narrow.narrowExtra == max(0, 434 - narrow.list.height))
        #expect(open(1280, .comfortable, pane: nil).narrowAccountHeight == 0)
        #expect(open(1280, .comfortable, pane: nil).openHeight == open(1280, .comfortable, pane: nil).rowHeight)
    }

    @Test("an accordion's account is a share of the pane between 340 and 640 until the cap takes it")
    func narrowAccount() {
        let roomy = open(700, .comfortable, pane: 1_400)
        #expect(roomy.narrowAccountHeight == 640)
        let medium = open(700, .comfortable, pane: 1_000)
        #expect(abs(medium.narrowAccountHeight - (720 - medium.list.y - 8 - 36)) < 1e-9)
        #expect(abs(medium.openHeight - 720) < 1e-9)
        let short = open(700, .comfortable, pane: 600)
        #expect(short.narrowAccountHeight >= short.list.height)
        #expect(short.openHeight <= max(floor(700, .comfortable), 600 * M.openHeightShare) + 1e-9)
    }

    @Test("the regions never overlap and leave no gap, at any pane height")
    func regions() {
        for width in widths {
            for pane in panes {
                let metrics = open(width, .comfortable, pane: pane)
                let tag = "\(width) pane \(pane)"
                #expect(abs(metrics.filterChips!.y - (metrics.stage.maxY + M.regionGap)) < 1e-9, "\(tag)")
                #expect(abs(metrics.list.y - (metrics.filterChips!.y + M.chipsBlock)) < 1e-9, "\(tag)")
                #expect(metrics.list.maxY <= metrics.brainHeight + 1e-9, "\(tag)")
                #expect(metrics.listRows.maxY <= metrics.list.maxY + 1e-9, "\(tag)")
                #expect(
                    abs(metrics.footer.y - (metrics.brainHeight + (metrics.footer.height == 36 ? 8 : 6)))
                        < 1e-9, "\(tag)")
                #expect(abs(metrics.rowHeight - metrics.footer.maxY) < 1e-9, "\(tag)")
                if metrics.arrangement == .split {
                    #expect(metrics.readout.height == metrics.brainHeight, "\(tag)")
                    #expect(
                        abs(metrics.readout.x - (metrics.column.maxX + M.gutter)) < 1e-9, "\(tag)")
                    #expect(metrics.readout.maxX <= metrics.width + 1e-9, "\(tag)")
                    #expect(metrics.list.maxY <= metrics.column.maxY + 1e-9, "\(tag)")
                } else {
                    #expect(
                        metrics.list.y + metrics.narrowAccountHeight
                            <= metrics.footer.y + metrics.narrowExtra + 1e-9, "\(tag)")
                }
            }
        }
    }

    @Test("the phone's compact stage does not read the pane at all")
    func phoneUnchanged() {
        let base = M.make(width: 388, density: .comfortable, input: .touch, phone: true)
        for pane in panes {
            let metrics = M.make(
                width: 388, density: .comfortable, input: .touch, viewportHeight: pane, phone: true)
            #expect(metrics == base)
            #expect(metrics.narrowExtra == 0 && metrics.openHeight == metrics.rowHeight)
        }
    }
}

@Suite("Neural wordmark")
struct NeuralWordmarkTests {
    typealias M = NeuralStageMetrics

    @Test("the name is Megatron in capitals")
    func name() {
        #expect(NeuralReading.wordmark == "MEGATRON")
    }

    @Test("a card has its wordmark only where it is wide enough and the headline leaves it the air")
    func card() {
        #expect(M.cardShowsWordmark(width: 400, headlineEnd: 150, headlineRight: 380, wordmarkWidth: 70))
        #expect(!M.cardShowsWordmark(width: 359, headlineEnd: 100, headlineRight: 340, wordmarkWidth: 70))
        #expect(M.cardShowsWordmark(width: 360, headlineEnd: 100, headlineRight: 340, wordmarkWidth: 70))
        #expect(M.cardShowsWordmark(width: 400, headlineEnd: 298, headlineRight: 380, wordmarkWidth: 70))
        #expect(!M.cardShowsWordmark(width: 400, headlineEnd: 299, headlineRight: 380, wordmarkWidth: 70))
    }

    @Test("the open stage's wordmark is a box in the corner of every row from 300 points, on every layout")
    func stage() {
        for width in [300.0, 320, 388, 520, 700, 900, 1280] {
            let metrics = M.make(width: width, density: .comfortable, input: .touch, phone: true)
            let box = metrics.stageWordmark
            #expect(box == NeuralRect(x: 10, y: 8, width: 104, height: 14))
            #expect(box!.maxY <= metrics.stage.maxY)
            #expect(box!.maxX <= metrics.width)
        }
        #expect(M.make(width: 299, density: .comfortable).stageWordmark == nil)
    }
}
