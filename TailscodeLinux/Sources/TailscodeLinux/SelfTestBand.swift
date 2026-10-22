import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the band promises that a screenshot cannot: a fact keeps its place while the clock, the
    /// share, the counts and the phase word change under it, the leading mark owns one width however
    /// wide the font draws it, a chip that arrives moves what follows it by its own width and once,
    /// and a pane too narrow still hides facts from the end instead of widening.
    static func checkBandHoldsStill() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("status band holds still: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(UnsafeMutableRawPointer(window)), 760, 60)
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(box, "status-band")
        gtk_widget_set_valign(box, GTK_ALIGN_START)
        gtk_window_set_child(ptr(UnsafeMutableRawPointer(window)), box)
        defer { gtk_window_destroy(ptr(UnsafeMutableRawPointer(window))) }
        gtk_window_present(ptr(UnsafeMutableRawPointer(window)))
        pump(0.3)

        var state = StatusBand.State()
        func startOver() {
            Gtk.removeChildren(of: box)
            state = StatusBand.State()
        }
        func show(_ facts: StatusFacts, width: Int32 = 760) -> [String: (x: Double, width: Double)] {
            StatusBand.render(into: box, state: state, facts: facts, notice: nil) { _ in }
            StatusBand.fit(box, state: state, width: width)
            pump(0.05)
            return state.placements(in: box)
        }

        let moments = StatusFacts.rehearsal
        for moment in moments { _ = show(moment) }
        let origins = moments.map { moment in
            show(moment).mapValues(\.x)
        }
        for (index, origin) in origins.enumerated() {
            try expect(
                origin.keys.sorted() == ["context", "cost", "phase"],
                "step \(index) wears the phase, the context and the count: \(origin.keys.sorted())")
            for (id, x) in origin {
                try expect(
                    abs(x - (origins[0][id] ?? -1)) < 0.5,
                    "after the first pass \(id) does not move: step \(index) \(x) against \(origins[0][id] ?? -1)")
            }
        }

        var absurd = moments[0]
        absurd.activity = .usingTool(name: StatusFacts.rehearsalAbsurdTool, kind: .other)
        _ = show(absurd)
        let settled = show(moments[0])
        try expect(
            (settled["phase"]?.width ?? 0) <= 760 * StatusBandSlots.shareLimit + 12,
            "an absurd tool name does not pin the phase: \(settled["phase"]?.width ?? 0)")

        let label = Gtk.label("", css: "seg", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(box), label)
        var widths = Set<Int32>()
        for glyph in StatusBandSlots.leadingGlyphs {
            gtk_label_set_markup(op(label), StatusBand.slotted(glyph + " live", state: state, on: label))
            guard let layout = gtk_label_get_layout(op(label)) else { continue }
            var width: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, nil)
            widths.insert(width)
        }
        gtk_box_remove(ptr(box), label)
        try expect(widths.count == 1, "every mark leaves the word where it was: \(widths.sorted())")

        startOver()
        let rest = moments[3]
        _ = show(rest)
        let before = show(rest).mapValues(\.x)
        var queued = rest
        queued.queued = 2
        let after = show(queued)
        let chip = after["queued"]
        try expect(chip != nil, "a queue is a chip of its own")
        try expect(
            abs((after["phase"]?.x ?? -1) - (before["phase"] ?? -2)) < 0.5,
            "a chip does not move the fact before it")
        let shift = (chip?.width ?? 0) + 10
        for id in ["context", "cost"] {
            try expect(
                abs((after[id]?.x ?? 0) - (before[id] ?? 0) - shift) < 1,
                "\(id) moves by the chip's own width, once: \(after[id]?.x ?? 0) from \(before[id] ?? 0)")
        }

        startOver()
        for moment in moments { _ = show(moment, width: 300) }
        let narrow = show(moments[3], width: 300)
        try expect(
            narrow.values.filter { $0.x + $0.width > 300.5 && $0.width > 0 }.count <= 1,
            "a narrow pane hides facts from the end instead of hanging past its edge")
        return checks
    }
}
