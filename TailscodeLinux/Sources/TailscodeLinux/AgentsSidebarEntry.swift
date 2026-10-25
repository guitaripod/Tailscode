import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The Agents card at the head of the sidebar: a live orb, the word, and two counts, one press to
/// the board. Working is a green orb breathing slowly under a green-edged card; something waiting
/// on the person is an amber orb that knocks twice and an amber light breathing along the card's
/// border; nothing running is a dim bead, the word, and the shortcut in a faint mono tail. It is a
/// fixture of the sidebar, not a row of its list, so a redraw of the list never takes it away.
final class AgentsSidebarEntry: @unchecked Sendable {
    let widget = gtk_overlay_new()!
    let button = gtk_button_new()!
    let orb = AgentsMiniOrb(size: 22)
    let chips = AgentsEntryChips()
    let glow = AgentsEntryGlow()
    private let title = Gtk.label(Localized.text("Agents"), css: "agents-entry-title", selectable: false)
    private let hint = Gtk.label("Ctrl+Shift+A", css: "agents-entry-hint", selectable: false)
    private let memory: AgentsShimmerMemory
    private var wantsSweep = false
    private var hintFits = true
    private(set) var reading = AgentsReading.quiet
    private(set) var spokenName = ""
    private(set) var hintWidth: Int32 = 0

    var mood: AgentsMood { reading.mood }
    var titleLabelWidget: UnsafeMutablePointer<GtkWidget> { title }
    var isHintShown: Bool { gtk_widget_get_visible(hint) != 0 }
    var titleText: String { gtk_label_get_text(op(title)).map { String(cString: $0) } ?? "" }

    init(memory: AgentsShimmerMemory = .settings, open: @escaping @Sendable () -> Void) {
        self.memory = memory
        Gtk.addClass(widget, "agents-entry-frame")
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "agents-entry")
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(hint, GTK_ALIGN_CENTER)
        gtk_label_set_ellipsize(op(hint), PANGO_ELLIPSIZE_NONE)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(line), orb.widget)
        gtk_box_append(ptr(line), title)
        gtk_box_append(ptr(line), hint)
        gtk_box_append(ptr(line), chips.widget)
        gtk_button_set_child(ptr(button), line)
        gtk_overlay_set_child(op(widget), button)
        gtk_overlay_add_overlay(op(widget), glow.widget)
        Gtk.margins(widget, top: 4, bottom: 2, leading: 6, trailing: 6)
        gtk_widget_set_tooltip_text(button, Localized.text("What every agent is doing · Ctrl+Shift+A"))
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { Gtk.onMain { open() } }
        Gtk.connect(UnsafeMutableRawPointer(widget), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.sweepIfOwed() }
        }
        glow.onFrame = { [weak self] time in self?.chips.step(time: time) }
        glow.onStill = { [weak self] in self?.chips.cancelPops() }
        measureHint()
        apply(.quiet)
    }

    /// The hint's own width, read once so the row can decide whether the shortcut has room.
    private func measureHint() {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var baseA: Int32 = 0
        var baseB: Int32 = 0
        gtk_widget_measure(hint, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, &baseA, &baseB)
        hintWidth = natural
    }

    /// Whether the shortcut has the room: it gives way whole below a width, never half a key.
    func fit(sidebarWidth width: Int32) {
        hintFits = width >= hintWidth + Self.hintClearance
        showHint()
    }

    static let hintClearance: Int32 = 150

    private func showHint() {
        gtk_widget_set_visible(hint, mood == .idle && hintFits ? 1 : 0)
    }

    func apply(_ next: AgentsReading) {
        let before = reading.mood
        reading = next
        let spoken = Self.spoken(next.chip)
        spokenName = spoken
        chips.set(working: next.chip.working, needs: next.chip.needsYou, popping: RepeatingMotion.allowed)
        orb.set(mood: next.mood)
        glow.set(mood: next.mood)
        Gtk.setTone(button, next.mood.cssClass, from: AgentsMood.cssClasses)
        showHint()
        if next.mood == .idle { chips.cancelPops() }
        tailscode_set_accessible_label(button, spoken)
        if before == .idle, next.mood != .idle { wantsSweep = true }
        sweepIfOwed()
    }

    static func spoken(_ chip: AgentsChip) -> String { chip.spoken }

    /// The one sweep of light, owed the first time the row has something to say and played once
    /// the row is on screen, so a launch that opens with the sidebar collapsed is not spent.
    private func sweepIfOwed() {
        guard wantsSweep, mood != .idle, RepeatingMotion.allowed, !memory.seen(),
            gtk_widget_get_mapped(widget) != 0
        else { return }
        wantsSweep = false
        memory.remember()
        glow.startSweep()
    }
}
