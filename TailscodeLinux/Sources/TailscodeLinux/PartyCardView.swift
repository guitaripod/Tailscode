import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a card does when it is pressed, dragged or asked. Every closure runs on the main loop.
final class PartyActions: @unchecked Sendable {
    var activate: (Int) -> Void = { _ in }
    var stepLevel: (Int) -> Void = { _ in }
    var release: (Int) -> Void = { _ in }
    var rename: (Int, String?) -> Void = { _, _ in }
    var swap: (Int, Int) -> Void = { _, _ in }
    var replace: (Int) -> Void = { _ in }
}

/// One of the six places in the grid, which stays where it is while what it holds changes: the
/// cell is built once, the card inside it is built again only when it changes shape (filled or
/// hollow, taking or editing), and every other change is said to the widgets already there, so a
/// name being typed is never pulled out from under the hand by a notification about another slot.
final class PartyCardView: @unchecked Sendable {
    static let cardWidth: Int32 = 190
    static let cardHeight: Int32 = 118
    static let gutter: Int32 = 8

    let slot: Int
    let cell: UnsafeMutablePointer<GtkWidget>
    private let actions: PartyActions
    private let badge: UnsafeMutablePointer<GtkWidget>
    private(set) var card: PartyCard
    private(set) var editing = false
    private var shape = ""
    private var body: UnsafeMutablePointer<GtkWidget>?
    private var ball: PartyBall?
    private var bars: PartyBars?
    private var ballButton: UnsafeMutablePointer<GtkWidget>?
    private var chord: UnsafeMutablePointer<GtkWidget>?
    private var title: UnsafeMutablePointer<GtkWidget>?
    private var entryHold: Gtk.WeakWidget?
    private var subtitle: UnsafeMutablePointer<GtkWidget>?
    private var machine: UnsafeMutablePointer<GtkWidget>?
    private var hollowWord: UnsafeMutablePointer<GtkWidget>?
    private var entryFocused = false

    /// The name field of an edited card, or nothing once the field is gone: a press that was
    /// queued behind the card being built again finds no field rather than a freed one.
    var entry: UnsafeMutablePointer<GtkWidget>? { entryHold?.widget }
    private var accepting = false

    init(slot: Int, actions: PartyActions) {
        self.slot = slot
        self.actions = actions
        card = .hollow(slot)
        cell = gtk_overlay_new()!
        Gtk.addClass(cell, "party-cell")
        badge = gtk_button_new()!
        Gtk.addClass(badge, "party-badge")
        gtk_button_set_child(
            ptr(badge), Gtk.label("✕", css: "party-badge-glyph", selectable: false))
        gtk_widget_set_halign(badge, GTK_ALIGN_START)
        gtk_widget_set_valign(badge, GTK_ALIGN_START)
        gtk_widget_set_visible(badge, 0)
        let release = Localized.text("Put back in the box")
        gtk_widget_set_tooltip_text(badge, release)
        tailscode_set_accessible_label(badge, release)
        gtk_overlay_add_overlay(op(cell), badge)
        Gtk.connect(UnsafeMutableRawPointer(badge), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.actions.release(self.slot)
            }
        }
        Gtk.onRightClick(cell) { [weak self] x, y in
            Gtk.onMain { [weak self] in self?.openMenu(x: x, y: y) }
        }
        installDrops()
    }

    var hasFocus: Bool {
        guard let focused = tailscode_focused_widget(cell) else { return false }
        return gtk_widget_is_ancestor(focused, cell) != 0
    }

    /// The card says what it is now. A change of shape builds the card again; anything else is
    /// said to the widgets that are already there.
    func apply(_ card: PartyCard, editing: Bool) {
        let wanted = (card.isHollow ? "hollow" : "filled") + (editing ? ":edit" : ":take")
        self.card = card
        self.editing = editing
        if wanted != shape {
            shape = wanted
            build()
        }
        fill()
    }

    private func build() {
        gtk_overlay_set_child(op(cell), nil)
        ball = nil
        bars = nil
        ballButton = nil
        chord = nil
        title = nil
        entryHold = nil
        subtitle = nil
        machine = nil
        hollowWord = nil
        entryFocused = false
        let made = card.isHollow ? buildHollow() : (editing ? buildEditing() : buildTaking())
        gtk_widget_set_size_request(made, Self.cardWidth, Self.cardHeight)
        Gtk.margins(made, top: Self.gutter, leading: Self.gutter)
        gtk_overlay_set_child(op(cell), made)
        body = made
        gtk_widget_set_visible(badge, !card.isHollow && editing ? 1 : 0)
    }

    private func buildHollow() -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "party-card")
        Gtk.addClass(button, "party-card-hollow")
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        let plus = Gtk.label("+", css: "party-plus", selectable: false)
        gtk_widget_set_halign(plus, GTK_ALIGN_CENTER)
        gtk_label_set_xalign(op(plus), 0.5)
        gtk_box_append(ptr(column), plus)
        let word = Gtk.label("", css: "party-hollow-word", wrap: true, selectable: false)
        gtk_label_set_xalign(op(word), 0.5)
        gtk_label_set_justify(op(word), GTK_JUSTIFY_CENTER)
        gtk_box_append(ptr(column), word)
        hollowWord = word
        gtk_button_set_child(ptr(button), column)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.actions.activate(self.slot)
            }
        }
        return button
    }

    private func buildTaking() -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "party-card")
        let overlay = gtk_overlay_new()!
        let column = content(editing: false)
        gtk_overlay_set_child(op(overlay), column)
        let bars = PartyBars()
        gtk_overlay_add_overlay(op(overlay), bars.widget)
        self.bars = bars
        gtk_button_set_child(ptr(button), overlay)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.actions.activate(self.slot)
            }
        }
        return button
    }

    private func buildEditing() -> UnsafeMutablePointer<GtkWidget> {
        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(frame, "party-card")
        Gtk.addClass(frame, "party-card-edit")
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), content(editing: true))
        let bars = PartyBars()
        gtk_overlay_add_overlay(op(overlay), bars.widget)
        self.bars = bars
        gtk_widget_set_vexpand(overlay, 1)
        gtk_box_append(ptr(frame), overlay)
        Gtk.makePartyDragSource(frame, payload: String(slot)) { [weak self] lifted in
            Gtk.onMain { [weak self] in
                guard let self, let body = self.body else { return }
                if lifted {
                    gtk_widget_add_css_class(body, "party-card-lifted")
                } else {
                    gtk_widget_remove_css_class(body, "party-card-lifted")
                }
            }
        }
        return frame
    }

    /// The anatomy: the ball and the chord across the top, the name, what runs under it, and the
    /// machine it runs on. The bars sit over the bottom right corner, drawn by the caller.
    private func content(editing: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let ball = PartyBall()
        self.ball = ball
        if editing {
            let button = gtk_button_new()!
            Gtk.addClass(button, "party-ball-button")
            gtk_button_set_child(ptr(button), ball.widget)
            let words = Localized.text("Change the level")
            gtk_widget_set_tooltip_text(button, words)
            tailscode_set_accessible_label(button, words)
            gtk_widget_set_valign(button, GTK_ALIGN_START)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.actions.stepLevel(self.slot)
                }
            }
            ballButton = button
            gtk_box_append(ptr(top), button)
        } else {
            gtk_box_append(ptr(top), ball.widget)
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(top), spacer)
        let chord = Gtk.label("", css: "party-chord", selectable: false)
        gtk_label_set_ellipsize(op(chord), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(chord, GTK_ALIGN_START)
        gtk_label_set_xalign(op(chord), 1)
        self.chord = chord
        gtk_box_append(ptr(top), chord)
        gtk_box_append(ptr(column), top)
        if editing {
            let entry = gtk_entry_new()!
            Gtk.addClass(entry, "party-name")
            gtk_entry_set_max_length(ptr(entry), Int32(ModelParty.nameLimit))
            gtk_entry_set_has_frame(ptr(entry), 0)
            gtk_widget_set_hexpand(entry, 1)
            Gtk.margins(entry, top: 4)
            Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
                Gtk.onMain { [weak self] in self?.commit(settling: true) }
            }
            let focus = gtk_event_controller_focus_new()!
            Gtk.connect(UnsafeMutableRawPointer(focus), "enter") { [weak self] in
                Gtk.onMain { [weak self] in self?.entryFocused = true }
            }
            Gtk.connect(UnsafeMutableRawPointer(focus), "leave") { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.entryFocused = false
                    self?.commit(settling: true)
                }
            }
            gtk_widget_add_controller(entry, focus)
            entryHold = Gtk.WeakWidget(entry)
            gtk_box_append(ptr(column), entry)
        } else {
            let title = Gtk.label("", css: "party-title", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(title), 17)
            gtk_widget_set_hexpand(title, 1)
            Gtk.margins(title, top: 7)
            self.title = title
            gtk_box_append(ptr(column), title)
        }
        let subtitle = Gtk.label("", css: "party-sub", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(subtitle), 19)
        gtk_widget_set_margin_end(subtitle, 28)
        self.subtitle = subtitle
        gtk_box_append(ptr(column), subtitle)
        let machine = Gtk.label("", css: "party-machine", wrap: true, selectable: false)
        gtk_widget_set_halign(machine, GTK_ALIGN_START)
        gtk_label_set_max_width_chars(op(machine), 14)
        gtk_label_set_wrap_mode(op(machine), PANGO_WRAP_WORD)
        Gtk.margins(machine, top: 4, trailing: 28)
        gtk_widget_set_visible(machine, 0)
        self.machine = machine
        gtk_box_append(ptr(column), machine)
        return column
    }

    private func hex(for chip: ModelChip?) -> String {
        guard let chip else { return MatrixTheme.palette.textDim }
        return ModelTint.identityHex(
            family: chip.family, name: chip.name, in: MatrixTheme.palette)
    }

    /// Says the card's words and marks to the widgets that hold them.
    private func fill() {
        guard let body else { return }
        tailscode_set_accessible_label(body, card.spoken)
        for name in ["party-card-use", "party-card-away", "party-card-hollow-edit"] {
            gtk_widget_remove_css_class(body, name)
        }
        if card.isHollow {
            let word =
                editing
                ? Localized.text("Fill slot %d", slot + 1) : Localized.text("Slot %d", slot + 1)
            if let hollowWord { gtk_label_set_text(op(hollowWord), word) }
            if editing { gtk_widget_add_css_class(body, "party-card-hollow-edit") }
            return
        }
        let tint = card.chip.map { ModelTint.identityClass(family: $0.family, name: $0.name) }
        Gtk.setTone(body, tint, from: DialPill.modelTintClasses)
        if card.isInUse { gtk_widget_add_css_class(body, "party-card-use") }
        if card.isAway { gtk_widget_add_css_class(body, "party-card-away") }
        let hue = hex(for: card.chip)
        ball?.show(hex: hue, inUse: card.isInUse)
        bars?.show(lit: card.bars, hex: hue)
        if let chord {
            let chordText = chordWords
            gtk_label_set_text(op(chord), chordText)
            Gtk.setTone(chord, card.isInUse ? tint : nil, from: DialPill.modelTintClasses)
        }
        if let title { gtk_label_set_text(op(title), card.title) }
        if let entry { showName(in: entry) }
        if let subtitle { gtk_label_set_text(op(subtitle), card.subtitle) }
        if let machine {
            let words = card.machine.map { Localized.text("on %@", $0) }
            gtk_label_set_text(op(machine), words ?? "")
            gtk_widget_set_visible(machine, words == nil ? 0 : 1)
        }
        if let ballButton {
            gtk_widget_set_tooltip_text(
                ballButton, card.takesLevels ? Localized.text("Change the level") : nil)
        }
    }

    /// The chord the slot is on, and *IN USE* beside it for the one this chat runs.
    var chordWords: String {
        let chord = "Ctrl+Alt+\(card.chord)"
        return card.isInUse ? chord + " · " + Localized.text("IN USE") : chord
    }

    private func showName(in entry: UnsafeMutablePointer<GtkWidget>) {
        let current = gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        guard current != card.title, !entryFocused else { return }
        gtk_editable_set_text(op(entry), card.title)
    }

    /// The typed name goes to the party when it is a different one. Empty, or the model's own
    /// word, is no name: the card gives the word back, and the field says so at once.
    func commit(settling: Bool) {
        guard let entry, editing, !card.isHollow else { return }
        let raw = gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        let typed = ModelParty.normalized(raw)
        let name = typed == card.modelWord ? nil : typed
        if name != card.name {
            actions.rename(slot, name)
        }
        let shown = name ?? card.modelWord
        if settling, raw != shown { gtk_editable_set_text(op(entry), shown) }
    }

    func focusName() {
        guard let entry else { return }
        gtk_widget_grab_focus(entry)
        gtk_editable_select_region(op(entry), 0, -1)
    }

    /// The control a press on this card lands on first, for a harness and for the keys that act
    /// on "the focused card".
    var anchor: UnsafeMutablePointer<GtkWidget>? { body }

    private func openMenu(x: Double, y: Double) {
        guard !card.isHollow else { return }
        let slot = slot
        let actions = actions
        Gtk.contextMenu(
            on: cell, x: x, y: y,
            rows: [
                (Localized.text("Replace…"), nil, { Gtk.onMain { actions.replace(slot) } }),
                (
                    Localized.text("Put back in the box"), nil,
                    { Gtk.onMain { actions.release(slot) } }
                ),
            ])
    }

    private func installDrops() {
        Gtk.acceptPartyDrops(
            on: cell,
            motion: { [weak self] payload, _, _ in
                Gtk.onMain { [weak self] in
                    guard let self, self.editing, let body = self.body else { return }
                    guard let payload, Int(payload) != self.slot else { return }
                    gtk_widget_add_css_class(body, "party-card-drop")
                }
            },
            leave: { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let body = self?.body else { return }
                    gtk_widget_remove_css_class(body, "party-card-drop")
                }
            },
            drop: { [weak self] payload, _, _ in
                guard let self, let from = Int(payload), from != self.slot, self.editing
                else { return false }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    if let body = self.body { gtk_widget_remove_css_class(body, "party-card-drop") }
                    self.actions.swap(from, self.slot)
                }
                return true
            })
    }
}
