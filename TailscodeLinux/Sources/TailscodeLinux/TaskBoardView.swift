import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The agent's plan as one card: what is done struck through and quiet, the task it is on now in
/// the accent wearing its present-tense wording, what is still ahead dim. The card is the fold of
/// the whole transcript (``TaskBoard``), placed at the last call that moved the list.
enum TaskBoardView {
    static func make(_ board: TaskBoard) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 5)
        Gtk.addClass(card, "task-board")

        let header = Gtk.label(board.headline, css: "task-board-head", selectable: false)
        gtk_label_set_xalign(op(header), 0)
        gtk_box_append(ptr(card), header)

        for item in board.items {
            let glyph: String
            let colour: String
            let body: String
            switch item.status {
            case .completed:
                glyph = "✔"
                colour = palette.textDim
                body = "<s>\(PangoMarkdown.escape(item.subject))</s>"
            case .inProgress:
                glyph = "◐"
                colour = palette.accent
                body = PangoMarkdown.escape(item.activeForm ?? item.subject)
            case .pending:
                glyph = "○"
                colour = palette.textDim
                body = PangoMarkdown.escape(item.subject)
            }
            let markup =
                "<span foreground=\"\(colour)\">\(glyph)</span>  "
                + "<span foreground=\"\(item.status == .inProgress ? palette.text : palette.textDim)\">\(body)</span>"
            let row = Gtk.markupLabel(markup, css: "task-board-item")
            gtk_label_set_xalign(op(row), 0)
            gtk_box_append(ptr(card), row)
        }
        return card
    }
}
