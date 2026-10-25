import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The theme catalog as cards: each draws its own canvas, a sliver of chat list, two lines of text
/// and the four signals, in the face the window is wearing right now. A theme is a look, and a
/// name and a sentence are a poor way to choose one.
final class ThemeSwatchGrid: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let caption: UnsafeMutablePointer<GtkWidget>

    var captionWidget: UnsafeMutablePointer<GtkWidget> { caption }
    private var cards: [(theme: AppTheme, button: UnsafeMutablePointer<GtkWidget>, canvas: AgentsCanvas)] = []
    private let onPick: @Sendable (AppTheme) -> Void

    init(selected: String, onPick: @escaping @Sendable (AppTheme) -> Void) {
        self.onPick = onPick
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, 12)
        let flow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(op(flow), 1)
        gtk_flow_box_set_min_children_per_line(op(flow), 2)
        gtk_flow_box_set_max_children_per_line(op(flow), 4)
        gtk_flow_box_set_column_spacing(op(flow), 6)
        gtk_flow_box_set_row_spacing(op(flow), 6)
        gtk_box_append(ptr(column), flow)
        caption = Gtk.label("", css: "theme-caption", wrap: true, selectable: false)
        gtk_box_append(ptr(column), caption)
        widget = column
        for theme in AppTheme.all {
            let card = makeCard(theme)
            cards.append(card)
            gtk_flow_box_append(op(flow), card.button)
        }
        select(selected)
    }

    func select(_ id: String) {
        for card in cards {
            if card.theme.id == id {
                gtk_widget_add_css_class(card.button, "theme-swatch-selected")
                gtk_label_set_text(
                    op(caption), "\(card.theme.name) — \(card.theme.blurb)")
            } else {
                gtk_widget_remove_css_class(card.button, "theme-swatch-selected")
            }
        }
    }

    /// The window flipped between its light and dark faces: every card shows the other one.
    func repaint() {
        for card in cards { card.canvas.redraw() }
    }

    private func makeCard(_ theme: AppTheme)
        -> (theme: AppTheme, button: UnsafeMutablePointer<GtkWidget>, canvas: AgentsCanvas)
    {
        let canvas = AgentsCanvas(width: 148, height: 76)
        canvas.paint = { cr, width, height in Self.paint(theme, cr, width, height) }
        let name = Gtk.label(theme.name, css: "theme-swatch-name", wrap: false, selectable: false)
        gtk_widget_set_halign(name, GTK_ALIGN_CENTER)
        let stack = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(stack), canvas.widget)
        gtk_box_append(ptr(stack), name)
        let button = gtk_button_new()!
        gtk_button_set_child(ptr(button), stack)
        gtk_widget_add_css_class(button, "theme-swatch")
        gtk_widget_set_tooltip_text(button, theme.blurb)
        let pick = onPick
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            pick(theme)
            self?.select(theme.id)
        }
        return (theme, button, canvas)
    }

    private static func paint(_ theme: AppTheme, _ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        let palette = theme.palette(dark: dark).corrected()
        let ink = { (hex: String) in PartyInk(hex: hex) }
        agentsRoundedRect(cr, x: 0, y: 0, width: width, height: height, radius: 10)
        ink(palette.canvas).set(cr)
        cairo_fill(cr)
        agentsRoundedRect(cr, x: 0.5, y: 0.5, width: width - 1, height: height - 1, radius: 10)
        ink(palette.rule).set(cr)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        let railWidth = width * 0.27
        agentsRoundedRect(cr, x: 7, y: 7, width: railWidth, height: height - 14, radius: 6)
        ink(palette.canvasRaised).set(cr)
        cairo_fill(cr)
        for row in 0..<3 {
            let y = 15 + Double(row) * 12
            agentsRoundedRect(
                cr, x: 13, y: y, width: railWidth - 12, height: 4, radius: 2)
            ink(row == 0 ? palette.accent : palette.textDim).set(cr, alpha: row == 0 ? 1 : 0.55)
            cairo_fill(cr)
        }

        let left = 7 + railWidth + 10
        let room = width - left - 10
        agentsRoundedRect(cr, x: left, y: 14, width: room * 0.7, height: 5, radius: 2.5)
        ink(palette.text).set(cr, alpha: 0.9)
        cairo_fill(cr)
        agentsRoundedRect(cr, x: left, y: 26, width: room * 0.92, height: 4, radius: 2)
        ink(palette.textDim).set(cr, alpha: 0.7)
        cairo_fill(cr)
        agentsRoundedRect(cr, x: left, y: 34, width: room * 0.55, height: 4, radius: 2)
        ink(palette.textDim).set(cr, alpha: 0.7)
        cairo_fill(cr)
        agentsRoundedRect(cr, x: left, y: 46, width: room * 0.34, height: 10, radius: 5)
        ink(palette.accent).set(cr)
        cairo_fill(cr)

        let dots = [palette.warn, palette.danger, palette.info, palette.special]
        for (index, hex) in dots.enumerated() {
            cairo_arc(cr, left + 4 + Double(index) * 13, height - 12, 3.6, 0, 2 * .pi)
            ink(hex).set(cr)
            cairo_fill(cr)
        }
    }
}
