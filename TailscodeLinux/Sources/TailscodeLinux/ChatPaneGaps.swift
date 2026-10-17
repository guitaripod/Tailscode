import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// The air above every row, from the one table of gaps. A row's widget is remade whenever its
    /// value changes and a row's neighbours change whenever one arrives, so the margins are written
    /// after every pass over the rows rather than carried by the widgets; GTK ignores a margin that
    /// is already what it is asked to be.
    ///
    /// Only from the first row a pass touched to the end: a margin depends on its row and the one
    /// before it, so rows above the first change are exactly as they were. A streamed token changes
    /// the end of the transcript and costs the end of the transcript.
    func applyGaps() {
        guard renderedRows.count == rowWidgets.count else { return }
        let density = Preferences.chatDensity
        if gapDensity != density {
            gapDensity = density
            gapsDirtyFrom = 0
        }
        guard gapsDirtyFrom < renderedRows.count else {
            gapsDirtyFrom = Int.max
            return
        }
        let metrics = TranscriptGaps.metrics
        for index in gapsDirtyFrom..<renderedRows.count {
            guard let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]) else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let wanted = Int32(
                TranscriptGaps.margin(at: index, in: renderedRows, metrics: metrics).rounded())
            if gtk_widget_get_margin_top(widget) != wanted {
                gtk_widget_set_margin_top(widget, wanted)
            }
        }
        gapsDirtyFrom = Int.max
    }

    /// Rows from `index` on need their margins set again.
    func markGaps(from index: Int) {
        gapsDirtyFrom = min(gapsDirtyFrom, max(0, index))
    }
}
