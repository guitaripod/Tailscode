import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What a beta card says and in what order, decided before any widget exists so the order is a
/// claim a harness can check. Every word is the catalog's; this only arranges them.
enum BetaCardLayout {
    enum Kind: Equatable {
        case solid
        case rough
    }

    enum Block: Equatable {
        case title(String)
        case lead(String)
        case since(heading: String, lines: [String])
        case paragraph(String)
        case list(kind: Kind, heading: String, lines: [String])
    }

    static func blocks(for card: BetaCard, freshness: BetaFreshness) -> [Block] {
        var blocks: [Block] = [.title(card.title), .lead(card.lead)]
        if freshness == .changed, !card.changes.isEmpty {
            blocks.append(.since(heading: BetaWords.sinceYouLastLooked, lines: card.changes.map(\.line)))
        }
        blocks += card.paragraphs.map(Block.paragraph)
        if !card.works.isEmpty {
            blocks.append(.list(kind: .solid, heading: BetaWords.solid, lines: card.works))
        }
        if !card.rough.isEmpty {
            blocks.append(.list(kind: .rough, heading: BetaWords.rough, lines: card.rough))
        }
        return blocks
    }

    static func glyph(_ kind: Kind) -> String {
        switch kind {
        case .solid: return "✓"
        case .rough: return "•"
        }
    }
}

/// The card behind a beta mark: the title with the mark, the lead, what changed since the person
/// last looked, the paragraphs, the two lists and the two actions. It is built afresh each time the
/// card opens, so what it leads with is what was true at that moment.
final class BetaCardView: @unchecked Sendable {
    static let width: Int32 = 460

    let widget: UnsafeMutablePointer<GtkWidget>
    let gotIt: UnsafeMutablePointer<GtkWidget>
    private let copy: UnsafeMutablePointer<GtkWidget>
    private var copiedTicket = 0

    init(
        card: BetaCard, freshness: BetaFreshness, onCopy: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        for block in BetaCardLayout.blocks(for: card, freshness: freshness) {
            gtk_box_append(ptr(column), Self.view(of: block))
        }
        let scroller = Gtk.boundedScroller(column, minimum: 0, maximum: 680)
        Gtk.margins(column, top: 14, bottom: 6, leading: 16, trailing: 16)

        copy = Gtk.button(BetaWords.copyReport, css: ["flat"], onClick: onCopy)
        gotIt = Gtk.button(BetaWords.gotIt, css: ["suggested-action"], onClick: onClose)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        Gtk.margins(actions, top: 10, bottom: 12, leading: 16, trailing: 16)
        gtk_box_append(ptr(actions), copy)
        gtk_box_append(ptr(actions), gotIt)

        widget = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 0, spoken: card.title)
        gtk_widget_set_size_request(widget, Self.width, -1)
        gtk_box_append(ptr(widget), scroller)
        gtk_box_append(ptr(widget), Gtk.hairline())
        gtk_box_append(ptr(widget), actions)
    }

    /// The button says the report is on the pasteboard for a moment, then goes back to offering it.
    func markCopied() {
        gtk_button_set_label(ptr(copy), BetaWords.reportCopied)
        copiedTicket += 1
        let ticket = copiedTicket
        Gtk.after(1500) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.copiedTicket == ticket else { return }
                gtk_button_set_label(ptr(self.copy), BetaWords.copyReport)
            }
        }
    }

    var copyLabel: String {
        gtk_button_get_label(ptr(copy)).map { String(cString: $0) } ?? ""
    }

    var text: String { Gtk.spokenText(of: widget) }

    private static func view(of block: BetaCardLayout.Block) -> UnsafeMutablePointer<GtkWidget> {
        switch block {
        case .title(let title):
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let label = Gtk.label(title, css: "beta-card-title", wrap: true, selectable: false)
            gtk_widget_set_hexpand(label, 1)
            gtk_box_append(ptr(row), label)
            gtk_box_append(ptr(row), mark())
            return row
        case .lead(let lead):
            return body(lead, css: "beta-card-lead")
        case .paragraph(let paragraph):
            return body(paragraph, css: "beta-card-body")
        case .since(let heading, let lines):
            return since(heading: heading, lines: lines)
        case .list(let kind, let heading, let lines):
            return list(kind: kind, heading: heading, lines: lines)
        }
    }

    /// The same capsule the title wears elsewhere, still: the card is where it is read, not where it
    /// is announced.
    private static func mark() -> UnsafeMutablePointer<GtkWidget> {
        let capsule = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(capsule, "beta-badge")
        Gtk.addClass(capsule, "beta-badge-static")
        gtk_widget_set_valign(capsule, GTK_ALIGN_CENTER)
        let label = Gtk.label(BetaWords.badge, selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(capsule), label)
        tailscode_set_accessible_hidden(capsule, 1)
        return capsule
    }

    private static func body(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: css, wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_label_set_max_width_chars(op(label), 70)
        return label
    }

    private static func since(heading: String, lines: [String]) -> UnsafeMutablePointer<GtkWidget> {
        let panel = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(panel, "beta-card-since")
        gtk_box_append(ptr(panel), Gtk.label(heading, css: "dg-section", selectable: false))
        for line in lines { gtk_box_append(ptr(panel), body(line, css: "beta-card-body")) }
        return panel
    }

    private static func list(
        kind: BetaCardLayout.Kind, heading: String, lines: [String]
    ) -> UnsafeMutablePointer<GtkWidget> {
        let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_box_append(ptr(section), Gtk.label(heading, css: "dg-section", selectable: false))
        let items = tailscode_box_new_with_role(GTK_ORIENTATION_VERTICAL, 4, GTK_ACCESSIBLE_ROLE_LIST)!
        tailscode_set_accessible_label(items, heading)
        for line in lines {
            let item = tailscode_box_new_with_role(
                GTK_ORIENTATION_HORIZONTAL, 8, GTK_ACCESSIBLE_ROLE_LIST_ITEM)!
            let glyph = Gtk.label(
                BetaCardLayout.glyph(kind), css: kind == .solid ? "beta-glyph-solid" : "beta-glyph-rough",
                selectable: false)
            gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(glyph, GTK_ALIGN_START)
            gtk_widget_set_size_request(glyph, 14, -1)
            tailscode_set_accessible_hidden(glyph, 1)
            gtk_box_append(ptr(item), glyph)
            gtk_box_append(ptr(item), body(line, css: "beta-card-body"))
            gtk_box_append(ptr(items), item)
        }
        gtk_box_append(ptr(section), items)
        return section
    }
}
