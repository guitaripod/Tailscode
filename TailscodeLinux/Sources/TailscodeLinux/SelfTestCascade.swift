import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The one thing a paced reveal can break that no unit test in the Kit can see: markup.
    ///
    /// Every frame of a streamed answer hands Pango a *prefix* of a markdown paragraph, and a
    /// prefix that ends inside a tag is not slightly wrong — `gtk_label_set_markup` rejects it and
    /// the row goes blank mid-sentence. So every cut the gate is willing to stop at is rendered
    /// and parsed by Pango itself, which is the only authority on whether the markup is legal.
    static func checkCascade() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let palette = MatrixTheme.palette
        let source = """
            Here is **bold** text, some *italic*, a `snippet`, a [link](https://x.dev), \
            and ~~struck~~ words with a & b < c.

            - first bullet with `code`
            - second bullet with **weight**

            ## A heading arrives
            1. numbered with _emphasis_
            > quoted with [another](https://y.dev)
            """
        var checks = 0
        let characters = Array(source)
        for cut in 0...characters.count {
            let safe = LiveCascade.renderable(String(characters[..<cut]), sealed: false)
            let markup = PangoMarkdown.render(
                safe, dim: palette.textDim, code: palette.info, accent: palette.accent,
                cache: false)
            try expect(
                parsesAsMarkup(markup),
                "prefix \(cut) renders unbalanced markup: \(markup.debugDescription)")
            guard let rendered = CascadePainter.renderedText(of: pangoOnly(markup)) else {
                throw SelfTestFailure("prefix \(cut) has no rendered text: \(markup)")
            }
            for marker in ["**", "~~", "`"] {
                try expect(
                    !rendered.contains(marker),
                    "prefix \(cut) leaked \(marker): \(rendered.debugDescription)")
            }
            checks += 1
        }

        let sealedCut = CascadeGate.safeCut(Array("an open **marker"), at: 15, sealed: true)
        try expect(sealedCut == 15, "a sealed turn must stop holding an unmatched marker")

        try expect(
            CascadePainter.renderedText(of: "a row with <b>no closer") == nil,
            "markup the parser refuses has no rendered text, and no reveal may claim to show it")
        var gated = LiveCascade()
        let abandonedToken = "the rest is behind an *opener"
        try expect(
            gated.renderable(row: "row", abandonedToken, sealed: false, at: 0).count
                < abandonedToken.count,
            "a token still in flight holds the renderer")
        try expect(
            gated.renderable(row: "row", abandonedToken, sealed: false, at: 4) == abandonedToken,
            "a token that never closes must stop holding the rest of the answer back")
        checks += 4

        let written = "The transcript should read as writing, not as a paste."
        var live = LiveCascade()
        live.focus("row", rendered: written, sealed: false, at: 0)
        try expect(live.revealed == 0, "a row born under our eyes starts empty")
        var time = 0.0
        var last = 0
        while time < 30, !live.isSettled {
            time += 1.0 / 120
            live.focus("row", rendered: written, sealed: false, at: time)
            live.advance(to: time)
            try expect(live.revealed >= last, "the reveal went backwards")
            try expect(live.revealed <= written.count, "the reveal ran past what had arrived")
            last = live.revealed
        }
        try expect(live.revealed == written.count, "the reveal never landed on its source")

        var adopted = LiveCascade()
        adopted.focus("history", rendered: source, sealed: false, at: 0)
        try expect(
            adopted.revealed == source.count,
            "a row that arrives already written is adopted rather than replayed")
        checks += 3

        let edge = CascadeTint.edge(for: palette, ultracode: false, phase: 0.5)
        try expect(edge == palette.accent, "a plain turn leads with the theme's accent")
        let rainbow = CascadeTint.edge(for: palette, ultracode: true, phase: 0.5)
        try expect(rainbow.count == 7 && rainbow.hasPrefix("#"), "ultracode leads with a colour")
        let spark = CascadeTint.spark(for: palette, edge: edge)
        let inks = CascadeTint.Inks(settled: palette.text, edge: edge, spark: spark)
        for distance in 0..<StreamCascade.span {
            let painted = CascadeTint.paint(
                StreamCascade.sample(distance: distance, phase: 0.3), inks: inks)
            try expect(painted.alpha >= 1, "a glyph must never be painted invisible")
            try expect(painted.rgb <= 0xff_ffff, "the wave produced a colour outside 24 bits")
            checks += 1
        }
        let settled = CascadeTint.paint(
            StreamCascade.sample(distance: StreamCascade.span * 4, phase: 0.3), inks: inks)
        try expect(
            settled.alpha == 65535, "a glyph the wave has passed must be fully opaque again")
        checks += 1
        return try checks + checkReveal(expect)
    }

    /// The regression the screenshots kept showing: a turn that ends while the reveal is nine
    /// characters into a sentence, and a row that keeps those nine characters for good.
    ///
    /// Everything here happens on a real label, because every earlier fix to this was proved
    /// against arithmetic that was already right. The paint is a prefix on purpose; what is asserted
    /// is that the row is whole again the moment the wave lets go, that the wave knows it is owed
    /// text until somebody proves otherwise, and that a settle nobody could make reports a failure
    /// instead of a repair.
    static func checkReveal(_ expect: (Bool, String) throws -> Void) throws -> Int {
        let sentence = "Good. Net changes on the host: `1920x1200@89` and the rest of the answer."
        let palette = MatrixTheme.palette
        let markup = PangoMarkdown.render(
            sentence, dim: palette.textDim, code: palette.info, accent: palette.accent,
            cache: false)
        guard let whole = CascadePainter.renderedText(of: markup) else {
            throw SelfTestFailure("the sentence under test does not render")
        }
        guard gtk_init_check() != 0 else { return 0 }
        let label = Gtk.markupLabel("", css: "agent-prose")
        let painter = CascadePainter()
        painter.focus(
            "row:part", markup: markup, sealed: false, ultracode: false, clock: nil)
        try expect(painter.isActive, "the wave must take a row it was pointed at")
        try expect(painter.owes, "a row nobody has painted yet is owed to the reader")
        try expect(painter.paint(label), "the wave must paint the label it was given")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == whole,
            "a reveal must lay the whole paragraph out and hide the tail, never cut it")

        painter.release()
        try expect(
            painter.settle(label, markup: markup),
            "a settle onto a live label must land, and must say that it did")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == whole,
            "a row the wave let go of must be holding every word it has")
        try expect(
            !painter.settle(label, markup: "an <b>unclosed row"),
            "a settle that could not be rendered must report a failure, not a repair")

        // One emoji is one Swift Character and two code points, and Pango indexes code points. A
        // reveal counted in the wrong unit saturates before the end of the paragraph, reports a
        // settled row, and leaves the last characters unpainted until something rebuilds the row.
        let withEmoji = "Ready ⚠️ now — done ✅ and the sentence carries on past the mark."
        let emojiMarkup = PangoMarkdown.render(
            withEmoji, dim: palette.textDim, code: palette.info, accent: palette.accent,
            cache: false)
        guard let emojiText = CascadePainter.renderedText(of: emojiMarkup) else {
            throw SelfTestFailure("the emoji sentence does not render")
        }
        try expect(
            emojiText.count != emojiText.unicodeScalars.count,
            "this check is only meaningful while the sentence counts differently in each unit")
        let paced = CascadePainter()
        paced.focus(
            "row:emoji", markup: emojiMarkup, sealed: false, ultracode: false, clock: nil)
        var settledAt = 0.0
        while paced.owes, settledAt < 40 {
            settledAt += 1.0 / 120
            paced.advance(to: settledAt)
            _ = paced.paint(label)
        }
        try expect(
            !paced.owes && paced.revealed == emojiText.unicodeScalars.count,
            "the reveal must land on every code point the painter can index, not one short")
        try expect(
            gtk_label_get_text(op(label)).map { String(cString: $0) } == emojiText,
            "a settled row must be holding every character of its sentence")

        // A streamed row is painted through Pango's parser, which has no anchor, so the painter
        // dresses a link as the span it looks like. Settling writes through GtkLabel's own road,
        // and only `<a href>` becomes something a click can follow there. One markup fed both
        // paths once, and every answer carrying an address spent the rest of the chat looking
        // touchable and doing nothing.
        let linked =
            "Read it at https://example.com/warranty and the rest of the answer."
        let linkMarkup = PangoMarkdown.render(
            linked, dim: palette.textDim, code: palette.info, accent: palette.accent, cache: false)
        try expect(
            linkMarkup.contains("<a href=\"https://example.com/warranty\">"),
            "the markdown renderer must lift a bare address into an anchor")
        let linkRow = TranscriptRow(
            key: "row:links", kind: .agentProse(text: linked, markup: linkMarkup))
        try expect(
            ChatPane.cascadeMarkup(for: linkRow)?.contains("<a href=\"") == false,
            "the painter's markup carries a link's ink, never its anchor")
        try expect(
            ChatPane.settleMarkup(for: linkRow)?.contains("<a href=\"") == true,
            "the markup a row settles with must keep the anchor GtkLabel turns into a link")
        return 12
    }

    /// A list that wraps under its words measures its marker once for each layout the label
    /// makes. A frame that only paints, and a measure at any width, must not allocate a layout of
    /// their own; a change of text or of type size must be measured again and hang by the new width.
    static func checkListHang() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("list hang case failed: \(label)") }
            checks += 1
        }
        let palette = MatrixTheme.palette
        let items = "- one item long enough to wrap\n- another item"
        let markup = PangoMarkdown.render(
            items, dim: palette.textDim, code: palette.info, accent: palette.accent, cache: false)
        guard let marker = PangoMarkdown.hangingMarker(for: items) else {
            throw SelfTestFailure("a list of bullets must name the marker its lines hang by")
        }
        let label = Gtk.markupLabel(markup, css: "hang-probe")
        tailscode_label_set_hanging_marker(label, marker)
        func measure(_ width: Int32) {
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, nil, nil)
        }
        func indent() -> Int32 {
            pango_layout_get_indent(gtk_label_get_layout(op(label)))
        }
        func settle() {
            for _ in 0..<20 {
                while g_main_context_iteration(nil, 0) != 0 {}
                g_usleep(10_000)
            }
        }
        let start = tailscode_hang_probe_count()
        for width in stride(from: 120 as Int32, to: 600, by: 8) { measure(width) }
        try expect(
            tailscode_hang_probe_count() - start == 1,
            "sixty measures at sixty widths must measure the marker once, not once each")
        let hung = indent()
        try expect(hung < 0, "the layout must hang its wrapped lines by the marker's width")
        for _ in 0..<200 { measure(300) }
        try expect(
            tailscode_hang_probe_count() - start == 1, "repeated measures must never measure again")

        gtk_label_set_markup(op(label), markup + " and more words")
        for width in stride(from: 120 as Int32, to: 600, by: 40) { measure(width) }
        try expect(
            tailscode_hang_probe_count() - start == 1,
            "new text in the same font is hung by the width already measured")
        try expect(indent() == hung, "the same marker in the same font hangs by the same width")

        let painted = tailscode_hang_probe_count()
        let painter = CascadePainter()
        let live = Gtk.markupLabel("", css: "hang-probe-live")
        tailscode_label_set_hanging_marker(live, marker)
        painter.focus("row:hang", markup: markup, sealed: false, ultracode: false, clock: nil)
        var frames = 0
        var clock = 0.0
        while painter.owes, frames < 600 {
            clock += 1.0 / 120
            painter.advance(to: clock)
            _ = painter.paint(live)
            measure(300)
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(live, GTK_ORIENTATION_VERTICAL, 300, &minimum, &natural, nil, nil)
            frames += 1
        }
        try expect(frames > 20, "the reveal must run for a few frames for this to prove anything")
        try expect(
            tailscode_hang_probe_count() - painted <= 2 + frames / 20,
            "a reveal's frames must not measure the marker on every frame")
        let window = gtk_window_new()!
        gtk_window_set_child(ptr(window), label)
        gtk_window_present(ptr(window))
        settle()
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, ".hang-probe { font-size: 40px; }")
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider!), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 10))
        }
        settle()
        for width in stride(from: 120 as Int32, to: 600, by: 40) { measure(width) }
        defer { gtk_window_destroy(ptr(window)) }
        try expect(
            indent() < hung,
            "a larger type size must hang by a wider marker, never by the width it had")
        return checks
    }

    /// GtkLabel resolves `<a href>` itself and never hands it to Pango, so the check makes the
    /// same substitution the label does before asking Pango whether the rest of the markup is
    /// legal — otherwise every prefix carrying a finished link would read as broken.
    static func parsesAsMarkup(_ markup: String) -> Bool {
        let text = pangoOnly(markup)
        var failure: UnsafeMutablePointer<GError>?
        let parsed = pango_parse_markup(text, -1, 0, nil, nil, nil, &failure) != 0
        if let failure { g_error_free(failure) }
        return parsed
    }

    /// The same substitution the live row makes: GtkLabel resolves `<a href>` itself and never
    /// hands it to Pango, so the check has to dress a link the way the painter does before asking
    /// Pango whether the rest of the markup is legal.
    static func pangoOnly(_ markup: String) -> String {
        var text = markup.replacingOccurrences(of: "</a>", with: "</span>")
        while let open = text.range(of: "<a href=\""),
            let close = text[open.upperBound...].range(of: "\">")
        {
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: "<span>")
        }
        return text
    }

    /// The durable half of the settings: written to a file, wiped from the in-memory defaults the
    /// way a reinstall wipes them, and read back. Sizes, panes, bookmarks and drafts all ride on
    /// this, so the round trip is worth asserting rather than assuming.
    static func checkSettingsFile() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "tailscode.selftest.flag", "tailscode.selftest.number", "tailscode.selftest.text",
            "tailscode.selftest.data",
        ]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous { SettingsFile.set(value, forKey: key) }
            SettingsFile.flush()
        }

        SettingsFile.set(true, forKey: keys[0])
        SettingsFile.set(1234, forKey: keys[1])
        SettingsFile.set("kept", forKey: keys[2])
        SettingsFile.set(Data("bytes".utf8), forKey: keys[3])

        for key in keys { defaults.removeObject(forKey: key) }
        SettingsFile.load()

        guard defaults.bool(forKey: keys[0]) else { throw SelfTestFailure("a switch was lost") }
        guard defaults.integer(forKey: keys[1]) == 1234 else {
            throw SelfTestFailure("a size was lost")
        }
        guard defaults.string(forKey: keys[2]) == "kept" else {
            throw SelfTestFailure("a draft was lost")
        }
        guard defaults.data(forKey: keys[3]) == Data("bytes".utf8) else {
            throw SelfTestFailure("saved chats would be lost")
        }
    }

    /// Every theme in the catalog, in both of its appearances, checked as data: every slot a real
    /// color that clears its contrast contract *after* correction, no two signals collapsed into
    /// one, the stylesheet actually carrying it, and the markup cache returning palette-true
    /// renderings — a stale cache would paint light-mode prose in dark-mode colors, which no
    /// compiler catches. A theme that cannot be made readable fails the build rather than shipping
    /// as a pretty palette nobody can use.
    /// The scan's picture, checked as arithmetic: a machine keeps the place its name gives it, the
    /// sweep laps without a step at the seam, a blip is brightest under the arm and never dark
    /// behind it, and a finished scan reports itself settled so the clock can stop.
    static func checkRadar() -> [String] {
        var failures: [String] = []
        let key = "macbook|claudeCode"
        let angle = TailnetRadar.angle(for: key)
        if angle != TailnetRadar.angle(for: key) { failures.append("a place that moves") }
        if TailnetRadar.angle(for: "arch|openCode") == angle { failures.append("two machines in one place") }
        let start = TailnetRadar.frame(at: 0, blips: [], scanning: true)
        let lap = TailnetRadar.frame(at: TailnetRadar.sweepPeriod, blips: [], scanning: true)
        if abs(start.sweep - lap.sweep) > 0.0001 { failures.append("a step at the seam") }
        let blip = RadarBlip(key: key, tone: .ready, bornAt: -10)
        let under = TailnetRadar.frame(
            at: angle / (2 * Double.pi) * TailnetRadar.sweepPeriod, blips: [blip], scanning: true)
        let behind = TailnetRadar.frame(
            at: (angle / (2 * Double.pi) + 0.45) * TailnetRadar.sweepPeriod, blips: [blip],
            scanning: true)
        if under.sparks.first.map({ $0.light }) ?? 0 <= behind.sparks.first.map({ $0.light }) ?? 1 {
            failures.append("the arm lights nothing")
        }
        if (behind.sparks.first?.light ?? 0) < TailnetRadar.rest - 0.0001 {
            failures.append("a blip that goes dark")
        }
        let done = TailnetRadar.frame(at: 12, blips: [blip], scanning: false)
        if !done.settled || done.sweepLight != 0 { failures.append("a finished scan that still moves") }
        if !TailnetRadar.frame(at: 12, blips: [blip], scanning: true, reducedMotion: true).settled {
            failures.append("motion a calm desk did not ask for")
        }
        return failures
    }
}
