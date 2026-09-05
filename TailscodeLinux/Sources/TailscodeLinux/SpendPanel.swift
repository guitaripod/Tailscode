import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

/// The whole account behind the band's one price: what the conversation cost, which turns were
/// expensive, where the money went between fresh tokens and cache, and which model spent it.
///
/// Every number comes from `SessionSpend`; this file only decides how tall a bar is. The turn
/// chart is the point of the panel — a conversation's cost is never evenly spread, and seeing the
/// three turns that cost more than the other forty is what changes how the next one is asked.
enum SpendPanel {
    private static let chartHeight = 74
    private static let barWidth = 7

    static func present(parent: UnsafeMutablePointer<GtkWidget>?, spend: SessionSpend, title: String) {
        let (window, content) = Dialogs.window(
            title: Localized.text("What this conversation cost"), parent: parent, width: 460)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_box_append(ptr(column), header(spend, title: title))
        if !spend.turns.isEmpty { gtk_box_append(ptr(column), chart(spend)) }
        if !spend.tiers.isEmpty { gtk_box_append(ptr(column), tiers(spend)) }
        if spend.models.count > 1 { gtk_box_append(ptr(column), models(spend)) }
        gtk_box_append(ptr(column), priciest(spend))
        gtk_box_append(
            ptr(column), Gtk.label(spend.source, css: "usage-source", selectable: false))

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(scroller), 620)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_box_append(ptr(content), scroller)

        let windowBits = UInt(bitPattern: window)
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_widget_set_halign(dismiss, GTK_ALIGN_END)
        Gtk.margins(dismiss, top: 4)
        gtk_box_append(ptr(content), dismiss)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)
    }

    /// The number, then the facts that make it mean something. The estimate warning rides directly
    /// under the money rather than at the foot of the panel, because it qualifies the money.
    private static func header(_ spend: SessionSpend, title: String)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")

        let name = Gtk.label(title, css: "usage-plan", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(card), name)

        let money = Gtk.label(spend.badge, css: "spend-total", selectable: false)
        gtk_label_set_ellipsize(op(money), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_halign(money, GTK_ALIGN_START)
        gtk_box_append(ptr(card), money)

        let facts = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        for (label, value) in spend.headline {
            let cell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let amount = Gtk.label(value, css: "usage-detail-value", selectable: false)
            gtk_label_set_xalign(op(amount), 0)
            gtk_box_append(ptr(cell), amount)
            let caption = Gtk.label(label.uppercased(), css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
            gtk_label_set_xalign(op(caption), 0)
            gtk_box_append(ptr(cell), caption)
            gtk_box_append(ptr(facts), cell)
        }
        gtk_box_append(ptr(card), facts)
        return card
    }

    /// One bar per turn, oldest at the left, each as tall as it cost against the priciest. A bar
    /// keeps its width whatever the count, and the row scrolls sideways rather than squeezing a
    /// hundred turns into a smear.
    private static func chart(_ spend: SessionSpend) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(
            ptr(card),
            heading(Localized.text("Turn by turn"), trailing: Localized.text("%@ turns", "\(spend.turnCount)")))

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_widget_set_valign(row, GTK_ALIGN_END)
        for turn in spend.turns {
            let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_set_valign(column, GTK_ALIGN_END)
            let height = max(2, Int(Double(chartHeight) * turn.share))
            let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(bar, turn.share > 0.66 ? "spend-bar-hot" : "spend-bar")
            gtk_widget_set_size_request(bar, Int32(barWidth), Int32(height))
            gtk_widget_set_tooltip_text(bar, tooltip(for: turn))
            gtk_box_append(ptr(column), bar)
            gtk_box_append(ptr(row), column)
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_widget_set_size_request(scroller, -1, Int32(chartHeight + 14))
        gtk_scrolled_window_set_child(op(scroller), row)
        gtk_box_append(ptr(card), scroller)

        if let first = spend.turns.first?.at, let last = spend.turns.last?.at {
            let span = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let start = Gtk.label(Self.clock(first), css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(start), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_hexpand(start, 1)
            gtk_label_set_xalign(op(start), 0)
            gtk_box_append(ptr(span), start)
            let end = Gtk.label(Self.clock(last), css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(end), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(span), end)
            gtk_box_append(ptr(card), span)
        }
        return card
    }

    /// Where the money went: one bar per token tier, priced. This is the section that explains a
    /// long cheap conversation and a short expensive one.
    private static func tiers(_ spend: SessionSpend) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(
            ptr(card),
            heading(
                Localized.text("Where it went"),
                trailing: Localized.text("%@ tokens", StatusFacts.tokens(spend.totalTokens))))
        for tier in spend.tiers {
            gtk_box_append(
                ptr(card),
                meter(
                    label: tier.label, value: SessionSpend.money(tier.costUSD),
                    detail: StatusFacts.tokens(tier.tokens), fraction: tier.share,
                    hot: tier.id == "output"))
        }
        return card
    }

    private static func models(_ spend: SessionSpend) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(Localized.text("Which model"), trailing: nil))
        for model in spend.models {
            gtk_box_append(
                ptr(card),
                meter(
                    label: model.label, value: SessionSpend.money(model.costUSD),
                    detail: Localized.text("%@ turns", "\(model.turns)"), fraction: model.share,
                    hot: false))
        }
        return card
    }

    /// The turns worth remembering, with the words that started them — a bar chart nobody can read
    /// back to a question is a decoration.
    private static func priciest(_ spend: SessionSpend) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(ptr(card), heading(Localized.text("The expensive ones"), trailing: nil))
        let ranked = spend.turns.sorted { $0.costUSD > $1.costUSD }.prefix(5)
        guard !ranked.isEmpty else {
            gtk_box_append(
                ptr(card),
                Gtk.label(Localized.text("Nothing has been spent yet."), css: "dim", selectable: false))
            return card
        }
        for turn in ranked {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let money = Gtk.label(
                SessionSpend.money(turn.costUSD), css: "usage-detail-value", selectable: false)
            gtk_label_set_ellipsize(op(money), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_size_request(money, 56, -1)
            gtk_label_set_xalign(op(money), 0)
            gtk_box_append(ptr(row), money)
            let text = turn.prompt ?? Localized.text("a turn with no prompt of its own")
            let label = Gtk.label(text, css: "usage-detail-key", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(op(label), 0)
            gtk_widget_set_hexpand(label, 1)
            gtk_widget_set_tooltip_text(label, tooltip(for: turn))
            gtk_box_append(ptr(row), label)
            gtk_box_append(ptr(card), row)
        }
        return card
    }

    private static func heading(_ text: String, trailing: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let title = Gtk.label(text, css: "usage-provider", selectable: false)
            // The title yields when the row runs narrow; the count beside it is the fact this
            // card exists to state, so it is never the label that loses its ending.
            gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(op(title), 0)
            gtk_widget_set_hexpand(title, 1)
            gtk_box_append(ptr(row), title)
        if let trailing {
            let caption = Gtk.label(trailing, css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), caption)
        }
        return row
    }

    private static func meter(
        label: String, value: String, detail: String, fraction: Double, hot: Bool
    ) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(label, css: "usage-gauge-label", selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_widget_set_hexpand(name, 1)
        gtk_box_append(ptr(row), name)
        let count = Gtk.label(detail, css: "spend-caption", selectable: false)
        gtk_label_set_ellipsize(op(count), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), count)
        let money = Gtk.label(value, css: "usage-detail-value", selectable: false)
        gtk_label_set_ellipsize(op(money), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), money)
        gtk_box_append(ptr(block), row)

        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(track, "gauge-track")
        gtk_widget_set_size_request(track, Int32(UsagePanel.trackWidth), 6)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(fill, hot ? "spend-bar-hot" : "spend-bar")
        let width = max(2, Int(Double(UsagePanel.trackWidth) * min(max(fraction, 0), 1)))
        gtk_widget_set_size_request(fill, Int32(width), 6)
        gtk_widget_set_halign(fill, GTK_ALIGN_START)
        gtk_box_append(ptr(track), fill)
        gtk_box_append(ptr(block), track)
        return block
    }

    private static func tooltip(for turn: SessionSpend.Turn) -> String {
        var parts = [SessionSpend.money(turn.costUSD), StatusFacts.tokens(turn.tokens) + " tokens"]
        if let seconds = turn.seconds { parts.append(SessionSpend.duration(seconds)) }
        if let model = turn.model { parts.append(ModelBadge.shortName(model)) }
        if let prompt = turn.prompt { parts.append(prompt) }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
