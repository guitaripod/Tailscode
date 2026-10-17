import Testing

@testable import TailscodeCore

@Suite("Neural glyph")
struct NeuralGlyphTests {
    private func step(_ index: Int, _ zone: NeuralZone, _ status: NeuralStatus = .ok, recovered: Bool = false)
        -> NeuralStep
    {
        NeuralStep(
            id: "m:\(index)", index: index, zone: zone, status: status, group: index,
            messageID: "m", title: "t", recovered: recovered)
    }

    private var fixture: [NeuralStep] {
        [
            step(0, .think), step(1, .sense), step(2, .sense), step(3, .shell, .failed),
            step(4, .shell), step(5, .shell), step(6, .shell), step(7, .shell, .failed, recovered: true),
            step(8, .say),
        ]
    }

    @Test("the outline is the mock's twenty-one points")
    func outline() {
        #expect(NeuralGlyph.outline.count == 21)
        #expect(NeuralGlyph.outline.first == NeuralPoint(196, 412))
        #expect(NeuralGlyph.outline.last == NeuralPoint(384, 412))
        #expect(NeuralGlyph.viewBox == (68, 6, 566, 368))
        #expect(NeuralGlyph.eyeBar.count == 4)
        #expect(NeuralGlyph.eyeHalo.center == NeuralPoint(586, 216))
        #expect(NeuralGlyph.eyeHalo.radius == 46 && NeuralGlyph.eyeHalo.opacity == 0.28)
    }

    @Test("a zone with steps gets one dot at its centre, in the mock's order")
    func dots() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .identity)
        #expect(glyph.dots.map(\.zone) == [.think, .sense, .shell, .say])
        for dot in glyph.dots { #expect(dot.center == dot.zone.center) }
        #expect(glyph.eyeTone == .identity)
    }

    @Test("a dot's radius is 44 plus 12 a step up to four, and its opacity grows by a tenth")
    func radii() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .quiet)
        let byZone = Dictionary(uniqueKeysWithValues: glyph.dots.map { ($0.zone, $0) })
        #expect(byZone[.think]?.radius == 56 && byZone[.think]?.count == 1)
        #expect(byZone[.sense]?.radius == 68 && byZone[.sense]?.count == 2)
        #expect(byZone[.shell]?.radius == 92 && byZone[.shell]?.count == 5)
        #expect(byZone[.say]?.radius == 56)
        #expect(abs((byZone[.think]?.opacity ?? 0) - 0.72) < 1e-9)
        #expect(abs((byZone[.sense]?.opacity ?? 0) - 0.82) < 1e-9)
        #expect(abs((byZone[.shell]?.opacity ?? 0) - 1.02) < 1e-9)
    }

    @Test("a dim glyph draws its dots at 40 percent")
    func dim() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .quiet, dim: true)
        let think = glyph.dots.first { $0.zone == .think }
        #expect(abs((think?.opacity ?? 0) - 0.72 * 0.4) < 1e-9)
    }

    @Test("a failure nobody recovered rings its zone, a recovered one does not")
    func failure() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .danger)
        let shell = glyph.dots.first { $0.zone == .shell }
        #expect(shell?.failureRing == NeuralGlyph.Ring(radius: 108, strokeWidth: 18))
        #expect(glyph.dots.filter { $0.failureRing != nil }.count == 1)
        let healed = NeuralGlyph(
            steps: [step(0, .shell, .failed, recovered: true), step(1, .shell)], eyeTone: .quiet)
        #expect(healed.dots.allSatisfy { $0.failureRing == nil })
    }

    @Test("the active ring sits 34 outside the dot, only on a zone that has one")
    func active() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .live, activeZone: .sense)
        let sense = glyph.dots.first { $0.zone == .sense }
        #expect(sense?.activeRing == NeuralGlyph.Ring(radius: 102, strokeWidth: 15))
        #expect(glyph.dots.filter { $0.activeRing != nil }.count == 1)
        let absent = NeuralGlyph(steps: fixture, eyeTone: .live, activeZone: .act)
        #expect(absent.dots.allSatisfy { $0.activeRing == nil })
    }

    @Test("the live flag marks the zone of the last step")
    func live() {
        let glyph = NeuralGlyph(steps: fixture, eyeTone: .live, live: true)
        #expect(glyph.dots.filter(\.isLive).map(\.zone) == [.say])
        #expect(NeuralGlyph(steps: fixture, eyeTone: .live).dots.allSatisfy { !$0.isLive })
    }

    @Test("no steps is no dots, and the height keeps the crop's proportion")
    func empty() {
        #expect(NeuralGlyph(steps: [], eyeTone: .quiet).dots.isEmpty)
        #expect(NeuralGlyph.height(forWidth: 566) == 368)
        #expect(NeuralGlyph.height(forWidth: 30) == 20)
    }
}
