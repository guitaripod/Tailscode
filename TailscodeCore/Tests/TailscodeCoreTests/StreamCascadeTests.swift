import Testing

@testable import TailscodeCore

@Suite("Stream cascade")
struct StreamCascadeTests {
    /// One frame of a stream: hand the cadence what has arrived, step the clock, take what should
    /// be on screen. Everything about smoothness is a statement about the sequence of steps.
    private func play(
        arrivals: [(at: Double, count: Int)], until end: Double, fps: Double = 120,
        sealed: Bool = false
    ) -> [Int] {
        var cadence = StreamCadence()
        var steps: [Int] = []
        var time = 0.0
        var pending = arrivals
        var available = 0
        cadence.advance(to: 0)
        while time < end {
            time += 1 / fps
            while let next = pending.first, next.at <= time {
                available = next.count
                pending.removeFirst()
            }
            cadence.observe(available: available, sealed: sealed && pending.isEmpty)
            let before = cadence.revealed
            cadence.advance(to: time)
            steps.append(cadence.revealed - before)
        }
        return steps
    }

    @Test("the reveal never goes backwards and never outruns what arrived")
    func monotone() {
        var cadence = StreamCadence()
        cadence.observe(available: 40, sealed: false)
        cadence.advance(to: 0)
        var last = 0
        var time = 0.0
        for _ in 0..<400 {
            time += 1.0 / 120
            cadence.advance(to: time)
            #expect(cadence.revealed >= last)
            #expect(cadence.revealed <= 40)
            last = cadence.revealed
        }
        #expect(cadence.isSettled)
    }

    @Test("a lumpy arrival plays out as an even hand")
    func lumpsBecomeEven() {
        let arrivals = (0..<8).map { index in
            (at: Double(index) * 0.35, count: (index + 1) * 190)
        }
        let steps = play(arrivals: arrivals, until: 3.2)
        let painted = steps.filter { $0 > 0 }
        #expect(painted.count > 250)
        #expect(painted.allSatisfy { $0 <= 4 })

        let quarters = stride(from: 0, to: steps.count - 60, by: 60).map { start in
            steps[start..<(start + 60)].reduce(0, +)
        }
        let busiest = quarters.max() ?? 0
        let quietest = quarters.filter { $0 > 0 }.min() ?? 0
        #expect(Double(busiest) < Double(quietest) * 3.2)
    }

    @Test("the buffer is never drained faster than the floor allows")
    func neverRunsDry() {
        var cadence = StreamCadence()
        cadence.advance(to: 0)
        cadence.observe(available: 300, sealed: false)
        var time = 0.0
        var emptied: Double?
        while time < 3 {
            time += 1.0 / 120
            cadence.advance(to: time)
            if cadence.isSettled, emptied == nil { emptied = time }
        }
        #expect((emptied ?? 0) > 0.9)
    }

    @Test("a paste is shown at once rather than typed")
    func burstsAreNotTyped() {
        var cadence = StreamCadence()
        cadence.advance(to: 0)
        cadence.observe(available: 40_000, sealed: false)
        cadence.advance(to: 1.0 / 120)
        #expect(cadence.revealed == 40_000)
    }

    @Test("a sealed turn lands its tail instead of lingering")
    func sealedDrains() {
        var open = StreamCadence()
        var closed = StreamCadence()
        open.advance(to: 0)
        closed.advance(to: 0)
        open.observe(available: 220, sealed: false)
        closed.observe(available: 220, sealed: true)
        var time = 0.0
        while time < 1.2 {
            time += 1.0 / 120
            open.advance(to: time)
            closed.advance(to: time)
        }
        #expect(closed.revealed > open.revealed)
    }

    @Test("a shrinking source clamps instead of stranding a reveal past its end")
    func clampsOnShrink() {
        var cadence = StreamCadence()
        cadence.adopt(300)
        cadence.observe(available: 120, sealed: false)
        #expect(cadence.revealed == 120)
    }

    @Test("the renderer is held at the last position with nothing half-open")
    func renderableHoldsOpenTokens() {
        #expect(LiveCascade.renderable("the answer is **very ", sealed: false) == "the answer is ")
        #expect(
            LiveCascade.renderable("the answer is **very** clear", sealed: false)
                == "the answer is **very** clear")
        #expect(LiveCascade.renderable("run `gtk_box", sealed: false) == "run ")
        #expect(
            LiveCascade.renderable("an open **marker", sealed: true) == "an open **marker")
    }

    @Test("the gate lets literal punctuation through")
    func gateIgnoresLiterals() {
        let arithmetic = Array("2 * 3 = 6")
        #expect(CascadeGate.safeCut(arithmetic, at: arithmetic.count) == arithmetic.count)

        let identifier = Array("call snake_case_name")
        #expect(CascadeGate.safeCut(identifier, at: identifier.count) == identifier.count)
    }

    @Test("a closer far behind the cut cannot invert the markers in front of it")
    func gateCountsFromTheStart() {
        let source = Array(
            "Here is **bold** text, some *italic*, a `snippet`, a [link](https://x.dev), "
                + "and ~~struck~~ words.\n\n- first bullet with `code`\n"
                + "- second bullet with **weight**\n\n## A heading arrives")
        for cut in 0...source.count {
            let gated = CascadeGate.safeCut(source, at: cut)
            let visible = String(source[..<gated])
            let markers = visible.components(separatedBy: "**").count - 1
            #expect(markers.isMultiple(of: 2), "cut \(cut) stopped inside a bold token")
        }
    }

    @Test("a marker older than the window is treated as literal")
    func gateWindowIsBounded() {
        let text = Array("*" + String(repeating: "x", count: CascadeGate.window + 40))
        #expect(CascadeGate.safeCut(text, at: text.count) == text.count)
    }

    @Test("the wave cools with distance and settles behind itself")
    func waveShape() {
        let edge = StreamCascade.sample(distance: 0, phase: 0.5)
        let mid = StreamCascade.sample(distance: StreamCascade.span / 2, phase: 0.5)
        let past = StreamCascade.sample(distance: StreamCascade.span * 4, phase: 0.5)
        #expect(edge.heat > mid.heat)
        #expect(mid.heat > past.heat)
        #expect(past.heat == 0)
        #expect(edge.alpha >= StreamCascade.entryFloor)
        #expect(edge.alpha < 1)
        #expect(mid.alpha == 1)
        #expect(past.pull == 0)
    }

    @Test("the shimmer travels and every sample stays inside its bounds")
    func shimmerTravels() {
        var peaks: [Int] = []
        for step in 0..<8 {
            let phase = Double(step) / 8
            var best = (distance: 0, value: 0.0)
            for distance in 0..<Int(StreamCascade.shimmerReach) {
                let sample = StreamCascade.sample(distance: distance, phase: phase, span: 4000)
                #expect(sample.shimmer >= 0 && sample.shimmer <= StreamCascade.shimmerPeak)
                #expect(sample.pull >= 0 && sample.pull <= 1)
                #expect(sample.alpha >= StreamCascade.entryFloor && sample.alpha <= 1)
                if sample.shimmer > best.value { best = (distance, sample.shimmer) }
            }
            peaks.append(best.distance)
        }
        #expect(peaks == peaks.sorted())
        #expect(peaks.last! > peaks.first!)
    }

    @Test("the rainbow walks the shared stops and meets itself")
    func rainbowMeetsItself() {
        let start = StreamCascade.rainbow(at: 0)
        let end = StreamCascade.rainbow(at: 1)
        #expect(abs(start.red - end.red) < 0.001)
        #expect(abs(start.green - end.green) < 0.001)
        #expect(abs(start.blue - end.blue) < 0.001)
    }

    @Test("a row born under our eyes types; one that arrives finished does not")
    func adoptsHistory() {
        var live = LiveCascade()
        live.focus("a", rendered: "hello", sealed: false, at: 0)
        #expect(live.revealed == 0)
        #expect(live.total == 5)

        var loaded = LiveCascade()
        let long = String(repeating: "settled prose. ", count: 40)
        loaded.focus("b", rendered: long, sealed: false, at: 0)
        #expect(loaded.revealed == long.count)

        var finished = LiveCascade()
        finished.focus("c", rendered: "done", sealed: true, at: 0)
        #expect(finished.revealed == 4)
    }

    @Test("the live row grows toward its source and lands on it")
    func liveRowLands() {
        var live = LiveCascade()
        let text = "The transcript should read as writing, not as a paste."
        live.focus("row", rendered: text, sealed: false, at: 0)
        var time = 0.0
        var last = 0
        for _ in 0..<600 {
            time += 1.0 / 120
            live.focus("row", rendered: text, sealed: false, at: time)
            live.advance(to: time)
            #expect(live.revealed >= last)
            #expect(live.revealed <= text.count)
            last = live.revealed
        }
        #expect(live.revealed == text.count)
        #expect(live.isSettled)
    }

    @Test("letting go of the row ends the animation")
    func releasingSettles() {
        var live = LiveCascade()
        live.focus("row", rendered: "half written", sealed: false, at: 0)
        live.advance(to: 0.016)
        #expect(live.isActive)
        live.focus(nil, rendered: "", sealed: true, at: 0.02)
        #expect(!live.isActive)
        #expect(live.revealed == 0)
    }

    @Test("a token that never closes stops holding the rest of the answer back")
    func gateGivesUpOnAnAbandonedToken() {
        var live = LiveCascade()
        let source = "Root cause is deeper: any *frame"
        #expect(live.renderable(row: "row", source, sealed: false, at: 0) == "Root cause is deeper: any ")
        #expect(live.renderable(row: "row", source, sealed: false, at: 0.4) == "Root cause is deeper: any ")
        #expect(live.owes)
        #expect(live.renderable(row: "row", source, sealed: false, at: 2) == source)
        #expect(!live.owes)
        #expect(live.renderable(row: "row", source, sealed: false, at: 2.1) == source)
        #expect(live.renderable(row: "row", source, sealed: false, at: 8) == source)
    }

    @Test("a cut that keeps moving is a token in flight, not an abandoned one")
    func gateKeepsHoldingWhileTheCutMoves() {
        var live = LiveCascade()
        var time = 0.0
        for tail in ["`one", "`one` and `two", "`one` and `two` and `three"] {
            time += 0.5
            #expect(live.renderable(row: "row", tail, sealed: false, at: time).count < tail.count)
        }
        let closed = "`one` and `two` and `three`"
        #expect(live.renderable(row: "row", closed, sealed: false, at: time + 0.5) == closed)
    }

    @Test("a reveal that owes text and stops moving is a stall, however settled it looks")
    func stallIsTimedFromTheDebt() {
        var live = LiveCascade()
        let text = "The transcript should read as writing, not as a paste."
        live.focus("row", rendered: text, sealed: false, at: 0)
        live.advance(to: 0.016)
        #expect(live.owes)
        #expect(!live.stalled(at: 0.5))
        #expect(live.stalled(at: 4))
        var time = 4.0
        while !live.isSettled, time < 20 {
            time += 1.0 / 120
            live.advance(to: time)
            live.lands(live.revealed, at: time)
        }
        #expect(live.isSettled)
        #expect(!live.owes)
        #expect(!live.stalled(at: time + 30))
    }

    @Test("a reveal held behind the gate is owed text even when it has caught up")
    func aHeldGateIsADebt() {
        var live = LiveCascade()
        let source = "shown *held"
        let safe = live.renderable(row: "row", source, sealed: false, at: 0)
        live.focus("row", rendered: safe, sealed: false, at: 0)
        var time = 0.0
        while !live.isSettled, time < 20 {
            time += 1.0 / 120
            live.advance(to: time)
            live.lands(live.revealed, at: time)
        }
        #expect(live.isSettled)
        #expect(live.owes)
        #expect(live.stalled(at: time + 2))
    }

    @Test("a reveal nobody painted is a debt, however far the arithmetic ran")
    func anUnpaintedRevealIsADebt() {
        var live = LiveCascade()
        let text = "Good. Net changes on the host, and the rest of the sentence after them."
        live.focus("row", rendered: text, sealed: false, at: 0)
        var time = 0.0
        while !live.isSettled, time < 20 {
            time += 1.0 / 120
            live.advance(to: time)
            if live.revealed <= 9 { live.lands(live.revealed, at: time) }
        }
        #expect(live.isSettled)
        #expect(live.landed == 9)
        #expect(live.owes)
        #expect(live.stalled(at: time + 2))
    }

    @Test("a frame that lands pays the reader and restarts the clock")
    func aLandedFrameRestartsTheClock() {
        var live = LiveCascade()
        live.focus("row", rendered: "one two three four five six", sealed: false, at: 0)
        live.advance(to: 0)
        live.advance(to: 0.5)
        live.lands(live.revealed, at: 0.5)
        #expect(live.landed > 0)
        #expect(!live.stalled(at: 1.2))
        #expect(live.stalled(at: 1.6))
    }

    @Test("a row whose words all reached the screen owes nothing")
    func aFullyPaintedRowIsQuiet() {
        var live = LiveCascade()
        let text = "short enough"
        live.focus("row", rendered: text, sealed: true, at: 0)
        live.lands(live.revealed, at: 0)
        #expect(live.landed == text.count)
        #expect(!live.owes)
        #expect(!live.stalled(at: 30))
    }

    /// Every prefix of a document, handed over one character at a time, must produce a rendered
    /// string that only ever grows. A shorter answer than the frame before it is text leaving the
    /// screen, and text leaving the screen re-measures the paragraph — the one thing the whole
    /// cascade exists to prevent.
    private func neverRewinds(_ document: String, file: String = #file, line: Int = #line) {
        var live = LiveCascade()
        var time = 0.0
        var shown = 0
        let characters = Array(document)
        for end in 1...characters.count {
            time += 0.05
            let source = String(characters[..<end])
            let rendered = live.renderable(row: "row", source, sealed: false, at: time)
            #expect(
                source.hasPrefix(rendered),
                "\(document.prefix(24))… rendered something that is not a prefix at \(end)")
            #expect(
                rendered.count >= shown,
                "\(document.prefix(24))… rewound \(shown) → \(rendered.count) at \(end)")
            shown = rendered.count
        }
    }

    @Test("the rendered answer never gets shorter, whatever the gate decides")
    func revealIsMonotone() {
        neverRewinds("see [ref " + String(repeating: "x", count: 140) + " and **bold")
        neverRewinds("Here is **bold** and *italic* and `code` and a [link](https://x.dev) done.")
        neverRewinds("def go(**kwargs):\n    self._value = other._value * 2\n    return `x`")
        neverRewinds("the array [0] holds the value and we keep writing after it for a while")
        neverRewinds("trailing emphasis *w* and ~~struck~~ and an unclosed [bracket at the end")
        neverRewinds(String(repeating: "a marker * every so often, ", count: 12))
    }

    @Test("a bracket is closed by its own bracket, not only by a link's parenthesis")
    func gateClosesBrackets() {
        let log = Array("the array [0] holds the value and we keep writing after it")
        #expect(CascadeGate.safeCut(log, at: log.count) == log.count)
        let tagged = Array("[INFO] started, [WARN] retried, and then it settled")
        #expect(CascadeGate.safeCut(tagged, at: tagged.count) == tagged.count)
        let link = Array("read [the docs](https://x.dev")
        #expect(CascadeGate.safeCut(link, at: link.count) == 5)
    }

    @Test("a marker at the very end is not judged until the next character decides it")
    func gateWaitsForTheDecidingCharacter() {
        #expect(CascadeGate.safeCut("hello *", at: 7) == 6)
        #expect(CascadeGate.safeCut("hello *w", at: 8) == 6)
        #expect(CascadeGate.safeCut("hello there", at: 11) == 11)
        #expect(CascadeGate.safeCut("hello *", at: 7, sealed: true) == 7)
    }

    @Test("the floor belongs to the row that earned it, not to the next one")
    func handedFloorIsPerRow() {
        var live = LiveCascade()
        let long = "a settled paragraph, long enough to have handed over a great deal of prose"
        #expect(live.renderable(row: "one", long, sealed: false, at: 0) == long)
        let short = "next row *op"
        #expect(live.renderable(row: "two", short, sealed: false, at: 0.1) == "next row ")
        #expect(live.renderable(row: "two", short, sealed: false, at: 0.2) == "next row ")
    }

    @Test("code is not prose, so the gate does not read it as markdown")
    func codeBypassesTheGate() {
        let python = "def go(**kwargs):\n    self._value = 1"
        #expect(LiveCascade.renderable(python, sealed: false, markdown: false) == python)
        #expect(LiveCascade.renderable(python, sealed: false).count < python.count)

        var live = LiveCascade()
        #expect(live.renderable(row: "row", python, sealed: false, markdown: false, at: 0) == python)
        #expect(!live.owes)
    }

    @Test("entrances stagger in order and stop staggering")
    func entrances() {
        #expect(StreamCascade.entranceDelay(index: 0, of: 5) == 0)
        #expect(
            StreamCascade.entranceDelay(index: 1, of: 5)
                < StreamCascade.entranceDelay(index: 2, of: 5))
        #expect(StreamCascade.entranceDelay(index: 200, of: 400) <= 0.34)
        #expect(StreamCascade.ease(0) == 0)
        #expect(StreamCascade.ease(1) == 1)
        #expect(StreamCascade.ease(0.5) > 0.5)
    }

    @Test("blending walks between two colours without passing through mud")
    func blendStaysColourful() {
        #expect(Contrast.blend("#000000", "#ffffff", 0) == "#000000")
        #expect(Contrast.blend("#000000", "#ffffff", 1) == "#ffffff")
        let midpoint = Contrast.blend("#00ff66", "#ff3355", 0.5)
        #expect(midpoint != nil)
        #expect(Contrast.luminance(midpoint!)! > 0.12)
        #expect(Contrast.hex(red: 1, green: 0, blue: 0) == "#ff0000")
    }

    @Test("every capability still has a spec")
    func registryIsComplete() {
        #expect(CapabilityRegistry.missingDefinitions.isEmpty)
        #expect(CapabilityRegistry.definition(for: .streamCascade).area == "transcript")
    }
}
