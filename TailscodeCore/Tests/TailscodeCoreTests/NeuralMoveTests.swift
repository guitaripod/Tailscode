import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural move: one progress, both ways, both card states")
struct NeuralMoveTests {
    typealias T = NeuralTransition

    private let metrics = NeuralStageMetrics.make(width: 1100, density: .comfortable)
    private let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }

    private func move(
        _ direction: T.Direction = .open, live: Bool = false, reduceMotion: Bool = false,
        level: ShedLevel = .calm
    ) -> T {
        T.make(direction, metrics: metrics, nodeCount: 29, reduceMotion: reduceMotion, level: level, live: live)
    }

    private func alphas(_ frame: NeuralTransitionFrame) -> [Double] {
        var out = [
            frame.travellerAlpha, frame.cardPictureAlpha, frame.cardLightsAlpha, frame.cardTextAlpha,
            frame.cardSurfaceAlpha, frame.readoutAlpha, frame.footerAlpha, frame.wireDraw,
            frame.tieDraw, frame.sweepAmount, frame.zoneLift, frame.panelAlpha, frame.listHeaderAlpha,
            frame.edge.alpha, frame.nowCrossfade.card, frame.nowCrossfade.account,
            frame.countsCrossfade.card, frame.countsCrossfade.account,
        ]
        for index in 0..<frame.nodes.count { out.append(frame.nodes.alpha(index)) }
        for index in 0..<frame.listRows.count { out.append(frame.listRows.alpha(index)) }
        return out
    }

    @Test("opening is g = easeOutCubic(t / 320), and closing is g0 x (1 - easeInOutCubic(t / 220))")
    func curves() {
        let open = move(.open)
        for u in samples { #expect(abs(open.gradient(at: u) - T.easeOutCubic(u)) < 1e-12) }
        let close = move(.close)
        for u in samples { #expect(abs(close.gradient(at: u) - (1 - T.easeInOutCubic(u))) < 1e-12) }
        #expect(T.easeInOutCubic(0) == 0 && T.easeInOutCubic(1) == 1)
        #expect(abs(T.easeInOutCubic(0.5) - 0.5) < 1e-12)
        #expect(T.easeInOutCubic(0.25) < T.easeInCubic(0.5))
        for u in samples.dropFirst() { #expect(T.easeInOutCubic(u) >= T.easeInOutCubic(u - 0.01) - 1e-12) }
        #expect(open.gradient(at: 0) == 0 && open.gradient(at: 1) == 1)
        #expect(close.gradient(at: 0) == 1 && close.gradient(at: 1) == 0)
    }

    @Test("content time is the opening timeline's: real time when opening, played back when closing")
    func contentTime() {
        let open = move(.open)
        for ms in stride(from: 0.0, through: 320, by: 8) {
            let frame = open.frame(at: ms / 320)
            #expect(abs(frame.contentTime - ms) < 1e-6)
        }
        #expect(T.contentTime(forGradient: 0) == 0 && T.contentTime(forGradient: 1) == 320)
        #expect(abs(T.contentTime(forGradient: 0.875) - 160) < 1e-6)
        let close = move(.close)
        var previous = 320.0
        for u in samples {
            let te = close.frame(at: u).contentTime
            #expect(te <= previous + 1e-9)
            previous = te
        }
        #expect(close.frame(at: 1).contentTime == 0)
    }

    @Test("the head overscales 1.5 percent in a half sine over g 0.6 to 1.0, about its centre, and is exact at the ends")
    func overscale() {
        #expect(T.overscale(at: 0) == 1 && T.overscale(at: 0.6) == 1 && T.overscale(at: 1) == 1)
        #expect(abs(T.overscale(at: 0.8) - 1.015) < 1e-12)
        #expect((0...100).allSatisfy { T.overscale(at: Double($0) / 100) <= 1.015 + 1e-12 })
        let open = move(.open)
        let stage = metrics.stage
        for u in samples {
            let frame = open.frame(at: u)
            #expect(frame.traveller.width <= max(metrics.card.picture.width, stage.width) * 1.015 + 1e-9)
        }
        let late = open.frame(at: 0.8)
        let g = late.progress
        let base = open.from.picture.interpolated(to: open.to.picture, g)
        let centre = (late.traveller.x + late.traveller.width / 2, base.x + base.width / 2)
        #expect(abs(centre.0 - centre.1) < 1e-9)
        #expect(late.traveller.width >= base.width && late.traveller.width <= base.width * 1.0151)
        #expect(open.frame(at: 1).traveller == metrics.stage)
        #expect(move(.close).frame(at: 1).traveller == metrics.card.picture)
    }

    @Test("the card's tone edge rides the picture's left edge for 90 ms of content time and is gone by 150")
    func edge() {
        let open = move(.open)
        func at(_ ms: Double) -> NeuralTransitionFrame { open.frame(at: ms / 320) }
        #expect(at(0).edge.alpha == 1 && at(90).edge.alpha == 1)
        #expect(at(120).edge.alpha > 0 && at(120).edge.alpha < 1)
        #expect(at(150).edge.alpha == 0 && at(320).edge.alpha == 0)
        #expect(abs(at(0).edge.x - (metrics.card.picture.x - 12)) < 1e-9)
        #expect(abs(at(60).edge.x - (open.from.picture.interpolated(to: open.to.picture, at(60).progress).x - 12)) < 1e-9)
        let close = move(.close)
        #expect(close.frame(at: 1).edge.alpha == 1 && close.frame(at: 0).edge.alpha == 0)
    }

    @Test("a live open keeps the live head's swell through the whole move on the shared clock")
    func liveSwell() {
        let live = move(.open, live: true)
        #expect(live.fromLive && !live.toLive && move(.close, live: true).toLive)
        let plain = move(.open)
        #expect(!plain.fromLive)
        for u in samples {
            #expect(plain.frame(at: u, clock: 0.4).travellerSwell == 1)
            let frame = live.frame(at: u, clock: 0.4)
            #expect(frame.travellerSwell == NeuralMotion.breathLevel(at: 0.4))
        }
        var seen = Set<Double>()
        for ms in stride(from: 0.0, to: 1.9, by: 0.1) { seen.insert(live.frame(at: 0.5, clock: ms).travellerSwell) }
        #expect(seen.count > 5)
        #expect(live.frame(at: 0.5, clock: 3.3).travellerSwell == live.frame(at: 0.9, clock: 3.3).travellerSwell)
        let reduced = move(.open, live: true, reduceMotion: true)
        #expect(reduced.frame(at: 0.5, clock: 0.4).travellerSwell == 1)
        #expect(live.frame(at: 0.3, clock: 1).travellerSwell >= ActivityTuning.breathFloor - 1e-9)
    }

    @Test("the NOW line leaves and the account's Now arrives in the same place, the counts the same")
    func nowCrossfade() {
        let open = move(.open, live: true)
        func at(_ ms: Double) -> NeuralTransitionFrame { open.frame(at: ms / 320) }
        #expect(at(0).nowCrossfade == NeuralNowCrossfade(card: 1, account: 0))
        #expect(at(90).nowCrossfade.card == 0 && at(130).nowCrossfade.account == 0)
        #expect(at(300).nowCrossfade == NeuralNowCrossfade(card: 0, account: 1))
        #expect(at(200).countsCrossfade == at(200).nowCrossfade)
        for u in samples {
            let frame = open.frame(at: u)
            #expect(frame.nowCrossfade.account >= 0 && frame.nowCrossfade.account <= 1)
        }
    }

    @Test("every alpha stays in 0 to 1 in every direction, mode, level and card state")
    func alphaBounds() {
        for direction in [T.Direction.open, .close, .swap, .swapClose] {
            for live in [false, true] {
                for (reduce, level) in [(false, ShedLevel.calm), (true, .calm), (false, .strained), (false, .critical)] {
                    let move = move(direction, live: live, reduceMotion: reduce, level: level)
                    for u in samples {
                        for value in alphas(move.frame(at: u, clock: u * 3)) {
                            #expect(value >= 0 && value <= 1, "\(direction) live \(live) reduce \(reduce) \(level) at \(u)")
                        }
                        let swell = move.frame(at: u, clock: u * 3).travellerSwell
                        #expect(swell >= 0 && swell <= 1)
                    }
                }
            }
        }
    }

    @Test("content timing follows the final numbers")
    func finalNumbers() {
        let open = move(.open)
        func at(_ ms: Double) -> NeuralTransitionFrame { open.frame(at: ms / 320) }
        #expect(at(129).readoutAlpha == 0 && at(131).readoutAlpha > 0 && at(300).readoutAlpha == 1)
        #expect(at(89).panelAlpha == 0 && at(190).listHeaderAlpha == 1)
        #expect(at(99).listRows.revealed == 0 && at(101).listRows.revealed == 1)
        #expect(at(119).nodes.revealed == 0 && at(121).nodes.revealed > 0)
        #expect(at(239).footerAlpha == 0 && at(320).footerAlpha == 1)
        #expect(at(39).sweepAmount == 0 && at(201).sweepAmount == 0)
        let stacked = T.make(.open, metrics: NeuralStageMetrics.make(width: 400, density: .comfortable), nodeCount: 5)
        #expect(stacked.to.readoutTravel == NeuralPoint(0, 12))
        #expect(open.to.readoutTravel == NeuralPoint(24, 0))
    }

    @Test("a strained or critical window shortens to 160 ms with no sweep or stagger but still moves")
    func strained() {
        for level in [ShedLevel.strained, .critical] {
            let move = move(.open, level: level)
            #expect(move.duration == 0.160)
            var moved = false
            for u in samples {
                let frame = move.frame(at: u)
                #expect(frame.sweepAmount == 0)
                let first = frame.nodes.progress(0)
                #expect((0..<29).allSatisfy { abs(frame.nodes.progress($0) - first) < 1e-9 })
                if frame.traveller != metrics.card.picture, frame.traveller != metrics.stage { moved = true }
            }
            #expect(moved)
        }
    }

    @Test("reduced motion is a 120 ms crossfade of the same fields")
    func reduced() {
        let open = move(.open, live: true, reduceMotion: true)
        #expect(open.duration == 0.120)
        #expect(open.frame(at: 0).traveller == metrics.card.picture)
        #expect(open.frame(at: 1).traveller == metrics.stage)
        let mid = open.frame(at: 0.5)
        #expect(mid.travellerAlpha == 0.5 && mid.cardTextAlpha == 0.5 && mid.nowCrossfade.account == 0.5)
        #expect(mid.sweepAmount == 0 && mid.cardTextOffsetX == 0 && mid.travellerSwell == 1)
    }

    @Test("a reversal from the live card turns round on the same g and the same swell")
    func liveReversal() {
        let open = move(.open, live: true)
        for p in [0.1, 0.4, 0.7, 0.95] {
            let back = open.reversed(from: p)
            #expect(back.toLive)
            let there = open.frame(at: p, clock: 2.2)
            let here = back.frame(at: 0, clock: 2.2)
            #expect(there.traveller == here.traveller && there.travellerSwell == here.travellerSwell)
            #expect(there.rowHeight == here.rowHeight && there.progress == here.progress)
            #expect(back.frame(at: 1).progress == 0)
        }
    }

    @Test("a reversal reverses and never restarts, even many times in a row")
    func manyReversals() {
        var current = move(.open)
        var u = 0.3
        var g = current.gradient(at: u)
        for turn in 0..<12 {
            current = current.reversed(from: u)
            #expect(current.frame(at: 0).progress == g, "turn \(turn)")
            u = [0.2, 0.5, 0.35, 0.8][turn % 4]
            g = current.gradient(at: u)
            #expect(g >= 0 && g <= 1)
        }
    }
}

@Suite("Neural crossing: one closing while another opens")
struct NeuralCrossingTests {
    typealias T = NeuralTransition

    private let closingMetrics = NeuralStageMetrics.make(width: 1100, density: .comfortable)
    private let openingMetrics = NeuralStageMetrics.make(width: 1100, density: .comfortable, rows: 4)

    private func crossing(above: Bool = true) -> NeuralCrossing {
        T.crossing(
            closing: T.make(.swapClose, metrics: closingMetrics, nodeCount: 29, live: false),
            opening: T.make(.swap, metrics: openingMetrics, nodeCount: 12, live: true),
            closingIsAbove: above)
    }

    @Test("the crossing runs 280 ms, and the two rows' heights add up continuously from start to end")
    func heights() {
        let crossing = crossing()
        #expect(crossing.duration == 0.280)
        let start = crossing.totalHeight(atTime: 0)
        #expect(start == closingMetrics.rowHeight + openingMetrics.cardHeight)
        let end = crossing.totalHeight(atTime: crossing.duration)
        #expect(end == closingMetrics.cardHeight + openingMetrics.rowHeight)
        var previous = start
        for ms in stride(from: 1.0, through: 280, by: 1) {
            let total = crossing.totalHeight(atTime: ms / 1000)
            #expect(abs(total - previous) < 24, "no jump at \(ms) ms")
            previous = total
        }
        #expect(crossing.belowShift(atTime: 0) == 0)
        #expect(abs(crossing.belowShift(atTime: crossing.duration) - (end - start)) < 1e-9)
    }

    @Test("the row below follows the row above: the opening row is carried by the closing row's change")
    func anchor() {
        let above = crossing(above: true)
        let below = crossing(above: false)
        #expect(above.openingRowShift(atTime: 0) == 0)
        #expect(above.openingRowShift(atTime: 0.14) < 0)
        #expect(below.openingRowShift(atTime: 0.14) == 0)
        let heights = above.rowHeights(atTime: 0.14)
        #expect(abs(above.openingRowShift(atTime: 0.14) - (heights.closing - closingMetrics.rowHeight)) < 1e-9)
    }

    @Test("both frames come from one clock, and a reversal turns both round where they are")
    func reversal() {
        let crossing = crossing()
        let at = 0.1
        let back = crossing.reversed(atTime: at)
        let before = crossing.closingFrame(atTime: at)
        let after = back.openingFrame(atTime: 0)
        #expect(before.traveller == after.traveller && before.rowHeight == after.rowHeight)
        let beforeOpen = crossing.openingFrame(atTime: at)
        let afterClose = back.closingFrame(atTime: 0)
        #expect(beforeOpen.traveller == afterClose.traveller && beforeOpen.rowHeight == afterClose.rowHeight)
        #expect(abs(back.totalHeight(atTime: 0) - crossing.totalHeight(atTime: at)) < 1e-9)
        #expect(crossing.closingFrame(atTime: 0.1, clock: 1).travellerSwell == 1)
        #expect(crossing.openingFrame(atTime: 0.1, clock: 1).travellerSwell == NeuralMotion.breathLevel(at: 1))
    }
}
