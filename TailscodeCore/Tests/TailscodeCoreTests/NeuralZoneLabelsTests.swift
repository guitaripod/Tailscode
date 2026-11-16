import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural zone names")
struct NeuralZoneLabelsTests {
    @Test("a name stands where the design drew it when nothing is under it, at the design's size")
    func home() {
        for zone in NeuralZone.allCases {
            #expect(NeuralZoneLabels.rect(of: zone) == zone.labelRect)
        }
        #expect(NeuralZoneLabels.rects(nodes: []) == NeuralZone.labelRects)
    }

    @Test("a name held larger than the design's keeps its foot on the ring and its middle over the zone")
    func grows() {
        for zone in NeuralZone.allCases {
            let design = zone.labelRect
            let grown = NeuralZoneLabels.rect(of: zone, magnify: 1.7)
            #expect(abs(grown.width - design.width * 1.7) < 0.001)
            #expect(abs(grown.x + grown.width / 2 - (design.x + design.width / 2)) < 0.001)
            #expect(grown.y >= NeuralZoneLabels.topFloor)
            #expect(grown.y + grown.height <= design.y + design.height + 0.001)
        }
        let shell = NeuralZoneLabels.rect(of: .shell, magnify: 1.7)
        #expect(abs(shell.y + shell.height - (NeuralZone.shell.labelRect.y + 20)) < 0.001)
        #expect(NeuralZoneLabels.rect(of: .act, magnify: 0.4) == NeuralZone.act.labelRect)
    }

    @Test("a node under a name lifts the name over it, and only that name")
    func lifts() {
        let home = NeuralZone.shell.labelRect
        let node = NeuralPoint(home.x + home.width / 2, home.y + home.height / 2 + 4)
        let placed = NeuralZoneLabels.rects(nodes: [node])
        let shell = placed[NeuralZone.shell.rawValue]
        #expect(shell.x == home.x && shell.width == home.width && shell.height == home.height)
        let foot = shell.y + shell.height
        #expect(abs(foot - (node.y - NeuralDesign.nodeRadius - NeuralZoneLabels.clearance)) < 0.001)
        #expect(!NeuralZoneLabels.covers(shell, node, radius: NeuralDesign.nodeRadius))
        for zone in NeuralZone.allCases where zone != .shell {
            #expect(placed[zone.rawValue] == zone.labelRect)
        }
    }

    @Test("a name is never lifted out of its zone, onto another node, or off the picture")
    func staysHome() {
        let home = NeuralZone.delegate.labelRect
        let middle = NeuralPoint(home.x + home.width / 2, home.y + home.height / 2)
        let stack = (0..<4).map { NeuralPoint(middle.x, middle.y - Double($0) * 14) }
        #expect(NeuralZoneLabels.rects(nodes: stack)[NeuralZone.delegate.rawValue] == home)
        let blocked = [middle, NeuralPoint(middle.x, middle.y - 30)]
        #expect(NeuralZoneLabels.rects(nodes: blocked)[NeuralZone.delegate.rawValue] == home)
        let act = NeuralZone.act.labelRect
        let high = NeuralPoint(act.x + act.width / 2, act.y + act.height / 2)
        let lifted = NeuralZoneLabels.rects(nodes: [high], magnify: 1.7)[NeuralZone.act.rawValue]
        #expect(lifted.y >= NeuralZoneLabels.topFloor)
    }

    @Test("on the design's 29-step turn, with a zone crowded to its second ring, no node sits across a name at any size a client holds it at")
    func demoTurn() {
        let model = BrainFixtures.model()
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: true)
        for magnify in [1.0, 1.3, 1.7] {
            let rects = NeuralZoneLabels.rects(draws: draws, magnify: magnify)
            #expect(rects.count == NeuralZone.allCases.count)
            for zone in NeuralZone.allCases {
                let rect = rects[zone.rawValue]
                #expect(!draws.contains { NeuralZoneLabels.covers(rect, $0.point, radius: $0.radius) })
                #expect(rect.x >= 0 && rect.x + rect.width <= NeuralDesign.width)
                #expect(rect.y >= NeuralZoneLabels.topFloor && rect.y + rect.height <= NeuralDesign.height)
            }
        }
        let shell = NeuralZoneLabels.rects(draws: draws)[NeuralZone.shell.rawValue]
        #expect(shell.y < NeuralZone.shell.labelRect.y)
    }
}
