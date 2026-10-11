import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The panes a window cannot show right now, named along the bottom of the canvas: zoomed away,
/// or stepped aside because the window is too small for every pane at its minimum.
///
/// Each is a chip — the activity face, the title cut to eighteen characters, a dot when the turn is
/// waiting on the person — and pressing one goes to that pane: out of the zoom, or swapped in for
/// the pane focused longest ago. Chips that do not fit become a count. On Linux it is a plain bar
/// in the palette, 28 points tall.
final class OverflowStrip: @unchecked Sendable {
    struct Chip: Equatable {
        let id: PaneID
        let title: String
        let activity: ActivityKind?
        let needsYou: Bool
    }

    let widget = tailscode_tile_clamp_new()!
    var onPress: ((PaneID) -> Void)?

    private let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let more = Gtk.label("", css: "tile-strip-more", selectable: false)
    private var built: [(chip: Chip, button: UnsafeMutablePointer<GtkWidget>)] = []
    private(set) var chips: [Chip] = []
    private(set) var hiddenCount = 0
    private var fitted = -1.0

    static let titleLimit = 18

    init() {
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        Gtk.addClass(widget, "tile-strip")
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(row, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(row, GTK_ALIGN_START)
        Gtk.margins(row, leading: 8)
        gtk_widget_set_valign(more, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(more, 0)
        gtk_box_append(ptr(row), more)
        tailscode_tile_clamp_add(widget, row)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    /// Shows these chips, rebuilding only when they changed, and as many as `width` holds.
    func show(_ next: [Chip], width: Double) {
        if next != chips {
            chips = next
            for entry in built { gtk_box_remove(ptr(row), entry.button) }
            built = []
            for chip in next {
                let button = makeChip(chip)
                gtk_box_insert_child_after(ptr(row), button, built.last?.button ?? nil)
                built.append((chip, button))
            }
            tailscode_set_accessible_label(widget, Localized.text("%@ more", "\(next.count)"))
            fitted = -1
        }
        fit(width: width)
    }

    /// Hides the chips past the strip's width and says how many.
    private func fit(width: Double) {
        guard width != fitted else { return }
        fitted = width
        let room = width - 8 - 70
        var used = 0.0
        var hidden = 0
        for entry in built {
            let natural = Gtk.naturalSize(of: entry.button).width + 6
            if used + natural > room {
                gtk_widget_set_visible(entry.button, 0)
                hidden += 1
            } else {
                gtk_widget_set_visible(entry.button, 1)
                used += natural
            }
        }
        hiddenCount = hidden
        gtk_label_set_text(op(more), Localized.text("%@ more", "\(hidden)"))
        gtk_widget_set_visible(more, hidden == 0 ? 0 : 1)
    }

    private func makeChip(_ chip: Chip) -> UnsafeMutablePointer<GtkWidget> {
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        if let activity = chip.activity {
            let icon = activity.icon
            let glyph = Gtk.label(icon.glyph, css: "glance-glyph", selectable: false)
            Gtk.setTone(glyph, icon.tone.glyphCSS, from: GlanceTile.tones)
            gtk_box_append(ptr(content), glyph)
        }
        gtk_box_append(
            ptr(content), Gtk.label(Self.cut(chip.title), css: "tile-chip-title", selectable: false))
        if chip.needsYou {
            gtk_box_append(ptr(content), Gtk.label("●", css: "tile-chip-dot", selectable: false))
        }
        let id = chip.id
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "tile-chip")
        gtk_button_set_child(ptr(button), content)
        gtk_widget_set_tooltip_text(button, chip.title)
        tailscode_set_accessible_label(
            button, [chip.title, chip.activity?.spoken].compactMap { $0 }.joined(separator: ", "))
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onPress?(id) }
        }
        return button
    }

    static func cut(_ title: String) -> String {
        title.count > titleLimit ? String(title.prefix(titleLimit - 1)) + "…" : title
    }

    func press(_ id: PaneID) {
        onPress?(id)
    }

    func button(for id: PaneID) -> UnsafeMutablePointer<GtkWidget>? {
        built.first { $0.chip.id == id }?.button
    }

    var visibleChips: Int { built.filter { gtk_widget_get_visible($0.button) != 0 }.count }
}
