import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One session doing work, or carrying it: the glyph in its tone and motion, the title, how long it
/// has run, the line of what it is doing, its heartbeat, the machine and model, and the agents it
/// has out hanging beneath as a tree. A click selects it for the peek; the chat is a verb of its
/// own, in the peek and on the context menu.
final class AgentsRow: AgentsItemView, @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget> = gtk_button_new()!
    private let glyph = AgentsParts.glyph()
    private let title = Gtk.label("", css: "agents-title", wrap: true, selectable: false)
    private let elapsed = Gtk.label("", css: "agents-elapsed", selectable: false)
    private let line = Gtk.label("", css: "agents-line", wrap: true, selectable: false)
    private let beat = AgentBeatStrip()
    private let word = Gtk.label("", css: "agents-word", selectable: false)
    private let machine = Gtk.label("", css: "agents-machine-name", selectable: false)
    private let modelHolder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let unread = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let folded = Gtk.label("", css: "agents-folded", selectable: false)
    private let tree = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let away = Gtk.label("", css: "agents-meta", wrap: true, selectable: false)
    private let select: @Sendable (String) -> Void
    private let openChat: @Sendable (String) -> Void
    private(set) var row: AgentRow?
    private var treeFor: [AgentChild] = []
    private var chipFor: ModelChip?
    private var ages: [(label: UnsafeMutablePointer<GtkWidget>, since: Date)] = []

    var titleLabel: UnsafeMutablePointer<GtkWidget> { title }
    var lineLabel: UnsafeMutablePointer<GtkWidget> { line }
    var beatStrip: AgentBeatStrip { beat }
    var treeBox: UnsafeMutablePointer<GtkWidget> { tree }

    init(select: @escaping @Sendable (String) -> Void, openChat: @escaping @Sendable (String) -> Void) {
        self.select = select
        self.openChat = openChat
        Gtk.addClass(widget, "flat")
        Gtk.addClass(widget, "agents-row")
        gtk_widget_set_hexpand(widget, 1)

        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_valign(elapsed, GTK_ALIGN_START)
        gtk_label_set_lines(op(line), 2)
        gtk_label_set_ellipsize(op(line), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(unread, GTK_ALIGN_CENTER)
        Gtk.addClass(unread, "agents-unread")
        tailscode_set_accessible_label(unread, Localized.text("Unread"))
        gtk_widget_set_visible(unread, 0)
        gtk_widget_set_hexpand(machine, 1)
        gtk_widget_set_halign(machine, GTK_ALIGN_END)
        gtk_label_set_xalign(op(machine), 1)
        gtk_widget_set_margin_start(tree, 4)

        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(top), title)
        gtk_box_append(ptr(top), elapsed)
        let facts = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_valign(facts, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(facts), beat.widget)
        gtk_box_append(ptr(facts), word)
        gtk_box_append(ptr(facts), machine)
        gtk_box_append(ptr(facts), modelHolder)
        gtk_box_append(ptr(facts), unread)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_hexpand(column, 1)
        gtk_box_append(ptr(column), top)
        gtk_box_append(ptr(column), line)
        gtk_box_append(ptr(column), facts)
        gtk_box_append(ptr(column), folded)
        gtk_box_append(ptr(column), tree)
        gtk_box_append(ptr(column), away)
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(content), glyph)
        gtk_box_append(ptr(content), column)
        gtk_button_set_child(ptr(widget), content)

        gtk_widget_set_halign(folded, GTK_ALIGN_START)
        gtk_widget_set_visible(folded, 0)
        gtk_widget_set_visible(away, 0)
        gtk_widget_set_visible(word, 0)

        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let key = self?.row?.id else { return }
                self?.select(key)
            }
        }
        Gtk.onRightClick(widget) { [weak self] x, y in
            Gtk.onMain { [weak self] in self?.showMenu(x, y) }
        }
    }

    private func showMenu(_ x: Double, _ y: Double) {
        guard let key = row?.id else { return }
        let open = openChat
        let pick = select
        Gtk.contextMenu(
            on: widget, x: x, y: y,
            rows: [
                (Localized.text("Peek"), nil, { pick(key) }),
                (Localized.text("Open chat"), nil, { open(key) }),
            ])
    }

    func apply(_ row: AgentRow, showsMachines: Bool, now: Date) {
        self.row = row
        AgentsParts.settleGlyph(glyph, tone: row.tone, motion: row.motion)
        AgentsParts.setText(title, row.title)
        let line = row.line ?? ""
        AgentsParts.setText(self.line, line)
        AgentsParts.setVisible(self.line, !line.isEmpty)
        beat.show(beat: row.beat, tone: row.tone)
        let said = row.word ?? (row.isWatched ? nil : Localized.text("listed"))
        AgentsParts.setText(word, said ?? "")
        AgentsParts.setVisible(word, said != nil)
        AgentsParts.setText(machine, row.machine)
        AgentsParts.setVisible(machine, showsMachines)
        AgentsParts.setVisible(unread, row.unread)
        applyChip(row.chip)
        applyTree(row, now: now)
        AgentsParts.setClass(widget, "agents-away", row.isAway)
        AgentsParts.setVisible(away, row.isAway)
        if row.isAway { AgentsParts.setText(away, AgentsParts.awayLine(profileID: row.profileID, now: now)) }
        tick(now: now)
        tailscode_set_accessible_label(widget, spoken(row, now: now))
    }

    func tick(now: Date) {
        guard let row else { return }
        AgentsParts.setText(elapsed, row.startedAt.map { AgentsParts.clock($0, now: now) } ?? "")
        for entry in ages { AgentsParts.setText(entry.label, AgentsParts.age(entry.since, now: now)) }
    }

    func setSelected(_ selected: Bool) {
        AgentsParts.setClass(widget, "agents-selected", selected)
    }

    private func spoken(_ row: AgentRow, now: Date) -> String {
        var words = [row.title]
        words.append(row.motion.isAnimated ? Localized.text("Working") : Localized.text("Settled"))
        if let started = row.startedAt { words.append(AgentsParts.clock(started, now: now)) }
        if let line = row.line { words.append(line) }
        if !row.isWatched { words.append(Localized.text("listed")) }
        if row.beat != nil, beat.isStalled { words.append(beat.spoken) }
        words.append(row.machine)
        if !row.children.isEmpty {
            words.append(Localized.text("%d agents", row.children.count))
        } else if row.listedAgents > 0 {
            words.append(Localized.text("%d agents", row.listedAgents))
        }
        return words.joined(separator: ", ")
    }

    private func applyChip(_ chip: ModelChip?) {
        guard chip != chipFor else { return }
        chipFor = chip
        AgentsParts.clearChildren(modelHolder)
        guard let chip else { return }
        gtk_box_append(ptr(modelHolder), SidebarRow.modelLabel(chip))
    }

    private func applyTree(_ row: AgentRow, now: Date) {
        let count = max(row.listedAgents, 0)
        let listedOnly = row.children.isEmpty && count > 0
        AgentsParts.setVisible(folded, listedOnly)
        if listedOnly { AgentsParts.setText(folded, Localized.text("%d agents", count)) }
        guard row.children != treeFor else { return }
        treeFor = row.children
        AgentsParts.clearChildren(tree)
        ages = []
        AgentsParts.setVisible(tree, !row.children.isEmpty)
        for child in row.children {
            let made = AgentsChildLine.make(child, now: now)
            if let age = made.age { ages.append(age) }
            gtk_box_append(ptr(tree), made.widget)
        }
    }
}

extension AgentsParts {
    /// A child's mark: breathing while it runs, held still when it is not, and never the green of a
    /// whole session's turn for a task that merely sits in the background.
    static func settleChildGlyph(
        _ label: UnsafeMutablePointer<GtkWidget>, active: Bool, background: Bool
    ) {
        let tone: ActivityTone = active ? .live : .quiet
        Gtk.setTone(label, tone.glyphCSS, from: ["glyph-running", "glyph-needs", "glyph-error", "glyph-pending"])
        let text = background ? "◔" : "○"
        guard active else {
            ActivityPulse.apply(nil, to: label)
            gtk_label_set_text(op(label), text)
            return
        }
        gtk_label_set_text(op(label), text)
        ActivityPulse.apply(
            ActivityIcon(symbol: "circle", glyph: text, tone: .live, motion: .working), to: label)
    }
}

/// Todos done of total, as a bar a person reads in a glance and a figure a screen reader reads.
enum AgentsTodoBar {
    static func make(done: Int, total: Int) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        let bar = gtk_progress_bar_new()!
        Gtk.addClass(bar, "agents-todos")
        gtk_progress_bar_set_fraction(op(bar), total > 0 ? Double(done) / Double(total) : 0)
        gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(bar, 44, -1)
        tailscode_set_accessible_hidden(bar, 1)
        gtk_box_append(ptr(box), bar)
        return box
    }
}

/// A turn that ended in the last hour: a tick or a cross, how it went in a line, how long ago, and
/// a dot while nobody has read it. A click opens the chat, because there is nothing left to peek at.
final class AgentsFinishRow: AgentsItemView, @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget> = gtk_button_new()!
    private let mark = Gtk.label("", css: "agents-glyph", selectable: false)
    private let title = Gtk.label("", css: "agents-title", wrap: true, selectable: false)
    private let line = Gtk.label("", css: "agents-line", wrap: true, selectable: false)
    private let machine = Gtk.label("", css: "agents-meta", selectable: false)
    private let ended = Gtk.label("", css: "agents-elapsed", selectable: false)
    private let unread = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let open: @Sendable (String) -> Void
    private(set) var finish: AgentFinish?

    var titleLabel: UnsafeMutablePointer<GtkWidget> { title }
    var lineLabel: UnsafeMutablePointer<GtkWidget> { line }

    init(open: @escaping @Sendable (String) -> Void) {
        self.open = open
        Gtk.addClass(widget, "flat")
        Gtk.addClass(widget, "agents-row")
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        tailscode_set_accessible_hidden(mark, 1)
        gtk_widget_set_hexpand(title, 1)
        Gtk.addClass(unread, "agents-unread")
        gtk_widget_set_valign(unread, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(unread, Localized.text("Unread"))
        gtk_widget_set_valign(ended, GTK_ALIGN_START)

        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(top), title)
        gtk_box_append(ptr(top), unread)
        gtk_box_append(ptr(top), ended)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(column, 1)
        gtk_box_append(ptr(column), top)
        gtk_box_append(ptr(column), line)
        gtk_box_append(ptr(column), machine)
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(content), mark)
        gtk_box_append(ptr(content), column)
        gtk_button_set_child(ptr(widget), content)
        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let key = self?.finish?.id else { return }
                self?.open(key)
            }
        }
    }

    func apply(_ finish: AgentFinish, showsMachines: Bool, now: Date) {
        self.finish = finish
        let face = AgentsParts.finishGlyph(finish.outcome)
        gtk_label_set_text(op(mark), face.glyph)
        Gtk.setTone(
            mark, face.tone.glyphCSS,
            from: ["glyph-running", "glyph-needs", "glyph-error", "glyph-pending"])
        AgentsParts.setText(title, finish.title)
        AgentsParts.setText(line, finish.line)
        AgentsParts.setText(machine, finish.machine)
        AgentsParts.setVisible(machine, showsMachines)
        AgentsParts.setVisible(unread, finish.unread)
        tick(now: now)
        tailscode_set_accessible_label(
            widget,
            [
                finish.title, finish.line, finish.unread ? Localized.text("Unread") : "",
                Localized.text("%@ ago", AgentsParts.age(finish.endedAt, now: now)),
            ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func tick(now: Date) {
        guard let finish else { return }
        AgentsParts.setText(ended, AgentsParts.age(finish.endedAt, now: now))
    }

    func setSelected(_ selected: Bool) {
        AgentsParts.setClass(widget, "agents-selected", selected)
    }
}
