import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// The wall the GPU draws is the wall cairo drew: each card, mark and orb built from nodes is
    /// rendered through the toolkit's own node drawing and held against the painter it replaced,
    /// state by state and moment by moment, so a moved edge, a lost wash or a breath gone wrong is
    /// a failed claim rather than a look nobody took. Only antialiased edges may disagree.
    static func checkWatchGPU(_ check: WatchCheck) throws {
        let started = Date()
        defer { report(String(format: "agents gpu: compared in %.1f s", Date().timeIntervalSince(started))) }
        let palette = WatchPalette.current()
        let states: [WallState] = [
            .working, .thinking, .needsYou(.fresh), .needsYou(.overdue), .retrying(attempt: 2),
            .quiet(since: Date()), .background(stuck: false), .background(stuck: true),
            .finished(.done), .finished(.failed), .finished(.stopped), .finished(.unknown),
            .away(lastSeen: Date()),
        ]
        let moments = [0.0, 1.9, 3.3]
        func gap(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, wide: Double) {
            var total = 0
            var wide = 0
            a.withUnsafeBufferPointer { left in
                b.withUnsafeBufferPointer { right in
                    for index in 0..<min(left.count, right.count) {
                        let delta = abs(Int(left[index]) &- Int(right[index]))
                        total &+= delta
                        if delta > 40 { wide &+= 1 }
                    }
                }
            }
            return (Double(total) / Double(a.count), Double(wide) / Double(a.count))
        }
        func image(_ width: Int32, _ height: Int32, _ paint: (OpaquePointer) -> Void) -> [UInt8] {
            renderLayer(width, height) { cr, _, _ in paint(cr) }
        }

        var worstCard = (mean: 0.0, wide: 0.0, at: "")
        for state in states {
            for t in moments {
                for animated in [true, false] {
                    let looks: [(Bool, Double)] = state == .working ? [(false, 0.0), (true, 0.6)] : [(false, 0.0)]
                    for (focused, pulse) in looks {
                        let face = WatchTilePaint.Face(state: state, focused: focused, pulse: pulse)
                        let painted = image(240, 160) { cr in
                            WatchTilePaint.card(
                                cr, width: 240, height: 160, unit: 8, face: face, palette: palette, t: t, animated: animated)
                        }
                        let card = WallCard()
                        let drawn = image(240, 160) { cr in
                            WallSnapshot.render(cr) {
                                card.draw(
                                    $0, width: 240, height: 160, unit: 8, face: face, palette: palette, paletteKey: 0,
                                    t: t, animated: animated)
                            }
                        }
                        let found = gap(painted, drawn)
                        if found.mean > worstCard.mean { worstCard = (found.mean, found.wide, "\(state) t=\(t)") }
                        try check.expect(
                            found.mean < 1.2 && found.wide < 0.02,
                            "the GPU card is the painted card for \(state) at \(t)s: mean \(found.mean), wide \(found.wide)")
                    }
                }
            }
        }
        report(String(format: "agents gpu: card worst mean %.3f wide %.4f (%@)", worstCard.mean, worstCard.wide, worstCard.at))

        let ringed = WatchTilePaint.Face(state: .working, focused: false, ultracode: true)
        for t in moments {
            let painted = image(240, 160) { cr in
                WatchTilePaint.card(cr, width: 240, height: 160, unit: 8, face: ringed, palette: palette, t: t, animated: true)
            }
            let card = WallCard()
            let drawn = image(240, 160) { cr in
                WallSnapshot.render(cr) {
                    card.draw($0, width: 240, height: 160, unit: 8, face: ringed, palette: palette, paletteKey: 0, t: t, animated: true)
                }
            }
            let found = gap(painted, drawn)
            try check.expect(
                found.mean < 2.5 && found.wide < 0.03,
                "the ultracode ring turns where the painted one did at \(t)s: mean \(found.mean), wide \(found.wide)")
        }

        var worstGlyph = (mean: 0.0, wide: 0.0, at: "")
        for state in states {
            for t in moments {
                for animated in [true, false] {
                    let painted = image(96, 96) { cr in
                        WatchGlyph.paint(cr, size: 96, state: state, share: 0.6, fade: 0.3, palette: palette, t: t, animated: animated)
                    }
                    let glyph = WallGlyph()
                    let drawn = image(96, 96) { cr in
                        WallSnapshot.render(cr) {
                            glyph.draw(
                                $0, size: 96, state: state, share: 0.6, fade: 0.3, palette: palette, paletteKey: 0, t: t,
                                animated: animated)
                        }
                    }
                    let found = gap(painted, drawn)
                    if found.mean > worstGlyph.mean { worstGlyph = (found.mean, found.wide, "\(state) t=\(t)") }
                    try check.expect(
                        found.mean < 2.5 && found.wide < 0.03,
                        "the GPU mark is the painted mark for \(state) at \(t)s: mean \(found.mean), wide \(found.wide)")
                }
            }
        }
        report(String(format: "agents gpu: mark worst mean %.3f wide %.4f (%@)", worstGlyph.mean, worstGlyph.wide, worstGlyph.at))

        for t in moments {
            let painted = image(200, 200) { cr in WatchCalmView.paint(cr, size: 200, palette: palette, t: t, animated: true) }
            let orb = WallCalmOrb()
            let drawn = image(200, 200) { cr in
                WallSnapshot.render(cr) { orb.draw($0, size: 200, palette: palette, paletteKey: 0, t: t, animated: true) }
            }
            let found = gap(painted, drawn)
            try check.expect(
                found.mean < 1.5 && found.wide < 0.02,
                "the calm orb breathes as the painted one did at \(t)s: mean \(found.mean), wide \(found.wide)")
        }

        let glyph = WallGlyph()
        func mark(_ state: WallState, _ t: Double, _ animated: Bool) -> [UInt8] {
            image(96, 96) { cr in
                WallSnapshot.render(cr) {
                    glyph.draw($0, size: 96, state: state, share: 0.6, fade: 0, palette: palette, paletteKey: 0, t: t, animated: animated)
                }
            }
        }
        for state in [WallState.working, .needsYou(.overdue), .retrying(attempt: 1), .background(stuck: false)] {
            try check.expect(
                (1..<6).contains { mark(state, 0.6 * Double($0), true) != mark(state, 0, true) },
                "\(state)'s GPU mark moves when the desk allows it")
            try check.expect(mark(state, 0, false) == mark(state, 41.7, false), "and holds still when it does not")
        }
        let holder = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        g_object_ref_sink(UnsafeMutableRawPointer(holder))
        weak var placed: AgentsCanvas?
        var widget: UnsafeMutablePointer<GtkWidget>?
        do {
            let swatch = AgentsCanvas(width: 24, height: 14)
            swatch.paint = { _, _, _ in }
            placed = swatch
            widget = swatch.widget
            gtk_box_append(ptr(holder), swatch.widget)
        }
        try check.expect(placed != nil, "a canvas placed and let go of lives as long as its widget, as a drawing area did")
        if let widget { gtk_box_remove(ptr(holder), widget) }
        try check.expect(placed == nil, "and goes with it")
        g_object_unref(UnsafeMutableRawPointer(holder))

        let cached = WallGlyph()
        var paints = WallPicture.paintsEverywhere
        for frame in 0..<30 {
            _ = image(96, 96) { cr in
                WallSnapshot.render(cr) {
                    cached.draw(
                        $0, size: 96, state: .working, share: 0.6, fade: 0, palette: palette, paletteKey: 0,
                        t: Double(frame) / 60, animated: true)
                }
            }
        }
        paints = WallPicture.paintsEverywhere - paints
        try check.expect(paints <= 2, "a breathing mark paints its pictures once and moves them for thirty frames: \(paints)")
    }
}
