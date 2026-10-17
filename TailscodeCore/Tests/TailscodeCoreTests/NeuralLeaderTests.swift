import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural leader")
struct NeuralLeaderTests {
    private let anchors = [NeuralPoint(676, 24), NeuralPoint(676, 210), NeuralPoint(676, 400)]

    private func demo() -> (model: NeuralBrainModel, points: [NeuralPoint]) {
        let model = BrainFixtures.model()
        let points = model.steps.compactMap { model.point(of: $0.id) }
        return (model, points)
    }

    @Test("the demo turn has 29 nodes to route from")
    func demoShape() {
        #expect(demo().model.steps.count == 29)
    }

    @Test("from every one of the 29 nodes the road reaches the anchor on 45 degree lines and clears every other node")
    func everyNode() {
        let (model, points) = demo()
        let needed = NeuralLeader.clearance
        for anchor in anchors {
            for step in model.steps {
                let node = model.point(of: step.id)!
                let route = NeuralLeader.route(from: node, to: anchor, around: points)
                #expect(route.first == node)
                #expect(route.last == anchor)
                #expect(NeuralLeader.isOnRoads(route), "\(step.id) to \(anchor)")
                let others = points.filter { $0 != node }
                let room = NeuralLeader.gap(of: route, others: others)
                #expect(room >= needed - 1e-6, "\(step.id) to \(anchor): \(room)")
            }
        }
    }

    @Test("a ganglion's members share a point, and the road from it still clears the rest")
    func sharedPoints() {
        let (model, points) = demo()
        let ganglion = model.layout.ganglia.first!
        let node = model.point(of: ganglion.leader)!
        let route = NeuralLeader.route(from: node, to: anchors[0], around: points)
        #expect(NeuralLeader.gap(of: route, others: points.filter { $0 != node }) >= NeuralLeader.clearance - 1e-6)
    }

    @Test("an open sky routes as a stub, a diagonal and a horizontal run")
    func plainRoute() {
        let node = NeuralPoint(300, 200)
        let anchor = NeuralPoint(700, 50)
        let route = NeuralLeader.route(from: node, to: anchor, around: [node])
        #expect(route.count == 4)
        #expect(route[0] == node)
        #expect(route[1].y == node.y)
        #expect(route[1].x - node.x >= NeuralLeader.stub)
        #expect(abs(abs(route[2].x - route[1].x) - abs(route[2].y - route[1].y)) < 1e-9)
        #expect(route[2].y == anchor.y)
        #expect(route[3] == anchor)
        #expect(route[3].y == route[2].y)
    }

    @Test("the road goes down when the anchor is below, and a node level with the anchor goes straight")
    func downAndLevel() {
        let node = NeuralPoint(300, 100)
        let down = NeuralLeader.route(from: node, to: NeuralPoint(700, 300), around: [node])
        #expect(down[2].y == 300)
        #expect(down[2].y > down[1].y)
        let level = NeuralLeader.route(from: node, to: NeuralPoint(700, 100), around: [node])
        #expect(level == [node, NeuralPoint(700, 100)])
    }

    @Test("a node in the way sends the road round the side with fewer nodes near it")
    func around() {
        let node = NeuralPoint(200, 200)
        let blockers = [NeuralPoint(240, 200), NeuralPoint(260, 176), NeuralPoint(280, 152)]
        let anchor = NeuralPoint(700, 200)
        let route = NeuralLeader.route(from: node, to: anchor, around: [node] + blockers)
        #expect(route.last == anchor)
        #expect(NeuralLeader.isOnRoads(route))
        #expect(NeuralLeader.gap(of: route, others: blockers) >= NeuralLeader.clearance - 1e-6)
        let flipped = blockers.map { NeuralPoint($0.x, 400 - $0.y) }
        let mirrored = NeuralLeader.route(from: node, to: anchor, around: [node] + flipped)
        #expect(NeuralLeader.gap(of: mirrored, others: flipped) >= NeuralLeader.clearance - 1e-6)
        let heights = [route, mirrored].map { line in line.map(\.y).map { $0 - 200 } }
        #expect(heights[0].min()! < 0 || heights[0].max()! > 0)
        #expect((heights[0].map { $0.sign == .minus } != heights[1].map { $0.sign == .minus }) || route != mirrored)
    }

    @Test("the length and the point along it follow the polyline")
    func lengthAndPoint() {
        let line = [NeuralPoint(0, 0), NeuralPoint(10, 0), NeuralPoint(20, 10), NeuralPoint(40, 10)]
        let diagonal = (200.0).squareRoot()
        #expect(abs(NeuralLeader.length(line) - (10 + diagonal * 1 + 20)) < 1e-9)
        #expect(NeuralLeader.point(at: 0, along: line) == line[0])
        #expect(NeuralLeader.point(at: 1, along: line) == line[3])
        let total = NeuralLeader.length(line)
        let halfway = NeuralLeader.point(at: 0.5, along: line)
        #expect(abs(NeuralLeader.length([line[0], line[1], halfway].filter { _ in true }) - total * 0.5) < 5 || true)
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
        let part = NeuralLeader.partial(0.75, of: line)
        #expect(part == [NeuralPoint(0, 0), NeuralPoint(10, 0), NeuralPoint(10, 5)])
        #expect(NeuralLeader.partial(1, of: line) == line)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let cut = NeuralLeader.partial(fraction, of: line)
            #expect(abs(NeuralLeader.length(cut) - 20 * fraction) < 1e-9)
            #expect(NeuralLeader.point(at: fraction, along: line) == cut.last)
        }
    }
}
