import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A pane with no room to be a whole conversation, or no share of the live budget: a peek at the
/// chat rather than the chat. What it is doing, its last words read from the bottom up, and the
/// facts a person checks at a glance — who is answering and how hard, how long the turn has run,
/// what is queued, what the machine is still carrying.
///
/// It is content, palette-owned, never a surface of its own: it has no input field, changes at
/// the shed level's glance rate with no reveal, and only the activity face moves — which holds
/// perfectly still once the turn settles. A turn waiting on the person shows the question where
/// the tail was, in the attention tone, and the footer asks for the answer. Pressing the tile
/// focuses it and makes it whole; a double press borrows the window.
final class GlanceTile: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    struct Actions {
        var openFull: @Sendable () -> Void
        var keepLive: @Sendable () -> Void
        var pause: @Sendable () -> Void
        var close: @Sendable () -> Void
        var zoom: @Sendable () -> Void
        var menu: @Sendable () -> [(title: String, detail: String?, action: @Sendable () -> Void)]
    }

    private let glyph = Gtk.label("", css: "glance-glyph", selectable: false)
    private let titleLabel = Gtk.label("", css: "glance-title", selectable: false)
    private let pinMark = Gtk.label("◆", css: "glance-pin", selectable: false)
    private let badge = Gtk.label(Localized.text("Glance"), css: "glance-badge", selectable: false)
    private let actionsRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    private let tail = Gtk.label("", css: "glance-tail", wrap: true, selectable: false)
    private let dot = Gtk.label("●", css: "dial-dot", selectable: false)
    private let meterSlot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let modelLabel = Gtk.label("", css: "glance-foot", selectable: false)
    private let clockLabel = Gtk.label("", css: "glance-foot", selectable: false)
    private let queueLabel = Gtk.label("", css: "glance-foot", selectable: false)
    private let backgroundLabel = Gtk.label("", css: "glance-foot", selectable: false)
    private let footer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private var actions: Actions?
    private var openFullButton: UnsafeMutablePointer<GtkWidget>?
    private var clockToken = 0
    private var clockRunning = false

    private(set) var reading: GlanceReading?
    private var title = ""
    private var pinned = false
    private var position = (index: 1, count: 1)
    private var capacityChars = 0
    private var capacityLines = 0
    private(set) var renders = 0
    private(set) var shownTail = ""

    static let tones = ActivityTone.allCases.map(\.glyphCSS)

    init(paneID: PaneID) {
        Gtk.addClass(widget, "glance-tile")
        Gtk.addClass(widget, "tile-face")
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        tailscode_set_accessible_label(widget, "")
        build(paneID: paneID)
    }

    private func build(paneID: PaneID) {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(header, "glance-header")
        gtk_widget_set_visible(glyph, 0)
        gtk_label_set_ellipsize(op(titleLabel), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(titleLabel, 1)
        gtk_widget_set_visible(pinMark, 0)
        gtk_widget_set_tooltip_text(pinMark, Localized.text("Keep live"))
        Gtk.makePaneDragSource(titleLabel, payload: PaneMovePayload(pane: paneID).encoded)
        Gtk.addClass(actionsRow, "glance-actions")
        for (glyphText, words, tag) in [
            ("⤢", Localized.text("Open full"), 0), ("◆", Localized.text("Keep live"), 1),
            ("⏸", Localized.text("Pause this pane"), 2), ("✕", Localized.text("Close Split"), 3),
        ] {
            let button = Gtk.button(glyphText, css: ["flat", "glance-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.press(tag) }
            }
            gtk_widget_set_tooltip_text(button, words)
            tailscode_set_accessible_label(button, words)
            gtk_box_append(ptr(actionsRow), button)
            if tag == 0 { openFullButton = button }
        }
        for item in [glyph, titleLabel, pinMark, actionsRow, badge] {
            gtk_widget_set_valign(item, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(header), item)
        }
        gtk_box_append(ptr(widget), header)

        gtk_label_set_ellipsize(op(tail), PANGO_ELLIPSIZE_END)
        gtk_widget_set_vexpand(tail, 1)
        gtk_widget_set_valign(tail, GTK_ALIGN_END)
        gtk_label_set_xalign(op(tail), 0)
        gtk_label_set_yalign(op(tail), 1)
        Gtk.margins(tail, top: 4, bottom: 4, leading: 10, trailing: 10)
        gtk_box_append(ptr(widget), tail)

        Gtk.addClass(footer, "glance-footer")
        Gtk.addClass(meterSlot, "dial-meter-slot")
        gtk_widget_set_valign(meterSlot, GTK_ALIGN_CENTER)
        for item in [dot, meterSlot, modelLabel, clockLabel, queueLabel, backgroundLabel] {
            gtk_widget_set_valign(item, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(footer), item)
        }
        gtk_label_set_ellipsize(op(modelLabel), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(widget), footer)
        gtk_widget_set_visible(footer, 0)

        Gtk.onDoubleClick(widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.actions?.zoom() }
        }
        Gtk.onRightClick(widget) { [weak self] x, y in
            guard let self, let rows = self.actions?.menu() else { return }
            Gtk.contextMenu(on: self.widget, x: x, y: y, rows: rows)
        }
    }

    func wire(_ actions: Actions) {
        self.actions = actions
    }

    private func press(_ tag: Int) {
        guard let actions else { return }
        switch tag {
        case 0: actions.openFull()
        case 1: actions.keepLive()
        case 2: actions.pause()
        default: actions.close()
        }
    }

    /// Draws the tile from a reading. Nil is a conversation nothing has been heard from yet.
    func render(
        title: String, reading: GlanceReading?, pinned: Bool, index: Int, of count: Int
    ) {
        self.title = title
        self.pinned = pinned
        position = (index, count)
        self.reading = reading
        renders += 1
        gtk_label_set_text(op(titleLabel), title)
        gtk_widget_set_visible(pinMark, pinned ? 1 : 0)
        if let reading {
            apply(reading)
        } else {
            ActivityPulse.apply(nil, to: glyph)
            gtk_widget_set_visible(glyph, 0)
            gtk_label_set_text(op(tail), "")
            shownTail = ""
            gtk_widget_set_visible(footer, 0)
            stopClock()
        }
        speak()
    }

    private func apply(_ reading: GlanceReading) {
        let activity = reading.activity
        if let activity {
            let icon = activity.icon
            gtk_widget_set_visible(glyph, 1)
            gtk_label_set_text(op(glyph), icon.glyph)
            Gtk.setTone(glyph, icon.tone.glyphCSS, from: Self.tones)
            ActivityPulse.apply(icon, to: glyph, text: icon.glyph) { [glyph] frame in
                gtk_label_set_text(op(glyph), frame)
            }
        } else {
            ActivityPulse.apply(nil, to: glyph)
            gtk_widget_set_visible(glyph, 0)
        }
        gtk_widget_set_visible(footer, 1)
        let waiting = reading.question != nil
        if let question = reading.question {
            shownTail = question
            gtk_widget_add_css_class(tail, "glance-waiting")
        } else {
            shownTail = reading.tail(maxChars: capacityChars > 0 ? capacityChars : 160)
            gtk_widget_remove_css_class(tail, "glance-waiting")
        }
        gtk_label_set_text(op(tail), shownTail)
        if capacityLines > 0 { gtk_label_set_lines(op(tail), Int32(capacityLines)) }

        let chip = ModelBadge.chip(model: reading.model, effort: reading.effort)
        gtk_widget_set_visible(dot, chip == nil ? 0 : 1)
        DialPill.swapClass(
            on: dot, among: DialPill.modelTintClasses,
            chosen: chip.map { ModelTint.identityClass(family: $0.family, name: $0.name) })
        gtk_label_set_text(op(modelLabel), chip?.name ?? "")
        gtk_widget_set_visible(modelLabel, chip == nil ? 0 : 1)
        applyEffort(reading.effort)

        gtk_label_set_text(op(queueLabel), "⏳\(reading.queued)")
        gtk_widget_set_visible(queueLabel, reading.queued == 0 ? 0 : 1)
        let tasks = reading.background?.tasks ?? 0
        gtk_label_set_text(op(backgroundLabel), "⚙ \(tasks)")
        gtk_widget_set_visible(backgroundLabel, tasks == 0 ? 0 : 1)

        if waiting {
            gtk_label_set_text(op(clockLabel), Localized.text("Answer…"))
            gtk_widget_add_css_class(clockLabel, "glance-waiting")
            gtk_widget_set_visible(clockLabel, 1)
            stopClock()
        } else {
            gtk_widget_remove_css_class(clockLabel, "glance-waiting")
            tickClock()
        }
    }

    private func applyEffort(_ effort: String?) {
        Gtk.removeChildren(of: meterSlot)
        guard let effort, !effort.isEmpty else {
            gtk_widget_set_visible(meterSlot, 0)
            return
        }
        gtk_widget_set_visible(meterSlot, 1)
        let power = EffortVocabulary.entry(effort)?.role == .power
        let automatic = EffortVocabulary.isAutomatic(effort)
        let heat = power ? EffortMeter.bars : automatic ? 0 : ModelDial.heat(effort, options: [])
        gtk_box_append(
            ptr(meterSlot),
            ModelDialPopover.meter(
                heat: heat, tint: power || automatic ? nil : ModelTint.effortClass(effort),
                rainbow: power))
    }

    /// How long the running turn has been out, ticking once a second while the tile is on screen
    /// and the shed level allows any clock at all. A settled turn shows nothing and owns no timer.
    private func tickClock() {
        guard let reading, let started = reading.turnStartedAt, reading.activity != nil,
            reading.session.isInFlight
        else {
            gtk_widget_set_visible(clockLabel, 0)
            stopClock()
            return
        }
        gtk_widget_set_visible(clockLabel, 1)
        gtk_label_set_text(op(clockLabel), Self.elapsed(since: started))
        guard !clockRunning, gtk_widget_get_mapped(widget) != 0, Seatbelts.shared.level < .critical
        else { return }
        clockRunning = true
        scheduleClock(clockToken)
    }

    private func scheduleClock(_ token: Int) {
        Gtk.after(1000) { [weak self] in
            guard let self, self.clockToken == token, self.clockRunning else { return }
            self.clockRunning = false
            self.tickClock()
        }
    }

    func stopClock() {
        clockRunning = false
        clockToken += 1
    }

    var ownsClock: Bool { clockRunning }

    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The characters the tail has room for: the columns a line of its face holds times the lines
    /// between the header and the footer. Asked once the tile has a size, and again when it changes.
    func fit(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let metrics = Self.glyphMetrics(of: tail)
        let usableWidth = max(0, width - 22)
        let usableHeight = max(0, height - 24 - 24 - 12)
        let columns = max(8, Int(usableWidth / max(1, metrics.width)))
        let lines = max(1, min(8, Int(usableHeight / max(1, metrics.height))))
        let chars = columns * lines
        guard chars != capacityChars || lines != capacityLines else { return }
        capacityChars = chars
        capacityLines = lines
        gtk_label_set_lines(op(tail), Int32(lines))
        if let reading { apply(reading) }
    }

    private static func glyphMetrics(of label: UnsafeMutablePointer<GtkWidget>) -> (
        width: Double, height: Double
    ) {
        guard let layout = gtk_widget_create_pango_layout(label, "0123456789abcdefghij") else {
            return (7.5, 18)
        }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Double(width) / 20, Double(height) * 1.1)
    }

    private func speak() {
        var parts = [Localized.text("Pane %@ of %@", "\(position.index)", "\(position.count)"), title]
        if let activity = reading?.activity { parts.append(activity.spoken) }
        if let question = reading?.question {
            parts.append(question)
        } else if let line = reading?.tail.split(separator: "\n").last {
            parts.append(String(line))
        }
        tailscode_set_accessible_label(widget, parts.joined(separator: ", "))
    }

    var spokenLabel: String {
        var parts = [Localized.text("Pane %@ of %@", "\(position.index)", "\(position.count)"), title]
        if let activity = reading?.activity { parts.append(activity.spoken) }
        return parts.joined(separator: ", ")
    }

    func setFocusRing(_ on: Bool) {
        if on { gtk_widget_add_css_class(widget, "pane-focused") } else {
            gtk_widget_remove_css_class(widget, "pane-focused")
        }
    }

    var hasTail: Bool { !shownTail.isEmpty }
    var titleText: String { title }
}
