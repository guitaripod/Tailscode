import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainView {
    func metrics(forWidth width: Double) -> NeuralStageMetrics {
        let zones = model.browseState.list.zoneChips.count
        let viewport = host?.viewportHeight
        let bucket = Int(viewport ?? 0)
        let need = BrainCard.neededHeight(for: self, width: width)
        if let memo = metricsMemo, memo.width == width, memo.density == density, memo.zones == zones,
            memo.viewport == bucket, memo.need == need
        {
            return memo.value
        }
        let made = NeuralStageMetrics.make(
            width: width, density: density, zonesWithSteps: max(zones, 1), viewportHeight: viewport,
            cardMinHeight: need)
        metricsMemo = (width, density, zones, bucket, need, made)
        return made
    }

    /// The metrics for the width the row has now.
    var currentMetrics: NeuralStageMetrics {
        let width = Double(gtk_widget_get_width(widget))
        return metrics(forWidth: width > 0 ? width : lastWidth > 0 ? lastWidth : 600)
    }

    func height(forWidth width: Int) -> Int {
        let m = metrics(forWidth: Double(max(width, 1)))
        switch phase {
        case .closed:
            return Int(m.card.height.rounded())
        case .open:
            return Int(m.openHeight.rounded())
        case .moving:
            return Int((moveState?.frame.rowHeight ?? m.rowHeight).rounded())
        }
    }

    func solve(width: Int, height: Int, sink: OpaquePointer) {
        let m = metrics(forWidth: Double(max(width, 1)))
        if Double(width) != lastWidth || m.density != lastDensity {
            lastWidth = Double(width)
            lastDensity = m.density
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.widthChanged()
            }
        }
        switch phase {
        case .closed: placeCard(sink, m, offset: 0)
        case .open: placeOpen(sink, m)
        case .moving: placeMoving(sink, m)
        }
    }

    func place(
        _ sink: OpaquePointer, _ child: UnsafeMutablePointer<GtkWidget>?,
        _ rect: NeuralRect, dx: Double = 0, dy: Double = 0
    ) {
        guard let child else { return }
        tailscode_brain_row_place(
            sink, child, Int32((rect.x + dx).rounded()), Int32((rect.y + dy).rounded()),
            Int32(rect.width.rounded()), Int32(rect.height.rounded()))
    }

    func naturalSize(_ widget: UnsafeMutablePointer<GtkWidget>, width: Int32 = -1) -> (Double, Double) {
        var w: Int32 = 0
        var h: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &w, nil, nil)
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, width >= 0 ? width : w, nil, &h, nil, nil)
        return (Double(w), Double(h))
    }

    func placeCard(
        _ sink: OpaquePointer, _ m: NeuralStageMetrics, offset: Double,
        height: Double? = nil
    ) {
        let cardHeight = height ?? m.card.height
        place(sink, card.surface, NeuralRect(x: 0, y: 0, width: m.width, height: cardHeight))
        place(sink, card.edgeLive, NeuralRect(x: 0, y: 0, width: 3, height: cardHeight))
        place(sink, card.picture, m.card.picture)
        let textRect = m.card.text
        if m.card.layout == .wide {
            let (buttonsWidth, buttonsHeight) = naturalSize(card.buttons)
            place(
                sink, card.text,
                NeuralRect(x: textRect.x, y: 0, width: textRect.width, height: cardHeight), dx: offset)
            place(
                sink, card.buttons,
                NeuralRect(
                    x: m.width - 12 - buttonsWidth, y: 8, width: buttonsWidth, height: buttonsHeight),
                dx: offset)
        } else {
            let (_, buttonsHeight) = naturalSize(card.buttons)
            let (buttonsWidth, _) = naturalSize(card.buttons)
            let (_, textHeight) = naturalSize(card.text, width: Int32(textRect.width))
            let total = textHeight + 6 + buttonsHeight
            let top = max(4, (cardHeight - total) / 2)
            place(
                sink, card.text,
                NeuralRect(x: textRect.x, y: top, width: textRect.width, height: textHeight), dx: offset)
            place(
                sink, card.buttons,
                NeuralRect(
                    x: textRect.x, y: top + textHeight + 6, width: buttonsWidth, height: buttonsHeight),
                dx: offset)
        }
    }

    func placeOpen(_ sink: OpaquePointer, _ m: NeuralStageMetrics) {
        guard let stage else {
            placeCard(sink, m, offset: 0)
            return
        }
        for layer in stage.visibleLayers { place(sink, layer, m.stage) }
        placeLeader(sink, m, stage: stage)
        place(sink, stage.hit, m.stageHover)
        placeBrowse(sink, m, readoutRect: nil)
        place(sink, footer?.widget, m.footer, dy: m.narrowExtra)
        placeWordmark(sink, m)
    }

    /// The name the open stage wears in the row's corner, nil where it wears none.
    var wordmarkText: String? {
        guard let wordmark, gtk_widget_get_visible(wordmark) != 0 else { return nil }
        return gtk_label_get_text(op(wordmark)).map { String(cString: $0) }
    }

    /// Megatron's name in the row's top left corner where Core's metrics say the corner is clear of
    /// the head.
    func placeWordmark(_ sink: OpaquePointer, _ m: NeuralStageMetrics) {
        guard let wordmark else { return }
        guard let box = m.stageWordmark else {
            gtk_widget_set_visible(wordmark, 0)
            return
        }
        gtk_widget_set_visible(wordmark, 1)
        place(sink, wordmark, box)
    }

    /// The leader's own canvas covers the head and the gutter, in the head's coordinates, so the
    /// route it draws starts at the node and ends on the readout's hairline.
    func placeLeader(_ sink: OpaquePointer, _ m: NeuralStageMetrics, stage: BrainStage) {
        let leaderWidth = m.arrangement == .split ? m.readout.x + 6 - m.stage.x : m.stage.width
        let region = m.arrangement == .split ? m.readout.height : m.stage.height
        place(
            sink, stage.leader,
            NeuralRect(x: m.stage.x, y: m.stage.y, width: leaderWidth, height: region))
    }

    /// The filter chips, the list with its search field, the account beside them, and the detail of
    /// the open step in the account's second column. A narrow brain has no list: its account stands
    /// where the list would, and the search field opens in the account's header.
    func placeBrowse(_ sink: OpaquePointer, _ m: NeuralStageMetrics, readoutRect: NeuralRect?) {
        if let rect = m.filterPanel ?? m.filterChips { place(sink, filters?.canvas, rect) }
        guard let list else { return }
        let narrow = m.arrangement == .accordion
        list.configure(metrics: m)
        filters?.configure(metrics: m)
        if !narrow {
            let canvasRect = NeuralRect(
                x: m.list.x, y: m.list.y, width: list.canvasWidth, height: list.canvasHeight)
            place(sink, list.canvas, canvasRect)
        }
        var base = narrow
            ? NeuralRect(x: 0, y: m.list.y, width: m.width, height: m.narrowAccountHeight) : m.readout
        if let moved = readoutRect {
            base = narrow ? base.offsetBy(dx: moved.x, dy: moved.y) : moved
        }
        if list.searchOpen {
            if narrow {
                place(
                    sink, list.entry,
                    NeuralRect(x: base.x + 16, y: base.y + 6, width: min(240, base.width - 32), height: 28))
            } else {
                place(
                    sink, list.entry,
                    NeuralRect(x: m.list.x + 4, y: m.list.y + 4, width: min(240, m.list.width - 90), height: 28))
            }
        }
        if let account {
            place(sink, account.root, base)
            account.touchFrame(width: base.width, height: base.height)
        }
        guard let clip = readoutClip else { return }
        var inside: NeuralRect?
        if m.arrangement == .split, m.accountLayout == .split, let detail = account?.detailRect() {
            inside = detail
        } else if readoutHoldsBody, let body = account?.bodyRect() {
            inside = body
        }
        if let inside {
            let rect = inside.offsetBy(dx: base.x, dy: base.y)
            place(sink, clip, rect)
            readout?.fit(width: rect.width, height: rect.height, at: (0, 0), inline: true)
            readout?.setDetail(m.accountLayout == .split && !readoutHoldsBody)
        }
    }

    func placeMoving(_ sink: OpaquePointer, _ m: NeuralStageMetrics) {
        guard let move = moveState else {
            placeOpen(sink, m)
            return
        }
        let f = move.frame
        placeCard(sink, m, offset: f.cardTextOffsetX)
        place(sink, moveCanvas, f.traveller)
        let picture = m.card.picture
        place(
            sink, edgeCanvas,
            NeuralRect(x: f.edge.x, y: picture.y, width: 3, height: picture.height))
        let target = move.openingGeometry
        if let stage { placeLeader(sink, m, stage: stage) }
        placeBrowse(
            sink, m,
            readoutRect: target.readout.offsetBy(dx: f.readoutOffset.x, dy: f.readoutOffset.y))
        place(sink, footer?.widget, target.footer)
        placeWordmark(sink, m)
    }

    func widthChanged() {
        let m = currentMetrics
        card.configure(metrics: m)
        stage?.configure(
            width: Int(m.stage.width.rounded()), height: Int(m.stage.height.rounded()),
            scaleFactor: max(1, Int(gtk_widget_get_scale_factor(widget))))
        footer?.configure(width: m.width, running: model.turn.outcome == .running)
        footer?.rebuildChips(width: m.width)
        readout?.retheme()
        list?.configure(metrics: m)
        filters?.configure(metrics: m)
        account?.geometryChanged()
        refreshReadout(animate: false)
        refreshAccordion()
        if let move = moveState, abs(move.metricsWidth - m.width) > 0.5 { finishMove(snapTo: move.opening) }
    }

    func relayout() {
        tailscode_brain_row_remeasure(widget)
        tailscode_brain_row_invalidate(widget)
    }
}
