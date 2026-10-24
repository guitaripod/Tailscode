import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The three figures under a peek: how much of the context window is in use, the tokens this turn
/// took, and an API-equivalent estimate of what they would cost, which says it is one.
final class AgentsMeters: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let ring = AgentsCanvas(width: 36, height: 36)
    private let fillValue = Gtk.label("", css: "agents-meter-value", selectable: false)
    private let fillCaption = Gtk.label("", css: "agents-meter-caption", wrap: true, selectable: false)
    private let tokensValue = Gtk.label("", css: "agents-meter-value", selectable: false)
    private let tokensCaption = Gtk.label("", css: "agents-meter-caption", wrap: true, selectable: false)
    private let costValue = Gtk.label("", css: "agents-meter-value", selectable: false)
    private let costCaption = Gtk.label("", css: "agents-meter-caption", wrap: true, selectable: false)
    private let fillBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let tokensBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let costBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private var fraction = 0.0
    private var tone: ActivityTone = .live
    private(set) var spoken = ""

    var fillText: String { gtk_label_get_text(op(fillValue)).map { String(cString: $0) } ?? "" }
    var costText: String { gtk_label_get_text(op(costValue)).map { String(cString: $0) } ?? "" }
    var costCaptionText: String { gtk_label_get_text(op(costCaption)).map { String(cString: $0) } ?? "" }
    var hasCost: Bool { gtk_widget_get_visible(costBox) != 0 }

    init() {
        gtk_label_set_wrap_mode(op(fillCaption), PANGO_WRAP_WORD)
        gtk_label_set_wrap_mode(op(tokensCaption), PANGO_WRAP_WORD)
        gtk_label_set_wrap_mode(op(costCaption), PANGO_WRAP_WORD)
        for (box, value, caption) in [(tokensBox, tokensValue, tokensCaption), (costBox, costValue, costCaption)] {
            Gtk.addClass(box, "agents-meter")
            gtk_box_append(ptr(box), value)
            gtk_box_append(ptr(box), caption)
        }
        Gtk.addClass(fillBox, "agents-meter")
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(ring.widget, GTK_ALIGN_START)
        gtk_box_append(ptr(words), fillValue)
        gtk_box_append(ptr(words), fillCaption)
        gtk_box_append(ptr(fillBox), ring.widget)
        gtk_box_append(ptr(fillBox), words)
        widget = Gtk.wrapRow([fillBox, tokensBox, costBox], spacing: 8)
        ring.paint = { [weak self] cr, width, height in self?.paintRing(cr, width: width, height: height) }
        gtk_widget_set_can_target(ring.widget, 0)
        tailscode_set_accessible_hidden(ring.widget, 1)
    }

    func apply(_ facts: AgentFacts) {
        let fill = facts.fill.flatMap { $0.used > 0 ? $0 : nil }
        AgentsParts.setVisible(fillBox, fill != nil)
        if let fill {
            let next = fill.fraction ?? 0
            let nextTone = Self.tone(fill.tone)
            if next != fraction || nextTone != tone {
                fraction = next
                tone = nextTone
                ring.redraw()
            }
            AgentsParts.setText(
                fillValue,
                fill.percent.map { $0 == 0 ? "<1%" : "\($0)%" }
                    ?? StatusFacts.tokens(fill.used))
            AgentsParts.setText(
                fillCaption,
                fill.percent != nil ? Localized.text("of context") : Localized.text("in context"))
        }
        AgentsParts.setVisible(tokensBox, facts.tokens != nil)
        if let tokens = facts.tokens {
            AgentsParts.setText(tokensValue, StatusFacts.tokens(tokens))
            AgentsParts.setText(tokensCaption, Localized.text("tokens this turn"))
        }
        AgentsParts.setVisible(costBox, facts.cost != nil)
        if let cost = facts.cost {
            AgentsParts.setText(costValue, "≈ " + SessionSpend.money(cost))
            AgentsParts.setText(costCaption, Localized.text("API estimate"))
        }
        var words: [String] = []
        if let fill {
            words.append(
                fill.percent.map { Localized.text("%d%% of the context window in use", $0) }
                    ?? Localized.text("%@ tokens in context", StatusFacts.tokens(fill.used)))
        }
        if let tokens = facts.tokens {
            words.append(Localized.text("%@ tokens this turn", StatusFacts.tokens(tokens)))
        }
        if let cost = facts.cost {
            words.append(Localized.text("about %@, an API estimate", SessionSpend.money(cost)))
        }
        spoken = words.joined(separator: ", ")
        tailscode_set_accessible_label(widget, spoken)
        AgentsParts.setVisible(widget, !words.isEmpty)
    }

    private static func tone(_ tone: ContextFill.Tone) -> ActivityTone {
        switch tone {
        case .quiet: return .live
        case .attention: return .attention
        case .danger: return .danger
        }
    }

    private func paintRing(_ cr: OpaquePointer, width: Double, height: Double) {
        let inks = AgentsInks()
        let centre = (width / 2, height / 2)
        let radius = min(width, height) / 2 - 3
        cairo_set_line_width(cr, 4)
        cairo_new_path(cr)
        cairo_arc(cr, centre.0, centre.1, radius, 0, 2 * .pi)
        inks.quiet.set(cr, alpha: 0.3)
        cairo_stroke(cr)
        guard fraction > 0 else { return }
        cairo_new_path(cr)
        cairo_arc(cr, centre.0, centre.1, radius, -.pi / 2, -.pi / 2 + 2 * .pi * fraction)
        inks.ink(tone).set(cr)
        cairo_stroke(cr)
    }
}
