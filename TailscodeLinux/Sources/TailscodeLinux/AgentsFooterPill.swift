import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The pill at the foot of the sidebar: how many agents run, with a small living orb, in the
/// words the Agents card above uses. Dim and still when all is quiet, amber when something waits
/// on the person. One press opens the board.
final class AgentsFooterPill: @unchecked Sendable {
    let widget = gtk_button_new()!
    let orb = AgentsMiniOrb(size: 16)
    private let text = Gtk.label("", css: "agents-pill-text", selectable: false)
    private(set) var mood: AgentsMood = .idle

    var shownText: String { gtk_label_get_text(op(text)).map { String(cString: $0) } ?? "" }

    init(open: @escaping @Sendable () -> Void) {
        Gtk.addClass(widget, "flat")
        Gtk.addClass(widget, "agents-pill")
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(line), orb.widget)
        gtk_box_append(ptr(line), text)
        gtk_button_set_child(ptr(widget), line)
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        Gtk.margins(widget, top: 6, bottom: 0, leading: 10, trailing: 10)
        gtk_widget_set_tooltip_text(widget, Localized.text("What every agent is doing · Ctrl+Shift+A"))
        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { Gtk.onMain { open() } }
        apply(.quiet)
    }

    func apply(_ reading: AgentsReading) {
        mood = reading.mood
        orb.set(mood: mood)
        AgentsParts.setText(text, reading.footerText)
        Gtk.setTone(widget, "agents-pill-" + Self.suffix(mood), from: AgentsMood.pillClasses)
        tailscode_set_accessible_label(widget, Localized.text("Agents") + ", " + reading.footerText)
    }

    private static func suffix(_ mood: AgentsMood) -> String {
        switch mood {
        case .idle: return "idle"
        case .working: return "working"
        case .needs: return "needs"
        }
    }
}

extension AgentsMood {
    static let pillClasses = ["agents-pill-idle", "agents-pill-working", "agents-pill-needs"]
}
