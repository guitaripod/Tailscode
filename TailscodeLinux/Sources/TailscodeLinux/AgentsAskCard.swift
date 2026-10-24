import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One session waiting on a person: what it asks word for word, how long it has waited, and the
/// answer in place — Approve and Deny for a permission, one button per option for a question.
/// The command is monospaced, wrapped whole and selectable, because the one thing a person is
/// being asked to trust is the exact text.
final class AgentsAskCard: AgentsItemView, @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let headerButton = gtk_button_new()!
    private let glyph = AgentsParts.glyph()
    private let lead = Gtk.label("", css: "agents-lead", wrap: true, selectable: false)
    private let meta = Gtk.label("", css: "agents-meta", wrap: true, selectable: false)
    private let object = AgentsParts.monospaced("")
    private let objectScroller = gtk_scrolled_window_new()!
    private let objectHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var scrolls = false
    private let buttons = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let error = Gtk.label("", css: "agents-error", wrap: true, selectable: true)
    private let away = Gtk.label("", css: "agents-meta", wrap: true, selectable: false)
    private let actions: AgentsActions
    private let select: @Sendable (String) -> Void
    private(set) var card: AgentAskCard?
    private(set) var approveButton: UnsafeMutablePointer<GtkWidget>?
    private(set) var denyButton: UnsafeMutablePointer<GtkWidget>?
    private(set) var optionButtons: [UnsafeMutablePointer<GtkWidget>] = []
    private var builtFor: String?
    private var state: AgentsActionState = .idle

    var objectBox: UnsafeMutablePointer<GtkWidget> { objectHolder }
    var objectScrolls: Bool { scrolls }
    static let objectCeiling: Int32 = 320
    static let scrollsPast = 18

    /// How many lines a command is likely to take at the width a card has: every line it holds,
    /// and a long one counted again for each time it is likely to wrap.
    static func estimatedLines(_ text: String, columns: Int = 60) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
            $0 + max(1, ($1.count + columns - 1) / columns)
        }
    }

    /// How many monospaced characters fit across the card as it is now laid out.
    private var columns: Int {
        let width = gtk_widget_get_width(widget)
        return width > 120 ? max(30, Int(Double(width - 60) / 8.2)) : 60
    }

    private func settleObjectMode() {
        let text = gtk_label_get_text(op(object)).map { String(cString: $0) } ?? ""
        placeObject(scrolls: Self.estimatedLines(text, columns: columns) > Self.scrollsPast)
    }
    var objectLabel: UnsafeMutablePointer<GtkWidget> { object }
    var leadLabel: UnsafeMutablePointer<GtkWidget> { lead }
    var errorLabel: UnsafeMutablePointer<GtkWidget> { error }

    init(actions: AgentsActions, select: @escaping @Sendable (String) -> Void) {
        self.actions = actions
        self.select = select
        widget = Gtk.groupBox(GTK_ORIENTATION_VERTICAL, spacing: 8, spoken: "")
        Gtk.addClass(widget, "agents-card")
        Gtk.addClass(widget, "agents-card-needs")
        AgentsParts.settleGlyph(glyph, tone: .attention, motion: .attention)

        let text = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(text, 1)
        gtk_box_append(ptr(text), lead)
        gtk_box_append(ptr(text), meta)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(head), glyph)
        gtk_box_append(ptr(head), text)
        gtk_button_set_child(ptr(headerButton), head)
        Gtk.addClass(headerButton, "flat")
        Gtk.addClass(headerButton, "agents-card-head")
        gtk_widget_set_hexpand(headerButton, 1)
        Gtk.connect(UnsafeMutableRawPointer(headerButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let key = self?.card?.id else { return }
                self?.select(key)
            }
        }

        gtk_label_set_xalign(op(error), 0)
        gtk_box_append(ptr(widget), headerButton)
        g_object_ref_sink(UnsafeMutableRawPointer(objectScroller))
        gtk_scrolled_window_set_policy(op(objectScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(objectScroller), Self.objectCeiling)
        gtk_widget_set_hexpand(objectScroller, 1)
        gtk_widget_set_hexpand(objectHolder, 1)
        gtk_widget_set_valign(object, GTK_ALIGN_START)
        gtk_box_append(ptr(objectHolder), object)
        gtk_box_append(ptr(widget), objectHolder)
        gtk_box_append(ptr(widget), buttons)
        gtk_box_append(ptr(widget), error)
        gtk_box_append(ptr(widget), away)
        gtk_widget_set_visible(error, 0)
        gtk_widget_set_visible(away, 0)
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(objectScroller)) }

    func apply(_ card: AgentAskCard, state: AgentsActionState, now: Date) {
        self.card = card
        self.state = state
        AgentsParts.setText(lead, card.ask.lead)
        let object = card.ask.object ?? ""
        AgentsParts.setText(self.object, object)
        AgentsParts.setVisible(objectHolder, !object.isEmpty)
        settleObjectMode()
        if builtFor != card.ask.id + "|" + card.ask.options.joined(separator: "\u{1f}") {
            rebuildButtons(card)
        }
        AgentsParts.setClass(widget, "agents-away", card.isAway)
        AgentsParts.setVisible(away, card.isAway)
        if card.isAway { AgentsParts.setText(away, AgentsParts.awayLine(profileID: card.profileID, now: now)) }
        tick(now: now)
        refreshButtons()
        tailscode_set_accessible_label(widget, spoken(now: now))
    }

    /// A command is laid out whole, and only one too long to read in a card at once is held in a
    /// box of its own that scrolls — never cut, never a card taller than the window.
    private func placeObject(scrolls next: Bool) {
        guard next != scrolls else { return }
        g_object_ref(UnsafeMutableRawPointer(object))
        if scrolls {
            gtk_scrolled_window_set_child(op(objectScroller), nil)
            gtk_box_remove(ptr(objectHolder), objectScroller)
        } else {
            gtk_box_remove(ptr(objectHolder), object)
        }
        scrolls = next
        if next {
            gtk_scrolled_window_set_child(op(objectScroller), object)
            gtk_box_append(ptr(objectHolder), objectScroller)
        } else {
            gtk_box_append(ptr(objectHolder), object)
        }
        g_object_unref(UnsafeMutableRawPointer(object))
    }

    func tick(now: Date) {
        guard let card else { return }
        settleObjectMode()
        var parts = [card.title, card.machine]
        if let since = card.ask.since {
            parts.append(Localized.text("waiting %@", AgentsParts.age(since, now: now)))
        }
        AgentsParts.setText(meta, parts.joined(separator: " · "))
    }

    func setSelected(_ selected: Bool) {
        AgentsParts.setClass(widget, "agents-selected", selected)
    }

    private func spoken(now: Date) -> String {
        guard let card else { return "" }
        var words = [Localized.text("Needs you"), card.ask.lead, card.title, card.machine]
        if let since = card.ask.since {
            words.append(Localized.text("waiting %@", AgentsParts.age(since, now: now)))
        }
        return words.joined(separator: ", ")
    }

    private func rebuildButtons(_ card: AgentAskCard) {
        AgentsParts.clearChildren(buttons)
        approveButton = nil
        denyButton = nil
        optionButtons = []
        builtFor = card.ask.id + "|" + card.ask.options.joined(separator: "\u{1f}")
        var made: [UnsafeMutablePointer<GtkWidget>] = []
        if card.ask.isApproval {
            let deny = AgentsParts.wrappingButton(Localized.text("Deny"), css: ["agents-deny"]) {
                [weak self] in
                Gtk.onMain { [weak self] in self?.press(.deny) }
            }
            let approve = AgentsParts.wrappingButton(
                Localized.text("Approve"), css: ["suggested-action", "agents-approve"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.press(.approve) }
            }
            tailscode_set_accessible_label(deny, Localized.text("Deny"))
            denyButton = deny
            approveButton = approve
            made = [deny, approve]
        } else {
            for option in card.ask.options {
                let button = AgentsParts.wrappingButton(option, css: ["agents-option"]) {
                    [weak self] in
                    Gtk.onMain { [weak self] in self?.press(.answer(option)) }
                }
                optionButtons.append(button)
                made.append(button)
            }
        }
        guard !made.isEmpty else { return }
        gtk_box_append(ptr(buttons), Gtk.wrapRow(made, spacing: 8))
    }

    private func press(_ action: AgentsAction) {
        guard let card, !card.isAway else { return }
        actions.perform(action, key: card.id, title: card.title)
    }

    /// The buttons say where a press has got to and are dead while it travels or while the machine
    /// is not answering; a failure says why under them and leaves them live.
    func refreshButtons() {
        guard let card else { return }
        let busy = state.blocks(.approve) || card.isAway
        var failure: String?
        if case .failed(_, let why) = state { failure = why }
        AgentsParts.setVisible(error, failure != nil)
        if let failure { AgentsParts.setText(error, Localized.text("Could not send: %@", failure)) }
        for button in [approveButton, denyButton].compactMap({ $0 }) + optionButtons {
            gtk_widget_set_sensitive(button, busy ? 0 : 1)
        }
        if let approve = approveButton {
            AgentsParts.setButtonTitle(approve, title(for: .approve, idle: Localized.text("Approve")))
        }
        if let deny = denyButton {
            AgentsParts.setButtonTitle(deny, title(for: .deny, idle: Localized.text("Deny")))
        }
        for (index, button) in optionButtons.enumerated() where card.ask.options.indices.contains(index) {
            let option = card.ask.options[index]
            AgentsParts.setButtonTitle(button, title(for: .answer(option), idle: option))
        }
    }

    private func title(for action: AgentsAction, idle: String) -> String {
        switch state {
        case .inFlight(let current) where current == action:
            return action == .approve ? Localized.text("Approving…") : Localized.text("Sending…")
        case .sent(let current, _) where current == action:
            return Localized.text("Sent")
        default:
            return idle
        }
    }
}
