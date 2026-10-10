import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What one tile of the shelf says, decided by whoever owns the thing it stands for. The shelf
/// itself knows nothing about pictures or clips: it lays tiles out, keeps the ones that did not
/// change, asks for a thumbnail only for the ones in view, and tells its owner what was pressed.
struct StudioTile: Sendable, Equatable {
    let id: String
    var inFlight = false
    /// A word in the tile's corner: the sampler's step while it paints, a clip's length once made.
    var badge: String?
    /// The sliver along the foot of the tile that is still being made.
    var progress: Double?
    /// A glyph for a tile that has no picture of its own.
    var glyph: String?
    /// The words that made it and what it is, which is what a screen reader reads.
    var words = ""
    var tooltip: String?
}

/// The Studio's shelf: everything the machine has made and this session has added, as a rail down
/// the right of a roomy pane and as a strip above the dock in a narrow one. One view serves both
/// by turning, never by being rebuilt, so the tile a person is looking at is the same tile after
/// the pane is resized under it.
///
/// A shelf may hold hundreds of pictures. Every tile is a light button; a tile gets a picture only
/// while it is within a few tiles of the eye, and gives it back when it leaves — so memory follows
/// what is on screen, and a thumbnail is decoded off the main loop only once somebody can see it.
/// The shelf never holds a texture of its own: a tile's picture is built from whatever the owner
/// hands over at the moment it is wanted.
final class StudioShelfView: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
    private let heading = Gtk.label("", css: "draw-shelf-heading", selectable: false)
    private let refresh: UnsafeMutablePointer<GtkWidget>
    private let note = Gtk.label("", css: "draw-shelf-note", wrap: false, selectable: false)
    private let scroller = gtk_scrolled_window_new()!
    private let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private struct Slot {
        let revealer: UnsafeMutablePointer<GtkWidget>
        let button: UnsafeMutablePointer<GtkWidget>
        let art: UnsafeMutablePointer<GtkWidget>
        let badge: UnsafeMutablePointer<GtkWidget>
        let sliver: UnsafeMutablePointer<GtkWidget>
        let glyph: UnsafeMutablePointer<GtkWidget>
        var picture: UnsafeMutablePointer<GtkWidget>?
        var tile: StudioTile
    }

    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private var rail = true
    private var selected: String?
    private var rangePending = false
    private var hoverID: String?
    private let metrics: StudioMetrics

    var onChoose: (@Sendable (String) -> Void)?
    var onMenu: (@Sendable (String, UnsafeMutablePointer<GtkWidget>, Double, Double) -> Void)?
    var onRefresh: (@Sendable () -> Void)?
    /// Told which tiles are near the eye, so the owner decodes exactly those thumbnails.
    var onWant: (@Sendable ([String]) -> Void)?
    /// The decoded thumbnail for a tile, asked for at the moment it is drawn; zero when the owner
    /// has none yet. Never remembered here: a texture the owner let go of is not one to draw.
    var thumbnail: (@Sendable (String) -> UInt)?
    /// The local file behind a tile, when this device holds it, for a drag out.
    var dragPath: (@Sendable (String) -> String?)?
    /// The pointer settled on a tile: a moment to fetch the original a drag will want.
    var onHover: (@Sendable (String) -> Void)?

    init(metrics: StudioMetrics = .pane) {
        self.metrics = metrics
        refresh = Gtk.button("⟳", css: ["flat", "draw-shelf-refresh"], onClick: {})
        build()
    }

    private func build() {
        Gtk.addClass(root, "studio-shelf")
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_hexpand(root, 0)

        gtk_label_set_ellipsize(op(heading), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(heading), 10)
        gtk_widget_set_hexpand(heading, 1)
        gtk_widget_set_tooltip_text(refresh, ImageGenLibraryWords.refresh)
        tailscode_set_accessible_label(refresh, ImageGenLibraryWords.refresh)
        Gtk.margins(header, top: 10, bottom: 4, leading: 12, trailing: 6)
        gtk_box_append(ptr(header), heading)
        gtk_box_append(ptr(header), refresh)
        gtk_box_append(ptr(root), header)

        gtk_widget_set_visible(note, 0)
        gtk_box_append(ptr(list), note)

        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 0)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_box_append(ptr(root), scroller)

        Gtk.connect(UnsafeMutableRawPointer(refresh), "clicked") { [weak self] in
            self?.onRefresh?()
        }
        for adjustment in [
            gtk_scrolled_window_get_vadjustment(op(scroller)),
            gtk_scrolled_window_get_hadjustment(op(scroller)),
        ] {
            guard let adjustment else { continue }
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "value") { [weak self] in
                self?.wantSoon()
            }
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "page-size") {
                [weak self] in self?.wantSoon()
            }
        }
        Gtk.onKey(scroller) { [weak self] keyval, state in
            guard state & (KeyChord.controlMask | KeyChord.altMask) == 0 else { return false }
            return self?.walk(keyval: keyval) ?? false
        }
        place(rail: true)
    }

    /// The arrow keys walk the shelf whichever way it is turned, Home and End go to its ends, and
    /// Return — which a focused tile already answers — puts the tile on the stage. The scroller
    /// would otherwise take the arrows to scroll, so they are claimed here first, and only while a
    /// tile has the keyboard.
    private func walk(keyval: UInt32) -> Bool {
        let step: Int
        switch keyval {
        case Keymap.up, 0xFF51: step = -1
        case Keymap.down, 0xFF53: step = 1
        case 0xFF50: step = -order.count
        case 0xFF57: step = order.count
        default: return false
        }
        guard let current = order.firstIndex(where: { id in
            slots[id].map { gtk_widget_has_focus($0.button) != 0 } ?? false
        }) else { return false }
        let target = min(max(current + step, 0), max(order.count - 1, 0))
        let id = order[target]
        focus(id)
        reveal(id)
        return true
    }

    /// Turns the shelf: a rail is a column 112 points wide, a strip a row 88 points high — the
    /// same tiles, the same scroller, the other way round.
    func place(rail: Bool) {
        self.rail = rail
        gtk_orientable_set_orientation(
            op(list), rail ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
        gtk_scrolled_window_set_policy(
            op(scroller), rail ? GTK_POLICY_NEVER : GTK_POLICY_AUTOMATIC,
            rail ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER)
        gtk_scrolled_window_set_min_content_height(
            op(scroller), rail ? 0 : Int32(metrics.stripHeight))
        gtk_scrolled_window_set_max_content_height(
            op(scroller), rail ? -1 : Int32(metrics.stripHeight))
        gtk_widget_set_visible(header, rail ? 1 : 0)
        gtk_widget_set_vexpand(root, rail ? 1 : 0)
        gtk_widget_set_hexpand(root, rail ? 0 : 1)
        gtk_widget_set_size_request(root, rail ? Int32(metrics.railWidth) : -1, -1)
        if rail {
            gtk_widget_remove_css_class(root, "studio-strip")
            Gtk.addClass(root, "studio-rail")
        } else {
            gtk_widget_remove_css_class(root, "studio-rail")
            Gtk.addClass(root, "studio-strip")
        }
        let inset = Int32((metrics.railWidth - metrics.tileSide) / 2)
        Gtk.margins(
            list, top: rail ? 2 : Int32(metrics.gutter), bottom: rail ? 12 : Int32(metrics.gutter),
            leading: rail ? inset : 16, trailing: rail ? inset : 16)
        gtk_widget_set_valign(list, rail ? GTK_ALIGN_START : GTK_ALIGN_FILL)
        gtk_widget_set_halign(list, rail ? GTK_ALIGN_FILL : GTK_ALIGN_START)
        gtk_label_set_wrap(op(note), rail ? 1 : 0)
        gtk_label_set_max_width_chars(op(note), rail ? 11 : 36)
        gtk_label_set_ellipsize(op(note), rail ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(note, rail ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
        gtk_widget_set_margin_bottom(note, rail ? 8 : 0)
        gtk_widget_set_margin_end(note, rail ? 0 : 12)
        for slot in slots.values { orient(slot) }
        wantSoon()
    }

    private func orient(_ slot: Slot) {
        gtk_revealer_set_transition_type(
            op(slot.revealer),
            rail ? GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN : GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT)
        gtk_widget_set_margin_bottom(slot.revealer, rail ? Int32(metrics.gutter) : 0)
        gtk_widget_set_margin_end(slot.revealer, rail ? 0 : Int32(metrics.gutter))
    }

    /// Everything the shelf says about itself above its tiles: which machine, how many, and the
    /// sentence a machine that cannot list says instead of a silent empty shelf.
    func describe(heading text: String, count line: String?, note sentence: String?) {
        gtk_label_set_text(op(heading), text)
        gtk_widget_set_tooltip_text(heading, line.map { "\(text) · \($0)" } ?? text)
        gtk_label_set_text(op(note), sentence ?? "")
        gtk_widget_set_visible(note, sentence == nil ? 0 : 1)
        gtk_widget_set_tooltip_text(note, sentence)
    }

    var statusSentence: String? {
        guard gtk_widget_get_visible(note) != 0 else { return nil }
        let text = gtk_label_get_text(op(note)).map { String(cString: $0) } ?? ""
        return text.isEmpty ? nil : text
    }

    var tileIDs: [String] { order }

    /// Puts the tiles on the shelf in this order, keeping every tile that is still there and
    /// only touching what changed.
    func update(tiles: [StudioTile], selection: String?) {
        let ids = tiles.map(\.id)
        let known = Set(ids)
        let populated = !slots.isEmpty
        for (id, slot) in slots where !known.contains(id) {
            gtk_box_remove(ptr(list), slot.revealer)
            slots.removeValue(forKey: id)
        }
        var previous: UnsafeMutablePointer<GtkWidget>? = note
        var reorder = ids != order
        for tile in tiles {
            if slots[tile.id] == nil {
                reorder = true
                let made = makeSlot(tile)
                slots[tile.id] = made
                gtk_box_append(ptr(list), made.revealer)
                if populated && Gtk.animationsAllowed {
                    gtk_revealer_set_reveal_child(op(made.revealer), 0)
                    let bits = UInt(bitPattern: made.revealer)
                    Gtk.after(16) {
                        Gtk.onMain {
                            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                            gtk_revealer_set_reveal_child(op(raw), 1)
                        }
                    }
                }
            }
            if reorder, let slot = slots[tile.id] {
                gtk_box_reorder_child_after(ptr(list), slot.revealer, previous)
                previous = slot.revealer
            }
        }
        order = ids
        for tile in tiles { apply(tile) }
        select(selection)
        wantSoon()
    }

    /// Changes what one tile says — the render in flight counting its steps — without touching
    /// the other tiles.
    func set(tile: StudioTile) {
        apply(tile)
    }

    private func apply(_ tile: StudioTile) {
        guard var slot = slots[tile.id] else { return }
        let before = slot.tile
        if tile.words != before.words { tailscode_set_accessible_label(slot.button, tile.words) }
        if tile.tooltip != before.tooltip { gtk_widget_set_tooltip_text(slot.button, tile.tooltip) }
        if tile.badge != before.badge {
            gtk_label_set_text(op(slot.badge), tile.badge ?? "")
            gtk_widget_set_visible(slot.badge, tile.badge == nil ? 0 : 1)
        }
        if let progress = tile.progress {
            gtk_progress_bar_set_fraction(op(slot.sliver), min(1, max(0, progress)))
            gtk_widget_set_visible(slot.sliver, 1)
        } else {
            gtk_widget_set_visible(slot.sliver, 0)
        }
        gtk_label_set_text(op(slot.glyph), tile.glyph ?? "")
        if tile.inFlight {
            Gtk.addClass(slot.button, "studio-tile-job")
        } else {
            gtk_widget_remove_css_class(slot.button, "studio-tile-job")
        }
        slot.tile = tile
        slots[tile.id] = slot
        refit(tile.id)
    }

    /// Gives a tile its picture when the owner has one and the tile is near the eye, and takes it
    /// away when it has left — a tile out of range is a placeholder holding no pixels at all. A
    /// picture already there is told the new frame in place, which is how the tile in flight
    /// follows the machine's sketch.
    private func refit(_ id: String) {
        guard var slot = slots[id] else { return }
        let bits = isNear(id) ? (thumbnail?(id) ?? 0) : 0
        if bits != 0 {
            if let picture = slot.picture {
                Gtk.replacePicture(of: picture, bits: bits)
            } else if let picture = Gtk.studioPicture(bits: bits, fit: GTK_CONTENT_FIT_COVER) {
                gtk_widget_set_size_request(picture, Int32(metrics.tileSide), Int32(metrics.tileSide))
                Gtk.setHidden(picture, true)
                let frame = Gtk.squareFrame(holding: picture, side: Int32(metrics.tileSide))
                gtk_box_append(ptr(slot.art), frame)
                gtk_widget_remove_css_class(slot.art, "draw-tile-empty")
                slot.picture = picture
            }
        } else if slot.picture != nil {
            while let child = gtk_widget_get_first_child(slot.art) { gtk_box_remove(ptr(slot.art), child) }
            Gtk.addClass(slot.art, "draw-tile-empty")
            slot.picture = nil
        }
        gtk_widget_set_visible(slot.glyph, slot.picture == nil && slot.tile.glyph != nil ? 1 : 0)
        slots[id] = slot
    }

    /// Redraws one tile's picture from what the owner holds now: a new sketch frame, a thumbnail
    /// that just decoded.
    func refreshPicture(_ id: String) { refit(id) }

    func refreshPictures() {
        for id in order { refit(id) }
    }

    private func select(_ id: String?) {
        let was = selected
        selected = id
        for key in [was, id].compactMap({ $0 }) {
            guard let slot = slots[key] else { continue }
            if key == id {
                Gtk.addClass(slot.button, "studio-tile-on")
            } else {
                gtk_widget_remove_css_class(slot.button, "studio-tile-on")
            }
        }
    }

    /// Whether a tile is within a few tiles of what the scroller shows, by arithmetic on its place
    /// in the order rather than by asking every widget where it is.
    private func isNear(_ id: String) -> Bool {
        guard let index = order.firstIndex(of: id) else { return false }
        return visibleRange.contains(index)
    }

    private var adjustment: UnsafeMutablePointer<GtkAdjustment>? {
        rail ? gtk_scrolled_window_get_vadjustment(op(scroller)) : gtk_scrolled_window_get_hadjustment(op(scroller))
    }

    private var visibleRange: Range<Int> {
        let offset = adjustment.map { gtk_adjustment_get_value($0) } ?? 0
        var viewport = adjustment.map { gtk_adjustment_get_page_size($0) } ?? 0
        if viewport <= 0 { viewport = rail ? 700 : 900 }
        return StudioShelfWindow.visible(
            offset: offset, viewport: viewport, pitch: metrics.tileSide + metrics.gutter,
            count: order.count)
    }

    private func wantSoon() {
        guard !rangePending else { return }
        rangePending = true
        Gtk.after(40) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.rangePending = false
                let range = self.visibleRange
                let near = self.order.enumerated().filter { range.contains($0.offset) }.map(\.element)
                self.onWant?(near)
                self.refreshPictures()
            }
        }
    }

    /// Scrolls so a tile is in view — the selection moved by the stage or an arrow key.
    func reveal(_ id: String) {
        guard let index = order.firstIndex(of: id), let adjustment else { return }
        let pitch = metrics.tileSide + metrics.gutter
        let start = Double(index) * pitch
        let end = start + metrics.tileSide
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        if start < value {
            gtk_adjustment_set_value(adjustment, max(0, start - metrics.gutter))
        } else if end > value + page {
            gtk_adjustment_set_value(adjustment, end - page + metrics.gutter)
        }
    }

    func focus(_ id: String) {
        guard let slot = slots[id] else { return }
        gtk_widget_grab_focus(slot.button)
    }

    private func makeSlot(_ tile: StudioTile) -> Slot {
        let revealer = gtk_revealer_new()!
        gtk_revealer_set_transition_duration(op(revealer), Gtk.animationsAllowed ? 160 : 0)
        gtk_revealer_set_reveal_child(op(revealer), 1)
        let button = gtk_button_new()!
        Gtk.addClass(button, "studio-tile")
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        let overlay = gtk_overlay_new()!
        let art = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(art, "draw-tile-empty")
        Gtk.addClass(art, "studio-tile-art")
        let side = Int32(metrics.tileSide)
        gtk_widget_set_size_request(art, side, side)
        gtk_overlay_set_child(op(overlay), art)
        let glyph = Gtk.label("", css: "studio-tile-glyph", selectable: false)
        gtk_widget_set_halign(glyph, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(glyph, 0)
        gtk_widget_set_visible(glyph, 0)
        gtk_overlay_add_overlay(op(overlay), glyph)
        let badge = Gtk.label("", css: "studio-tile-badge", selectable: false)
        gtk_label_set_ellipsize(op(badge), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_halign(badge, GTK_ALIGN_START)
        gtk_widget_set_valign(badge, GTK_ALIGN_END)
        Gtk.margins(badge, bottom: 6, leading: 4)
        gtk_widget_set_can_target(badge, 0)
        gtk_widget_set_visible(badge, 0)
        gtk_overlay_add_overlay(op(overlay), badge)
        let sliver = gtk_progress_bar_new()!
        Gtk.addClass(sliver, "studio-tile-sliver")
        gtk_widget_set_valign(sliver, GTK_ALIGN_END)
        gtk_widget_set_can_target(sliver, 0)
        gtk_widget_set_visible(sliver, 0)
        gtk_overlay_add_overlay(op(overlay), sliver)
        gtk_button_set_child(ptr(button), overlay)
        gtk_revealer_set_child(op(revealer), button)

        let id = tile.id
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onChoose?(id) }
        }
        let bits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { [weak self] x, y in
            Gtk.onMain { [weak self] in
                guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { return }
                self?.onMenu?(id, widget, x, y)
            }
        }
        Gtk.onPointer(button, move: { [weak self] _, _ in self?.hovered(id) }, leave: {})
        Gtk.makeFileDragSource(button) { [weak self] in self?.dragPath?(id) }
        let made = Slot(
            revealer: revealer, button: button, art: art, badge: badge, sliver: sliver,
            glyph: glyph, picture: nil, tile: StudioTile(id: id))
        orient(made)
        return made
    }

    private func hovered(_ id: String) {
        guard hoverID != id else { return }
        hoverID = id
        Gtk.after(350) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.hoverID == id else { return }
                self.onHover?(id)
            }
        }
    }

    /// For the headless driver: where the shelf is turned, how many tiles exist and how many hold
    /// a picture right now.
    var summary: String {
        let pictured = slots.values.filter { $0.picture != nil }.count
        return "\(rail ? "rail" : "strip") tiles=\(order.count) pictured=\(pictured) selected=\(selected ?? "-")"
    }

    /// Where a tile sits inside an ancestor, for a harness that has to click it.
    func bounds(of id: String, in ancestor: UnsafeMutablePointer<GtkWidget>)
        -> (x: Double, y: Double, width: Double, height: Double)?
    {
        guard let slot = slots[id] else { return nil }
        return Gtk.bounds(of: slot.button, in: ancestor)
    }
}
