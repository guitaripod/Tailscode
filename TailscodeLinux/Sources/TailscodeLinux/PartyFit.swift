import CAdw
import CGtkShim
import Foundation

/// Where a party popover may stand when the pill that opens it is not at the bottom of a wide
/// window: how far it is moved sideways to keep its edge with the window's, and the tallest it may
/// be before it scrolls rather than run off the screen.
struct PartyFit {
    let ceiling: Int32?
    let shift: Int32
}

extension PartyPopover {
    /// Lays the owner's fit on content about to be shown: the sideways shift goes to the popover,
    /// and content taller than the ceiling is put in a scroller of that height.
    func fitted(_ shell: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        guard let fit = fit?() else { return shell }
        gtk_popover_set_offset(ptr(popover), fit.shift, 0)
        guard let ceiling = fit.ceiling else { return shell }
        var least: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(
            shell, GTK_ORIENTATION_VERTICAL, Self.width, &least, &natural, &ignoredA, &ignoredB)
        guard natural > ceiling else { return shell }
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroll), 1)
        gtk_scrolled_window_set_max_content_height(op(scroll), ceiling)
        gtk_scrolled_window_set_child(op(scroll), shell)
        return scroll
    }
}
