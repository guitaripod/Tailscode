import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A view the board keeps by identity and tells the time to.
protocol AgentsItemView: AnyObject {
    var widget: UnsafeMutablePointer<GtkWidget> { get }
    func tick(now: Date)
    func setSelected(_ selected: Bool)
}

/// The small pieces more than one board view is made of, so a glyph, an age and a dimmed machine
/// read the same on a card, a row and the peek.
enum AgentsParts {
    private static let toneClasses = ["glyph-running", "glyph-needs", "glyph-error", "glyph-pending"]

    static func glyph() -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label("●", css: "agents-glyph", selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_START)
        tailscode_set_accessible_hidden(label, 1)
        return label
    }

    /// The state's glyph in its tone, moving the way the state moves and standing still where it
    /// is settled or the desk asked for less movement.
    static func settleGlyph(
        _ label: UnsafeMutablePointer<GtkWidget>, tone: ActivityTone, motion: ActivityMotion
    ) {
        Gtk.setTone(label, tone.glyphCSS, from: toneClasses)
        guard motion.isAnimated else {
            ActivityPulse.apply(nil, to: label)
            gtk_label_set_text(op(label), "●")
            return
        }
        var sweeps = false
        if case .sweep = motion { sweeps = true }
        let icon = ActivityIcon(
            symbol: "circle.fill", glyph: sweeps ? ActivityIcon.sweepCycle[0] : "●",
            cycle: sweeps ? ActivityIcon.sweepCycle : [], tone: tone, motion: motion)
        ActivityPulse.apply(icon, to: label)
    }

    /// A finished turn's mark: a tick, a cross, a stop or a dot, each its own shape so the outcome
    /// never rests on its colour.
    static func finishGlyph(_ outcome: AgentFinish.Outcome) -> (glyph: String, tone: ActivityTone) {
        switch outcome {
        case .done: return (StatusMark.done, .live)
        case .failed: return (StatusMark.failed, .danger)
        case .stopped: return ("■", .quiet)
        case .unknown: return (StatusMark.idle, .quiet)
        }
    }

    static func outcomeGlyph(_ outcome: AgentOutcome) -> (glyph: String, tone: ActivityTone) {
        switch outcome {
        case .running: return ("◐", .live)
        case .done: return (StatusMark.done, .quiet)
        case .failed: return (StatusMark.failed, .danger)
        case .stopped: return ("■", .quiet)
        }
    }

    static func setText(_ label: UnsafeMutablePointer<GtkWidget>, _ text: String) {
        guard let current = gtk_label_get_text(op(label)), String(cString: current) == text else {
            gtk_label_set_text(op(label), text)
            return
        }
    }

    static func setVisible(_ widget: UnsafeMutablePointer<GtkWidget>, _ visible: Bool) {
        gtk_widget_set_visible(widget, visible ? 1 : 0)
    }

    static func setClass(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ name: String, _ on: Bool
    ) {
        if on {
            gtk_widget_add_css_class(widget, name)
        } else {
            gtk_widget_remove_css_class(widget, name)
        }
    }

    static func clearChildren(_ box: UnsafeMutablePointer<GtkWidget>) {
        Gtk.removeChildren(of: box)
    }

    /// How long ago, in the units the rest of the app uses, floored at a second.
    static func age(_ date: Date, now: Date) -> String {
        StatusFacts.age(max(0, now.timeIntervalSince(date)))
    }

    /// How long a clock has run: seconds under a minute, then minutes and seconds.
    static func clock(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        return seconds >= 3600 ? StatusFacts.age(seconds) : StatusFacts.clock(seconds)
    }

    /// The line under a dimmed card or row: the machine stopped answering, and since when.
    static func awayLine(profileID: String, now: Date) -> String {
        if let heard = AgentsRuntime.shared.lastSeen(profileID) {
            return Localized.text("Not answering · last seen %@ ago", age(heard, now: now))
        }
        return Localized.text("Not answering")
    }

    static func machineLine(_ machine: String) -> String { machine }

    static func monospaced(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "agents-object", wrap: true, selectable: true)
        gtk_label_set_xalign(op(label), 0)
        gtk_widget_set_hexpand(label, 1)
        return label
    }

    /// A button whose words wrap rather than push the card wider, for an option as long as a
    /// sentence.
    static func wrappingButton(
        _ title: String, css: [String], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        for name in css { Gtk.addClass(button, name) }
        let label = Gtk.label(title, wrap: true, selectable: false)
        gtk_label_set_justify(op(label), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(label), 0.5)
        gtk_label_set_max_width_chars(op(label), 48)
        gtk_button_set_child(ptr(button), label)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
    }

    static func setButtonTitle(_ button: UnsafeMutablePointer<GtkWidget>, _ title: String) {
        guard let child = gtk_button_get_child(ptr(button)), tailscode_is_label(child) != 0 else {
            return
        }
        setText(child, title)
    }

    static func buttonTitle(_ button: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let child = gtk_button_get_child(ptr(button)), tailscode_is_label(child) != 0,
            let text = gtk_label_get_text(op(child))
        else { return "" }
        return String(cString: text)
    }
}
