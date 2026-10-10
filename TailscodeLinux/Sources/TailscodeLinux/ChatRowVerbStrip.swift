import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The verbs a chat row offers to a pointer resting on it — pin, save, archive and the way into
/// its menu — standing where the row's age was.
///
/// One strip serves the whole list: it is a child of the overlay the list scrolls in and moves to
/// whichever row the pointer is on, so the list is watched through a single controller and no row
/// carries buttons of its own. It sits over the row's trailing end with a plate of its own, so
/// nothing in the list reflows when it comes or goes; the row beneath it keeps answering clicks
/// everywhere the strip is not.
final class ChatRowVerbStrip: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    var press: ((ChatRowVerb, UnsafeMutablePointer<GtkWidget>) -> Void)?

    private var buttons: [(verb: ChatRowVerb, widget: UnsafeMutablePointer<GtkWidget>)] = []
    private(set) var shownKey: String?
    private(set) var state: ChatRowVerbState?
    private var visibilityToken: UInt = 0

    private static let fadeOutRoom: UInt32 = 140

    init() {
        Gtk.addClass(widget, "row-verbs")
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_widget_set_visible(widget, 0)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        gtk_widget_set_focusable(widget, 0)
        for verb in ChatRowVerb.allCases {
            let button = gtk_button_new_from_icon_name(Self.icon(verb, on: false))!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "row-verb")
            gtk_widget_set_focusable(button, 0)
            gtk_widget_set_focus_on_click(button, 0)
            let bits = UInt(bitPattern: button)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let raw = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { return }
                    self?.press?(verb, raw)
                }
            }
            gtk_box_append(ptr(widget), button)
            buttons.append((verb, button))
        }
    }

    /// Whether a point in `overlay`'s coordinates is on the strip.
    func contains(x: Double, y: Double, in overlay: UnsafeMutablePointer<GtkWidget>) -> Bool {
        shownKey != nil && gtk_widget_get_visible(widget) != 0
            && Gtk.contains(widget, x: x, y: y, in: overlay)
    }

    /// The button that stands for a verb, for a menu that opens beneath it.
    func button(for verb: ChatRowVerb) -> UnsafeMutablePointer<GtkWidget>? {
        buttons.first { $0.verb == verb }?.widget
    }

    /// Puts the strip on the row called `key`, its trailing edge at `right` and its bottom at
    /// `bottom` (the overlay's coordinates), each verb reading the way it would go now.
    func present(key: String, state: ChatRowVerbState, right: Double, bottom: Double) {
        if state != self.state || key != shownKey {
            for (verb, button) in buttons {
                let title = state.title(verb)
                gtk_button_set_icon_name(ptr(button), Self.icon(verb, on: state.isOn(verb)))
                gtk_widget_set_tooltip_text(button, title)
                tailscode_set_accessible_label(button, title)
                if state.isOn(verb) {
                    gtk_widget_add_css_class(button, "row-verb-on")
                } else {
                    gtk_widget_remove_css_class(button, "row-verb-on")
                }
            }
            self.state = state
        }
        let wasShown = shownKey != nil
        shownKey = key
        gtk_widget_set_visible(widget, 1)
        let size = Gtk.naturalSize(of: widget)
        gtk_widget_set_margin_start(widget, Int32(max(0, right - size.width).rounded()))
        gtk_widget_set_margin_top(widget, Int32(max(0, bottom - size.height).rounded()))
        gtk_widget_set_can_target(widget, 1)
        visibilityToken &+= 1
        if wasShown {
            gtk_widget_add_css_class(widget, "row-verbs-on")
            return
        }
        let token = visibilityToken
        Gtk.after(16) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token, self.shownKey != nil else { return }
                gtk_widget_add_css_class(self.widget, "row-verbs-on")
            }
        }
    }

    func dismiss() {
        guard shownKey != nil else { return }
        shownKey = nil
        state = nil
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_remove_css_class(widget, "row-verbs-on")
        visibilityToken &+= 1
        let token = visibilityToken
        Gtk.after(Self.fadeOutRoom) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token else { return }
                gtk_widget_set_visible(self.widget, 0)
            }
        }
    }

    /// The icon a verb wears: the same shape when it is in force, lit by the strip's own style, so
    /// a pinned chat reads as pinned without the glyph changing size.
    static func icon(_ verb: ChatRowVerb, on: Bool) -> String {
        switch verb {
        case .pin: return "view-pin-symbolic"
        case .save: return on ? "starred-symbolic" : "non-starred-symbolic"
        case .archive: return "folder-download-symbolic"
        case .more: return "view-more-horizontal-symbolic"
        }
    }
}
