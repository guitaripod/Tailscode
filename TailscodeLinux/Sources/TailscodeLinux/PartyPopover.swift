import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What the party's popover asks of the pane it is opened from.
final class PartyHooks: @unchecked Sendable {
    var inputs: () -> PartyInputs = { PartyInputs(sources: [], model: nil, effort: nil, agentOptions: []) }
    var take: (PartyCard) -> Void = { _ in }
    var pick: (ModelPick) -> Void = { _ in }
    var fill: (Int) -> Void = { _ in }
    var addRecent: (PartyRecent, UnsafeMutablePointer<GtkWidget>) -> Void = { _, _ in }
    var catalog: () -> Void = {}
}

/// What the model pill opens: six cards you carry, then the models used lately and the door to
/// every other one. Edit turns the cards editable in place. Everything a card says is Core's
/// reading (`PartyReading`); this draws it, and a change to the party anywhere redraws it.
final class PartyPopover: @unchecked Sendable {
    static let width: Int32 = 612
    let popover: UnsafeMutablePointer<GtkWidget>
    private let hooks: PartyHooks
    let actions = PartyActions()
    private var grid: PartyGridView?
    private var title: UnsafeMutablePointer<GtkWidget>?
    private var count: UnsafeMutablePointer<GtkWidget>?
    private var editButton: UnsafeMutablePointer<GtkWidget>?
    private var footer: UnsafeMutablePointer<GtkWidget>?
    private var observer: ObserverToken?
    private(set) var editing = false
    /// How the pill that owns this popover closes it, so the pill's own toggle lets go in step: a
    /// popover put away behind its menu button's back leaves the button believing it is open, and
    /// the next press on it only closes what is already closed.
    var owner: (() -> Void)?
    private var cards: [PartyCard] = []
    private var note: String?
    private var noteGeneration = 0

    init(hooks: PartyHooks) {
        self.hooks = hooks
        popover = gtk_popover_new()!
        Gtk.addClass(popover, "party-pop")
        gtk_popover_set_has_arrow(ptr(popover), 1)
        wire()
        Gtk.connect(UnsafeMutableRawPointer(popover), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.focusStart() }
        }
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") { [weak self] in
            Gtk.onMain { [weak self] in self?.tearDown() }
        }
        Gtk.onKey(popover) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
    }

    /// The card actions, which differ by mode: a press takes a slot outside edit mode and does
    /// nothing in it but what the control pressed says.
    private func wire() {
        actions.activate = { [weak self] slot in
            guard let self, let card = self.cards.first(where: { $0.slot == slot }) else { return }
            if card.isHollow {
                self.close()
                self.hooks.fill(slot)
            } else if !self.editing {
                self.close()
                self.hooks.take(card)
            }
        }
        actions.stepLevel = { [weak self] slot in self?.stepLevel(slot) }
        actions.release = { slot in PartyEdits.release(slot) }
        actions.rename = { slot, name in PartyEdits.rename(slot, name) }
        actions.swap = { first, second in PartyEdits.swap(first, second) }
        actions.replace = { [weak self] slot in
            self?.close()
            self?.hooks.fill(slot)
        }
    }

    func close() {
        if let owner { owner() } else { gtk_popover_popdown(ptr(popover)) }
    }

    /// Builds the content the popover is about to show. GTK sizes a popover's surface from what it
    /// holds at the moment it is presented, and pops it down again if content that arrives later
    /// needs more room than that surface has, so this runs before the popup and never after: a
    /// popover that was emptied on close and filled once it was on screen dismissed itself
    /// milliseconds after opening, which was the pill's dead press and the party that did not
    /// come back after a fill.
    func fillForPopup() {
        retire()
        gtk_popover_set_child(ptr(popover), prepare())
    }

    /// Says what just happened in the header, where the count is, for a couple of seconds. The
    /// words belong here and not in a toast when the party opens straight after the change: the
    /// popover sits over the toast's corner of the window.
    func announce(_ words: String) {
        note = words
        noteGeneration += 1
        let generation = noteGeneration
        reload()
        Gtk.after(2400) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.noteGeneration == generation else { return }
                self.note = nil
                self.reload()
            }
        }
    }

    /// Opens the popover on its own parent, content first.
    func popup() {
        fillForPopup()
        gtk_popover_popup(ptr(popover))
    }

    /// The arrows start from the card the chat runs, or the first held one: a popover that opens
    /// with the focus on its Edit button makes every walk begin with a stray press.
    private func focusStart() {
        let start = grid?.views.first { $0.card.isInUse } ?? grid?.views.first { !$0.card.isHollow }
        if let body = start?.anchor { gtk_widget_grab_focus(body) }
    }

    /// The popover's content, built and reading the party, for the popover to hold or for a
    /// harness to lay out in a window of its own: a popover that never maps proves nothing about
    /// the width it would have had.
    func prepare() -> UnsafeMutablePointer<GtkWidget> {
        editing = false
        let shell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(shell, Self.width, -1)

        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(head, top: 14, bottom: 6, leading: 12, trailing: 14)
        let title = Gtk.label(Localized.text("Party"), css: "party-head", selectable: false)
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(head), title)
        let count = Gtk.label("", css: "party-count", selectable: false)
        gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(head), count)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(head), spacer)
        let edit = gtk_button_new()!
        Gtk.addClass(edit, "party-edit")
        gtk_widget_set_valign(edit, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(edit), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.toggleEditing() }
        }
        gtk_box_append(ptr(head), edit)
        gtk_box_append(ptr(shell), head)
        self.title = title
        self.count = count
        editButton = edit

        let grid = PartyGridView(actions: actions)
        gtk_widget_set_margin_start(grid.widget, 4)
        gtk_widget_set_margin_end(grid.widget, 14)
        gtk_box_append(ptr(shell), grid.widget)
        self.grid = grid

        let rule = Gtk.hairline()
        Gtk.margins(rule, top: 10, leading: 12, trailing: 14)
        gtk_box_append(ptr(shell), rule)
        let footer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(footer, top: 8, bottom: 12, leading: 12, trailing: 14)
        gtk_box_append(ptr(shell), footer)
        self.footer = footer

        observe()
        reload()
        return shell
    }

    private func observe() {
        observer = ObserverToken(
            NotificationCenter.default.addObserver(
                forName: ModelParty.didChange, object: nil, queue: nil
            ) { [weak self] _ in
                Gtk.onMain { [weak self] in self?.reload() }
            })
    }

    private func tearDown() {
        retire()
        gtk_popover_set_child(ptr(popover), nil)
    }

    /// Lets go of everything the content held: the grid, the header, the watch on the party.
    func retire() {
        grid?.commitAll()
        if let observer { NotificationCenter.default.removeObserver(observer.observer) }
        observer = nil
        grid = nil
        title = nil
        count = nil
        editButton = nil
        footer = nil
        cards = []
        editing = false
    }

    /// Reads the party again and says it to the cards and the header, in place.
    func reload() {
        guard let grid else { return }
        let inputs = hooks.inputs()
        cards = inputs.cards
        grid.apply(cards, editing: editing)
        let held = cards.filter { !$0.isHollow }.count
        if let count {
            gtk_label_set_text(op(count), note ?? Localized.text("%d of %d", held, ModelParty.size))
            if note == nil {
                gtk_widget_remove_css_class(count, "party-note")
            } else {
                gtk_widget_add_css_class(count, "party-note")
            }
        }
        if let title {
            gtk_label_set_text(op(title), Localized.text(editing ? "Edit party" : "Party"))
        }
        if let editButton {
            gtk_button_set_label(ptr(editButton), Localized.text(editing ? "Done" : "Edit"))
        }
        fillFooter(inputs)
    }

    func toggleEditing() {
        grid?.commitAll()
        editing.toggle()
        reload()
    }

    private func stepLevel(_ slot: Int) {
        guard let card = cards.first(where: { $0.slot == slot }), let preset = card.preset,
            let resolved = card.resolved, card.takesLevels,
            let source = hooks.inputs().sources.first(where: { $0.profileID == card.profileID })
        else { return }
        let options = ModelEffort.options(
            models: source.models, selection: resolved.selection,
            agentOptions: hooks.inputs().agentOptions)
        guard let next = PartyEdits.nextLevel(after: preset.effort, options: options) else { return }
        PartyEdits.setEffort(slot, next)
    }

    /// Recent models and the door to the rest — or, while editing, the three things a hand can do.
    private func fillFooter(_ inputs: PartyInputs) {
        guard let footer else { return }
        Gtk.removeChildren(of: footer)
        if editing {
            let hint = Gtk.label(
                Localized.text(
                    "Click a name to rename it. Click the ball to change its level. Drag a card onto another to swap."
                ), css: "party-hint", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(hint), 60)
            gtk_widget_set_hexpand(hint, 1)
            gtk_box_append(ptr(footer), hint)
            return
        }
        let recents = inputs.recents
        if !recents.isEmpty {
            let word = Gtk.label(Localized.text("Recent"), css: "party-recent", selectable: false)
            gtk_widget_set_valign(word, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(footer), word)
        }
        for recent in recents { gtk_box_append(ptr(footer), chip(for: recent)) }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(footer), spacer)
        let all = gtk_button_new()!
        Gtk.addClass(all, "flat")
        Gtk.addClass(all, "party-all")
        gtk_button_set_child(
            ptr(all), Gtk.label(Localized.text("All models…"), css: "party-all-word", selectable: false))
        gtk_widget_set_valign(all, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(all), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.close()
                self?.hooks.catalog()
            }
        }
        gtk_box_append(ptr(footer), all)
    }

    /// A model used lately, as a chip: its house's dot and its word. A press takes it on the
    /// machine that runs it, exactly as a pick from the chooser does; the right button offers it
    /// to the party.
    private func chip(for recent: PartyRecent) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "party-chip")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let dot = Gtk.label("●", css: "dial-row-dot", selectable: false)
        gtk_widget_set_valign(dot, GTK_ALIGN_START)
        gtk_widget_set_margin_top(dot, 2)
        if let chip = recent.chip {
            Gtk.addClass(dot, ModelTint.identityClass(family: chip.family, name: chip.name))
        }
        gtk_box_append(ptr(line), dot)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let word = Gtk.label(recent.word, css: "party-chip-word", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(word), 20)
        gtk_box_append(ptr(words), word)
        if let machine = recent.machine {
            let place = Gtk.label(machine, css: "party-chip-machine", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(place), 20)
            gtk_box_append(ptr(words), place)
        }
        gtk_box_append(ptr(line), words)
        gtk_button_set_child(ptr(button), line)
        let spoken = recent.machine.map { recent.word + ", " + Localized.text("on %@", $0) } ?? recent.word
        tailscode_set_accessible_label(button, spoken)
        let pick = ModelPick(
            profileID: recent.profileID, selection: recent.selection,
            isElsewhere: recent.machine != nil, serverName: recent.machine ?? "",
            modelName: recent.word)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                self?.close()
                self?.hooks.pick(pick)
            }
        }
        let buttonBits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { [weak self] x, y in
            Gtk.onMain { [weak self] in
                guard let self, let footer = self.footer,
                    let source = UnsafeMutablePointer<GtkWidget>(bitPattern: buttonBits)
                else { return }
                let anchor: UnsafeMutablePointer<GtkWidget> = footer
                let anchorBits = UInt(bitPattern: anchor)
                let point = Gtk.bounds(of: source, in: anchor)
                Gtk.contextMenu(
                    on: anchor, x: (point?.x ?? 0) + x, y: (point?.y ?? 0) + y,
                    rows: [
                        (
                            Localized.text("Add to party"), nil,
                            {
                                Gtk.onMain {
                                    guard
                                        let held = UnsafeMutablePointer<GtkWidget>(
                                            bitPattern: anchorBits)
                                    else { return }
                                    self.hooks.addRecent(recent, held)
                                }
                            }
                        )
                    ])
            }
        }
        return button
    }

    /// Ctrl+E edits and finishes, F2 renames the focused card, and Delete puts the focused card
    /// back in the box — except while a name is being typed, where it deletes a letter.
    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard grid != nil else { return false }
        let control = state & KeyChord.controlMask != 0
        if control, Keymap.scalar(keyval) == "e" {
            toggleEditing()
            return true
        }
        guard editing, !control else { return false }
        switch keyval {
        case Self.f2:
            guard let card = grid?.focused ?? grid?.views.first(where: { !$0.card.isHollow })
            else { return false }
            card.focusName()
            return true
        case Self.delete:
            guard let grid, !grid.focusIsInName, let card = grid.focused, !card.card.isHollow
            else { return false }
            PartyEdits.release(card.slot)
            return true
        default:
            return false
        }
    }

    static let f2: UInt32 = 0xFFBF
    static let delete: UInt32 = 0xFFFF

    var gridView: PartyGridView? { grid }

    var currentCards: [PartyCard] { cards }
}
