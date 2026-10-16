import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The small helpers the world clock's three surfaces share.
enum ClockUI {
    /// Calls `changed` on the main loop whenever the pointer comes onto or leaves `widget` or
    /// anything inside it. The property is read rather than the enter and leave signals, which a
    /// crossing between a surface and a popup answers with a leave straight after the enter.
    static func watchPointer(
        on widget: UnsafeMutablePointer<GtkWidget>, _ changed: @escaping @Sendable (Bool) -> Void
    ) {
        let motion = gtk_event_controller_motion_new()!
        gtk_widget_add_controller(widget, motion)
        let address = Int(bitPattern: UnsafeMutableRawPointer(motion))
        Gtk.onNotify(UnsafeMutableRawPointer(motion), property: "contains-pointer") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let inside = gtk_event_controller_motion_contains_pointer(op(raw)) != 0
            Gtk.onMain { changed(inside) }
        }
    }

    static func label(
        _ text: String, _ css: String, wrap: Bool = false, chars: Int32 = 0
    ) -> UnsafeMutablePointer<GtkWidget> {
        let widget = Gtk.label(text, css: nil, wrap: wrap, selectable: false)
        for name in css.split(separator: " ") { Gtk.addClass(widget, String(name)) }
        gtk_label_set_ellipsize(op(widget), PANGO_ELLIPSIZE_NONE)
        if wrap, chars > 0 { gtk_label_set_max_width_chars(op(widget), chars) }
        return widget
    }

    static func rule() -> UnsafeMutablePointer<GtkWidget> {
        let rule = Gtk.hairline()
        Gtk.addClass(rule, "clock-rule")
        return rule
    }

    static func dot(_ tone: ClockTone) -> UnsafeMutablePointer<GtkWidget> {
        let dot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(dot, "clock-dot")
        Gtk.addClass(dot, "clock-dot-\(tone.rawValue)")
        gtk_widget_set_size_request(dot, 7, 7)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        tailscode_set_accessible_hidden(dot, 1)
        return dot
    }

    static func tone(_ tone: ClockTone) -> String { "clock-\(tone.rawValue)" }

    static let toneClasses = [ClockTone.ok, .warn, .quiet].map { "clock-\($0.rawValue)" }

    static func glyph(
        _ kind: TailscodeGlyphKind, size: Int32, body: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let glyph = tailscode_glyph_new(size)!
        MeridianInk.glyph(glyph, kind: kind, body: MeridianInk.rgb(body))
        tailscode_set_accessible_hidden(glyph, 1)
        return glyph
    }
}

/// The world clock's mark at the foot of the sidebar: the sky over this desk and the time, in a
/// capsule. It is drawn once a minute and holds still between, because a glyph that is not changing
/// runs no clock. Resting the pointer on it opens the glance, which stays while the pointer is on
/// the capsule or the glance and leaves shortly after it is on neither; a click, Enter or Space
/// opens the sheet.
final class ClockChip: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let sky: UnsafeMutablePointer<GtkWidget>
    private let time = Gtk.label("", css: "clock-chip-time", selectable: false)
    private let popover: UnsafeMutablePointer<GtkWidget>
    private var glance: ClockGlanceView?
    private var generation = 0
    private var pointerOnGlance = false
    private var token = 0
    private let onOpen: @Sendable () -> Void

    init(onOpen: @escaping @Sendable () -> Void) {
        self.onOpen = onOpen
        widget = tailscode_box_new_with_role(GTK_ORIENTATION_HORIZONTAL, 7, GTK_ACCESSIBLE_ROLE_BUTTON)!
        Gtk.addClass(widget, "clock-chip")
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(widget, 0)
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_cursor_from_name(widget, "pointer")
        sky = tailscode_glyph_new(16)!
        tailscode_set_accessible_hidden(sky, 1)
        gtk_label_set_ellipsize(op(time), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(widget), sky)
        gtk_box_append(ptr(widget), time)

        popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, widget)
        gtk_popover_set_autohide(ptr(popover), 0)
        gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
        Gtk.addClass(popover, "clock-glance")

        ClockUI.watchPointer(on: widget) { [weak self] inside in
            if inside { self?.showGlance() } else { self?.scheduleHide() }
        }
        Gtk.onRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.open() }
        }
        ClockUI.watchPointer(on: popover) { [weak self] inside in
            self?.pointerOnGlance = inside
            if !inside { self?.scheduleHide() }
        }
        Gtk.onKey(widget) { [weak self] keyval, _ in
            guard keyval == Keymap.enter || keyval == Keymap.keypadEnter || keyval == 0x20 else {
                return false
            }
            Gtk.onMain { [weak self] in self?.open() }
            return true
        }
        Gtk.onKey(popover) { [weak self] keyval, _ in
            guard keyval == Keymap.escape else { return false }
            Gtk.onMain { [weak self] in self?.hideGlance() }
            return true
        }
        refresh()
        token = ClockWatch.shared.observe { [weak self] in
            Gtk.onMain { [weak self] in self?.refresh() }
        }
    }

    deinit { ClockWatch.shared.stopObserving(token) }

    /// What the chip says right now, for the harness.
    var line: String {
        let text = gtk_label_get_text(op(time)).map { String(cString: $0) } ?? ""
        return "chip=\(text) glance=\(isShown ? "open" : "shut")"
    }

    var isShown: Bool { gtk_widget_get_visible(popover) != 0 }

    var glanceText: String? { glance?.text }

    var glanceRoot: UnsafeMutablePointer<GtkWidget>? { glance?.widget }

    func refresh() {
        let reading = ClockWatch.shared.reading()
        gtk_label_set_text(op(time), reading.chipTime)
        MeridianInk.sky(sky, reading.sky)
        gtk_widget_set_tooltip_text(widget, isShown ? nil : reading.spoken)
        tailscode_set_accessible_label(widget, reading.spoken)
        if isShown { glance?.render(reading) }
    }

    func open() {
        hideGlance()
        onOpen()
    }

    func showGlance() {
        generation += 1
        guard !isShown else { return }
        let view = ClockGlanceView()
        glance = view
        gtk_popover_set_child(ptr(popover), view.widget)
        view.render(ClockWatch.shared.reading())
        gtk_widget_set_tooltip_text(widget, nil)
        gtk_popover_popup(ptr(popover))
    }

    /// The pointer crossing from the capsule to the glance is a leave and an enter a few pixels
    /// apart, so a leave only hides the glance once it has gone unanswered for a moment.
    private func scheduleHide() {
        generation += 1
        let mine = generation
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.generation == mine, !self.pointerOnGlance else { return }
                self.hideGlance()
            }
        }
    }

    func hideGlance() {
        generation += 1
        pointerOnGlance = false
        guard isShown else { return }
        gtk_popover_popdown(ptr(popover))
        refresh()
    }

    func tearDown() {
        ClockWatch.shared.stopObserving(token)
        hideGlance()
        gtk_widget_unparent(popover)
    }
}
