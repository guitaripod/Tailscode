import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The pace-bar grammar drawn in GTK: a solid fill for what has been used, a tick where an even
/// burn would be by now, and a hatched tail where the fill lands if nothing changes. Every word
/// and number is ``PaceRow``'s; this file decides only which ink each mark wears and how a row of
/// them is stacked.
enum PaceBar {
    static let tickOverhang: Int32 = 4

    /// The bar alone, drawn against whatever width its container gives it. A glance surface draws
    /// the tail only when it carries news; an opened one always draws it.
    static func make(
        _ row: PaceRow, height: Double, glance: Bool, background: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let area = tailscode_meter_new()!
        gtk_widget_set_hexpand(area, 1)
        let fill = rgb(fillInk(row, palette: palette))
        [fill.red, fill.green, fill.blue].withUnsafeBufferPointer {
            tailscode_meter_set(area, row.fill, $0.baseAddress, 0.12, height)
        }
        let showsTail = row.tailEnd != nil && (!glance || row.tailIsNews)
        guard row.tick != nil || showsTail else { return area }
        let tick = rgb(palette.text)
        let outline = rgb(background ?? palette.canvasRaised)
        let tail = rgb(tailInk(row, palette: palette))
        [tick.red, tick.green, tick.blue].withUnsafeBufferPointer { tickBuffer in
            [outline.red, outline.green, outline.blue].withUnsafeBufferPointer { outlineBuffer in
                [tail.red, tail.green, tail.blue].withUnsafeBufferPointer { tailBuffer in
                    tailscode_meter_set_pace(
                        area, row.tick ?? -1, row.tickApproximate ? 1 : 0,
                        tickBuffer.baseAddress, outlineBuffer.baseAddress,
                        showsTail ? (row.tailEnd ?? -1) : -1, tailBuffer.baseAddress)
                }
            }
        }
        return area
    }

    /// One tank as one row of an opened surface: its name and what it is on the left, the figure on
    /// the right, the bar, and under it the one line the pace owes when it is news (or the quiet
    /// remark, when there is no news). A row on pace is the two lines it always was.
    static func row(
        _ row: PaceRow, amount override: String? = nil, trailing: String? = nil,
        background: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(row.title, css: "usage-gauge-label", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(head), title)
        if !row.detail.isEmpty {
            let detail = Gtk.label(row.detail, css: "usage-plan", selectable: false)
            gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)
            gtk_widget_set_hexpand(detail, 1)
            gtk_box_append(ptr(head), detail)
        } else {
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(head), spacer)
        }
        let amount = Gtk.label(override ?? row.amount, css: amountClass(row), selectable: false)
        gtk_label_set_ellipsize(op(amount), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(head), amount)
        gtk_box_append(ptr(block), head)

        if row.kind != .balance {
            gtk_box_append(ptr(block), make(row, height: 6, glance: false, background: background))
        }
        if let line = words(row, trailing: trailing) { gtk_box_append(ptr(block), line) }
        gtk_widget_set_opacity(block, row.dimmed ? 0.62 : 1)
        tailscode_set_accessible_label(block, row.accessibilityLabel)
        return block
    }

    /// The pace's word for a window, where it has one: the verdict the tail and the tick add up to.
    static func verdictWord(_ row: PaceRow) -> String? {
        if row.amount == Localized.text("Used up") { return Localized.text("Used up") }
        if let news = row.news {
            switch news.tone {
            case .danger: return Localized.text("Used up")
            case .attention:
                return news.lead == Localized.text("Wall")
                    ? Localized.text("Will run out") : Localized.text("Mind the pace")
            case .quiet: return nil
            }
        }
        return row.tick == nil ? nil : Localized.text("On pace")
    }

    /// The one line of news a row owes, or nothing when the row is on pace.
    static func newsLine(_ row: PaceRow) -> UnsafeMutablePointer<GtkWidget>? {
        row.news == nil ? nil : words(row, trailing: nil)
    }

    /// The line under a bar: the news in its tone, or the note in the quiet ink, or the caller's own
    /// caption when there is neither.
    private static func words(_ row: PaceRow, trailing: String?)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        let palette = MatrixTheme.palette
        if let news = row.news {
            let hex: String
            switch news.tone {
            case .quiet: hex = palette.textDim
            case .attention: hex = palette.warn
            case .danger: hex = palette.danger
            }
            let lead = PangoMarkdown.escape(news.lead.uppercased())
            let body = PangoMarkdown.escape(news.body)
            let label = Gtk.label("", css: "gauge-news", wrap: true, selectable: false)
            gtk_label_set_markup(
                op(label),
                "<span foreground='\(hex)' weight='bold' size='small' letter_spacing='600'>\(lead)</span>  \(body)"
            )
            return label
        }
        if let note = row.note ?? trailing {
            return Gtk.label(note, css: "gauge-reset", wrap: true, selectable: false)
        }
        return nil
    }

    private static func amountClass(_ row: PaceRow) -> String {
        switch row.tone {
        case .quiet: return row.kind == .balance ? "usage-detail-value" : "gauge-ok"
        case .attention: return "gauge-warn"
        case .danger: return "gauge-danger"
        }
    }

    private static func fillInk(_ row: PaceRow, palette: Palette) -> String {
        switch row.tone {
        case .quiet: return brand(row, palette: palette)
        case .attention: return palette.warn
        case .danger: return palette.danger
        }
    }

    private static func tailInk(_ row: PaceRow, palette: Palette) -> String {
        row.tailTone == .attention ? palette.warn : brand(row, palette: palette)
    }

    private static func brand(_ row: PaceRow, palette: Palette) -> String {
        guard let slug = row.slug else {
            return row.kind == .context ? palette.accent : palette.accentDim
        }
        switch slug {
        case "claude": return palette.brandClaude
        case "opencode": return palette.brandOpencode
        case "omp": return MatrixTheme.brandOmp(in: palette)
        case "grok": return palette.brandGrok
        case "deepseek": return palette.brandDeepseek
        case "ollama-cloud": return palette.brandOllama
        default: return palette.accentDim
        }
    }

    private static func rgb(_ hex: String) -> PresenceRGB {
        PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
    }
}
