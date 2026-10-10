import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// The air above every row, from the one table of gaps. A row's widget is remade whenever its
    /// value changes and a row's neighbours change whenever one arrives, so the margins are written
    /// after every pass over the rows rather than carried by the widgets; GTK ignores a margin that
    /// is already what it is asked to be.
    func applyGaps() {
        guard renderedRows.count == rowWidgets.count else { return }
        let margins = TranscriptGaps.margins(for: renderedRows, metrics: TranscriptGaps.metrics)
        for (index, bits) in rowWidgets.enumerated() {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let wanted = Int32(margins[index].rounded())
            if gtk_widget_get_margin_top(widget) != wanted {
                gtk_widget_set_margin_top(widget, wanted)
            }
        }
    }
}
