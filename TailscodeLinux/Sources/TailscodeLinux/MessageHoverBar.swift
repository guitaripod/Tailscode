import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The verbs of a message, offered to a pointer resting on it: when it was written, Copy, and — on
/// a prompt a server can wind back to — Undo from here.
///
/// They used to live on a right-click nobody was told about. Here they float as a small plate at
/// the message's top trailing corner, over the room the page leaves between one message and the
/// next, for as long as the pointer is on the message or on the plate itself. The plate is one
/// widget that moves from message to message; the transcript is watched through a single motion
/// controller on its overlay, and the message under the pointer is found by where the rows stand
/// (`PointerRows`), so a pointer crossing a long conversation costs a binary search per move.
///
/// It takes no focus and claims nothing: the plate is a sibling of the scroller, so a press on the
/// words under it is still a press on the words.
final class MessageHoverBar: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    var copy: ((String) -> Void)?
    var undo: ((String) -> Void)?

    private let stamp = Gtk.label("", css: "hover-stamp", selectable: false)
    private lazy var copyButton = Self.verbButton(Localized.text("Copy")) { [weak self] in
        guard let self, let id = self.shownID else { return }
        self.copy?(id)
    }
    private lazy var undoButton = Self.verbButton(Localized.text("Undo")) { [weak self] in
        guard let self, let id = self.shownID else { return }
        self.undo?(id)
    }
    private(set) var shownID: String?
    private var shownVerbs: MessageHover.Verbs?
    private var visibilityToken: UInt = 0
    private var hideToken: UInt = 0

    /// The fade the plate comes up with, and how long it stays mapped after it has gone so the
    /// fade out can finish. With animations off at the desk, GTK runs the transition in no time.
    private static let fadeOutRoom: UInt32 = 160
    private static let hideDelay: UInt32 = 250

    init() {
        Gtk.addClass(widget, "hover-bar")
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_widget_set_visible(widget, 0)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        gtk_widget_set_focusable(widget, 0)
        gtk_label_set_ellipsize(op(stamp), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(stamp, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(widget), stamp)
        gtk_box_append(ptr(widget), copyButton)
        gtk_box_append(ptr(widget), undoButton)
    }

    /// Whether a point in `overlay`'s coordinates is on the plate.
    func contains(
        x: Double, y: Double, in overlay: UnsafeMutablePointer<GtkWidget>
    ) -> Bool {
        gtk_widget_get_visible(widget) != 0 && shownID != nil
            && Gtk.contains(widget, x: x, y: y, in: overlay)
    }

    /// Puts the plate on a message: `right` is the trailing edge of the message's rows and `top`
    /// their top, both in the overlay's coordinates, and `ceiling` the highest the plate may sit.
    /// The words and the verbs are set only when the message or what is offered for it changed, so
    /// a message being written under a resting pointer only moves the corner the plate hangs from.
    func present(
        messageID: String, verbs: MessageHover.Verbs, right: Double, top: Double, ceiling: Double
    ) {
        cancelHide()
        if messageID != shownID || verbs != shownVerbs {
            gtk_label_set_text(op(stamp), verbs.stamp)
            gtk_widget_set_tooltip_text(stamp, verbs.fullDate)
            gtk_widget_set_visible(copyButton, verbs.copy ? 1 : 0)
            gtk_widget_set_visible(undoButton, verbs.undo ? 1 : 0)
            gtk_widget_set_tooltip_text(undoButton, RevertReading.actionTitle)
            shownID = messageID
            shownVerbs = verbs
        }
        let wasShown = gtk_widget_get_visible(widget) != 0
        gtk_widget_set_visible(widget, 1)
        let size = Gtk.naturalSize(of: widget)
        let x = max(2, right - size.width)
        let y = max(ceiling, top - size.height + 4)
        gtk_widget_set_margin_start(widget, Int32(x.rounded()))
        gtk_widget_set_margin_top(widget, Int32(y.rounded()))
        gtk_widget_set_can_target(widget, 1)
        visibilityToken &+= 1
        if wasShown {
            gtk_widget_add_css_class(widget, "hover-bar-on")
            return
        }
        let token = visibilityToken
        Gtk.after(20) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token, self.shownID != nil else { return }
                gtk_widget_add_css_class(self.widget, "hover-bar-on")
            }
        }
    }

    /// Takes the plate down at once — a chat switched, a scroll begun, a press on the words.
    func dismiss() {
        cancelHide()
        guard shownID != nil || gtk_widget_get_visible(widget) != 0 else { return }
        shownID = nil
        shownVerbs = nil
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_remove_css_class(widget, "hover-bar-on")
        visibilityToken &+= 1
        let token = visibilityToken
        Gtk.after(Self.fadeOutRoom) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.visibilityToken == token else { return }
                gtk_widget_set_visible(self.widget, 0)
            }
        }
    }

    /// Crossing the gap between a message and its plate is not leaving the message.
    func scheduleHide() {
        guard shownID != nil else { return }
        hideToken &+= 1
        let token = hideToken
        Gtk.after(Self.hideDelay) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.hideToken == token else { return }
                self.dismiss()
            }
        }
    }

    func cancelHide() {
        hideToken &+= 1
    }

    private static func verbButton(
        _ title: String, onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: ["flat", "hover-verb"]) {
            Gtk.onMain { onClick() }
        }
        gtk_widget_set_focusable(button, 0)
        gtk_widget_set_focus_on_click(button, 0)
        return button
    }
}
