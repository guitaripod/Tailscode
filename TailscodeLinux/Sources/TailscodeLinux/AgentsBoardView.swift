import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Now view: a sentence that says how the board stands, how much of it is watched, and then
/// the four places an agent can be — waiting on you, working, in the background, finished — each a
/// list kept by identity. A publish updates the views already there and adds or removes only what
/// came or went, so a card being read does not move under the pointer.
final class AgentsBoardView: @unchecked Sendable {
    enum Kind: Int, CaseIterable {
        case needsYou
        case working
        case background
        case finished

        var title: String {
            switch self {
            case .needsYou: return Localized.text("Needs you")
            case .working: return Localized.text("Working")
            case .background: return Localized.text("In the background")
            case .finished: return Localized.text("Finished")
            }
        }
    }

    private final class Section {
        let kind: Kind
        let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        let header = Gtk.label("", css: "agents-section", selectable: false)
        let side = Gtk.label("", css: "agents-section-side", selectable: false)
        let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        var views: [String: any AgentsItemView] = [:]
        var order: [String] = []

        init(kind: Kind) {
            self.kind = kind
            let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_widget_set_hexpand(header, 1)
            gtk_box_append(ptr(head), header)
            gtk_box_append(ptr(head), side)
            gtk_box_append(ptr(box), head)
            gtk_box_append(ptr(box), list)
            Gtk.addClass(box, "agents-block")
            if kind == .needsYou { Gtk.addClass(header, "agents-section-needs") }
        }
    }

    let widget: UnsafeMutablePointer<GtkWidget>
    private let scroller = gtk_scrolled_window_new()!
    private let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 18)
    private let sentence = Gtk.markupLabel("", css: "agents-sentence", wrap: true)
    private let watch = Gtk.label("", css: "agents-watch", wrap: true, selectable: false)
    private let machines = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let empty = Gtk.label("", css: "agents-empty", wrap: true, selectable: false)
    private var sections: [Kind: Section] = [:]
    private let actions: AgentsActions
    private let hooks: Hooks
    private(set) var board: AgentBoard = .empty
    private var selected: String?

    struct Hooks {
        let select: @Sendable (String) -> Void
        let openChat: @Sendable (String) -> Void
    }

    init(actions: AgentsActions, hooks: Hooks) {
        self.actions = actions
        self.hooks = hooks
        widget = scroller
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)

        gtk_label_set_selectable(op(sentence), 0)
        let head = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_box_append(ptr(head), sentence)
        gtk_box_append(ptr(head), watch)
        gtk_box_append(ptr(head), machines)
        gtk_box_append(ptr(column), head)
        gtk_box_append(ptr(column), empty)
        for kind in Kind.allCases {
            let section = Section(kind: kind)
            sections[kind] = section
            gtk_box_append(ptr(column), section.box)
            gtk_widget_set_visible(section.box, 0)
        }
        Gtk.margins(column, top: 18, bottom: 28, leading: 22, trailing: 22)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(op(UnsafeMutableRawPointer(clamp)), 860)
        adw_clamp_set_tightening_threshold(op(UnsafeMutableRawPointer(clamp)), 860)
        adw_clamp_set_child(op(UnsafeMutableRawPointer(clamp)), column)
        gtk_scrolled_window_set_child(op(scroller), clamp)
        gtk_label_set_text(op(empty), Self.emptyWords)
        gtk_widget_set_visible(empty, 0)
        gtk_widget_set_margin_top(sentence, 0)
    }

    static var emptyWords: String {
        Localized.text(
            "Agents that are working, waiting on you or running in the background on any of your machines are listed here, and a card can be answered without opening its chat. Nothing is running right now.")
    }

    var sentenceLabel: UnsafeMutablePointer<GtkWidget> { sentence }
    var emptyLabel: UnsafeMutablePointer<GtkWidget> { empty }
    var scrolled: UnsafeMutablePointer<GtkWidget> { scroller }
    var contentColumn: UnsafeMutablePointer<GtkWidget> { column }

    func counts() -> [Kind: Int] {
        var result: [Kind: Int] = [:]
        for (kind, section) in sections { result[kind] = section.order.count }
        return result
    }

    func askCard(_ key: String) -> AgentsAskCard? { sections[.needsYou]?.views[key] as? AgentsAskCard }
    func row(_ key: String) -> AgentsRow? {
        (sections[.working]?.views[key] ?? sections[.background]?.views[key]) as? AgentsRow
    }
    func finishRow(_ key: String) -> AgentsFinishRow? {
        sections[.finished]?.views[key] as? AgentsFinishRow
    }

    /// Every key on the board, top to bottom: what a drive verb or an arrow key walks.
    var orderedKeys: [String] {
        Kind.allCases.flatMap { sections[$0]?.order ?? [] }
    }

    func apply(_ board: AgentBoard, now: Date) {
        self.board = board
        gtk_label_set_markup(op(sentence), sentenceMarkup(board))
        AgentsParts.setText(watch, board.watchLine)
        AgentsParts.setVisible(watch, true)
        applyMachines(board)
        let showsMachines = board.showsMachines
        reconcile(
            .needsYou, models: board.needsYou.map { ($0.id, $0) }, make: {
                AgentsAskCard(actions: self.actions, select: self.hooks.select)
            },
            update: { view, card in
                view.apply(card, state: self.actions.state(card.id), now: now)
            })
        reconcile(
            .working, models: board.working.map { ($0.id, $0) }, make: { self.makeRow() },
            update: { view, row in view.apply(row, showsMachines: showsMachines, now: now) })
        reconcile(
            .background, models: board.background.map { ($0.id, $0) }, make: { self.makeRow() },
            update: { view, row in view.apply(row, showsMachines: showsMachines, now: now) })
        reconcile(
            .finished, models: board.finished.map { ($0.id, $0) },
            make: { AgentsFinishRow(open: self.hooks.openChat) },
            update: { view, finish in view.apply(finish, showsMachines: showsMachines, now: now) })
        sections[.finished].map { section in
            AgentsParts.setText(
                section.side,
                board.headline.unread > 0 ? Localized.text("%d unread", board.headline.unread) : "")
            AgentsParts.setVisible(section.side, board.headline.unread > 0)
        }
        let nothing = board.isEmpty
        AgentsParts.setVisible(empty, nothing)
        applySelection(selected)
    }

    func tick(now: Date) {
        for section in sections.values {
            for view in section.views.values { view.tick(now: now) }
        }
    }

    func refresh(key: String, now: Date) {
        if let card = board.needsYou.first(where: { $0.id == key }), let view = askCard(key) {
            view.apply(card, state: actions.state(key), now: now)
        }
    }

    func applySelection(_ key: String?) {
        selected = key
        for section in sections.values {
            for (id, view) in section.views { view.setSelected(id == key) }
        }
    }

    private func makeRow() -> AgentsRow {
        AgentsRow(select: hooks.select, openChat: hooks.openChat)
    }

    private func reconcile<Model, View: AgentsItemView>(
        _ kind: Kind, models: [(String, Model)], make: () -> View,
        update: (View, Model) -> Void
    ) {
        guard let section = sections[kind] else { return }
        var views: [String: any AgentsItemView] = [:]
        var previous: UnsafeMutablePointer<GtkWidget>?
        for (id, model) in models {
            let view = (section.views[id] as? View) ?? make()
            update(view, model)
            views[id] = view
            if gtk_widget_get_parent(view.widget) == section.list {
                gtk_box_reorder_child_after(ptr(section.list), view.widget, previous)
            } else {
                gtk_box_insert_child_after(ptr(section.list), view.widget, previous)
            }
            previous = view.widget
        }
        for (id, view) in section.views where views[id] == nil {
            gtk_box_remove(ptr(section.list), view.widget)
        }
        section.views = views
        section.order = models.map(\.0)
        let count = models.count
        gtk_widget_set_visible(section.box, count > 0 ? 1 : 0)
        AgentsParts.setText(section.header, "\(kind.title.uppercased()) · \(count)")
    }

    /// The headline, each part wearing the tone of what it counts: the working in the live ink, the
    /// waiting in the attention ink. Core wrote the words; only their colours are chosen here, and
    /// only when the parts line up with what Core would have counted.
    private func sentenceMarkup(_ board: AgentBoard) -> String {
        let words = board.sentence
        let parts = words.components(separatedBy: " · ")
        var tones: [ActivityTone] = []
        if board.headline.working > 0 { tones.append(.live) }
        if board.headline.needsYou > 0 { tones.append(.attention) }
        if tones.isEmpty, board.headline.background > 0 { tones.append(.live) }
        let palette = MatrixTheme.palette
        guard parts.count == tones.count, !tones.isEmpty else {
            return PangoMarkdown.escape(words)
        }
        let colored = zip(parts, tones).map { part, tone -> String in
            let hex = tone == .attention ? palette.warn : palette.accent
            return "<span foreground=\"\(hex)\">\(PangoMarkdown.escape(part))</span>"
        }
        let dot = "<span foreground=\"\(palette.textDim)\"> · </span>"
        return colored.joined(separator: dot)
    }

    /// One chip a machine: a computer that runs three agents' servers is three profiles, and three
    /// chips of the same name would read as three computers.
    static func byName(_ machines: [AgentMachine]) -> [(name: String, reachable: Bool?, running: Int)] {
        var order: [String] = []
        var merged: [String: (reachable: Bool?, running: Int)] = [:]
        for machine in machines {
            if var known = merged[machine.name] {
                known.running += machine.running
                if machine.reachable == false { known.reachable = false }
                merged[machine.name] = known
            } else {
                order.append(machine.name)
                merged[machine.name] = (machine.reachable, machine.running)
            }
        }
        return order.map { ($0, merged[$0]?.reachable ?? nil, merged[$0]?.running ?? 0) }
    }

    private func applyMachines(_ board: AgentBoard) {
        AgentsParts.clearChildren(machines)
        AgentsParts.setVisible(machines, board.showsMachines)
        guard board.showsMachines else { return }
        for machine in Self.byName(board.machines) {
            var words = machine.name
            if machine.reachable == false {
                words += " · " + Localized.text("not answering")
            } else if machine.running > 0 {
                words += " · \(machine.running)"
            }
            let chip = Gtk.label(words, css: "agents-machine", selectable: false)
            if machine.reachable == false { Gtk.addClass(chip, "agents-machine-off") }
            tailscode_set_accessible_label(
                chip,
                machine.reachable == false
                    ? Localized.text("%@, not answering", machine.name)
                    : Localized.text("%@, %d running", machine.name, machine.running))
            gtk_box_append(ptr(machines), chip)
        }
    }
}
