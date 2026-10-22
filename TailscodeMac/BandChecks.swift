import AppKit
import CodingAgentKit
import TailscodeCore

/// The status band's claims, checked headlessly from `--selftest`'s chat child: a fact keeps its
/// place while the clock, the share, the counts and the phase word change under it, and the
/// per-second render stays cheap. The picture is the same claim made by eye.
@MainActor
enum BandChecks {
    private static var windows: [NSWindow] = []

    /// What a label's frame adds to the width its words ask for, and a bound on it.
    static let padding: CGFloat = 5

    private static func stage(width: CGFloat) -> (band: StatusBandView, root: NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        let band = StatusBandView()
        root.addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            band.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        windows.append(window)
        return (band, root)
    }

    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("status band: \(label)") }
            checks += 1
        }
        try holdsStill(expect)
        try glyphSlot(expect)
        try chipsMove(expect)
        try narrowPane(expect)
        try quietTick(expect)
        return checks
    }

    private static func place(_ band: StatusBandView, _ id: String) -> StatusBandView.Placement? {
        band.placements.first { $0.id == id }
    }

    private static func settle(_ band: StatusBandView, _ root: NSView, _ facts: StatusFacts) {
        band.render(facts: facts, notice: nil)
        root.layoutSubtreeIfNeeded()
    }

    private static func holdsStill(_ expect: (Bool, String) throws -> Void) throws {
        let (band, root) = stage(width: 760)
        let moments = StatusFacts.rehearsal
        for moment in moments { settle(band, root, moment) }
        let resting = band.frame
        let phaseWidths = moments.map { moment -> CGFloat in
            band.render(facts: moment, notice: nil)
            return place(band, "phase")?.natural ?? 0
        }
        try expect(
            Set(phaseWidths.map { Int($0) }).count >= 3,
            "the script really does change the phase's words: \(phaseWidths)")
        var origins: [[String: CGFloat]] = []
        for moment in moments {
            settle(band, root, moment)
            origins.append(
                Dictionary(uniqueKeysWithValues: band.placements.map { ($0.id, $0.frame.minX) }))
            try expect(band.frame == resting, "the band's frame never changes")
        }
        for (index, origin) in origins.enumerated() {
            try expect(
                origin == origins[0],
                "after the first pass no fact moves: step \(index) \(origin) against \(origins[0]) \(band.placements.map { "\($0.id) \($0.frame) \($0.natural)" })")
        }
        try expect(
            origins[0].keys.sorted() == ["context", "cost", "phase"],
            "the script wears the phase, the context and the count: \(origins[0].keys.sorted())")

        var absurd = moments[0]
        absurd.activity = .usingTool(name: StatusFacts.rehearsalAbsurdTool, kind: .other)
        settle(band, root, absurd)
        settle(band, root, moments[0])
        let held = place(band, "phase")?.frame.width ?? 0
        try expect(
            held <= 760 * CGFloat(StatusBandSlots.shareLimit) + Self.padding,
            "an absurd tool name does not pin the phase past its share: \(held)")

        let ring = moments[0]
        let bare = moments[4]
        settle(band, root, ring)
        let withRing = place(band, "context")?.image ?? 0
        settle(band, root, bare)
        let without = place(band, "context")?.image ?? 0
        try expect(withRing > 0 && withRing == without, "the ring's room is kept with no ring: \(withRing) \(without)")

        band.resetSlots()
        settle(band, root, moments[0])
        let reset = place(band, "phase")
        try expect(
            reset.map { abs($0.frame.width - $0.natural) < Self.padding } == true,
            "another conversation starts with the widths it needs")
    }

    private static func glyphSlot(_ expect: (Bool, String) throws -> Void) throws {
        let (band, root) = stage(width: 760)
        settle(band, root, StatusFacts.rehearsal[0])
        let first = place(band, "phase")?.natural ?? 0
        for glyph in StatusBandSlots.leadingGlyphs {
            band.sweep(glyph, segment: "phase")
            root.layoutSubtreeIfNeeded()
            let now = place(band, "phase")
            try expect(
                abs((now?.natural ?? 0) - first) < 0.01,
                "\(glyph) is as wide as the others: \(now?.natural ?? 0) against \(first)")
            try expect(
                now?.frame.minX == place(band, "phase")?.frame.minX
                    && abs((now?.frame.width ?? 0) - first) < Self.padding,
                "\(glyph) does not move or resize the phase")
        }
    }

    private static func chipsMove(_ expect: (Bool, String) throws -> Void) throws {
        let (band, root) = stage(width: 760)
        let moment = StatusFacts.rehearsal[3]
        settle(band, root, moment)
        settle(band, root, moment)
        let before = Dictionary(
            uniqueKeysWithValues: band.placements.map { ($0.id, $0.frame.minX) })
        var queued = moment
        queued.queued = 2
        settle(band, root, queued)
        let chip = place(band, "queued")
        let after = Dictionary(uniqueKeysWithValues: band.placements.map { ($0.id, $0.frame.minX) })
        try expect(chip != nil, "a queue is a chip of its own")
        try expect(after["phase"] == before["phase"], "a chip does not move the fact before it")
        let shift = (chip?.natural ?? 0) + MacTheme.Spacing.m
        for id in ["context", "cost"] {
            try expect(
                abs((after[id] ?? 0) - (before[id] ?? 0) - shift) < 0.5,
                "\(id) moves by the chip's own width, once: \(after[id] ?? 0) from \(before[id] ?? 0)")
        }
        settle(band, root, moment)
        let back = Dictionary(uniqueKeysWithValues: band.placements.map { ($0.id, $0.frame.minX) })
        try expect(back == before, "and returns when the chip goes")
    }

    private static func narrowPane(_ expect: (Bool, String) throws -> Void) throws {
        let (band, root) = stage(width: 300)
        for moment in StatusFacts.rehearsal { settle(band, root, moment) }
        try expect(band.frame.width == 300, "a narrow pane keeps its width: \(band.frame.width)")
        let overflow = band.placements.filter { $0.frame.width > 0 && $0.frame.maxX > 300.5 }
        try expect(overflow.isEmpty, "no fact hangs past a narrow pane: \(overflow.map(\.id))")
        try expect(
            place(band, "phase").map { $0.frame.minX >= 0 && $0.frame.width > 0 } == true,
            "the phase is never dropped")
    }

    private static func quietTick(_ expect: (Bool, String) throws -> Void) throws {
        let (band, root) = stage(width: 760)
        let facts = StatusFacts.rehearsal[3]
        settle(band, root, facts)
        let stack = band.subviews.first
        band.render(facts: facts, notice: nil)
        try expect(stack?.needsLayout == false, "a tick that says the same again asks for no layout")
        var ticked = facts
        ticked.elapsed = (facts.elapsed ?? 0) + 1
        band.render(facts: ticked, notice: nil)
        root.layoutSubtreeIfNeeded()
        let same = band.placements.map(\.frame)
        var later = ticked
        later.elapsed = (ticked.elapsed ?? 0) + 1
        band.render(facts: later, notice: nil)
        root.layoutSubtreeIfNeeded()
        try expect(band.placements.map(\.frame) == same, "a second of clock moves nothing")
    }

    private static func microseconds(_ duration: Duration, per count: Int) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1e6 + Double(parts.attoseconds) / 1e12) / Double(count)
    }

    /// What one second of a running turn costs the band, in microseconds: a render of facts whose
    /// clock moved, followed by the layout pass that answers it, then the same render when nothing
    /// moved, then one frame of a sweeping mark. The last is what the band pays thirty times a
    /// second, and `segments` is what each of those frames used to rebuild before it wrote.
    static func costs(ticks: Int = 600) -> String {
        let (band, root) = stage(width: 760)
        let moments = StatusFacts.rehearsal
        for moment in moments {
            band.render(facts: moment, notice: nil)
            root.layoutSubtreeIfNeeded()
        }
        let clock = ContinuousClock()
        var ticked = Duration.zero
        for tick in 0..<ticks {
            var facts = moments[(tick / 20) % moments.count]
            facts.elapsed = TimeInterval(tick)
            let started = clock.now
            band.render(facts: facts, notice: nil)
            root.layoutSubtreeIfNeeded()
            ticked += clock.now - started
        }
        let still = moments[0]
        band.render(facts: still, notice: nil)
        root.layoutSubtreeIfNeeded()
        var quiet = Duration.zero
        for _ in 0..<ticks {
            let started = clock.now
            band.render(facts: still, notice: nil)
            root.layoutSubtreeIfNeeded()
            quiet += clock.now - started
        }
        let frames = StatusBandSlots.leadingGlyphs
        var swept = Duration.zero
        for frame in 0..<ticks {
            let started = clock.now
            band.sweep(frames[frame % frames.count], segment: "phase")
            root.layoutSubtreeIfNeeded()
            swept += clock.now - started
        }
        var rebuilt = Duration.zero
        for _ in 0..<ticks {
            let started = clock.now
            _ = still.segments
            rebuilt += clock.now - started
        }
        return String(
            format: "band per tick: %.0f µs moving, %.0f µs unchanged; per sweep frame: %.0f µs, segments rebuild %.0f µs",
            microseconds(ticked, per: ticks), microseconds(quiet, per: ticks),
            microseconds(swept, per: ticks), microseconds(rebuilt, per: ticks))
    }
}
