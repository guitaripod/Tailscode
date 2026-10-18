import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural nodes")
struct NeuralNodesTests {
    typealias Fixtures = NeuralTurnFixtures

    @Test("a status is worn as the doctrine says")
    func tonesAndMotions() {
        let table: [(NeuralStatus, NeuralNodeTone, NeuralMotion)] = [
            (.ok, .zone, .still), (.running, .live, .breath),
            (.waitingApproval, .attention, .heartbeat), (.waitingAnswer, .attention, .heartbeat),
            (.stalled, .attention, .still), (.failed, .danger, .still), (.stopped, .quiet, .still),
        ]
        for (status, tone, motion) in table {
            #expect(NeuralNodes.tone(of: status) == tone)
            #expect(NeuralNodes.motion(of: status) == motion)
            let step = ReadingFixtures.step(0, .shell, "Bash", status: status)
            let model = BrainFixtures.model(NeuralTurn(id: "x", steps: [step], outcome: .settled))
            let draw = NeuralNodes.draws(model: model, time: 1, reduceMotion: false)[0]
            #expect(draw.tone == tone)
            #expect(draw.motion == motion)
            #expect(draw.status == status)
            let still = NeuralNodes.draws(model: model, time: 1, reduceMotion: true)[0]
            #expect(still.motion == .still)
        }
    }

    @Test("a node is drawn per step, a ganglion as one at its leader")
    func drawsTheTurn() throws {
        let model = BrainFixtures.model()
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        #expect(draws.count == 29 - 6)
        #expect(model.nodeCount == 23)
        let ganglion = try #require(model.layout.ganglia.first)
        let leader = try #require(draws.first { $0.id == ganglion.leader })
        #expect(leader.ganglionCount == 7)
        #expect(leader.isGanglion)
        #expect(leader.label == "+7")
        #expect(leader.radius == NeuralDesign.nodeRadius * NeuralNodes.ganglionScale)
        #expect(leader.zone == .shell)
        #expect(leader.shape == NeuralZone.shell.shape)
        for member in ganglion.members.dropFirst() {
            #expect(!draws.contains { $0.id == member })
        }
        let numbers = draws.map(\.number)
        #expect(numbers == numbers.sorted())
        #expect(numbers.first == 1)
        for draw in draws where !draw.isGanglion {
            #expect(draw.ganglionCount == nil)
            #expect(draw.radius == NeuralDesign.nodeRadius)
            #expect(draw.shape == draw.zone.shape)
            #expect(draw.point == model.point(of: draw.id))
            #expect(draw.number == (model.step(id: draw.id)?.index ?? -1) + 1)
            #expect(draw.label == String(draw.number))
        }
    }

    @Test("a ganglion wears the worst of what it holds, and a waiting node wears its mark")
    func aggregateAndMarks() throws {
        var steps = (0..<14).map { ReadingFixtures.step($0, .shell, "Bash") }
        steps[12].status = .failed
        steps[13].status = .running
        let model = BrainFixtures.model(NeuralTurn(id: "x", steps: steps, outcome: .running))
        let draw = try #require(NeuralNodes.draws(model: model, time: 0, reduceMotion: false).last)
        #expect(draw.ganglionCount == 3)
        #expect(draw.status == .running)
        #expect(draw.tone == .live)

        steps[13].status = .ok
        let failed = BrainFixtures.model(NeuralTurn(id: "x", steps: steps))
        #expect(NeuralNodes.draws(model: failed, time: 0, reduceMotion: false).last?.status == .failed)

        var waiting = ReadingFixtures.step(0, .shell, "Bash", status: .waitingApproval)
        waiting.mark = "⏸"
        let marked = BrainFixtures.model(NeuralTurn(id: "x", steps: [waiting]))
        let node = NeuralNodes.draws(model: marked, time: 0, reduceMotion: false)[0]
        #expect(node.label == "⏸")
        #expect(node.mark == "⏸")
        #expect(node.number == 1)
    }

    @Test("a turn at rest is lit end to end")
    func litAtRest() {
        let model = BrainFixtures.model()
        for draw in NeuralNodes.draws(model: model, time: 5, reduceMotion: false) {
            #expect(draw.lit == 1)
            #expect(draw.flash == 0)
        }
        let wires = NeuralNodes.wires(model: model, time: 5)
        #expect(wires.routes.allSatisfy { $0.lit == 1 })
        #expect(wires.ties.allSatisfy { $0.lit == 1 })
        #expect(wires.vias.allSatisfy { $0.lit == 1 })
    }

    @Test("in a replay a node is dark before it fires, ramps at it, then stays lit")
    func litRamp() throws {
        var model = BrainFixtures.model()
        let fire = model.timeline.fireTimes
        let target = try #require(model.steps.indices.first { fire[$0] > 1 && model.steps[$0].zone == .sense })
        let id = model.steps[target].id
        model.startReplay(now: 10)
        func draw(_ at: Double, reduce: Bool = false) throws -> NeuralNodeDraw {
            try #require(
                NeuralNodes.draws(model: model, time: 10 + at, reduceMotion: reduce)
                    .first { $0.id == id })
        }
        let at = fire[target]
        #expect(try draw(at - 0.01).lit == 0)
        #expect(try draw(at - 0.01).flash == 0)
        let halfway = try draw(at + NeuralNodes.rampTime / 2)
        #expect(abs(halfway.lit - 0.5) < 0.001)
        #expect(halfway.flash > 0.5)
        #expect(try draw(at + NeuralNodes.rampTime).lit == 1)
        #expect(try draw(at + 3).lit == 1)
        #expect(try draw(at + 3).flash == 0)
        #expect(try draw(at + 0.01, reduce: true).lit == 1)
        #expect(try draw(at + 0.01, reduce: true).flash == 0)
        #expect(try draw(at - 0.01, reduce: true).lit == 0)
        let moving = try draw(at + 0.5)
        #expect(moving.motion == .still)
    }

    @Test("a ganglion fires with its earliest member")
    func ganglionFires() throws {
        var model = BrainFixtures.model()
        let ganglion = try #require(model.layout.ganglia.first)
        model.startReplay(now: 0)
        let fire = try #require(model.replay?.fire)
        let times = ganglion.members.compactMap { model.indexByID[$0] }.map { fire[$0] }
        #expect(Set(times).count == 1)
        let raw = model.timeline.fireTimes
        let earliest = ganglion.members.compactMap { model.indexByID[$0] }.map { raw[$0] }.min()
        #expect(times.first == earliest)
    }

    @Test("an answer word dims every node it does not point at, and the selection lights its own")
    func dimmedHotPinned() throws {
        var model = BrainFixtures.model()
        #expect(NeuralNodes.draws(model: model, time: 0, reduceMotion: false).allSatisfy { !$0.dimmed && !$0.hot })
        model.setProvenance(token: Fixtures.flac)
        let carried = model.provenanceSteps
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        for draw in draws {
            let inSet = model.members(of: draw.id).contains { carried.contains($0) }
            #expect(draw.hot == inSet)
            #expect(draw.dimmed == !inSet)
        }
        #expect(draws.contains { $0.hot })

        model.setProvenance(token: nil)
        let step = model.steps[4]
        model.togglePin(step.id)
        let pinned = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        #expect(pinned.filter { $0.pinned }.map(\.id) == [step.id])
        #expect(Set(pinned.filter { $0.hot }.map(\.id)) == Set(model.hotSteps).intersection(pinned.map(\.id)))
        #expect(pinned.allSatisfy { !$0.dimmed })
    }

    @Test("a ganglion carries its members' answer words and its members' selection")
    func ganglionEmphasis() throws {
        var model = BrainFixtures.model()
        let ganglion = try #require(model.layout.ganglia.first)
        let member = ganglion.members[3]
        let detail = try #require(model.step(id: member)?.detail)
        model.setProvenance(token: detail)
        let leader = try #require(
            NeuralNodes.draws(model: model, time: 0, reduceMotion: false).first { $0.id == ganglion.leader })
        #expect(leader.hot)
        #expect(!leader.dimmed)

        model.setProvenance(token: nil)
        model.setHover(member)
        let hovered = try #require(
            NeuralNodes.draws(model: model, time: 0, reduceMotion: false).first { $0.id == ganglion.leader })
        #expect(hovered.hot)
    }

    @Test("a recovered failure is flagged and wears attention, not danger")
    func recovered() throws {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        let healed = try #require(draws.first { $0.isRecovered })
        #expect(healed.status == .failed)
        #expect(healed.tone == .attention)
        #expect(healed.verdict == .fixed)
        #expect(draws.filter { $0.isRecovered }.count == 1)
    }

    @Test("wires are the layout's routes, hot where the selection touches them")
    func wires() throws {
        var model = BrainFixtures.model(BrainFixtures.buildFix())
        var wires = NeuralNodes.wires(model: model, time: 0)
        let routes = model.layout.routes
        #expect(wires.routes.count == routes.count)
        #expect(wires.routes.map(\.points) == routes.map(\.points))
        #expect(wires.routes.map(\.zone) == routes.map(\.edge.zone))
        #expect(wires.routes.allSatisfy { !$0.hot && !$0.dimmed })
        #expect(wires.vias.count == model.layout.vias.count)

        model.setHover(model.steps[6].id)
        wires = NeuralNodes.wires(model: model, time: 0)
        let hot = wires.routes.filter { $0.hot }.map(\.points)
        #expect(hot == model.hotRoutes.map(\.points))
        #expect(!hot.isEmpty)
    }

    @Test("an answer word dims the wires and ties it does not touch")
    func wireProvenance() {
        var model = BrainFixtures.model(BrainFixtures.buildFix())
        model.setProvenance(token: "TailscodeLinux/Sources/Chat/TranscriptRows.swift")
        let wires = NeuralNodes.wires(model: model, time: 0)
        #expect(wires.routes.contains { $0.hot })
        #expect(wires.routes.contains { $0.dimmed })
        #expect(wires.routes.allSatisfy { $0.hot != $0.dimmed })
        #expect(wires.ties.allSatisfy { $0.dimmed })
    }

    @Test("ties are labelled by the file's name or the command's first words")
    func ties() throws {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let ties = NeuralNodes.wires(model: model, time: 0).ties
        let file = try #require(ties.first { !$0.isCommand })
        #expect(file.label == "TranscriptRows.swift")
        #expect(!file.arcs.isEmpty)
        let command = try #require(ties.first { $0.isCommand })
        #expect(command.label == "swift build -c")
        let long = NeuralLayout.Tie(
            key: String(repeating: "abcdefgh ", count: 6), isCommand: true, members: [], arcs: [])
        #expect(NeuralNodes.label(forTie: long).count <= 28)
        let bare = NeuralLayout.Tie(key: "README.md", isCommand: false, members: [], arcs: [])
        #expect(NeuralNodes.label(forTie: bare) == "README.md")
    }

    @Test("a hovered node lights the ties it belongs to")
    func tieHot() throws {
        var model = BrainFixtures.model(BrainFixtures.buildFix())
        let tie = try #require(model.layout.ties.first { !$0.isCommand })
        model.setHover(tie.members[0])
        let ties = NeuralNodes.wires(model: model, time: 0).ties
        #expect(ties.filter { $0.hot }.count >= 1)
        #expect(ties.first { $0.key == tie.key }?.hot == true)
        model.setHover(model.steps[0].id)
        #expect(NeuralNodes.wires(model: model, time: 0).ties.allSatisfy { !$0.hot })
    }

    @Test("in a replay a wire's pulse crosses it as its group fires, and a tie follows its last step")
    func replayWires() throws {
        var model = BrainFixtures.model()
        model.startReplay(now: 0)
        let first = NeuralNodes.wires(model: model, time: -5)
        #expect(first.routes.allSatisfy { $0.lit == 0 })
        #expect(first.ties.allSatisfy { $0.lit == 0 })
        let last = NeuralNodes.wires(model: model, time: model.timeline.duration)
        #expect(last.routes.allSatisfy { $0.lit == 1 })
        #expect(last.ties.allSatisfy { $0.lit == 1 })
        #expect(last.vias.allSatisfy { $0.lit == 1 })
        var sawPulse = false
        var time = 0.0
        while time < model.timeline.duration {
            let wires = NeuralNodes.wires(model: model, time: time)
            if wires.routes.contains(where: \.isPulsing) { sawPulse = true }
            let reduced = NeuralNodes.wires(model: model, time: time, reduceMotion: true)
            #expect(reduced.routes.allSatisfy { $0.lit == 0 || $0.lit == 1 })
            time += 0.05
        }
        #expect(sawPulse)
    }

    @Test("past sixty nodes the Apple clients instance them")
    func instancing() {
        func model(_ zones: [NeuralZone]) -> NeuralBrainModel {
            BrainFixtures.model(NeuralTurn(id: "x", steps: BrainFixtures.steps(zones)))
        }
        let sixty = model(
            Array(repeating: .think, count: 19) + Array(repeating: .sense, count: 19)
                + Array(repeating: .act, count: 16) + Array(repeating: .shell, count: 6))
        #expect(sixty.nodeCount == 60)
        #expect(!sixty.useInstancedNodes)
        #expect(!NeuralNodes.useInstancedNodes(model: sixty))
        #expect(NeuralNodes.draws(model: sixty, time: 0, reduceMotion: false).count == 60)

        let sixtyOne = model(
            Array(repeating: .think, count: 19) + Array(repeating: .sense, count: 19)
                + Array(repeating: .act, count: 16) + Array(repeating: .shell, count: 7))
        #expect(sixtyOne.nodeCount == 61)
        #expect(sixtyOne.useInstancedNodes)
        #expect(NeuralNodes.useInstancedNodes(model: sixtyOne))
    }

    @Test("a long turn in one zone is a few nodes and one ganglion")
    func longTurnFewNodes() throws {
        let model = BrainFixtures.model(
            NeuralTurn(id: "x", steps: BrainFixtures.steps(Array(repeating: .shell, count: 100))))
        #expect(model.nodeCount == 12)
        #expect(!model.useInstancedNodes)
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        #expect(draws.count == 12)
        #expect(draws.last?.ganglionCount == 89)
        #expect(draws.last?.label == "+89")
    }
}
