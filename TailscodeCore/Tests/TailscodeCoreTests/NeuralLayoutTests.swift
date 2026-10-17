import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural layout")
struct NeuralLayoutTests {
    typealias Fixtures = NeuralTurnFixtures

    private func step(
        _ id: String, _ zone: NeuralZone, group: Int, tie: String? = nil, command: Bool = false
    ) -> NeuralStep {
        NeuralStep(
            id: id, index: 0, zone: zone, group: group, messageID: "m\(group)", title: "T",
            tieKey: tie, tieIsCommand: command)
    }

    /// Groups of the given sizes, spread over the zones so the points differ.
    private func grouped(_ sizes: [Int], zone: NeuralZone? = nil) -> [NeuralStep] {
        var out: [NeuralStep] = []
        for (group, size) in sizes.enumerated() {
            for member in 0..<size {
                let chosen = zone ?? NeuralZone.allCases[out.count % NeuralZone.allCases.count]
                out.append(step("g\(group)s\(member)", chosen, group: group))
            }
        }
        return out
    }

    private func big(_ copies: Int) -> [NeuralStep] {
        let base = Fixtures.steps(Fixtures.turn())
        var out: [NeuralStep] = []
        for copy in 0..<copies {
            for item in base {
                let copied = NeuralStep(
                    id: "c\(copy)-\(item.id)", index: 0, zone: item.zone, group: item.group + copy * 30,
                    messageID: item.messageID, title: item.title, tieKey: item.tieKey,
                    tieIsCommand: item.tieIsCommand)
                out.append(copied)
            }
        }
        return out
    }

    private struct ReferenceEdge: Equatable {
        var from: String
        var to: String
        var group: Int
    }

    /// The mock's `analyse`, the edge walk and the route de-duplication, written from scratch.
    private func reference(_ steps: [NeuralStep], _ layout: NeuralLayout)
        -> (edges: [ReferenceEdge], routes: [[NeuralPoint]])
    {
        var groups: [[Int]] = []
        for (index, item) in steps.enumerated() {
            if groups.isEmpty || steps[groups[groups.count - 1][0]].group != item.group {
                groups.append([])
            }
            groups[groups.count - 1].append(index)
        }
        func point(_ index: Int) -> NeuralPoint { layout.placements[steps[index].id]! }
        var edges: [ReferenceEdge] = []
        var lines: [[NeuralPoint]] = []
        var seen = Set<String>()
        func add(_ a: String, _ b: String, _ group: Int, _ from: NeuralPoint, _ to: NeuralPoint) {
            edges.append(ReferenceEdge(from: a, to: b, group: group))
            let line = NeuralLayout.route(from: from, to: to)
            let key = line.map { "\(($0.x * 10).rounded()),\(($0.y * 10).rounded())" }.joined(separator: ";")
            if seen.insert(key).inserted { lines.append(line) }
        }
        for group in 1..<max(1, groups.count) {
            let previous = groups[group - 1]
            let next = groups[group]
            if previous.count > 1, next.count > 1 {
                let all = previous + next
                let x = all.map { point($0).x }.reduce(0, +) / Double(all.count)
                let y = all.map { point($0).y }.reduce(0, +) / Double(all.count)
                let via = NeuralPoint(x, y)
                for p in previous { add(steps[p].id, "via\(group)", group, point(p), via) }
                for n in next { add("via\(group)", steps[n].id, group, via, point(n)) }
            } else {
                for p in previous {
                    for n in next { add(steps[p].id, steps[n].id, group, point(p), point(n)) }
                }
            }
        }
        return (edges, lines)
    }

    private func name(_ end: NeuralLayout.Endpoint) -> String {
        switch end {
        case .step(let id): return id
        case .via(let group): return "via\(group)"
        }
    }

    private func matchesReference(_ steps: [NeuralStep], _ layout: NeuralLayout) -> Bool {
        let expected = reference(steps, layout)
        let edges = layout.edges.map { ReferenceEdge(from: name($0.from), to: name($0.to), group: $0.group) }
        guard edges == expected.edges else { return false }
        let routes = layout.routes.map(\.points)
        return routes == expected.routes
    }

    @Test("placements take each zone's slots in order")
    func placements() {
        let steps = grouped([1, 1, 1, 1, 1, 1, 1], zone: .think)
        let layout = NeuralLayout.make(steps: steps)
        for (index, item) in steps.enumerated() {
            #expect(layout.placements[item.id] == NeuralZone.think.slots[index])
        }
        #expect(layout.zoneCounts[.think] == 7)
        #expect(layout.zoneCounts[.shell] == 0)
        #expect(layout.stepCount == 7)
    }

    @Test("shell past its capacity gathers its tail in a ganglion of seven")
    func shellGanglion() {
        #expect(NeuralZone.shell.capacity == 12)
        let steps = Fixtures.steps(Fixtures.turn())
        let layout = NeuralLayout.make(steps: steps)
        let shell = steps.filter { $0.zone == .shell }
        #expect(shell.count == 18)
        #expect(layout.ganglia.count == 1)
        let ganglion = layout.ganglia[0]
        #expect(ganglion.zone == .shell)
        #expect(ganglion.members.count == 7)
        #expect(ganglion.leader == shell[11].id)
        #expect(ganglion.members == shell[11...].map(\.id))
        let slots = NeuralZone.shell.slots
        for index in 0..<11 { #expect(layout.placements[shell[index].id] == slots[index]) }
        for member in shell[11...] { #expect(layout.placements[member.id] == slots[11]) }
        #expect(Set(shell.map { layout.placements[$0.id]! }).count == 12)
        #expect(layout.representative(of: shell[15].id) == shell[11].id)
        #expect(layout.representative(of: shell[3].id) == shell[3].id)
        #expect(layout.zoneCounts[.shell] == 18)
    }

    @Test("a single step past the slots is no ganglion, two are")
    func ganglionThreshold() {
        for zone in NeuralZone.allCases {
            let capacity = zone.capacity
            let exact = NeuralLayout.make(steps: grouped(Array(repeating: 1, count: capacity), zone: zone))
            #expect(exact.ganglia.isEmpty)
            let one = NeuralLayout.make(steps: grouped(Array(repeating: 1, count: capacity + 1), zone: zone))
            #expect(one.ganglia.count == 1)
            #expect(one.ganglia[0].members.count == 2)
            let four = NeuralLayout.make(steps: grouped(Array(repeating: 1, count: capacity + 3), zone: zone))
            #expect(four.ganglia[0].members.count == 4)
            #expect(four.ganglia[0].zone == zone)
        }
        let lastSlotAlone = NeuralLayout.make(steps: grouped(Array(repeating: 1, count: 12), zone: .shell))
        #expect(lastSlotAlone.placements["g11s0"] == NeuralZone.shell.slots[11])
        #expect(lastSlotAlone.ganglia.isEmpty)
    }

    @Test("three parallel calls between single calls wire as a complete bipartite graph")
    func parallelCalls() {
        let steps = Fixtures.steps(Fixtures.buildFix())
        let layout = NeuralLayout.make(steps: steps)
        let parallel = steps.filter { $0.messageID == "m2" }.map(\.id)
        #expect(parallel.count == 3)
        let before = steps[0].id
        let after = steps[4].id
        let edges = layout.edges
        #expect(layout.vias.isEmpty)
        #expect(edges.filter { $0.group == 1 }.map { [name($0.from), name($0.to)] } == parallel.map { [before, $0] })
        #expect(edges.filter { $0.group == 2 }.map { [name($0.from), name($0.to)] } == parallel.map { [$0, after] })
        #expect(edges.count == 3 + 3 + 9)
        #expect(matchesReference(steps, layout))
    }

    @Test("two groups of several wire through a via at their centroid")
    func viaPoint() {
        let steps = grouped([3, 2])
        let layout = NeuralLayout.make(steps: steps)
        #expect(layout.vias.count == 1)
        let via = layout.vias[0]
        #expect(via.group == 1)
        #expect(via.members == steps.map(\.id))
        let points = steps.map { layout.placements[$0.id]! }
        #expect(abs(via.point.x - points.map(\.x).reduce(0, +) / 5) < 1e-9)
        #expect(abs(via.point.y - points.map(\.y).reduce(0, +) / 5) < 1e-9)
        let edges = layout.edges
        #expect(edges.count == 5)
        #expect(edges.filter { $0.part == 0 }.count == 3)
        #expect(edges.filter { $0.part == 1 }.count == 2)
        #expect(edges.filter { $0.part == 0 }.allSatisfy { name($0.to) == "via1" })
        #expect(edges.filter { $0.part == 1 }.allSatisfy { name($0.from) == "via1" })
        #expect(edges.filter { $0.part == 0 }.map(\.zone) == steps[0..<3].map(\.zone))
        #expect(edges.filter { $0.part == 1 }.map(\.zone) == steps[3..<5].map(\.zone))
        #expect(matchesReference(steps, layout))
    }

    @Test("a group of one on either side wires direct")
    func singleSides() {
        let layout = NeuralLayout.make(steps: grouped([1, 4, 1, 2, 1]))
        #expect(layout.vias.isEmpty)
        #expect(layout.edges.count == 4 + 4 + 2 + 2)
    }

    @Test("a route runs a diagonal then straight, and straight when aligned")
    func routeGeometry() {
        let a = NeuralPoint(100, 100)
        #expect(NeuralLayout.route(from: a, to: NeuralPoint(160, 100)) == [a, NeuralPoint(160, 100)])
        #expect(NeuralLayout.route(from: a, to: NeuralPoint(100, 40)) == [a, NeuralPoint(100, 40)])
        #expect(NeuralLayout.route(from: a, to: NeuralPoint(100.5, 40)) == [a, NeuralPoint(100.5, 40)])
        #expect(
            NeuralLayout.route(from: a, to: NeuralPoint(180, 130))
                == [a, NeuralPoint(130, 130), NeuralPoint(180, 130)])
        #expect(
            NeuralLayout.route(from: a, to: NeuralPoint(30, 40))
                == [a, NeuralPoint(40, 40), NeuralPoint(30, 40)])
        #expect(
            NeuralLayout.route(from: a, to: NeuralPoint(130, 180))
                == [a, NeuralPoint(130, 130), NeuralPoint(130, 180)])
        #expect(
            NeuralLayout.route(from: a, to: NeuralPoint(60, 20))
                == [a, NeuralPoint(60, 60), NeuralPoint(60, 20)])
    }

    @Test("identical wires are drawn once and the mock's walk is reproduced")
    func routeDeduplication() {
        let steps = Fixtures.steps(Fixtures.turn())
        let layout = NeuralLayout.make(steps: steps)
        let edges = layout.edges
        let routes = layout.routes
        #expect(routes.count < edges.count)
        #expect(Set(routes.map { $0.points }).count == routes.count)
        #expect(matchesReference(steps, layout))
    }

    @Test("a 174-step turn draws the mock's 109 distinct wires for its 191 edges")
    func manyWires() {
        let steps = big(6)
        #expect(steps.count == 174)
        let layout = NeuralLayout.make(steps: steps)
        #expect(layout.edges.count == 191)
        #expect(layout.routes.count == 109)
        #expect(matchesReference(steps, layout))
        #expect(layout.ganglia.count == 2)
    }

    @Test("ties join steps on the same file or command, with the mock's arc")
    func ties() throws {
        let steps = Fixtures.steps(Fixtures.turn())
        let layout = NeuralLayout.make(steps: steps)
        let ties = layout.ties
        let cut = try #require(ties.first { $0.key == "out/demo/cut-list.json" })
        #expect(cut.members.count == 3)
        #expect(cut.isCommand == false)
        #expect(cut.arcs.count == 2)
        let mux = try #require(ties.first { $0.isCommand && $0.key.hasPrefix("ffmpeg -f concat") })
        #expect(mux.members.count == 2)
        #expect(mux.arcs.count == 1)
        #expect(ties.allSatisfy { $0.members.count >= 2 })
        #expect(ties.allSatisfy { $0.arcs.count == $0.members.count - 1 })
    }

    @Test("a tie arc bows by 0.28 of the chord, to the left of the way it runs")
    func tieArc() {
        let steps = [
            step("a", .think, group: 0, tie: "f"), step("b", .sense, group: 1, tie: "f"),
            step("c", .act, group: 2, tie: "solo"),
        ]
        let layout = NeuralLayout.make(steps: steps)
        #expect(layout.ties.count == 1)
        let arc = layout.ties[0].arcs[0]
        let a = layout.placements["a"]!
        let b = layout.placements["b"]!
        #expect(arc.from == a && arc.to == b)
        let dx = b.x - a.x
        let dy = b.y - a.y
        #expect(abs(arc.control.x - ((a.x + b.x) / 2 - dy * 0.28)) < 1e-9)
        #expect(abs(arc.control.y - ((a.y + b.y) / 2 + dx * 0.28)) < 1e-9)
    }

    @Test("hovering a step lights its wire neighbours and its ties")
    func hotSet() {
        let steps = [
            step("a", .think, group: 0),
            step("b1", .sense, group: 1, tie: "f"), step("b2", .sense, group: 1),
            step("b3", .act, group: 1),
            step("c", .shell, group: 2, tie: "f"),
            step("d", .delegate, group: 3),
        ]
        let layout = NeuralLayout.make(steps: steps)
        #expect(layout.hotSet(for: "a") == ["a", "b1", "b2", "b3"])
        #expect(layout.hotSet(for: "b2") == ["a", "b2", "c"])
        #expect(layout.hotSet(for: "b1") == ["a", "b1", "c"])
        #expect(layout.hotSet(for: "c") == ["b1", "b2", "b3", "c", "d"])
        #expect(layout.hotSet(for: "d") == ["c", "d"])
        #expect(layout.hotSet(for: "nope").isEmpty)
    }

    @Test("hovering inside a via lights both sides of it")
    func hotSetThroughVia() {
        let steps = grouped([3, 2, 1])
        let layout = NeuralLayout.make(steps: steps)
        let first = steps[0..<5].map(\.id)
        #expect(layout.hotSet(for: "g0s1") == first)
        #expect(layout.hotSet(for: "g1s0") == first + ["g2s0"])
        #expect(layout.hotSet(for: "g2s0") == ["g1s0", "g1s1", "g2s0"])
    }

    @Test("hovering a ganglion member lights the whole ganglion")
    func hotSetGanglion() {
        let steps = grouped(Array(repeating: 1, count: 18), zone: .shell)
        let layout = NeuralLayout.make(steps: steps)
        let members = layout.ganglia[0].members
        let hot = layout.hotSet(for: members[3])
        #expect(Set(members).isSubset(of: Set(hot)))
        #expect(hot.contains("g10s0"))
        #expect(!hot.contains("g5s0"))
        #expect(layout.hotSet(for: members[0]) == hot)
    }

    @Test("hot routes are the wires touching the step")
    func hotRoutes() {
        let steps = grouped([1, 3, 1])
        let layout = NeuralLayout.make(steps: steps)
        let routes = layout.hotRoutes(for: "g1s1")
        #expect(!routes.isEmpty)
        #expect(
            routes.allSatisfy { route in
                [route.edge.from, route.edge.to].contains(.step("g1s1"))
            })
        #expect(layout.hotRoutes(for: "g0s0").count <= 3)
        #expect(layout.hotRoutes(for: "nope").isEmpty)
    }

    @Test("appending step by step equals building at once, at every length")
    func appendEqualsMake() {
        for steps in [Fixtures.steps(Fixtures.turn()), Fixtures.steps(Fixtures.buildFix()), grouped([3, 2, 1, 4, 4, 1]), big(2)] {
            var layout = NeuralLayout()
            for (count, item) in steps.enumerated() {
                layout.append(item)
                let prefix = Array(steps[0...count])
                let whole = NeuralLayout.make(steps: prefix)
                #expect(layout == whole)
                #expect(layout.edges == whole.edges)
                #expect(layout.routes == whole.routes)
                #expect(layout.ties == whole.ties)
                #expect(layout.ganglia == whole.ganglia)
                #expect(layout.vias == whole.vias)
                #expect(layout.placements == whole.placements)
                #expect(matchesReference(prefix, layout))
            }
        }
    }

    @Test("sync appends what is new and rebuilds when a tie key arrives late")
    func sync() {
        var steps = grouped([1, 1, 1, 1])
        var layout = NeuralLayout()
        layout.sync(Array(steps[0..<2]))
        #expect(layout.stepCount == 2)
        layout.sync(steps)
        #expect(layout == NeuralLayout.make(steps: steps))
        #expect(layout.ties.isEmpty)
        steps[0].tieKey = "late"
        steps[3].tieKey = "late"
        layout.sync(steps)
        #expect(layout.ties.count == 1)
        #expect(layout == NeuralLayout.make(steps: steps))
        layout.sync(Array(steps[0..<1]))
        #expect(layout == NeuralLayout.make(steps: Array(steps[0..<1])))
        layout.sync([])
        #expect(layout.stepCount == 0)
    }

    @Test("the layout of a live turn grows by one step at a time without rebuilding")
    func appendIsCheap() {
        var layout = NeuralLayout()
        for index in 0..<3000 {
            layout.append(step("s\(index)", NeuralZone.allCases[index % 6], group: index / 2))
        }
        #expect(layout.stepCount == 3000)
        #expect(layout.groupCount == 1500)
        #expect(layout.ganglia.count == 6)
    }

    @Test("zone counts match the steps")
    func zoneCounts() {
        let steps = Fixtures.steps(Fixtures.turn())
        let layout = NeuralLayout.make(steps: steps)
        for zone in NeuralZone.allCases {
            #expect(layout.zoneCounts[zone] == Fixtures.count(steps, zone))
        }
    }
}
