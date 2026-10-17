import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural transition")
struct NeuralTransitionTests {
    typealias T = NeuralTransition

    private let metrics = NeuralStageMetrics.make(width: 1100, density: .comfortable)
    private let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }

    private func move(
        _ direction: T.Direction = .open, nodes: Int = 29, reduceMotion: Bool = false,
        level: ShedLevel = .calm
    ) -> T {
        T.make(direction, metrics: metrics, nodeCount: nodes, reduceMotion: reduceMotion, level: level)
    }

    private func alphas(_ frame: NeuralTransitionFrame) -> [Double] {
        var out = [
            frame.travellerAlpha, frame.cardPictureAlpha, frame.cardTextAlpha,
            frame.cardSurfaceAlpha, frame.readoutAlpha, frame.footerAlpha, frame.wireDraw,
            frame.tieDraw, frame.sweepAmount, frame.sweepPhase, frame.zoneLift,
        ]
        for index in 0..<frame.nodes.count { out.append(frame.nodes.alpha(index)) }
        return out
    }

    @Test("durations: 320 opening, 220 closing, 280 for a swap, 160 strained, 120 reduced")
    func durations() {
        #expect(move(.open).duration == 0.320)
        #expect(move(.close).duration == 0.220)
        #expect(move(.swap).duration == 0.280)
        #expect(move(.swapClose).duration == 0.280)
        #expect(move(.open, level: .strained).duration == 0.160)
        #expect(move(.close, level: .critical).duration == 0.160)
        #expect(move(.open, level: .loaded).duration == 0.320)
        #expect(move(.open, reduceMotion: true).duration == 0.120)
        #expect(move(.close, reduceMotion: true, level: .strained).duration == 0.120)
    }

    @Test("an opening starts on the card and ends on the stage, exactly")
    func openEndpoints() {
        let open = move(.open)
        let start = open.frame(at: 0)
        #expect(start.traveller == metrics.card.picture)
        #expect(start.rowHeight == metrics.cardHeight)
        #expect(start.cardTextAlpha == 1 && start.cardSurfaceAlpha == 1)
        #expect(start.readoutAlpha == 0 && start.footerAlpha == 0)
        #expect(start.nodes.revealed == 0)
        #expect(start.wireDraw == 0 && start.tieDraw == 0)
        #expect(start.sweepAmount == 0 && start.zoneLift == 0)
        let end = open.frame(at: 1)
        #expect(end.traveller == metrics.stage)
        #expect(end.rowHeight == metrics.rowHeight)
        #expect(end.cardTextAlpha == 0 && end.cardSurfaceAlpha == 0)
        #expect(end.readoutAlpha == 1 && end.footerAlpha == 1)
        #expect(end.readoutOffset == NeuralPoint(0, 0))
        #expect(end.nodes.revealed == 29)
        #expect((0..<29).allSatisfy { end.nodes.scale($0) == 1 && end.nodes.alpha($0) == 1 })
        #expect(end.wireDraw == 1 && end.tieDraw == 1)
        #expect(end.zoneLift == 1 && end.sweepAmount == 0)
    }

    @Test("a closing starts on the stage and ends on the card, exactly")
    func closeEndpoints() {
        let close = move(.close)
        let start = close.frame(at: 0)
        #expect(start.traveller == metrics.stage)
        #expect(start.rowHeight == metrics.rowHeight)
        #expect(start.readoutAlpha == 1 && start.footerAlpha == 1)
        #expect(start.nodes.revealed == 29)
        #expect(start.wireDraw == 1 && start.tieDraw == 1)
        #expect(start.cardTextAlpha == 0 && start.cardSurfaceAlpha == 0)
        let end = close.frame(at: 1)
        #expect(end.traveller == metrics.card.picture)
        #expect(end.rowHeight == metrics.cardHeight)
        #expect(end.readoutAlpha == 0 && end.footerAlpha == 0)
        #expect(end.nodes.revealed == 0)
        #expect(end.wireDraw == 0 && end.tieDraw == 0)
        #expect(end.cardTextAlpha == 1 && end.cardSurfaceAlpha == 1)
        #expect(end.cardTextOffsetX == 0)
    }

    @Test("the head's rectangle moves monotonically, and so does the row's height")
    func monotonic() {
        for direction in [T.Direction.open, .close, .swap, .swapClose] {
            let move = move(direction)
            var previous = move.frame(at: 0)
            let opening = direction.isOpening
            for p in samples.dropFirst() {
                let frame = move.frame(at: p)
                let sign: Double = opening ? 1 : -1
                #expect(sign * (frame.traveller.width - previous.traveller.width) >= -1e-9)
                #expect(sign * (frame.traveller.height - previous.traveller.height) >= -1e-9)
                #expect(sign * (frame.rowHeight - previous.rowHeight) >= -1e-9)
                let low = min(metrics.cardHeight, metrics.rowHeight)
                let high = max(metrics.cardHeight, metrics.rowHeight)
                #expect(frame.rowHeight >= low - 1e-9 && frame.rowHeight <= high + 1e-9)
                previous = frame
            }
        }
    }

    @Test("every position of the head moves one way, edge by edge")
    func travelEdges() {
        let open = move(.open)
        var previous = open.frame(at: 0).traveller
        for p in samples.dropFirst() {
            let rect = open.frame(at: p).traveller
            #expect(rect.x <= previous.x + 1e-9 && rect.maxX >= previous.maxX - 1e-9)
            previous = rect
        }
    }

    @Test("no element's alpha ever leaves 0 to 1, in any mode")
    func alphaBounds() {
        for direction in [T.Direction.open, .close, .swap, .swapClose] {
            for (reduce, level) in [(false, ShedLevel.calm), (true, .calm), (false, .strained), (false, .critical)] {
                let move = move(direction, reduceMotion: reduce, level: level)
                for p in samples {
                    for value in alphas(move.frame(at: p)) {
                        #expect(value >= 0 && value <= 1, "\(direction) reduce \(reduce) level \(level) at \(p)")
                    }
                }
            }
        }
    }

    @Test("the opening table: nothing but the card moves until the times in the spec")
    func openingTable() {
        let open = move(.open)
        func at(_ ms: Double) -> NeuralTransitionFrame { open.frame(at: ms / 320) }
        #expect(at(119).nodes.revealed == 0)
        #expect(at(121).nodes.revealed > 0)
        #expect(at(149).readoutAlpha == 0)
        #expect(at(151).readoutAlpha > 0)
        #expect(at(239).footerAlpha == 0)
        #expect(at(241).footerAlpha > 0)
        #expect(at(39).sweepAmount == 0)
        #expect(at(41).sweepAmount > 0)
        #expect(at(120).sweepAmount > 0.9 || at(120).sweepAmount > 0.5)
        #expect(at(201).sweepAmount == 0)
        #expect(at(90).cardTextAlpha == 0 && at(90).cardSurfaceAlpha == 0)
        #expect(at(45).cardTextAlpha > 0 && at(45).cardTextAlpha < 1)
        #expect(at(45).cardTextOffsetX < 0 && at(45).cardTextOffsetX > -8)
        #expect(at(90).cardTextOffsetX == -8)
        #expect(at(139).wireDraw == 0 && at(141).wireDraw > 0)
        #expect(at(239).tieDraw == 0 && at(241).tieDraw > 0)
        #expect(at(300).nodes.revealed == 29)
        #expect(at(300).wireDraw == 1)
    }

    @Test("the geometry is snappy: 70 percent of the travel in the first 40 percent of the time")
    func snappy() {
        let open = move(.open)
        let width = { (p: Double) in open.frame(at: p).traveller.width }
        let start = width(0)
        let end = width(1)
        #expect((width(0.4) - start) / (end - start) > 0.7)
    }

    @Test("nodes pop in step order, staggered over 150 ms, with a six percent overshoot")
    func nodePops() {
        let open = move(.open)
        let mid = open.frame(at: 200.0 / 320)
        let progress = (0..<29).map { mid.nodes.progress($0) }
        #expect(progress == progress.sorted(by: >))
        #expect(progress.first! > progress.last!)
        let firstStart = (0...320).first { open.frame(at: Double($0) / 320).nodes.progress(0) > 0 }!
        let lastStart = (0...320).first { open.frame(at: Double($0) / 320).nodes.progress(28) > 0 }!
        #expect(firstStart == 121)
        #expect(abs(Double(lastStart - firstStart) - 150) <= 2)
        var peak = 0.0
        for ms in 0...320 {
            let scale = open.frame(at: Double(ms) / 320).nodes.scale(0)
            peak = max(peak, scale)
            #expect(scale >= 0.6 - 1e-9)
        }
        #expect(abs(peak - 1.06) < 0.006)
        #expect(open.frame(at: 0.5).nodes.scale(0) >= 0.6)
    }

    @Test("closing has no overshoot and takes nodes out last first")
    func closeNodes() {
        let close = move(.close)
        for p in samples {
            let frame = close.frame(at: p)
            for index in 0..<29 { #expect(frame.nodes.scale(index) <= 1 + 1e-9) }
        }
        let early = close.frame(at: 90.0 / 220)
        #expect(early.nodes.progress(28) < early.nodes.progress(0))
        #expect(close.frame(at: 150.0 / 220).nodes.revealed == 0)
        #expect(close.frame(at: 100.0 / 220).readoutAlpha == 0)
        #expect(close.frame(at: 100.0 / 220).footerAlpha == 0)
        #expect(close.frame(at: 110.0 / 220).cardSurfaceAlpha == 0)
        #expect(close.frame(at: 160.0 / 220).cardSurfaceAlpha > 0)
    }

    @Test("a press during the move reverses from where it is, and the frames match")
    func reversalContinuity() {
        for direction in [T.Direction.open, .close, .swap] {
            let forward = move(direction)
            for p in [0.0, 0.1, 0.25, 0.5, 0.8, 1.0] {
                let back = forward.reversed(from: p)
                #expect(back.frame(at: 0) == forward.frame(at: p), "\(direction) at \(p)")
                #expect(back.frame(at: 1) == forward.frame(at: 0), "\(direction) at \(p)")
                #expect(back.direction == direction.reversed)
            }
        }
    }

    @Test("a reversed move moves continuously and takes the time the distance left needs")
    func reversalSmooth() {
        let forward = move(.open)
        let back = forward.reversed(from: 0.5)
        var previous = back.frame(at: 0).traveller
        for u in samples.dropFirst() {
            let rect = back.frame(at: u).traveller
            #expect(rect.width <= previous.width + 1e-9)
            previous = rect
        }
        #expect(back.duration < move(.close).duration)
        #expect(back.duration > 0)
        let again = back.reversed(from: 0.5)
        #expect(again.frame(at: 0) == back.frame(at: 0.5))
        #expect(again.frame(at: 1) == forward.frame(at: 1))
    }

    @Test("reduced motion is a crossfade: no travel, no sweep, no stagger, no overshoot")
    func reduced() {
        for direction in [T.Direction.open, .close] {
            let move = move(direction, reduceMotion: true)
            #expect(move.duration == 0.120)
            for p in samples {
                let frame = move.frame(at: p)
                #expect(frame.sweepAmount == 0)
                #expect(frame.cardTextOffsetX == 0)
                #expect(frame.readoutOffset == NeuralPoint(0, 0))
                let first = frame.nodes.progress(0)
                #expect((0..<29).allSatisfy { frame.nodes.progress($0) == first })
                #expect((0..<29).allSatisfy { frame.nodes.scale($0) == 1 })
                let widths = [metrics.card.picture, metrics.stage].map(\.width)
                #expect(widths.contains(frame.traveller.width))
            }
        }
        let open = move(.open, reduceMotion: true)
        #expect(open.frame(at: 0).traveller == metrics.card.picture)
        #expect(open.frame(at: 1).traveller == metrics.stage)
        #expect(open.frame(at: 0.5).cardTextAlpha == 0.5)
        #expect(open.frame(at: 0.5).readoutAlpha == 0.5)
        #expect(open.frame(at: 0.5).travellerAlpha == 0.5)
    }

    @Test("a strained window keeps the travel and drops the sweep and the stagger")
    func strained() {
        for level in [ShedLevel.strained, .critical] {
            let move = move(.open, level: level)
            #expect(move.isStrained)
            var moved = false
            for p in samples {
                let frame = move.frame(at: p)
                #expect(frame.sweepAmount == 0)
                let first = frame.nodes.progress(0)
                #expect((0..<29).allSatisfy { abs(frame.nodes.progress($0) - first) < 1e-9 })
                if frame.traveller != metrics.card.picture, frame.traveller != metrics.stage { moved = true }
            }
            #expect(moved)
        }
        #expect(!move(.open, level: .loaded).isStrained)
    }

    @Test("a stacked row slides its readout in from below")
    func stackedSlide() {
        let narrow = NeuralStageMetrics.make(width: 400, density: .comfortable)
        let open = T.make(.open, metrics: narrow, nodeCount: 5)
        #expect(open.frame(at: 0.5).readoutOffset.x == 0)
        #expect(open.frame(at: 0.5).readoutOffset.y > 0)
        let wide = move(.open).frame(at: 0.6)
        #expect(wide.readoutOffset.y == 0 && wide.readoutOffset.x > 0)
    }

    @Test("the curves are the ones the spec names")
    func curves() {
        #expect(T.easeOutCubic(0) == 0 && T.easeOutCubic(1) == 1)
        #expect(T.easeInCubic(0) == 0 && T.easeInCubic(1) == 1)
        #expect(abs(T.easeOutCubic(0.4) - 0.784) < 1e-9)
        #expect(abs(T.easeInCubic(0.5) - 0.125) < 1e-9)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(T.easeInCubic(t) - (1 - T.easeOutCubic(1 - t))) < 1e-9)
        }
        #expect(T.easeOutBack(0) == 0)
        #expect(abs(T.easeOutBack(1) - 1) < 1e-9)
        #expect((0...100).map { T.easeOutBack(Double($0) / 100) }.max()! > 1)
        #expect(T.easeOutCubic(-1) == 0 && T.easeOutCubic(2) == 1)
    }

    @Test("the first content cross-fades in over 90 ms after the readout has landed")
    func firstContent() {
        #expect(T.firstContentAlpha(after: 0) == 0)
        #expect(abs(T.firstContentAlpha(after: 0.045) - 0.5) < 1e-9)
        #expect(T.firstContentAlpha(after: 0.2) == 1)
    }

    @Test("a turn with no nodes still moves")
    func noNodes() {
        let move = move(.open, nodes: 0)
        #expect(move.frame(at: 0.5).nodes.revealed == 0)
        #expect(move.frame(at: 1).traveller == metrics.stage)
    }

    @Test("progress outside 0 to 1 is held at the ends")
    func clamped() {
        let open = move(.open)
        #expect(open.frame(at: -1) == open.frame(at: 0))
        #expect(open.frame(at: 3) == open.frame(at: 1))
    }
}
