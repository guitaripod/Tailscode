import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The Agents card at the head of the sidebar, and the one place the sidebar says what the agents
/// are doing: the glass orb with its orbit of lights, the word and its chips on the first line, a
/// live sentence in small mono on the second. Working is a green card with a green-edged
/// surface; something waiting on the person is amber, names the first chat that waits and has a
/// light breathing along its border; nothing running is a calm card that names the shortcut. It
/// is a fixture of the sidebar, not a row of its list, so a redraw of the list never takes it
/// away, and it is a button, so Tab reaches it and Enter or Space opens the board.
final class AgentsSidebarEntry: @unchecked Sendable {
    let widget = gtk_overlay_new()!
    let button = gtk_button_new()!
    let orb = AgentsMiniOrb(size: 36)
    let chips = AgentsEntryChips()
    let glow = AgentsEntryGlow()
    private let title = Gtk.label(Localized.text("Agents"), css: "agents-entry-title", selectable: false)
    private let sentence = Gtk.label("", css: "agents-entry-sentence", wrap: true, selectable: false)
    private let memory: AgentsShimmerMemory
    private var wantsSweep = false
    private var sidebarWidth: Int32?
    private(set) var reading = AgentsReading.quiet
    private(set) var spokenName = ""
    private(set) var shownSentence = ""

    var mood: AgentsMood { reading.mood }
    var titleLabelWidget: UnsafeMutablePointer<GtkWidget> { title }
    var sentenceWidget: UnsafeMutablePointer<GtkWidget> { sentence }
    var isOrbShown: Bool { gtk_widget_get_visible(orb.widget) != 0 }
    var isSentenceShown: Bool { gtk_widget_get_visible(sentence) != 0 }
    var titleText: String { gtk_label_get_text(op(title)).map { String(cString: $0) } ?? "" }
    var sentenceText: String { gtk_label_get_text(op(sentence)).map { String(cString: $0) } ?? "" }

    init(memory: AgentsShimmerMemory = .settings, open: @escaping @Sendable () -> Void) {
        self.memory = memory
        Gtk.addClass(widget, "agents-entry-frame")
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "agents-entry")
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        gtk_label_set_wrap_mode(op(sentence), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_xalign(op(sentence), 0)
        gtk_widget_set_hexpand(sentence, 1)
        tailscode_set_accessible_hidden(sentence, 1)
        let first = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(first), title)
        gtk_box_append(ptr(first), chips.widget)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_hexpand(column, 1)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(column), first)
        gtk_box_append(ptr(column), sentence)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 9)
        gtk_box_append(ptr(line), orb.widget)
        gtk_box_append(ptr(line), column)
        gtk_button_set_child(ptr(button), line)
        gtk_overlay_set_child(op(widget), button)
        gtk_overlay_add_overlay(op(widget), glow.widget)
        Gtk.margins(widget, top: 6, bottom: 2, leading: 6, trailing: 6)
        gtk_widget_set_tooltip_text(button, Localized.text("What every agent is doing · Ctrl+Shift+A"))
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { Gtk.onMain { open() } }
        Gtk.connect(UnsafeMutableRawPointer(widget), "map") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.sweepIfOwed()
                self?.relayout()
            }
        }
        glow.onFrame = { [weak self] time in self?.chips.step(time: time) }
        glow.onStill = { [weak self] in self?.chips.cancelPops() }
        apply(.quiet)
    }

    /// The sidebar's width, as the divider says it, so the card can be judged against the room it
    /// will have before GTK has laid it out.
    func fit(sidebarWidth width: Int32) {
        sidebarWidth = width
        relayout()
    }

    /// The frame's margins, the card's border and padding: what surrounds everything in it.
    static let frameClearance: Int32 = 12 + 2 + 20

    /// The orb and the gap after it.
    static let orbClearance: Int32 = 36 + 9

    /// Under this much room a sentence is not worth setting: the chips and the word say it.
    static let sentenceFloor: Int32 = 120

    static let sentenceLines = 2

    /// Room for the quiet sentence to carry the shortcut after it.
    static let shortcutRoom: Int32 = 190

    private static func naturalWidth(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        var least: Int32 = 0
        var natural: Int32 = 0
        var baselineLeast: Int32 = 0
        var baselineNatural: Int32 = 0
        gtk_widget_measure(
            widget, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, &baselineLeast, &baselineNatural)
        return natural
    }

    /// Whether the word and the chips need the orb's place: with counts as long as a sidebar's
    /// minimum can hold, the orb gives way before the chips would overlap anything.
    var isCompact: Bool {
        guard let sidebarWidth else { return false }
        let needed = Self.frameClearance + Self.orbClearance + Self.naturalWidth(title) + 6
            + (chips.isShown(.working) || chips.isShown(.needs) || chips.isShown(.background)
                ? Self.naturalWidth(chips.widget) : 0)
        return sidebarWidth < needed
    }

    private var sentenceRoom: Int32 {
        let orb = isCompact ? 0 : Self.orbClearance
        if let sidebarWidth { return sidebarWidth - Self.frameClearance - orb }
        let drawn = gtk_widget_get_width(button)
        return drawn > 0 ? drawn - (Self.frameClearance - 12) - orb : 200
    }

    private func relayout() {
        gtk_widget_set_visible(orb.widget, isCompact ? 0 : 1)
        fitSentence()
    }

    /// Whether the key is the card's own: Enter or Space, bare, while the card has focus, which the
    /// window's keys must leave to the button so it opens the board instead of the list's row
    /// under the cursor.
    func ownsKey(_ keyval: UInt32, state: UInt32, in window: UnsafeMutablePointer<GtkWidget>) -> Bool {
        guard keyval == Keymap.enter || keyval == Keymap.keypadEnter || keyval == 0x20,
            state & (KeyChord.controlMask | KeyChord.altMask) == 0
        else { return false }
        return gtk_window_get_focus(ptr(window)) == button
    }

    func apply(_ next: AgentsReading) {
        let before = reading.mood
        reading = next
        spokenName = next.spoken
        chips.set(
            working: next.working, needs: next.needsYou, background: next.background,
            popping: RepeatingMotion.allowed)
        orb.set(mood: next.mood, running: next.running)
        glow.set(mood: next.mood)
        Gtk.setTone(button, next.mood.cssClass, from: AgentsMood.cssClasses)
        if next.mood == .idle { chips.cancelPops() }
        tailscode_set_accessible_label(button, spokenName)
        relayout()
        if before == .idle, next.mood != .idle { wantsSweep = true }
        sweepIfOwed()
    }

    /// Sets the sentence for the room it has: whole words only, the waiting chat's name given up
    /// word by word with an ellipsis rather than cut through a word, counts broken onto a second
    /// line between one count and the next rather than through one, two lines at most, and
    /// nothing at all where not even that fits.
    func fitSentence() {
        let room = sentenceRoom
        var text = reading.sentence(withShortcut: room >= Self.shortcutRoom)
        if room >= Self.sentenceFloor, reading.needsYou > 0, let waiting = reading.waiting, !waiting.isEmpty {
            text = Self.fitted(waiting, room: room, in: sentence)
        } else if room >= Self.sentenceFloor, Self.lines(text, room: room, in: sentence) > 1 {
            text = Self.broken(reading.parts, room: room, in: sentence) ?? text
        }
        let fits = room >= Self.sentenceFloor && Self.lines(text, room: room, in: sentence) <= Self.sentenceLines
        shownSentence = fits ? text : ""
        gtk_label_set_text(op(sentence), text)
        gtk_widget_set_visible(sentence, fits ? 1 : 0)
    }

    /// The counts on two lines, as many on the first as fit there, or nil when no split lets
    /// each line stand on its own.
    private static func broken(
        _ parts: [String], room: Int32, in label: UnsafeMutablePointer<GtkWidget>
    ) -> String? {
        for split in stride(from: parts.count - 1, through: 1, by: -1) {
            let first = parts.prefix(split).joined(separator: " · ")
            let rest = parts.dropFirst(split).joined(separator: " · ")
            if lines(first, room: room, in: label) == 1, lines(rest, room: room, in: label) == 1 {
                return first + "\n" + rest
            }
        }
        return nil
    }

    private static func fitted(
        _ name: String, room: Int32, in label: UnsafeMutablePointer<GtkWidget>
    ) -> String {
        let words = name.split(separator: " ").map(String.init)
        for count in stride(from: words.count, through: 1, by: -1) {
            let shown = words.prefix(count).joined(separator: " ") + (count < words.count ? "…" : "")
            let text = Localized.text("%@ needs you", shown)
            if lines(text, room: room, in: label) <= sentenceLines { return text }
        }
        return Localized.text("%@ needs you", (words.first ?? name) + "…")
    }

    /// How many lines `text` takes in `room` points, asked of GTK itself so it is the label's own
    /// font, weight and wrapping that are measured. The label is left holding `text`.
    static func lines(_ text: String, room: Int32, in label: UnsafeMutablePointer<GtkWidget>) -> Int {
        gtk_label_set_text(op(label), "X")
        let one = height(of: label, at: 10_000)
        gtk_label_set_text(op(label), text)
        let all = height(of: label, at: room)
        return max(1, Int((Double(all) / Double(max(1, one)) - 0.15).rounded(.up)))
    }

    private static func height(of label: UnsafeMutablePointer<GtkWidget>, at width: Int32) -> Int32 {
        var least: Int32 = 0
        var natural: Int32 = 0
        var baselineLeast: Int32 = 0
        var baselineNatural: Int32 = 0
        gtk_widget_measure(
            label, GTK_ORIENTATION_VERTICAL, width, &least, &natural, &baselineLeast, &baselineNatural)
        return natural
    }

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
