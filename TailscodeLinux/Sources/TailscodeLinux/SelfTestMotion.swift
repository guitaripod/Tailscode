import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The reveal paints; it never lays out. A real label in a real window, so the layout is the
    /// one GTK draws, and every claim is read against Pango's own positions: nothing past the edge
    /// is drawn, the wave's clusters sit where the layout puts those characters, a wave across a
    /// wrap break lands on both lines, a right-to-left run hands the row back to the label, and a
    /// hundred frames leave the layout exactly as it was.
    static func checkRevealGeometry() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("reveal geometry: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        struct Plan {
            var fallback = false
            var empty = false
            var clips: [(x: Double, y: Double, w: Double, h: Double)] = []
            var units: [(x: Double, y: Double, w: Double, h: Double, first: Int, count: Int)] = []
        }
        func plan(_ label: UnsafeMutablePointer<GtkWidget>, _ visible: Int, wave: Int = 26) -> Plan {
            var out = [Double](repeating: 0, count: 4 + 8 + 64 * 6)
            let written = tailscode_label_reveal_plan(
                label, Int32(visible), Int32(wave), &out, Int32(out.count))
            var result = Plan()
            guard written > 0 else { return result }
            result.fallback = out[0] != 0
            result.empty = out[1] != 0
            for index in 0..<Int(out[2]) {
                let base = 4 + index * 4
                result.clips.append((out[base], out[base + 1], out[base + 2], out[base + 3]))
            }
            for index in 0..<Int(out[3]) {
                let base = 12 + index * 6
                result.units.append(
                    (out[base], out[base + 1], out[base + 2], out[base + 3], Int(out[base + 4]),
                        Int(out[base + 5])))
            }
            return result
        }
        let prose =
            "The stream writes an answer slowly into a paragraph that wraps around the edge of "
            + "the pane and never moves again after landing. Naïve café 日本語のテキスト and a ✅ "
            + "mark, then more words so the paragraph runs on to a fourth line of the label."
        let label = Gtk.markupLabel(prose, css: "agent-text")
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(UnsafeMutableRawPointer(window)), 380, 500)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(label, GTK_ALIGN_START)
        gtk_box_append(ptr(column), label)
        gtk_window_set_child(ptr(UnsafeMutableRawPointer(window)), column)
        defer { gtk_window_destroy(ptr(UnsafeMutableRawPointer(window))) }
        var rgb = [UInt32](repeating: 0xd0d0d0, count: 26)
        var alpha = [UInt16](repeating: 65535, count: 26)
        let total = Int(tailscode_label_reveal(label, nil, prose, 0, 26, &rgb, &alpha))
        try expect(total == prose.unicodeScalars.count, "the label takes the paragraph whole")
        gtk_window_present(ptr(UnsafeMutableRawPointer(window)))
        pump(1.0)
        guard let layout = gtk_label_get_layout(op(label)),
            let layoutText = pango_layout_get_text(layout)
        else { throw SelfTestFailure("reveal geometry: the label has no layout") }
        var offsetX: Int32 = 0
        var offsetY: Int32 = 0
        gtk_label_get_layout_offsets(op(label), &offsetX, &offsetY)
        let lineCount = Int(pango_layout_get_line_count(layout))
        try expect(lineCount >= 4, "the paragraph wraps to several lines (\(lineCount))")

        func position(ofCharacter character: Int) -> PangoRectangle {
            var rect = PangoRectangle()
            let pointer = g_utf8_offset_to_pointer(layoutText, glong(character))!
            pango_layout_index_to_pos(
                layout, Int32(UnsafePointer(pointer) - layoutText), &rect)
            return rect
        }

        try expect(plan(label, 0).empty, "nothing is drawn before the first character")

        for visible in [1, 7, 30, 61, 88, 103, 118, 140, 171, total - 1, total] {
            let drawn = plan(label, visible)
            try expect(
                !drawn.fallback && !drawn.empty,
                "\(visible): left-to-right text is painted by the wave")
            guard let last = drawn.units.last, let first = drawn.units.first else {
                throw SelfTestFailure(
                    "reveal geometry: \(visible) characters left the wave with no clusters")
            }
            try expect(
                last.first + last.count <= visible && last.first + last.count >= visible - 1,
                "\(visible): the wave stops at the edge, not past it (ends at \(last.first + last.count))")
            try expect(
                drawn.units.count <= 26 && first.first + first.count > visible - 26,
                "\(visible): the wave is the last 26 characters and no more")
            for (a, b) in zip(drawn.units, drawn.units.dropFirst()) {
                try expect(
                    b.first == a.first + a.count, "\(visible): clusters follow each other with no gap")
            }
            for unit in drawn.units {
                let rect = position(ofCharacter: unit.first)
                let centre = Double(offsetY) + (Double(rect.y) + Double(rect.height) / 2) / 1024
                try expect(
                    abs(unit.x - (Double(offsetX) + Double(rect.x) / 1024)) < 1
                        && centre >= unit.y && centre <= unit.y + unit.h,
                    "\(visible): a cluster sits where the layout puts character \(unit.first)")
            }
            let lowest = drawn.units.map { $0.y + $0.h }.max() ?? 0
            let drawnHeight = drawn.clips.map { $0.y + $0.h }.max() ?? 0
            try expect(
                drawn.clips.count <= 2 && drawnHeight <= lowest + 1,
                "\(visible): the label's own drawing stops at the line holding the edge")
            if drawn.clips.count == 2 {
                try expect(
                    abs(drawn.clips[1].w - first.x) < 1,
                    "\(visible): the label's own drawing stops where the wave starts")
            }
        }

        let lineStarts = (0..<lineCount).compactMap { line -> Int? in
            guard let row = pango_layout_get_line_readonly(layout, Int32(line)) else { return nil }
            return Int(g_utf8_pointer_to_offset(layoutText, layoutText + Int(row.pointee.start_index)))
        }
        try expect(lineStarts.count >= 4, "the layout reports where each line starts")
        let across = plan(label, lineStarts[2] + 6)
        let tops = Set(across.units.map { Int($0.y.rounded()) })
        try expect(tops.count == 2, "a wave across a wrap break lands on both lines (\(tops.count))")
        try expect(
            across.clips.count == 2 && across.clips[1].y < across.units.last!.y,
            "and the label's own drawing stops on the earlier of them")
        let longLine = zip(lineStarts, lineStarts.dropFirst().map { $0 } + [total])
            .first { $1 - $0 >= 30 }
        try expect(longLine != nil, "a window this wide wraps at more than thirty characters")
        let onLine = plan(label, (longLine?.1 ?? 0) - 2)
        try expect(
            Set(onLine.units.map { Int($0.y.rounded()) }).count == 1,
            "a wave inside one line stays on it")

        var widthBefore: Int32 = 0
        var heightBefore: Int32 = 0
        pango_layout_get_pixel_size(layout, &widthBefore, &heightBefore)
        let serial = pango_layout_get_serial(layout)
        let allocatedHeight = gtk_widget_get_height(label)
        let allocatedWidth = gtk_widget_get_width(label)
        for frame in 0..<100 {
            try expect(
                tailscode_label_reveal(label, nil, prose, Int32(20 + frame), 26, &rgb, &alpha)
                    == Int32(total),
                "frame \(frame) is taken")
            if frame % 10 == 0 { pump(0.02) }
        }
        pump(0.1)
        var widthAfter: Int32 = 0
        var heightAfter: Int32 = 0
        pango_layout_get_pixel_size(gtk_label_get_layout(op(label)), &widthAfter, &heightAfter)
        try expect(
            gtk_label_get_layout(op(label)) == layout && pango_layout_get_serial(layout) == serial
                && widthBefore == widthAfter && heightBefore == heightAfter
                && gtk_widget_get_height(label) == allocatedHeight
                && gtk_widget_get_width(label) == allocatedWidth,
            "a hundred frames leave the layout as it was: same layout, same serial, same size")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == prose,
            "and the text the label holds")

        let hebrew = "שלום עולם שלום עולם שלום עולם שלום עולם שלום עולם שלום עולם שלום עולם"
        let rightToLeft = Gtk.markupLabel(hebrew, css: "agent-text")
        gtk_box_append(ptr(column), rightToLeft)
        _ = tailscode_label_reveal(rightToLeft, nil, hebrew, 10, 26, &rgb, &alpha)
        pump(0.5)
        try expect(
            plan(rightToLeft, 10).fallback,
            "a right-to-left run hands the row back to the label rather than drawing it wrongly")

        let plainLabel = Gtk.label("plain", css: "agent-text", selectable: false)
        try expect(
            tailscode_label_reveal(plainLabel, nil, "plain", 2, 26, &rgb, &alpha) < 0,
            "a label that cannot reveal says so, so the pane rebuilds the row")
        return checks
    }

    /// Every motion in this client that never ends on its own, proved to ask the desk again rather
    /// than only once.
    ///
    /// A guard read where the clock is installed answers the question at that instant and never
    /// afterwards, and the question stays open for exactly as long as the lap does — which is the
    /// whole defect: a ring lit when a tier was picked turns for the rest of that conversation
    /// under a preference changed a minute later, and a desk that allows movement back is never
    /// given it. So the claim is made the only way a running app can make it. The harness takes the
    /// desktop's own switch in its hand (`gtk-enable-animations`, which is what every desktop's
    /// "reduce animation" setting actually writes), turns it off and on under surfaces that are
    /// already moving, and reads what each one is left holding.
    ///
    /// The road itself is proved before its callers, because two surfaces agreeing means nothing if
    /// The reveal's clock is the display's: a calm window moves it on every frame, however fast the
    /// panel, and only a window the governor has shed is held to a cap. The cap was once applied at
    /// every level, which left text stepping at thirty frames a second on a panel that draws a
    /// hundred and sixty-five.
    static func checkCascadeBudget() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("cascade budget: \(label)") }
            checks += 1
        }
        let before = (CascadeBudget.budget, CascadeBudget.level)
        defer { CascadeBudget.apply(before.0, level: before.1) }
        func settle(_ level: ShedLevel) {
            CascadeBudget.apply(TileGovernor.animation(level: level, reducedMotion: false), level: level)
        }
        settle(.calm)
        try expect(CascadeBudget.reveals, "a calm window reveals")
        try expect(CascadeBudget.minimumInterval == nil, "and puts no gap between two frames")
        settle(.busy)
        try expect(CascadeBudget.reveals, "a busy window still reveals")
        try expect(
            CascadeBudget.minimumInterval.map { abs($0 - (1.0 / 30 - 0.004)) < 0.0001 } ?? false,
            "but holds the clock to thirty frames a second")
        settle(.loaded)
        try expect(!CascadeBudget.reveals, "a loaded window hands text over at arrival granularity")
        settle(.critical)
        try expect(CascadeBudget.minimumInterval == nil && !CascadeBudget.reveals, "a critical one runs no clock at all")
        return checks
    }

    /// what they agree through is wrong: ``RepeatingMotion`` lays a clock exactly when the desk
    /// allows movement, never stacks a second on the first, takes it off again, and refuses a
    /// meaning the vocabulary calls still whatever the desk allows. GTK will not enumerate a
    /// widget's tick callbacks, so the count of clocks this whole process holds is what those
    /// claims are read against — the same number the sweep ends on, so nothing here leaves one
    /// turning behind it.
    static func checkRepeatingMotion() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("repeating motion: \(label)") }
            checks += 1
        }
        let asFound = RepeatingMotion.allowed
        func desk(wantsMotion: Bool) { tailscode_set_animations_enabled(wantsMotion ? 1 : 0) }
        func glyph(of label: UnsafeMutablePointer<GtkWidget>) -> String {
            gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
        }
        defer { desk(wantsMotion: asFound) }

        let clocks = tailscode_live_ticks()
        let subject = gtk_label_new("·")!
        let lap = RepeatingMotion {}
        desk(wantsMotion: true)
        try expect(
            lap.lay(on: subject) && lap.isTurning && tailscode_live_ticks() == clocks + 1,
            "the road lays one clock on when the desk allows movement")
        try expect(
            lap.lay(on: subject) && tailscode_live_ticks() == clocks + 1,
            "and asked twice it replaces that clock rather than stacking a second on top of it")
        lap.lift()
        try expect(
            !lap.isTurning && tailscode_live_ticks() == clocks,
            "lifted, the client is holding nothing that would ask for another frame")
        desk(wantsMotion: false)
        let quiet = tailscode_live_ticks()
        try expect(
            !lap.lay(on: subject) && tailscode_live_ticks() == quiet,
            "a desk that asked for less motion is handed no clock at all")
        desk(wantsMotion: true)
        let moving = tailscode_live_ticks()
        try expect(
            !lap.lay(on: subject, meaning: .still) && tailscode_live_ticks() == moving,
            "a meaning the vocabulary calls still never moves, whatever the desk allows")

        var released: RepeatingMotion? = RepeatingMotion(holding: false) {}
        released?.lay(on: subject)
        try expect(
            released?.isTurning == true && tailscode_live_ticks() == moving + 1,
            "a lap laid on a mark it does not hold turns like any other")
        released = nil
        try expect(
            tailscode_live_ticks() == moving,
            "and let go of while it turns it takes its clock with it, rather than leaving the"
                + " frame clock calling into a lap that no longer exists")

        let doomed = gtk_label_new("·")!
        g_object_ref_sink(UnsafeMutableRawPointer(doomed))
        let orphaned = RepeatingMotion(holding: false) {}
        orphaned.lay(on: doomed)
        g_object_unref(UnsafeMutableRawPointer(doomed))
        try expect(
            !orphaned.isTurning && tailscode_live_ticks() == moving,
            "a mark torn down under its lap ends the clock with it, and the lap can tell")
        orphaned.lift()
        try expect(
            tailscode_live_ticks() == moving,
            "so lifting it afterwards asks nothing of a widget that is gone")

        let pill = DialPill(
            dial: ModelDialPopover(
                makeState: {
                    ModelDialState(
                        sources: [], selected: nil, effort: nil, options: [], modelWord: "")
                }, onPick: { _, _, _ in }, onEffort: { _ in }, onOpenCatalog: {}),
            onStep: { _ in })
        let ladder = ["low", "medium", "high", "xhigh", "max", Ultracode.effortLevel]
        let power = ModelDial.face(
            modelWord: "Opus", effort: Ultracode.effortLevel, options: ladder)
        pill.render(power, modelTint: nil)
        pill.render(power, modelTint: nil)
        pill.render(power, modelTint: nil)
        try expect(
            pill.isShimmering && tailscode_live_ticks() == moving + 1,
            "a pill drawn on the power three times — the quick ask draws it when it opens and"
                + " again when the aimed machine's models arrive — holds one clock, never one per"
                + " drawing with the earlier ones left calling into freed laps")
        pill.render(
            ModelDial.face(modelWord: "Opus", effort: "high", options: ladder), modelTint: nil)
        try expect(
            !pill.isShimmering && tailscode_live_ticks() == moving,
            "and drawn off the power it holds none")

        let aura = AuraPainter()
        aura.setActive(true)
        try expect(aura.isTurning, "the aura turns for as long as the tier stays picked")
        desk(wantsMotion: false)
        try expect(
            !aura.isTurning && aura.isActive,
            "a desk asking for less mid-conversation stops the ring and keeps it lit — a power"
                + " being on is a fact, and the fact is the edge rather than the travel around it")
        desk(wantsMotion: true)
        try expect(
            aura.isTurning,
            "and allowing movement back turns it again, however long ago the tier was picked")
        aura.setActive(false)
        desk(wantsMotion: false)
        desk(wantsMotion: true)
        try expect(
            !aura.isTurning,
            "an aura whose power is off has no fact to draw and stays dark through the change")

        let radar = RadarView()
        radar.scanning = true
        radar.startClock()
        try expect(radar.isTurning, "a scan still out on the tailnet turns the dial")
        desk(wantsMotion: false)
        try expect(!radar.isTurning, "a desk asking for less mid-scan settles it at rest")
        desk(wantsMotion: true)
        try expect(
            radar.isTurning,
            "and allowing movement back mid-scan turns it again, which the old one-directional"
                + " guard could never do on the one screen somebody walks away from")
        radar.scanning = false
        desk(wantsMotion: false)
        desk(wantsMotion: true)
        try expect(
            !radar.isTurning,
            "a scan that finished is not restarted by the change: the dial is a picture of"
                + " something happening, and nothing is")

        let mark = gtk_label_new("x")!
        ActivityPulse.apply(.openWork, to: mark)
        try expect(
            ActivityPulse.reading(of: mark).contains("moving=1"),
            "an open piece of work turns its mark for as long as the work is open")
        desk(wantsMotion: false)
        try expect(
            ActivityPulse.reading(of: mark) == "moving=0"
                && glyph(of: mark) == ActivityIcon.openWork.glyph,
            "a desk asking for less mid-turn stops the mark on the state's own glyph, because"
                + " reduced motion drops the movement and nothing else")
        desk(wantsMotion: true)
        try expect(
            ActivityPulse.reading(of: mark).contains("moving=1"),
            "and a turn that is still running is given its mark back")

        let settled = gtk_label_new("·")!
        ActivityPulse.apply(.failed, to: settled)
        desk(wantsMotion: false)
        desk(wantsMotion: true)
        try expect(
            ActivityPulse.reading(of: settled) == "moving=0",
            "a state the vocabulary calls still keeps no clock and is handed none by the change")

        setenv("TAILSCODE_ORB", "1", 1)
        let orb = OrbPainter()
        try expect(orb.isDrawing, "a creature standing at the foot of the sidebar has a clock")
        setenv("TAILSCODE_ORB", "0", 1)
        orb.applyEnabled()
        try expect(
            !orb.isDrawing,
            "a stopped clock is exactly what a settled frame under reduced motion leaves behind,"
                + " and a stopped clock asks nothing more")
        desk(wantsMotion: false)
        desk(wantsMotion: true)
        try expect(
            !orb.isDrawing,
            "so the change never wakes a creature the setting itself switched off")
        setenv("TAILSCODE_ORB", "1", 1)
        desk(wantsMotion: false)
        desk(wantsMotion: true)
        try expect(
            orb.isDrawing,
            "while a body frozen mid-breath is started again by it, rather than standing there"
                + " for as long as the sidebar does")

        setenv("TAILSCODE_ORB", "0", 1)
        orb.applyEnabled()
        unsetenv("TAILSCODE_ORB")
        ActivityPulse.stop(mark)
        ActivityPulse.stop(settled)
        radar.stopClock()
        lap.lift()
        try expect(
            tailscode_live_ticks() == clocks,
            "and everything the sweep started asks for no more frames than the client began with")
        return checks
    }

    /// A picture must come back byte-identical, keyed to its server file — and two different
    /// files must never collide into one cache slot.
    static func checkImageCache() throws {
        let first = FileReference(path: "/tmp/selftest/a.png", mime: "image/png", filename: "a.png")
        let second = FileReference(path: "/tmp/selftest/b.png", mime: "image/png", filename: "b.png")
        guard let one = ImageCache.identity(for: first), let two = ImageCache.identity(for: second),
            one != two
        else { throw SelfTestFailure("two files share one identity") }
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        ImageCache.save(bytes, for: first)
        guard ImageCache.load(first) == bytes else {
            throw SelfTestFailure("bytes did not round-trip")
        }
        guard ImageCache.load(second) == nil else {
            throw SelfTestFailure("an unsaved file loaded")
        }
        guard ImageCache.identity(for: FileReference()) == nil else {
            throw SelfTestFailure("an unidentifiable file got an identity")
        }
    }
}
