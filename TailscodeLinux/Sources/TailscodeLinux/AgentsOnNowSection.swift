import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One press-able line of the "On now" section: a tone dot, the chat's title on one line, how long
/// it has run, and the words of what it is doing dimmed beneath.
final class AgentsOnNowButton: @unchecked Sendable {
    let widget = gtk_button_new()!
    private let dot = Gtk.label("●", css: "agents-now-dot", selectable: false)
    private let title = Gtk.label("", css: "agents-now-title", selectable: false)
    private let elapsed = Gtk.label("", css: "agents-now-elapsed", selectable: false)
    private let words = Gtk.label("", css: "agents-now-words", selectable: false)
    private(set) var row: AgentsOnNowRow?

    var titleLabel: UnsafeMutablePointer<GtkWidget> { title }
    var wordsLabel: UnsafeMutablePointer<GtkWidget> { words }
    var elapsedLabel: UnsafeMutablePointer<GtkWidget> { elapsed }
    var titleText: String { text(title) }
    var wordsText: String { text(words) }
    var elapsedText: String { text(elapsed) }

    private func text(_ label: UnsafeMutablePointer<GtkWidget>) -> String {
        gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
    }

    init(open: @escaping @Sendable (String) -> Void) {
        Gtk.addClass(widget, "flat")
        Gtk.addClass(widget, "agents-now-row")
        tailscode_set_accessible_hidden(dot, 1)
        gtk_widget_set_valign(dot, GTK_ALIGN_START)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_valign(elapsed, GTK_ALIGN_CENTER)
        gtk_label_set_xalign(op(elapsed), 1)
        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(top), title)
        gtk_box_append(ptr(top), elapsed)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(column, 1)
        gtk_box_append(ptr(column), top)
        gtk_box_append(ptr(column), words)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 7)
        gtk_box_append(ptr(line), dot)
        gtk_box_append(ptr(line), column)
        gtk_button_set_child(ptr(widget), line)
        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let key = self?.row?.key else { return }
                open(key)
            }
        }
    }

    func apply(_ next: AgentsOnNowRow, now: Date) {
        row = next
        AgentsParts.setText(title, next.title)
        AgentsParts.setText(words, next.words)
        AgentsParts.setVisible(words, !next.words.isEmpty)
        Gtk.setTone(dot, next.tone.glyphCSS, from: ["glyph-running", "glyph-needs"])
        AgentsParts.setClass(widget, "agents-now-needs", next.needsYou)
        tick(now: now)
        var spoken = [next.title, next.words]
        if let since = next.since { spoken.append(AgentsParts.clock(since, now: now)) }
        tailscode_set_accessible_label(widget, spoken.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func tick(now: Date) {
        let age = row?.since.map { AgentsParts.clock($0, now: now) } ?? ""
        AgentsParts.setText(elapsed, age)
        AgentsParts.setVisible(elapsed, !age.isEmpty)
    }
}

/// The running chats right under the Agents card, at most four, the ones that wait on the person
/// first and in amber. It collapses out of the sidebar when nothing runs, and its clocks tick once
/// a second only while it is on screen.
final class AgentsOnNowSection: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let header = Gtk.label(Localized.text("On now").uppercased(), css: "agents-now-header", selectable: false)
    private let buttons: [AgentsOnNowButton]
    private var token = 0
    private var looping = false
    private(set) var rows: [AgentsOnNowRow] = []

    var isShown: Bool { gtk_widget_get_visible(widget) != 0 }
    var shownButtons: [AgentsOnNowButton] { buttons.filter { gtk_widget_get_visible($0.widget) != 0 } }
    var headerText: String { gtk_label_get_text(op(header)).map { String(cString: $0) } ?? "" }

    init(open: @escaping @Sendable (String) -> Void) {
        buttons = (0..<AgentsReading.capacity).map { _ in AgentsOnNowButton(open: open) }
        Gtk.addClass(widget, "agents-now")
        gtk_widget_set_visible(widget, 0)
        gtk_widget_set_hexpand(header, 1)
        tailscode_set_accessible_hidden(header, 1)
        gtk_box_append(ptr(widget), header)
        for button in buttons {
            gtk_widget_set_visible(button.widget, 0)
            gtk_box_append(ptr(widget), button.widget)
        }
        Gtk.margins(widget, top: 0, bottom: 4, leading: 6, trailing: 6)
        Gtk.connect(UnsafeMutableRawPointer(widget), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.startClock() }
        }
    }

    func apply(_ next: [AgentsOnNowRow]) {
        rows = next
        let now = Date()
        for (index, button) in buttons.enumerated() {
            if index < next.count {
                button.apply(next[index], now: now)
                gtk_widget_set_visible(button.widget, 1)
            } else {
                gtk_widget_set_visible(button.widget, 0)
            }
        }
        gtk_widget_set_visible(widget, next.isEmpty ? 0 : 1)
        if next.isEmpty {
            token += 1
            looping = false
        } else {
            startClock()
        }
    }

    private func startClock() {
        guard !looping, !rows.isEmpty, gtk_widget_get_mapped(widget) != 0 else { return }
        looping = true
        token += 1
        beat(token)
    }

    private func beat(_ mine: Int) {
        Gtk.after(1000) { [weak self] in
            guard let self, self.token == mine else { return }
            guard gtk_widget_get_mapped(self.widget) != 0, !self.rows.isEmpty else {
                self.looping = false
                return
            }
            let now = Date()
            for button in self.buttons { button.tick(now: now) }
            self.beat(mine)
        }
    }
}
