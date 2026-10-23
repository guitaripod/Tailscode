import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainReadout {
    func digestHeader(_ digest: R.Digest, in page: Page) {
        let turn = owner.model.turn
        let label = BrainUI.label(BrainWords.turn, "bn-zone", "bn-dim")
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        let verdict = NeuralVerdict.read(turn).verdict
        let tone = verdict.pillTone
        let chip = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "bn-chip", Self.toneClass(tone), "bn-chip-mark")
        gtk_box_append(
            ptr(chip),
            BrainUI.verdictGlyph(
                BrainAccount.stepVerdict(for: verdict), size: 12, inks: inks,
                color: BrainDraw.toneColor(tone, inks: inks)))
        gtk_box_append(ptr(chip), BrainUI.label(verdict.pillWord.uppercased(), "bn-chip-word"))
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(chip, verdict.word)
        let duration = NeuralReading.line(for: turn).duration
        let right = BrainUI.label(
            BrainWords.count(digest.ticks.count, steps: BrainWords.steps(digest.ticks.count), duration: duration),
            "bn-counter", ellipsize: true)
        gtk_widget_set_hexpand(right, 1)
        gtk_label_set_xalign(op(right), 1)
        BrainUI.add(page.header, label, chip, right)
    }

    func digestFoot(_ digest: R.Digest, in page: Page) {
        let steps = BrainUI.label(BrainWords.steps(digest.ticks.count), "bn-fact")
        var began = ""
        if let at = owner.model.turn.startedAt ?? owner.model.steps.compactMap(\.at).min() {
            began = NeuralReading.clock(at)
        }
        let clock = BrainUI.label(began, "bn-fact")
        let hint = BrainUI.label(BrainWords.hoverHint, "bn-fact", ellipsize: true)
        gtk_label_set_xalign(op(hint), 1)
        BrainUI.add(page.foot, steps, clock, BrainUI.spacer(), hint)
    }

    func buildDigest(_ digest: R.Digest, in page: Page) {
        let body = page.body
        let hex = inks.hex
        let headline = section(first: true)
        gtk_box_append(ptr(headline), BrainUI.markup(headlineMarkup(digest), "bn-headline", selectable: true))
        gtk_box_append(ptr(body), headline)

        let bars = section()
        gtk_box_append(
            ptr(bars),
            labelRow(
                BrainWords.whereTheWorkWent, right: rightLabel(BrainWords.steps(digest.ticks.count))))
        for bar in digest.zoneBars { gtk_box_append(ptr(bars), zoneBarRow(bar)) }
        gtk_box_append(ptr(bars), timeline(digest))
        gtk_box_append(ptr(body), bars)

        if !digest.failures.isEmpty {
            let box = section()
            gtk_box_append(
                ptr(box), labelRow(digest.failuresTitle, right: rightLabel(String(digest.failures.count))))
            for failure in digest.failures.prefix(Self.digestRows) { gtk_box_append(ptr(box), failureRow(failure)) }
            if digest.failures.count > Self.digestRows {
                let ref = self.ref
                gtk_box_append(
                    ptr(box),
                    BrainUI.link(BrainWords.moreFailures(digest.failures.count - Self.digestRows)) {
                        ref.view?.browse(.failedToggle, grabFocus: false)
                    })
            }
            gtk_box_append(ptr(body), box)
        }
        if !digest.changed.isEmpty {
            let box = section()
            let model = owner.model
            let added = model.steps.reduce(0) { $0 + ($1.added ?? 0) }
            let removed = model.steps.reduce(0) { $0 + ($1.removed ?? 0) }
            gtk_box_append(
                ptr(box), labelRow(BrainWords.changed, right: tallyLabel(added: added, removed: removed)))
            for change in digest.changed.prefix(Self.digestRows) { gtk_box_append(ptr(box), changedRow(change)) }
            if digest.changed.count > Self.digestRows {
                gtk_box_append(
                    ptr(box),
                    BrainUI.label(BrainWords.moreFiles(digest.changed.count - Self.digestRows), "bn-fact"))
            }
            gtk_box_append(ptr(body), box)
        }
        if let answer = digest.answer, !answer.isEmpty {
            let box = section()
            gtk_box_append(ptr(box), labelRow(BrainWords.answer))
            gtk_box_append(ptr(box), BrainUI.label(answer, "bn-answer", wrap: true, selectable: true))
            gtk_box_append(ptr(body), box)
        }
        _ = hex
    }

    /// How many failures and changed files the digest lists before saying how many more there are:
    /// a turn of two thousand steps is not two thousand widgets.
    static let digestRows = 6

    /// The headline with its last sentence in the warning colour when the turn had a failure to
    /// tell, the way the mock sets it.
    func headlineMarkup(_ digest: R.Digest) -> String {
        let model = owner.model
        let card = model.brainCard(now: Date())
        let sentence = card.digest.isEmpty ? digest.headline : card.digest
        guard let clause = card.headline.piece(.failure)?.text else { return BrainUI.escape(sentence) }
        let word = clause.prefix(1).uppercased() + clause.dropFirst() + "."
        return BrainUI.escape(sentence) + " <span foreground=\"\(inks.hex.warn)\">\(BrainUI.escape(word))</span>"
    }

    func zoneBarRow(_ bar: R.ZoneBar) -> UnsafeMutablePointer<GtkWidget> {
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-bar-row", "bn-z-\(BrainUI.zoneName(bar.zone))")
        let name = BrainUI.label(bar.label, "bn-bar-name", "bn-tone-text")
        gtk_widget_set_size_request(name, 72, -1)
        let tone = inks.corrected(bar.zone)
        let canvas = barCanvas(fraction: bar.fraction, color: tone, height: 6)
        let count = BrainUI.label(String(bar.count), "bn-bar-count")
        gtk_widget_set_size_request(count, 28, -1)
        gtk_label_set_xalign(op(count), 1)
        BrainUI.add(row, name, canvas, count)
        let zone = bar.zone
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.dive(into: zone) }
        tailscode_set_accessible_label(row, "\(bar.label) \(bar.count)")
        return row
    }

    /// A horizontal bar: a quiet track and the fill, both in the zone's colour.
    func barCanvas(fraction: Double, color: BrainInks.RGB, height: Double)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let canvasColor = inks.canvas
        let box = Unmanaged.passRetained(BarBox(fraction: fraction, color: color, ground: canvasColor)).toOpaque()
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let bar = Unmanaged<BarBox>.fromOpaque(raw).takeUnretainedValue()
                let h = Double(height)
                let track = BrainInks.mix(bar.ground, bar.color, 0.12)
                BrainPainter.round(cr, 0, 0, Double(width), h, h / 2)
                cairo_set_source_rgba(cr, track.red, track.green, track.blue, 1)
                cairo_fill(cr)
                BrainPainter.round(cr, 0, 0, max(h, Double(width) * bar.fraction), h, h / 2)
                cairo_set_source_rgba(cr, bar.color.red, bar.color.green, bar.color.blue, 1)
                cairo_fill(cr)
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<BarBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, 20, Int32(height))
        gtk_widget_set_hexpand(canvas, 1)
        gtk_widget_set_valign(canvas, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(canvas, 0)
        return canvas
    }

    final class BarBox: @unchecked Sendable {
        let fraction: Double
        let color: BrainInks.RGB
        let ground: BrainInks.RGB
        init(fraction: Double, color: BrainInks.RGB, ground: BrainInks.RGB) {
            self.fraction = fraction
            self.color = color
            self.ground = ground
        }
    }

    // MARK: the timeline strip

    func timeline(_ digest: R.Digest) -> UnsafeMutablePointer<GtkWidget> {
        let strip = TimelineStrip(digest: digest, owner: owner, inks: inks)
        let canvas = strip.make()
        gtk_widget_set_size_request(canvas, -1, 32)
        gtk_widget_set_margin_top(canvas, 8)
        return canvas
    }

    final class TimelineStrip: @unchecked Sendable {
        let digest: R.Digest
        weak var owner: BrainView?
        let inks: BrainInks
        var hovered: Int?
        var font = "Sans Bold 9"
        var scrubbing = false
        var canvas: UnsafeMutablePointer<GtkWidget>?

        init(digest: R.Digest, owner: BrainView, inks: BrainInks) {
            self.digest = digest
            self.owner = owner
            self.inks = inks
        }

        private var slots: Double {
            Double(digest.ticks.count) + (digest.answerBegins == nil ? 0 : 1.6)
        }

        func x(_ index: Int, width: Double) -> Double {
            (Double(index) + 0.5) / max(1, slots) * width
        }

        func index(at x: Double, width: Double) -> Int? {
            guard !digest.ticks.isEmpty, width > 0 else { return nil }
            let raw = Int((x / width * slots - 0.5).rounded())
            let clamped = min(max(0, raw), digest.ticks.count - 1)
            return abs(self.x(clamped, width: width) - x) <= 7 ? clamped : nil
        }

        func make() -> UnsafeMutablePointer<GtkWidget> {
            let box = Unmanaged.passRetained(self).toOpaque()
            _ = Gtk.releaseInstalled
            let area = tailscode_canvas_new(
                { cr, width, height, raw in
                    guard let cr, let raw else { return }
                    Unmanaged<TimelineStrip>.fromOpaque(raw).takeUnretainedValue()
                        .paint(cr, width: Double(width), height: Double(height))
                }, box,
                { raw in
                    guard let raw else { return }
                    Unmanaged<TimelineStrip>.fromOpaque(raw).release()
                })!
            canvas = area
            font = BrainUI.font(of: BrainUI.label("A", "bn-label"))
            Gtk.onPointer(
                area,
                move: { [weak self] x, _ in self?.moved(x: x) },
                leave: { [weak self] in self?.left() })
            let click = Unmanaged.passRetained(ClickBox { [weak self] x in self?.pressed(x: x) }).toOpaque()
            _ = Gtk.releaseInstalled
            tailscode_on_click_at(
                area,
                { x, _, _, button, raw in
                    guard let raw, button == 1 else { return }
                    Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x)
                }, click)
            Gtk.onPressHold(
                area, down: {}, up: { [weak self] in Gtk.onMain { [weak self] in self?.released() } })
            gtk_widget_set_cursor_from_name(area, "pointer")
            tailscode_set_accessible_label(
                area, Localized.text("Timeline of %lld steps", digest.ticks.count))
            return area
        }

        private final class ClickBox: @unchecked Sendable {
            let handler: (Double) -> Void
            init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
        }

        private func width() -> Double {
            canvas.map { Double(gtk_widget_get_width($0)) } ?? 0
        }

        private func moved(x: Double) {
            if scrubbing {
                scrub(x: x)
                return
            }
            let found = index(at: x, width: width())
            guard found != hovered else { return }
            hovered = found
            owner?.stripHover(found.map { digest.ticks[$0].stepID })
            canvas.map { gtk_widget_queue_draw($0) }
        }

        private func left() {
            guard hovered != nil, !scrubbing else { return }
            hovered = nil
            owner?.stripHover(nil)
            canvas.map { gtk_widget_queue_draw($0) }
        }

        private func pressed(x: Double) {
            scrubbing = true
            scrub(x: x)
        }

        private func released() {
            guard scrubbing else { return }
            scrubbing = false
            owner?.stripScrubEnded()
        }

        private func scrub(x: Double) {
            let wide = width()
            guard wide > 0, !digest.ticks.isEmpty else { return }
            let raw = Int((x / wide * slots - 0.5).rounded())
            let target = min(max(0, raw), digest.ticks.count - 1)
            owner?.stripScrub(toStep: digest.ticks[target].stepID)
            hovered = target
            canvas.map { gtk_widget_queue_draw($0) }
        }

        func paint(_ cr: OpaquePointer, width: Double, height: Double) {
            let baseline = height - 4
            let rule = inks.rule2
            cairo_set_source_rgba(cr, rule.red, rule.green, rule.blue, 1)
            cairo_set_line_width(cr, 1)
            cairo_new_path(cr)
            cairo_move_to(cr, 0, baseline + 0.5)
            cairo_line_to(cr, width, baseline + 0.5)
            cairo_stroke(cr)
            for tick in digest.ticks {
                let center = x(tick.index, width: width)
                let tall = tick.isFailure && !tick.isRecovered
                let h = tick.isFailure ? 28.0 : 14.0
                let color = tick.isFailure ? inks.cDanger : inks.corrected(tick.zone)
                cairo_set_source_rgba(cr, color.red, color.green, color.blue, tall || !tick.isFailure ? 1 : 0.85)
                BrainPainter.round(cr, center - 2, baseline - 4 - h + 4, 4, h, 2)
                cairo_fill(cr)
                if hovered == tick.index {
                    cairo_set_source_rgba(cr, inks.ink.red, inks.ink.green, inks.ink.blue, 1)
                    cairo_set_line_width(cr, 2)
                    BrainPainter.round(cr, center - 3, baseline - h, 6, h + 2, 3)
                    cairo_stroke(cr)
                }
            }
            if let begins = digest.answerBegins {
                let center = x(begins, width: width)
                let ink = inks.dim
                cairo_set_source_rgba(cr, ink.red, ink.green, ink.blue, 1)
                cairo_set_line_width(cr, 1)
                cairo_new_path(cr)
                cairo_move_to(cr, center + 0.5, 0)
                cairo_line_to(cr, center + 0.5, height)
                cairo_stroke(cr)
                var measured = 0.0
                var textHeight = 0.0
                let word = BrainWords.answer
                tailscode_text_measure(word, font, 0, 1, &measured, &textHeight)
                _ = tailscode_text_draw(
                    cr, word, font, center - measured - 6, 0, 0, 0, 1, ink.red, ink.green, ink.blue, 1)
            }
        }
    }

    // MARK: failures and changes

    func failureRow(_ failure: R.Failure) -> UnsafeMutablePointer<GtkWidget> {
        let hex = inks.hex
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-list-row")
        let number = BrainUI.label(String(failure.number), "bn-fail-no")
        gtk_widget_set_size_request(number, 28, -1)
        gtk_widget_set_valign(number, GTK_ALIGN_START)
        let text = BrainUI.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(text, 1)
        let title = BrainUI.label(failure.title, "bn-fail-title", ellipsize: true)
        let first = BrainUI.label(failure.firstLine, "bn-fail-line", ellipsize: true)
        BrainUI.add(text, title, first)
        let retried = BrainUI.label(failure.label, "bn-fail-re")
        if failure.verdict == .failed { Gtk.addClass(retried, "bn-fail-never") }
        gtk_widget_set_valign(retried, GTK_ALIGN_CENTER)
        let mark = BrainUI.verdictGlyph(failure.verdict, size: 14, inks: inks)
        BrainUI.add(row, number, text, mark, retried)
        tailscode_set_accessible_label(row, "\(failure.verdictWord), \(failure.label)")
        let id = failure.stepID
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.pin(id) }
        _ = hex
        return row
    }

    func changedRow(_ change: R.Changed) -> UnsafeMutablePointer<GtkWidget> {
        let hex = inks.hex
        let row = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "bn-list-row")
        let path = BrainUI.markup(
            "<span foreground=\"\(hex.dim)\">\(BrainUI.escape(change.shortDirectory))</span><span foreground=\"\(hex.text)\" weight=\"bold\">\(BrainUI.escape(change.fileName))</span>",
            "bn-changed-path", wrap: false)
        gtk_label_set_ellipsize(op(path), PANGO_ELLIPSIZE_START)
        gtk_widget_set_hexpand(path, 1)
        let total = change.added + change.removed
        let meter = changeMeter(added: change.added, removed: change.removed, width: Double(min(72, max(12, total * 6))))
        let tally = tallyLabel(added: change.added, removed: change.removed)
        gtk_widget_set_size_request(tally, 56, -1)
        BrainUI.add(row, path, meter, tally)
        let id = change.stepID
        let ref = self.ref
        BrainUI.clickable(row) { ref.view?.pin(id) }
        return row
    }

    func changeMeter(added: Int, removed: Int, width: Double) -> UnsafeMutablePointer<GtkWidget> {
        let box = Unmanaged.passRetained(MeterBox(added: added, removed: removed, inks: inks)).toOpaque()
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let meter = Unmanaged<MeterBox>.fromOpaque(raw).takeUnretainedValue()
                let total = Double(max(1, meter.added + meter.removed))
                let w = Double(width)
                let addWidth = w * Double(meter.added) / total
                let a = meter.inks.accent
                let d = meter.inks.cDanger
                cairo_set_source_rgba(cr, a.red, a.green, a.blue, 1)
                BrainPainter.round(cr, 0, 0, max(0, addWidth - (meter.removed > 0 ? 0.5 : 0)), 6, 1)
                cairo_fill(cr)
                if meter.removed > 0 {
                    cairo_set_source_rgba(cr, d.red, d.green, d.blue, 1)
                    BrainPainter.round(cr, addWidth + 0.5, 0, max(0, w - addWidth - 0.5), 6, 1)
                    cairo_fill(cr)
                }
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<MeterBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(canvas, Int32(width), 6)
        gtk_widget_set_valign(canvas, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(canvas, 0)
        return canvas
    }

    final class MeterBox: @unchecked Sendable {
        let added: Int
        let removed: Int
        let inks: BrainInks
        init(added: Int, removed: Int, inks: BrainInks) {
            self.added = added
            self.removed = removed
            self.inks = inks
        }
    }

    // MARK: now, the ask, a zone, the replay
}
