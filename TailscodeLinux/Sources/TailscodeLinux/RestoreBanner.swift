import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The strip across the top of the panes after a launch that followed an unclean exit with three
/// or more chats open. Every chat comes back paused rather than live, because relaunching straight
/// into the load that froze the machine is how one freeze becomes a loop; the banner says so and
/// waits for the person. It is not a toast: it stays until answered, and it sits over the panes'
/// tops, never over a composer.
final class RestoreBanner {
    let widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let label = Gtk.label("", css: "restore-banner-text", wrap: true, selectable: false)

    init(
        text: String, resumeAll: @escaping @Sendable () -> Void,
        resumeOneByOne: @escaping @Sendable () -> Void, dismiss: @escaping @Sendable () -> Void
    ) {
        Gtk.addClass(widget, "restore-banner")
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_widget_set_halign(widget, GTK_ALIGN_FILL)
        gtk_label_set_text(op(label), text)
        gtk_label_set_xalign(op(label), 0)
        gtk_widget_set_hexpand(label, 1)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(widget), label)
        let all = Gtk.button(Localized.text("Resume all"), css: ["restore-primary"], onClick: resumeAll)
        let oneByOne = Gtk.button(Localized.text("Resume one by one"), onClick: resumeOneByOne)
        let close = Gtk.button("×", css: ["restore-dismiss"], onClick: dismiss)
        tailscode_set_accessible_label(close, Localized.text("Close"))
        gtk_widget_set_tooltip_text(close, Localized.text("Close"))
        for button in [all, oneByOne, close] {
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(widget), button)
        }
    }

    var text: String {
        gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
    }

    private var overlay: UnsafeMutablePointer<GtkWidget>?

    var isShown: Bool { overlay != nil }

    func attach(to overlay: UnsafeMutablePointer<GtkWidget>) {
        guard self.overlay == nil else { return }
        self.overlay = overlay
        gtk_overlay_add_overlay(op(overlay), widget)
    }

    func remove() {
        guard let overlay else { return }
        self.overlay = nil
        gtk_overlay_remove_overlay(op(overlay), widget)
    }
}
