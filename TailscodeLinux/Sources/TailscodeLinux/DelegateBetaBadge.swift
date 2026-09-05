import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The mark Delegate wears while it is new, on GTK: a capsule beside the window's title. Resting
/// the pointer on it is enough to read why — the popover stays while the pointer is on it and
/// leaves when the pointer does — and a click does the same for a touchpad or a screen reader.
/// Every word is `DelegateBeta`'s.
final class DelegateBetaBadge: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let popover: UnsafeMutablePointer<GtkWidget>
    private var generation = 0
    private var pointerOnCard = false

    init() {
        widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(widget, "beta-badge")
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_cursor_from_name(widget, "pointer")
        gtk_widget_set_tooltip_text(widget, nil)
        let label = Gtk.label(DelegateBeta.badge, selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(widget, 0)
        gtk_box_append(ptr(widget), label)

        popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, widget)
        gtk_popover_set_autohide(ptr(popover), 0)
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 12, bottom: 12, leading: 14, trailing: 14)
        gtk_widget_set_size_request(column, 380, -1)
        gtk_box_append(ptr(column), Gtk.label(DelegateBeta.title, css: "row-title", selectable: false))
        for paragraph in DelegateBeta.paragraphs {
            let body = Gtk.label(paragraph, css: "row-detail", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(body), 56)
            gtk_box_append(ptr(column), body)
        }
        gtk_popover_set_child(ptr(popover), column)

        let badgeMotion = gtk_event_controller_motion_new()!
        gtk_widget_add_controller(widget, badgeMotion)
        Gtk.connect(UnsafeMutableRawPointer(badgeMotion), "enter") { [weak self] in
            Gtk.onMain { [weak self] in self?.show() }
        }
        Gtk.connect(UnsafeMutableRawPointer(badgeMotion), "leave") { [weak self] in
            Gtk.onMain { [weak self] in self?.scheduleHide() }
        }
        let cardMotion = gtk_event_controller_motion_new()!
        gtk_widget_add_controller(column, cardMotion)
        Gtk.connect(UnsafeMutableRawPointer(cardMotion), "enter") { [weak self] in
            Gtk.onMain { [weak self] in self?.pointerOnCard = true }
        }
        Gtk.connect(UnsafeMutableRawPointer(cardMotion), "leave") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.pointerOnCard = false
                self?.scheduleHide()
            }
        }
        Gtk.onRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in self?.toggle() }
        }
    }

    private var isShown: Bool { gtk_widget_get_visible(popover) != 0 }

    private func toggle() {
        if isShown { hide() } else { show() }
    }

    private func show() {
        generation += 1
        guard !isShown else { return }
        gtk_popover_popup(ptr(popover))
    }

    /// The pointer crossing from the badge to the card is a leave and an enter a few pixels apart,
    /// so a leave only hides the card once it has gone unanswered for a moment.
    private func scheduleHide() {
        generation += 1
        let mine = generation
        Gtk.after(250) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.generation == mine, !self.pointerOnCard else { return }
                self.hide()
            }
        }
    }

    private func hide() {
        guard isShown else { return }
        gtk_popover_popdown(ptr(popover))
    }

    /// The popover is parented on the badge rather than owned by the window, so a window that is
    /// destroyed hands it back itself.
    func tearDown() {
        hide()
        gtk_widget_unparent(popover)
    }
}
