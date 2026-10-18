import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The claims about a card that is alive and the moves between it and the stage: that a running
    /// turn's card says the verdict, the counts and the NOW line from Core's words, that a quote
    /// holds the line and a silence replaces the output, that one clock serves the live cards and
    /// none serves a settled one, that a card settles in one move of its own and then owns nothing,
    /// and that the moves from both card states, both ways, reversed and strained are smooth.
    static func checkBrainLive(_ expect: (Bool, String) throws -> Void) throws {
        try timedBrain("live card") { try checkLiveCard(expect) }
        try timedBrain("live settle") { try checkSettle(expect) }
        try timedBrain("live moves") { try checkLiveMoves(expect) }
    }

    private static func closedRow(_ kind: String, settled: Bool = false) throws -> (BrainRow, TranscriptRowBuilder) {
        let made = try accountRow(kind, settled: settled, open: false)
        return (made.row, made.builder)
    }

    private static func checkLiveCard(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try closedRow("accountlive")
        let bed = try BrainBed(row: row, width: 1000, key: "st-livecard", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(8) { bed.view.card.hasContent && bed.view.card.hasPicture }
        _ = brainPump(0.5)
        let card: BrainCard = bed.view.card
        guard let reading = card.card.live, let words = card.liveHeadline(), let line = card.liveLine() else {
            throw SelfTestFailure("brain: a running turn's card has no live reading")
        }
        try expect(
            card.live.isLive && words.word == reading.reading(now: Date()).word
                && words.counts == reading.reading(now: Date(), lastActivity: card.live.lastActivityAt).counts,
            "a running turn's card says its verdict and its counts in Core's words (\(words.word): \(words.counts))")
        try expect(
            TailscodeCore.Typography.spec(.rowStamp).figures == .tabular
                && line.title == reading.flight?.title && line.argument == reading.flight?.argument,
            "the counts are tabular, and the third line is the step in flight in plain words with its argument (\(line.title))")
        try expect(
            card.liveCanvasesShown && card.settledHeadlineOpacity == 0 && card.settledThirdOpacity == 0,
            "the live words are drawn and the settled ones wait invisibly under them")
        try expect(
            bed.view.isClockRunning && card.needsLiveClock(at: BrainClock.now) && !bed.view.model.needsClock
                || bed.view.isClockRunning,
            "a live card on screen is on the clock while its turn runs")

        card.live.lastActivityAt = Date().addingTimeInterval(-90)
        let silent = card.liveLine()
        var isSilence = false
        if case .silence(let said)? = silent?.trailing { isSilence = said.contains("silent") }
        try expect(
            isSilence && card.liveHeadline()?.isSilent == true,
            "nothing for ninety seconds and the line says it was silent in place of the output")

        if let quote = reading.quote {
            card.live.quoteArrivedAt = Date()
            let held = card.liveLine()
            card.live.quoteArrivedAt = Date().addingTimeInterval(-5)
            let released = card.liveLine()
            try expect(
                held?.kind == .quote && held?.quote?.stepID == quote.stepID && released?.kind == .step,
                "a note the agent writes replaces the line for four seconds and then gives it back")
        }
        card.live.lastActivityAt = nil

        let (waitRow, waitBuilder) = try closedRow("accountwait")
        let waiting = try BrainBed(row: waitRow, width: 1000, key: "st-livewait", policy: { waitBuilder.brainPolicy })
        defer { waiting.close() }
        _ = brainPump(8) { waiting.view.card.hasContent }
        _ = brainPump(0.3)
        let wcard: BrainCard = waiting.view.card
        let wlive = wcard.card.live
        try expect(
            wlive?.verdict == .needsYou && wlive?.motion == .heartbeat && wcard.card.edge == .waiting
                && wcard.liveHeadline()?.glyph == .pauseBars && wcard.liveHeadline()?.tone == .attention
                && wcard.liveHeadline()?.word == NeuralReading.verdictWaiting,
            "a turn waiting on the person says so with pause bars in amber, a heartbeat and the waiting edge")
        let early = wlive?.edgeLevel(at: ActivityTuning.heartbeatPeriod * NeuralMotion.firstBeat.centre) ?? 0
        let rest = wlive?.edgeLevel(at: ActivityTuning.heartbeatPeriod * 0.6) ?? 1
        try expect(early > rest + 0.3, "and the edge knocks and rests (\(String(format: "%.2f", early)) over \(String(format: "%.2f", rest)))")

        let (settledRow, settledBuilder) = try closedRow("account")
        let settled = try BrainBed(row: settledRow, width: 1000, key: "st-liveset", policy: { settledBuilder.brainPolicy })
        defer { settled.close() }
        _ = brainPump(8) { settled.view.card.hasContent }
        _ = brainPump(0.4)
        let scard: BrainCard = settled.view.card
        try expect(
            !settled.view.isClockRunning && scard.card.live == nil && !scard.liveCanvasesShown
                && scard.settledHeadlineOpacity == 1,
            "a settled card owns no clock and shows nothing but its settled words")
        try expect(
            bed.view.isClockRunning && waiting.view.isClockRunning && !settled.view.isClockRunning,
            "two live cards run and the settled one beside them does not: one clock for what is alive")
        let now = BrainClock.now
        try expect(
            wlive?.swell(at: now) == wlive?.swell(at: now) && reading.swell(at: now) == reading.swell(at: now)
                && abs(reading.swell(at: 0.5) - reading.swell(at: 0.5 + ActivityTuning.breathPeriod)) < 1e-9,
            "the swell is arithmetic on absolute time, so every card breathes as one hand")

        BrainLogWatch.install()
        let complaints = BrainLogWatch.count
        let narrow = try BrainBed(row: row, width: 420, key: "st-livenarrow", policy: { builder.brainPolicy })
        defer { narrow.close() }
        _ = brainPump(8) { narrow.view.card.hasContent }
        _ = brainPump(0.6)
        let ncard: BrainCard = narrow.view.card
        try expect(
            ncard.layoutClass == .narrow && ncard.liveCanvasesShown && ncard.liveHeadline() != nil
                && ncard.settledHeadlineOpacity == 0 && BrainLogWatch.count == complaints,
            "on a narrow row the live card keeps its verdict and says it in the room it has, and the toolkit has nothing to say")

        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        _ = brainPump(0.4)
        try expect(
            !bed.view.isClockRunning && card.liveCanvasesShown,
            "with reduced motion the live card says the same words and takes its clock off")
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
    }

    private static func checkSettle(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try closedRow("accountlive")
        let (settledRow, _) = try closedRow("accountlive", settled: true)
        let bed = try BrainBed(row: row, width: 1000, key: "st-settle", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(8) { bed.view.card.hasContent && bed.view.card.hasPicture }
        _ = brainPump(0.4)
        let card: BrainCard = bed.view.card
        try expect(card.live.isLive && card.settledHeadlineOpacity == 0, "the card is live before its turn ends")
        bed.view.restate(settledRow)
        let began = Date()
        var opacities: [Double] = []
        var thirds: [Double] = []
        var landed = false
        while Date().timeIntervalSince(began) < 3 {
            while g_main_context_iteration(nil, 0) != 0 {}
            opacities.append(card.settledHeadlineOpacity)
            thirds.append(card.settledThirdOpacity)
            if !card.liveCanvasesShown, !card.needsLiveClock(at: BrainClock.now), card.live.held == nil {
                landed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
        let took = Date().timeIntervalSince(began)
        try expect(
            landed && took > 0.3 && took < 1.0,
            "a card that ends settles in one move of about 400 ms (\(String(format: "%.0f", took * 1000)) ms)")
        try expect(
            zip(opacities, opacities.dropFirst()).allSatisfy { $1 >= $0 - 0.001 } && (opacities.first ?? 1) < 0.2
                && (opacities.last ?? 0) == 1
                && zip(thirds, thirds.dropFirst()).allSatisfy { $1 >= $0 - 0.001 },
            "the settled words come up as the live ones leave and never flicker back (\(opacities.count) frames)")
        _ = brainPump(0.3)
        try expect(
            !bed.view.isClockRunning && card.card.live == nil && card.settledHeadlineOpacity == 1
                && card.settledThirdOpacity == 1,
            "and afterwards the card is exactly a settled card: no clock, no live canvas, all of its words")
        try expect(
            card.card.edge == .settled && card.edgeAlpha() == 1,
            "the edge stops pulsing and holds at full")
    }

    private static func checkLiveMoves(_ expect: (Bool, String) throws -> Void) throws {
        let metrics = NeuralStageMetrics.make(width: 1000, density: .comfortable)
        let openLive = NeuralTransition.make(.open, metrics: metrics, nodeCount: 14, live: true)
        let closeLive = NeuralTransition.make(.close, metrics: metrics, nodeCount: 14, live: true)
        let closeSettled = NeuralTransition.make(.close, metrics: metrics, nodeCount: 14)
        let clock = 0.7
        try expect(
            openLive.fromLive && closeLive.toLive && !closeSettled.toLive
                && openLive.frame(at: 0.5, clock: clock).travellerSwell == NeuralMotion.breathLevel(at: clock)
                && closeSettled.frame(at: 0.5, clock: clock).travellerSwell == 1,
            "an opening from a live card carries the live swell on its head and a settled one does not")
        let mid = openLive.frame(at: 0.4, clock: clock)
        let back = openLive.reversed(from: 0.4).frame(at: 0, clock: clock)
        try expect(
            abs(mid.progress - back.progress) < 1e-9 && mid.traveller == back.traveller && mid.rowHeight == back.rowHeight,
            "turned round in mid-move it continues from the frame it was on, whichever card state it began from")
        try expect(
            openLive.frame(at: 0).traveller == metrics.card.picture && closeLive.frame(at: 1).traveller == metrics.card.picture
                && closeSettled.frame(at: 1).rowHeight == metrics.card.height,
            "closing lands the head exactly on the card's picture and the row on the card's height")
        let crossing = NeuralTransition.crossing(
            closing: NeuralTransition.make(.swapClose, metrics: metrics, nodeCount: 14),
            opening: NeuralTransition.make(.swap, metrics: metrics, nodeCount: 14))
        var steps: [Double] = []
        var last = crossing.totalHeight(atTime: 0)
        for index in 1...28 {
            let total = crossing.totalHeight(atTime: Double(index) * 0.01)
            steps.append(abs(total - last))
            last = total
        }
        try expect(
            (steps.max() ?? 0) < 60 && crossing.belowShift(atTime: 0) == 0,
            "two cards crossing share one height animation, and what is below moves by a few points a frame")

        for (name, kind) in [("live", "accountlive"), ("settled", "account")] {
            let (closed, builder) = try closedRow(kind)
            var opened = closed
            opened.open = true
            let bed = try BrainBed(row: closed, width: 1000, key: "st-lmove-\(name)", policy: { builder.brainPolicy })
            _ = brainPump(8) { bed.view.card.hasPicture && bed.view.card.hasContent }
            _ = brainPump(0.4)
            try expect(bed.view.phase == .closed, "\(name): nothing opens by itself")
            for round in 0..<2 {
                BrainMoveLog.reset()
                bed.view.restate(opened)
                var edgeEarly = 0.0
                var edgeLate = 1.0
                var swells: [Double] = []
                let began = Date()
                var landed = false
                while Date().timeIntervalSince(began) < 20 {
                    while g_main_context_iteration(nil, 0) != 0 {}
                    if let move = bed.view.moveState {
                        if let edge = bed.view.edgeCanvas {
                            if move.progress < 0.15 { edgeEarly = max(edgeEarly, gtk_widget_get_opacity(edge)) }
                            if move.progress > 0.6 { edgeLate = min(edgeLate, gtk_widget_get_opacity(edge)) }
                        }
                        swells.append(move.frame.travellerSwell)
                    }
                    if bed.view.phase == .open { landed = true; break }
                    Thread.sleep(forTimeInterval: 0.004)
                }
                let took = Date().timeIntervalSince(began)
                let gaps = BrainMoveLog.lastGaps.sorted()
                let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
                let slow = gaps.filter { $0 > median * 1.5 + 0.002 }.count
                report(
                    "brain move open from \(name) card: \(BrainMoveLog.lastFrames) frames in \(String(format: "%.0f", took * 1000)) ms, median \(String(format: "%.1f", median * 1000)) ms, worst \(String(format: "%.1f", (gaps.last ?? 0) * 1000)) ms, \(slow) over 1.5x")
                try expect(
                    landed && BrainMoveLog.lastFrames >= 6 && slow <= 1,
                    "\(name) card opens in one move with at most one frame over one and a half display intervals (\(slow) of \(BrainMoveLog.lastFrames))")
                try expect(
                    edgeEarly > 0.5 && edgeLate < 0.05,
                    "\(name): the tone edge rides the head and is gone by the time the move is half done (\(edgeEarly) \(edgeLate) \(bed.view.edgeCanvas == nil))")
                if name == "live" {
                    try expect(
                        (swells.min() ?? 1) < 0.99,
                        "live: the head is still breathing through the move (\(String(format: "%.2f", swells.min() ?? 1)) at its dimmest)")
                } else {
                    try expect((swells.min() ?? 0) == 1, "settled: the head does not breathe in the move")
                }
                _ = brainPump(0.4)

                BrainMoveLog.reset()
                bed.view.restate(closed)
                let shut = Date()
                var shrank = false
                var heights: [Double] = []
                while Date().timeIntervalSince(shut) < 5 {
                    while g_main_context_iteration(nil, 0) != 0 {}
                    heights.append(Double(gtk_widget_get_height(bed.widget)))
                    if bed.view.phase == .closed { shrank = true; break }
                    Thread.sleep(forTimeInterval: 0.004)
                }
                let closeGaps = BrainMoveLog.lastGaps.sorted()
                let closeMedian = closeGaps.isEmpty ? 0 : closeGaps[closeGaps.count / 2]
                let closeSlow = closeGaps.filter { $0 > closeMedian * 1.5 + 0.002 }.count
                report(
                    "brain move close to \(name) card: \(BrainMoveLog.lastFrames) frames, median \(String(format: "%.1f", closeMedian * 1000)) ms, worst \(String(format: "%.1f", (closeGaps.last ?? 0) * 1000)) ms, \(closeSlow) over 1.5x")
                try expect(
                    shrank && closeSlow <= 1 && zip(heights, heights.dropFirst()).allSatisfy { $1 <= $0 + 1.5 },
                    "closing to the \(name) card is one move that only ever shrinks the row (\(closeSlow) slow of \(BrainMoveLog.lastFrames))")
                _ = brainPump(0.3)
                try expect(
                    bed.view.card.hasPicture && bed.view.moveState == nil && bed.view.stage == nil
                        && (name == "settled" ? !bed.view.isClockRunning : bed.view.isClockRunning),
                    "\(name): and the card is whole again, with its clock if it is alive and without if not (round \(round + 1))")
            }
            bed.view.restate(opened)
            _ = brainPump(0.1)
            let turnedAt = bed.view.moveState?.progress ?? -1
            bed.view.restate(closed)
            var lows: [Double] = []
            let turned = Date()
            while Date().timeIntervalSince(turned) < 1.5 {
                while g_main_context_iteration(nil, 0) != 0 {}
                lows.append(Double(gtk_widget_get_height(bed.widget)))
                if bed.view.phase == .closed { break }
                Thread.sleep(forTimeInterval: 0.004)
            }
            let rising = zip(lows, lows.dropFirst()).filter { $1 > $0 + 8 }.count
            try expect(
                turnedAt > 0 && turnedAt < 1 && bed.view.phase == .closed && rising <= 1,
                "\(name): a press in the middle of the move reverses it from where it is, without a jump (at \(String(format: "%.2f", turnedAt)))")
            bed.close()
        }

        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        let (closed, builder) = try closedRow("accountlive")
        var opened = closed
        opened.open = true
        let still = try BrainBed(row: closed, width: 1000, key: "st-lmove-reduced", policy: { builder.brainPolicy })
        _ = brainPump(8) { still.view.card.hasPicture }
        let quick = Date()
        still.view.restate(opened)
        _ = brainPump(1.5) { still.view.phase == .open }
        let reduced = Date().timeIntervalSince(quick)
        try expect(
            still.view.phase == .open && reduced < 0.6
                && NeuralTransition.make(.open, metrics: metrics, nodeCount: 14, reduceMotion: true, live: true)
                    .frame(at: 0.5, clock: 0.7).travellerSwell == 1,
            "with reduced motion a live card opens in a 120 ms crossfade and the head holds still (\(String(format: "%.2f", reduced)) s)")
        still.close()
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
    }
}
