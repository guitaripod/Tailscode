import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One agent a session has out — a subagent with its errand and its todos, or the background task
/// the machine carries — as the line it hangs from its session on, in the board's tree and in the
/// peek's list alike.
enum AgentsChildLine {
    static func make(_ child: AgentChild, now: Date) -> (
        widget: UnsafeMutablePointer<GtkWidget>, age: (label: UnsafeMutablePointer<GtkWidget>, since: Date)?
    ) {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(line, "agents-child")
        let mark = AgentsParts.glyph()
        let background = child.kind == .background
        AgentsParts.settleChildGlyph(mark, active: child.isActive, background: background)
        gtk_box_append(ptr(line), mark)
        let words = Gtk.label("", css: "agents-child-words", wrap: true, selectable: false)
        gtk_label_set_use_markup(op(words), 1)
        let said = child.line.isEmpty ? "" : " " + PangoMarkdown.escape(child.line)
        gtk_label_set_markup(op(words), "<b>\(PangoMarkdown.escape(child.title))</b>\(said)")
        gtk_widget_set_hexpand(words, 1)
        gtk_box_append(ptr(line), words)
        if let todos = child.todos {
            gtk_box_append(ptr(line), AgentsTodoBar.make(done: todos.done, total: todos.total))
        }
        var age: (label: UnsafeMutablePointer<GtkWidget>, since: Date)?
        if let started = child.startedAt, background {
            let label = Gtk.label(
                AgentsParts.age(started, now: now), css: "agents-elapsed", selectable: false)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            age = (label, started)
            gtk_box_append(ptr(line), label)
        }
        tailscode_set_accessible_label(
            line,
            [
                child.title, child.line,
                child.todos.map { Localized.text("%d of %d done", $0.done, $0.total) } ?? "",
            ].filter { !$0.isEmpty }.joined(separator: ", "))
        return (line, age)
    }
}
