import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural leader")
struct NeuralLeaderTests {
    private let metrics = NeuralStageMetrics.make(width: 1100, density: .comfortable)

    private func demo() -> (model: NeuralBrainModel, points: [NeuralPoint]) {
        let model = BrainFixtures.model()
        return (model, model.steps.compactMap { model.point(of: $0.id) })
    }

    /// The labels the node does not sit in, which a road must not enter.
    private func foreignLabels(of node: NeuralPoint) -> [NeuralRect] {
        NeuralZone.labelRects.filter { NeuralLeader.distance(from: node, toRect: $0) > NeuralLeader.clearance + 2 }
    }

    @Test("the demo turn has 29 nodes to route from")
    func demoShape() {
        #expect(demo().model.steps.count == 29)
    }

    @Test("from every one of the 29 nodes the line ends on its own row at the hairline, on 45 degree roads, clear of every other node and label")
    func everyNode() throws {
        let (model, points) = demo()
        for step in model.steps {
            let node = model.point(of: step.id)!
            let line = try #require(model.leader(forStep: step.id, in: metrics))
            let anchor = try #require(metrics.leaderAnchor(forNodeAt: node))
            #expect(line.route.first == node)
            #expect(line.route.last == anchor)
            #expect(NeuralLeader.isOnRoads(line.route), "\(step.id)")
            let room = NeuralLeader.gap(of: line.route, others: points.filter { $0 != node })
            #expect(room >= NeuralLeader.clearance - 1e-6, "\(step.id): \(room)")
            for label in foreignLabels(of: node) {
                for index in 1..<line.route.count {
                    #expect(!NeuralLeader.segmentCrosses(line.route[index - 1], line.route[index], label), "\(step.id) cuts a label")
                }
            }
            #expect(line.route.last?.y == anchor.y)
            if line.route.count > 1 {
                let last = line.route[line.route.count - 1]
                let before = line.route[line.route.count - 2]
                #expect(abs(last.y - before.y) < 1e-9, "\(step.id) does not end level")
            }
        }
    }

    @Test("the line lands on a 3 by 24 tab on the hairline, on the node's row held inside the header and footer")
    func landing() throws {
        let (model, _) = demo()
        for step in model.steps {
            let line = try #require(model.leader(forStep: step.id, in: metrics))
            let node = model.point(of: step.id)!
            #expect(line.tab == metrics.leaderTab(forNodeAt: node))
            #expect(line.tab.width == 3 && line.tab.height == 24)
            #expect(abs(line.dot.y - line.row) < 1e-9)
            #expect(abs(line.dot.x - (metrics.readout.x + 0.5)) < 1e-9)
            #expect(line.row >= 56 - 1e-9 && line.row <= metrics.readout.maxY - 48 + 1e-9)
            let nodeRow = metrics.point(forDesign: node).y
            let held = min(max(nodeRow, 56), metrics.readout.maxY - 48)
            #expect(abs(line.row - held) < 1e-9)
            #expect(line.toneSet == .corrected)
            #expect(line.length > 0)
        }
    }

    @Test("a stacked row has no leader")
    func stacked() {
        let (model, _) = demo()
        let narrow = NeuralStageMetrics.make(width: 400, density: .comfortable)
        #expect(model.leader(forStep: model.steps[0].id, in: narrow) == nil)
        #expect(model.leader(forStep: "nope", in: metrics) == nil)
    }

    @Test("a node whose row is clear goes straight across on it")
    func straight() {
        let node = NeuralPoint(300, 200)
        let anchor = NeuralPoint(700, 200)
        #expect(NeuralLeader.route(from: node, to: anchor, around: [node], labels: []) == [node, anchor])
    }

    @Test("an anchor on another row takes a level run, a diagonal and a level run")
    func plainRoute() {
        let node = NeuralPoint(300, 200)
        let anchor = NeuralPoint(700, 150)
        let route = NeuralLeader.route(from: node, to: anchor, around: [node], labels: [])
        #expect(route.first == node && route.last == anchor)
        #expect(NeuralLeader.isOnRoads(route))
        #expect(route.count == 4)
        #expect(route[1].y == node.y)
        #expect(abs(abs(route[2].x - route[1].x) - abs(route[2].y - route[1].y)) < 1e-9)
        #expect(route[3].y == route[2].y)
    }

    @Test("a node in the way sends the line round it by a lane, on whichever side is cheaper")
    func around() {
        let node = NeuralPoint(200, 200)
        let blockers = [NeuralPoint(240, 200), NeuralPoint(300, 200), NeuralPoint(360, 200)]
        let anchor = NeuralPoint(700, 200)
        let route = NeuralLeader.route(from: node, to: anchor, around: [node] + blockers, labels: [])
        #expect(route.last == anchor)
        #expect(NeuralLeader.isOnRoads(route))
        #expect(NeuralLeader.gap(of: route, others: blockers) >= NeuralLeader.clearance - 1e-6)
        #expect(route.contains { $0.y != 200 })
        #expect(route.map { abs($0.y - 200) }.max()! <= 90 + 1e-9)
    }

    @Test("a label in the way is gone round as a node is")
    func aroundLabel() {
        let node = NeuralPoint(200, 200)
        let label = NeuralRect(x: 280, y: 190, width: 80, height: 20)
        let anchor = NeuralPoint(700, 200)
        let route = NeuralLeader.route(from: node, to: anchor, around: [node], labels: [label])
        #expect(route.last == anchor)
        #expect(NeuralLeader.isOnRoads(route))
        for index in 1..<route.count {
            #expect(!NeuralLeader.segmentCrosses(route[index - 1], route[index], label))
        }
    }

    @Test("a node's own label is ignored, and a head full of nodes falls back to the search")
    func crowded() {
        let node = NeuralPoint(300, 200)
        let own = NeuralRect(x: 280, y: 180, width: 40, height: 20)
        #expect(NeuralLeader.route(from: node, to: NeuralPoint(700, 200), around: [node], labels: [own]) == [node, NeuralPoint(700, 200)])
        var wall: [NeuralPoint] = []
        for y in stride(from: -100.0, through: 500, by: 28) { wall.append(NeuralPoint(360, y)) }
        wall.removeAll { abs($0.y - 200) < 20 }
        wall.append(contentsOf: [NeuralPoint(330, 200), NeuralPoint(360, 200 + 14)])
        let route = NeuralLeader.route(from: node, to: NeuralPoint(700, 200), around: wall + [node], labels: [])
        #expect(route.first == node && route.last == NeuralPoint(700, 200))
        #expect(NeuralLeader.isOnRoads(route))
    }

    @Test("the zone labels sit above their wells, 4 units wider than their text")
    func labelRects() {
        for zone in NeuralZone.allCases {
            let rect = zone.labelRect
            #expect(rect.height == 20)
            #expect(abs(rect.x + rect.width / 2 - zone.center.x) < 1e-9)
            #expect(rect.maxY <= zone.center.y - zone.well.ry + 3 + 1e-9)
        }
        #expect(NeuralZone.think.labelRect == NeuralRect(x: 456 - 26, y: 150 - 58 - 17, width: 52, height: 20))
        #expect(NeuralZone.delegate.labelHalfWidth == 48)
        #expect(NeuralZone.labelRects.count == 6)
    }

    @Test("the length and the point along it follow the polyline")
    func lengthAndPoint() {
        let line = [NeuralPoint(0, 0), NeuralPoint(10, 0), NeuralPoint(20, 10), NeuralPoint(40, 10)]
        let diagonal = (200.0).squareRoot()
        #expect(abs(NeuralLeader.length(line) - (10 + diagonal + 20)) < 1e-9)
        #expect(NeuralLeader.point(at: 0, along: line) == line[0])
        #expect(NeuralLeader.point(at: 1, along: line) == line[3])
        #expect(NeuralLeader.point(at: -1, along: line) == line[0])
        #expect(NeuralLeader.point(at: 9, along: line) == line[3])
        #expect(NeuralLeader.point(at: 0.5, along: []) == NeuralPoint(0, 0))
        #expect(NeuralLeader.length([]) == 0)
    }

    @Test("drawing along keeps whole segments and cuts the one the head is on")
    func partial() {
        let line = [NeuralPoint(0, 0), NeuralPoint(10, 0), NeuralPoint(10, 10)]
        #expect(NeuralLeader.partial(0, of: line) == [NeuralPoint(0, 0), NeuralPoint(0, 0)])
        #expect(NeuralLeader.partial(0.5, of: line) == [NeuralPoint(0, 0), NeuralPoint(10, 0)])
        #expect(NeuralLeader.partial(0.75, of: line) == [NeuralPoint(0, 0), NeuralPoint(10, 0), NeuralPoint(10, 5)])
        #expect(NeuralLeader.partial(1, of: line) == line)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let cut = NeuralLeader.partial(fraction, of: line)
            #expect(abs(NeuralLeader.length(cut) - 20 * fraction) < 1e-9)
            #expect(NeuralLeader.point(at: fraction, along: line) == cut.last)
        }
    }
}
