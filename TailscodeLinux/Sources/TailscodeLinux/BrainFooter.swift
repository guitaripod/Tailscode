import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The strip under an open brain across the whole row: Replay, the scrubber with the turn's
/// failures marked on it, the clock, the words of the answer a step produced, Rows, Share, Close.
/// What stays at a width is Core's (`NeuralStageMetrics.footerParts`): Close goes under 960 points,
/// and under 640 Replay is its icon and the answer chips go.
final class BrainFooter: @unchecked Sendable {
    unowned let owner: BrainView
    let widget: UnsafeMutablePointer<GtkWidget>
    private let replay: UnsafeMutablePointer<GtkWidget>
    private let scale: UnsafeMutablePointer<GtkWidget>
    private let marks: UnsafeMutablePointer<GtkWidget>
    private let scrubHost: UnsafeMutablePointer<GtkWidget>
    private let clock: UnsafeMutablePointer<GtkWidget>
    private let chipHost: UnsafeMutablePointer<GtkWidget>
    private let rows: UnsafeMutablePointer<GtkWidget>
    private let share: UnsafeMutablePointer<GtkWidget>
    private let close: UnsafeMutablePointer<GtkWidget>
    private var chipSignature = ""
    private var chipWidths: [Int] = []
    private var chips: [UnsafeMutablePointer<GtkWidget>] = []
    private var chipLead: UnsafeMutablePointer<GtkWidget>?
    private var suppressScale = false
    private var scrubTicket = 0
    private var replayStopped = false
    private var iconOnly = false
    private var lastClock = ""
    private var markFractions: [Double] = []

    init(owner: BrainView) {
        self.owner = owner
        let ref = WeakBrainView(owner)
        widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        Gtk.addClass(widget, "bn-footer")
        replay = Gtk.button(NeuralReading.replayLabel, css: ["brain-pill", "bn-foot-button"]) {
            Gtk.onMain { ref.view?.toggleReplay() }
        }
        scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1000, 1)!
        marks = gtk_drawing_area_new()!
        scrubHost = gtk_overlay_new()!
        clock = BrainUI.label("", "bn-time")
        chipHost = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        rows = Gtk.button(NeuralReading.rowsLabel, css: ["brain-pill", "bn-foot-button"]) {
            Gtk.onMain { ref.view?.toggleRows() }
        }
        share = Gtk.button(BrainWords.share, css: ["brain-pill", "bn-foot-button"]) {
            Gtk.onMain { ref.view?.presentShare() }
        }
        close = Gtk.button(BrainWords.close, css: ["brain-pill", "bn-foot-button"]) {
            Gtk.onMain { ref.view?.toggleOpen() }
        }
        build()
    }

    private func build() {
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_scale_set_draw_value(ptr(scale), 0)
        gtk_widget_set_hexpand(scale, 1)
        Gtk.addClass(scale, "brain-scrub")
        tailscode_set_accessible_label(scale, NeuralReading.scrubLabel)
        gtk_overlay_set_child(op(scrubHost), scale)
        gtk_widget_set_hexpand(scrubHost, 1)
        gtk_widget_set_valign(scrubHost, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(scrubHost, 80, -1)
        gtk_overlay_add_overlay(op(scrubHost), marks)
        gtk_widget_set_can_target(marks, 0)
        gtk_widget_set_can_focus(marks, 0)
        tailscode_set_accessible_hidden(marks, 1)
        gtk_widget_set_valign(marks, GTK_ALIGN_START)
        gtk_widget_set_size_request(marks, -1, 8)
        installMarks()
        Gtk.connect(UnsafeMutableRawPointer(scale), "value-changed") { [weak self] in
            self?.scaleMoved()
        }
        gtk_widget_set_valign(clock, GTK_ALIGN_CENTER)
        gtk_widget_set_overflow(chipHost, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(chipHost, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(chipHost, 0)
        gtk_widget_set_tooltip_text(share, Localized.text("Share this turn"))
        tailscode_set_accessible_label(share, Localized.text("Share this turn"))
        tailscode_set_accessible_label(close, Localized.text("Close Megatron"))
        tailscode_set_accessible_label(rows, NeuralReading.rowsLabel)
        for button in [replay, rows, share, close] { gtk_widget_set_valign(button, GTK_ALIGN_CENTER) }
        BrainUI.add(widget, replay, scrubHost, clock, chipHost, rows, share, close)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
    }

    private func installMarks() {
        let holder = MarksBox(self)
        _ = Gtk.releaseInstalled
        let box = Unmanaged.passRetained(holder).toOpaque()
        gtk_drawing_area_set_draw_func(
            ptr(marks),
            { _, cr, width, height, raw in
                guard let cr, let raw else { return }
                let held = Unmanaged<MarksBox>.fromOpaque(raw).takeUnretainedValue()
                guard let footer = held.footer else { return }
                footer.paintMarks(cr, width: Double(width), height: Double(height))
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<MarksBox>.fromOpaque(raw).release()
            })
    }

    private final class MarksBox: @unchecked Sendable {
        weak var footer: BrainFooter?
        init(_ footer: BrainFooter) { self.footer = footer }
    }

    private func paintMarks(_ cr: OpaquePointer, width: Double, height: Double) {
        let danger = owner.inks.cDanger
        cairo_set_source_rgba(cr, danger.red, danger.green, danger.blue, 1)
        let inset = 8.0
        for fraction in markFractions {
            let x = inset + fraction * (width - inset * 2)
            BrainPainter.round(cr, x - 1, 0, 2, 6, 1)
            cairo_fill(cr)
        }
    }

    /// Lays the strip out for a row `width` points wide: which parts stay, which go.
    func configure(width: Double, running: Bool) {
        let parts = NeuralStageMetrics.footerParts(width: width)
        func has(_ kind: NeuralStageMetrics.FooterPart.Kind) -> Bool { parts.contains { $0.kind == kind } }
        gtk_widget_set_visible(share, has(.share) ? 1 : 0)
        gtk_widget_set_visible(close, has(.close) ? 1 : 0)
        gtk_widget_set_visible(rows, has(.rows) ? 1 : 0)
        gtk_widget_set_visible(clock, has(.time) ? 1 : 0)
        let icon = parts.first { $0.kind == .replay }?.isIcon ?? false
        iconOnly = icon
        let showChips = has(.answerChips)
        gtk_widget_set_visible(chipHost, showChips && !chips.isEmpty ? 1 : 0)
        gtk_widget_set_sensitive(replay, running ? 0 : 1)
        gtk_widget_set_sensitive(share, running ? 0 : 1)
        gtk_widget_set_sensitive(scale, running ? 0 : 1)
        refreshReplay()
        fitChips(width: width)
    }

    private func refreshReplay() {
        let playing = owner.model.isReplaying
        let title: String
        if iconOnly {
            title = playing ? "\u{25A0}" : "\u{25B6}"
        } else {
            title = playing ? "\u{25A0} " + Localized.text("Stop") : "\u{25B6} " + NeuralReading.replayLabel
        }
        gtk_button_set_label(ptr(replay), title)
        tailscode_set_accessible_label(replay, playing ? Localized.text("Stop") : NeuralReading.replayLabel)
        gtk_widget_set_tooltip_text(replay, playing ? Localized.text("Stop") : NeuralReading.replayLabel)
        gtk_widget_remove_css_class(rows, "on")
        if owner.row.showRows { gtk_widget_add_css_class(rows, "on") }
        tailscode_set_accessible_pressed(rows, owner.row.showRows ? 1 : 0)
    }

    /// The scrubber's place and the clock beside it, from the playhead.
    func sync(_ time: Double) {
        let model = owner.model
        refreshReplay()
        let fraction = model.replayFraction(now: time) ?? 1
        suppressScale = true
        gtk_range_set_value(ptr(scale), fraction * 1000)
        suppressScale = false
        var shown = ""
        let steps = model.steps
        if model.isReplaying, let tick = model.ticker(now: time),
            let step = model.step(id: tick.stepID), let at = step.at
        {
            shown = NeuralReading.clock(at)
        } else if let last = steps.last(where: { $0.at != nil })?.at {
            shown = NeuralReading.clock(last)
        }
        if shown != lastClock {
            lastClock = shown
            gtk_label_set_text(op(clock), shown)
        }
        let failures = steps.enumerated().compactMap { index, step -> Double? in
            step.status == .failed && !steps.isEmpty ? (Double(index) + 0.5) / Double(steps.count) : nil
        }
        if failures != markFractions {
            markFractions = failures
            gtk_widget_queue_draw(marks)
        }
    }

    private func scaleMoved() {
        guard !suppressScale else { return }
        let fraction = gtk_range_get_value(ptr(scale)) / 1000
        owner.scrub(to: fraction)
        scrubTicket += 1
        let ticket = scrubTicket
        let ref = WeakBrainView(owner)
        Gtk.after(320) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let view = ref.view, self.scrubTicket == ticket else { return }
                view.endScrub()
            }
        }
    }

    var isScrubbing: Bool { gtk_widget_get_sensitive(scale) != 0 }

    // MARK: the answer's words

    /// The path-like words of the answer that a step carries, as chips that point at those steps.
    func rebuildChips(width: Double) {
        let unique = owner.answerChips.prefix(12)
        let signature = unique.joined(separator: "\u{1}")
        guard signature != chipSignature else {
            fitChips(width: width)
            return
        }
        chipSignature = signature
        Gtk.removeChildren(of: chipHost)
        chips = []
        chipLead = nil
        guard !unique.isEmpty else {
            gtk_widget_set_visible(chipHost, 0)
            return
        }
        let lead = BrainUI.label(BrainWords.inTheAnswer.uppercased(), "bn-label")
        gtk_widget_set_valign(lead, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(chipHost), lead)
        chipLead = lead
        for text in unique {
            let shown = text.count > 44 ? "\u{2026}" + text.suffix(43) : text
            let chip = gtk_button_new_with_label(shown)!
            Gtk.addClass(chip, "brain-chip")
            tailscode_set_accessible_label(chip, text)
            gtk_widget_set_tooltip_text(chip, text)
            let box = Unmanaged.passRetained(ChipBox(text: text, owner: owner)).toOpaque()
            _ = Gtk.releaseInstalled
            tailscode_on_hover_focus(
                chip,
                { raw in
                    guard let raw else { return }
                    let held = Unmanaged<ChipBox>.fromOpaque(raw).takeUnretainedValue()
                    held.owner?.point(at: held.text)
                },
                { raw in
                    guard let raw else { return }
                    Unmanaged<ChipBox>.fromOpaque(raw).takeUnretainedValue().owner?.point(at: nil)
                }, box)
            gtk_box_append(ptr(chipHost), chip)
            chips.append(chip)
        }
        fitChips(width: width)
    }

    private final class ChipBox: @unchecked Sendable {
        let text: String
        weak var owner: BrainView?
        init(text: String, owner: BrainView) {
            self.text = text
            self.owner = owner
        }
    }

    /// Shows the chips that fit whole between the clock and Rows, and leaves the rest out.
    private func fitChips(width: Double) {
        let parts = NeuralStageMetrics.footerParts(width: width)
        guard parts.contains(where: { $0.kind == .answerChips }), !chips.isEmpty else {
            gtk_widget_set_visible(chipHost, 0)
            return
        }
        for chip in chips { gtk_widget_set_visible(chip, 0) }
        gtk_widget_set_visible(chipHost, 1)
        if let lead = chipLead { gtk_widget_set_visible(lead, 1) }
        var shownAny = false
        for chip in chips {
            gtk_widget_set_visible(chip, 1)
            if Double(Self.minimum(widget)) > width - 4 {
                gtk_widget_set_visible(chip, 0)
                break
            }
            shownAny = true
        }
        if let lead = chipLead { gtk_widget_set_visible(lead, shownAny ? 1 : 0) }
        gtk_widget_set_visible(chipHost, shownAny ? 1 : 0)
    }

    private static func minimum(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        var minimum: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        return minimum
    }

    private static func natural(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        var natural: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
        return natural
    }

    /// What the strip shows, for the harness.
    var reading: String {
        func shown(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int { Int(gtk_widget_get_visible(widget)) }
        return "replay=\(shown(replay)) icon=\(iconOnly) scrub=\(shown(scrubHost)) chips=\(chips.filter { gtk_widget_get_visible($0) != 0 }.count)/\(chips.count) rows=\(shown(rows)) share=\(shown(share)) close=\(shown(close)) time=\(lastClock)"
    }

    var chipsVisible: Int { chips.filter { gtk_widget_get_visible($0) != 0 }.count }
    var closeVisible: Bool { gtk_widget_get_visible(close) != 0 }
    var replayIconOnly: Bool { iconOnly }
    var chipsShown: Bool { gtk_widget_get_visible(chipHost) != 0 }
}
