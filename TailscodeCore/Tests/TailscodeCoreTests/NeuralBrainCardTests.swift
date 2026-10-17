import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural brain card")
struct NeuralBrainCardTests {
    typealias F = ReadoutFixtures

    private let now = Date(timeIntervalSince1970: 1_000_100)

    private func card(_ model: NeuralBrainModel = F.model()) -> NeuralBrainCard {
        model.brainCard(now: now)
    }

    private func failedTurn() -> NeuralTurn {
        F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)]),
        ])
    }

    @Test("the headline leads with the count as a number, then the duration, the tally and the failure clause")
    func headline() throws {
        let card = card()
        #expect(card.headline.number == 12)
        #expect(card.headline.count == "12 tools")
        #expect(card.headline.pieces.map(\.kind) == [.count, .duration, .tally, .failure])
        #expect(card.headline.piece(.duration)?.tone == .quiet)
        #expect(card.headline.piece(.tally)?.text == "+11 \u{2212}3")
        #expect(card.headline.piece(.tally)?.tone == .live)
        #expect(card.headline.piece(.failure)?.text == "1 failed, then passed")
        #expect(card.headline.piece(.failure)?.tone == .attention)
    }

    @Test("a failure nobody retried is danger, and a turn that only spoke counts steps")
    func failureAndSteps() {
        let failed = card(F.model(failedTurn()))
        #expect(failed.headline.piece(.failure)?.text == "failed")
        #expect(failed.headline.piece(.failure)?.tone == .danger)
        let words = card(F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [.reasoning("hm"), .text("so"), .reasoning("ok"), .text("done")]),
        ])))
        #expect(words.headline.number == 3)
        #expect(words.headline.count == "3 steps")
        #expect(words.headline.piece(.failure) == nil)
        #expect(words.headline.piece(.tally) == nil)
    }

    @Test("zone chips are the zones that have steps, in zone order, with their counts")
    func chips() {
        let card = card()
        #expect(card.chips.map(\.zone) == [.think, .sense, .act, .shell, .delegate])
        #expect(card.chips.map(\.count) == [2, 4, 3, 4, 1])
        #expect(card.chips.map(\.label) == card.chips.map { $0.zone.label })
        #expect(card.chips.allSatisfy { $0.tone == .zone })
        let failed = self.card(F.model(failedTurn()))
        #expect(failed.chips.map(\.zone) == [.shell])
        #expect(failed.chips[0].tone == .danger)
    }

    @Test("the digest is one sentence of clauses, cut by whole clauses and never mid-word")
    func digest() {
        let card = card()
        #expect(card.digestClauses == [
            "ran 4 commands", "read 3 files", "searched 1 time", "edited 2 files", "delegated 1 task",
        ])
        #expect(card.digest == "Ran 4 commands, read 3 files, searched 1 time, edited 2 files, delegated 1 task.")
        #expect(card.digest(fitting: 46) == "Ran 4 commands, read 3 files, searched 1 time.")
        #expect(card.digest(fitting: 45) == "Ran 4 commands, read 3 files.")
        #expect(card.digest(fitting: 29) == "Ran 4 commands, read 3 files.")
        #expect(card.digest(fitting: 3) == "Ran 4 commands.")
        for width in 10...90 {
            let text = card.digest(fitting: width)
            #expect(text.hasSuffix("."))
            #expect(text.count <= width || !text.contains(","))
        }
    }

    @Test("the lights follow the glyph's rule: 44 plus 12 per step up to four, at .62 plus .1 per step")
    func lights() throws {
        let model = F.model()
        let card = card(model)
        #expect(card.lights.map(\.zone) == [.think, .sense, .act, .shell, .delegate])
        for light in card.lights {
            let n = Double(min(light.count, 4))
            #expect(light.radius == 44 + 12 * n)
            #expect(abs(light.strength - (0.62 + 0.1 * n)) < 1e-9)
            #expect(light.center == light.zone.center)
        }
        let think = try #require(card.lights.first { $0.zone == .think })
        #expect(think.count == 2)
        #expect(think.radius == 68)
        #expect(!card.lights.contains { $0.zone == .say })
    }

    @Test("a zone with no steps has no light, and a zone with an unrecovered failure has a ring")
    func rings() {
        let ok = card()
        #expect(ok.ringZones.isEmpty)
        let failed = card(F.model(failedTurn()))
        #expect(failed.lights.map(\.zone) == [.shell])
        #expect(failed.ringZones == [.shell])
        let recovered = F.model()
        #expect(card(recovered).lights.allSatisfy { $0.failureRing == nil })
    }

    @Test("hovering lifts the lights by 15 percent and never past full")
    func hover() {
        let card = card(F.model(BrainFixtures.turn()))
        let busy = card.lights.max { $0.strength < $1.strength }!
        #expect(busy.strength(hovered: false) == busy.strength)
        #expect(busy.strength(hovered: true) == 1)
        let quiet = card.lights.min { $0.strength < $1.strength }!
        #expect(abs(quiet.strength(hovered: true) - min(1, quiet.strength * 1.15)) < 1e-9)
    }

    @Test("the edge is the accent when settled, danger when failed, attention when waiting, quiet when stopped")
    func edge() throws {
        #expect(card().edge == .settled)
        #expect(card().edgeTone == .live)
        #expect(card(F.model(failedTurn())).edge == .failed)
        #expect(card(F.model(failedTurn())).edgeTone == .danger)
        let waiting = NeuralTurns.partition(
            messages: [
                NeuralTurnFixtures.user(0),
                NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("rm x", status: .running)], streaming: true),
            ], running: true, awaiting: NeuralAwaiting(approvals: ["m1:p0"]))[0]
        #expect(card(F.model(waiting)).edge == .waiting)
        #expect(card(F.model(waiting)).edgeTone == .attention)
        let stopped = F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("sleep 9", status: .stopped)], finish: "abort"),
        ])
        #expect(card(F.model(stopped)).edge == .stopped)
        #expect(card(F.model(stopped)).edgeTone == .quiet)
    }

    @Test("the eye wears who answered for a settled turn and the state's tone otherwise")
    func eye() {
        #expect(card().eyeTone == .identity)
        #expect(card(F.model(failedTurn())).eyeTone == .identity)
        let errored = F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)], error: "provider error"),
        ])
        #expect(errored.outcome == .failed)
        #expect(card(F.model(errored)).eyeTone == .danger)
        #expect(card(F.model(errored)).edge == .failed)
        let live = card(F.model(BrainFixtures.turn(running: true), ))
        #expect(live.eyeTone == F.model(BrainFixtures.turn(running: true)).state.tone)
    }

    @Test("a narrow card drops the zone strip first and then the digest, and keeps the rest")
    func fit() {
        let card = card()
        let always: Set<NeuralBrainCard.Part> = [.picture, .headline, .replay, .rows]
        #expect(card.fit(width: 800) == always.union([.zoneStrip, .digest]))
        #expect(card.fit(width: 460) == always.union([.zoneStrip, .digest]))
        #expect(card.fit(width: 459) == always.union([.digest]))
        #expect(card.fit(width: 380) == always.union([.digest]))
        #expect(card.fit(width: 379) == always)
        #expect(card.fit(width: 0) == always)
    }

    @Test("the card's words are the reading's, and a screen reader gets the turn's sentence")
    func spoken() {
        let model = F.model()
        #expect(card(model).spoken == NeuralReading.spoken(model.turn, now: now))
        #expect(card(model).turnID == model.turn.id)
    }
}
