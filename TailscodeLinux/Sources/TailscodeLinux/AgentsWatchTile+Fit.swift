import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension WatchTileView {
    struct Level {
        var glyph: Double
        var title: Double
        var status: Double
        var meta: Double
        var words: Double
        var detail: Double
        var beat: Double
    }

    static let levels = [
        Level(glyph: 12.5, title: 3.3, status: 2.9, meta: 2.2, words: 4.8, detail: 3.0, beat: 4.2),
        Level(glyph: 11, title: 2.95, status: 2.6, meta: 2.0, words: 4.0, detail: 2.55, beat: 3.7),
        Level(glyph: 9.6, title: 2.6, status: 2.3, meta: 1.8, words: 3.4, detail: 2.2, beat: 3.4),
        Level(glyph: 8.2, title: 2.3, status: 2.0, meta: 1.7, words: 3.0, detail: 1.95, beat: 3.0),
        Level(glyph: 6.8, title: 2.0, status: 1.8, meta: 1.6, words: 2.6, detail: 1.75, beat: 2.6),
        Level(glyph: 5.6, title: 1.8, status: 1.6, meta: 1.6, words: 2.2, detail: 1.6, beat: 0),
    ]

    struct Plan {
        var glyph = TileRect(x: 0, y: 0, width: 0, height: 0)
        var title = TileRect(x: 0, y: 0, width: 0, height: 0)
        var status = TileRect(x: 0, y: 0, width: 0, height: 0)
        var meta: TileRect?
        var words = TileRect(x: 0, y: 0, width: 0, height: 0)
        var detail: TileRect?
        var beat: TileRect?
        var deny: TileRect?
        var approve: TileRect?
        var chat: TileRect?
        var hint: TileRect?
        var steps: TileRect?
    }

    private var hintIsAdvice: Bool {
        guard let tile else { return false }
        return !context.actions.state(tile.id).isFailure
    }

    var asksForYou: Bool {
        guard let tile, case .needsYou = tile.state else { return false }
        return true
    }

    func solve(width: Int32, height: Int32, sink: TileSink) {
        sink.place(card.widget, TileRect(x: 0, y: 0, width: width, height: height))
        guard tile != nil, width > 8, height > 8 else { return }
        let last = Self.levels.count - 1
        for (index, level) in Self.levels.enumerated() where index >= (context.allowsBigType ? 0 : 2) {
            if let plan = plan(level, width: Double(width), height: Double(height), truncating: index == last) {
                place(plan, sink: sink)
                let words = truncated ? Localized.text("Tap to read it all") : ""
                if hint.text.isEmpty != words.isEmpty, hintIsAdvice { refreshControls() }
                return
            }
        }
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> TileRect {
        TileRect(
            x: Int32(x.rounded()), y: Int32(y.rounded()), width: Int32(max(1, width.rounded())),
            height: Int32(max(1, height.rounded())))
    }

    private func plan(_ level: Level, width: Double, height: Double, truncating: Bool) -> Plan? {
        guard let tile else { return nil }
        let u = unit
        let palette = context.palette
        let pad = 1.7 * u
        let inner = width - 2 * pad
        let gap = 1.0 * u
        let glyphSize = min(level.glyph * u, height * 0.4)
        let columnX = pad + glyphSize + 1.4 * u
        let columnWidth = width - columnX - pad
        let tone = palette.ink(tile.state).lifted(0.18)
        var plan = Plan()

        title.set(style: context.label(level.title, bold: true))
        title.set(lines: 0)
        status.set(style: context.label(level.status, bold: true, ink: tone))
        status.set(lines: 0)
        meta.set(style: context.label(level.meta, ink: palette.dim))
        meta.set(lines: 0)
        words.set(style: context.label(level.words, bold: true))
        words.set(lines: 0)
        let titleHeight = title.height(forWidth: columnWidth)
        let statusHeight = status.height(forWidth: columnWidth)
        let hasMeta = !meta.text.isEmpty
        let metaHeight = hasMeta ? meta.height(forWidth: columnWidth) : 0
        let column = titleHeight + 0.3 * u + statusHeight + (hasMeta ? 0.3 * u + metaHeight : 0)
        let headHeight = max(glyphSize, column)
        let wordsHeight = words.text.isEmpty ? 0 : words.height(forWidth: inner)

        plan.glyph = rect(pad, pad, glyphSize, glyphSize)
        plan.title = rect(columnX, pad, columnWidth, titleHeight)
        plan.status = rect(columnX, pad + titleHeight + 0.3 * u, columnWidth, statusHeight)
        if hasMeta {
            plan.meta = rect(columnX, pad + titleHeight + 0.6 * u + statusHeight, columnWidth, metaHeight)
        }
        plan.words = rect(pad, pad + headHeight + gap, inner, wordsHeight)

        var footer = 0.0
        if asksForYou, !tile.isAwayState {
            footer = (level.beat > 2.8 ? 5.8 : 4.8) * u
            footerButtons(&plan, level: level, footer: footer, pad: pad, height: height, inner: inner, tile: tile)
        } else if !beatValues.isEmpty, level.beat > 0 {
            footer = level.beat * u
            plan.beat = rect(pad, height - pad - footer, min(inner * 0.5, 38 * u), footer)
        }

        let top = pad + headHeight + gap + wordsHeight + (wordsHeight > 0 ? gap : 0)
        let limit = height - pad - footer - (footer > 0 ? gap : 0)
        let text = detail.text
        truncated = false
        if top > limit + 1 && !truncating { return nil }
        if text.isEmpty {
            detail.set(lines: 0)
            addSteps(&plan, from: top, limit: limit, inner: inner, pad: pad)
            return plan
        }
        let boost = asksForYou ? 1.32 : 1.0
        detail.set(style: context.label(level.detail * boost, mono: true, ink: palette.text, alpha: asksForYou ? 1 : 0.86))
        detail.set(lines: 0)
        let natural = detail.height(forWidth: inner)
        let room = limit - top
        if natural <= room {
            plan.detail = rect(pad, top, inner, natural)
            addSteps(&plan, from: top + natural + gap, limit: limit, inner: inner, pad: pad)
            return plan
        }
        guard truncating else { return nil }
        let line = lineHeight(of: detail)
        let lines = Int((room / line).rounded(.down))
        guard lines >= 1 else {
            truncated = true
            return plan
        }
        detail.set(lines: lines)
        truncated = true
        plan.detail = rect(pad, top, inner, min(room, Double(lines) * line))
        return plan
    }

    /// What one line of a label takes, read from the layout it draws: a wrapping label that is told
    /// to stop at some lines still measures all of them, so the lines that fit are counted here.
    private func lineHeight(of label: WatchLabel) -> Double {
        guard let layout = gtk_label_get_layout(op(label.widget)) else { return 1 }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        let count = max(1, pango_layout_get_line_count(layout))
        return max(1, (Double(height) / Double(count)).rounded(.up))
    }

    private func addSteps(_ plan: inout Plan, from top: Double, limit: Double, inner: Double, pad: Double) {
        guard !steps.text.isEmpty else { return }
        steps.set(style: context.label(1.75, ink: context.palette.dim))
        steps.set(lines: 0)
        let height = steps.height(forWidth: inner)
        if top + height <= limit { plan.steps = rect(pad, top, inner, height) }
    }

    private func footerButtons(
        _ plan: inout Plan, level: Level, footer: Double, pad: Double, height: Double, inner: Double,
        tile: WallTile
    ) {
        let u = unit
        let buttonSize = level.beat > 2.8 ? 2.3 : 2.0
        let y = height - pad - footer
        for label in [denyLabel, approveLabel, chatLabel] {
            label.set(style: context.label(buttonSize, bold: true))
        }
        if tile.ask?.isApproval == true, context.style.approvals == .hold {
            let denyWidth = denyLabel.naturalWidth + 4.4 * u
            let ringSize = min(footer * 0.8, 4.4 * u)
            gtk_widget_set_size_request(ring.widget, Int32(ringSize), Int32(ringSize))
            gtk_widget_set_margin_start(ring.widget, Int32(1.1 * u))
            gtk_widget_set_margin_end(ring.widget, Int32(0.9 * u))
            let hold = approveLabel.widthFor(Localized.text("Hold to approve"))
            let approveWidth = ringSize + 2.0 * u + max(hold, approveLabel.widthFor(Localized.text("Approving…"))) + 3.0 * u
            plan.deny = rect(pad, y, denyWidth, footer)
            plan.approve = rect(pad + denyWidth + 1.4 * u, y, approveWidth, footer)
            let hintX = pad + denyWidth + approveWidth + 3.4 * u
            if inner - (hintX - pad) > 12 * u {
                hint.set(style: context.label(1.9, ink: context.palette.dim))
                hint.set(lines: 2)
                let hintHeight = min(footer, hint.height(forWidth: width(of: hintX, inner: inner, pad: pad)))
                plan.hint = rect(hintX, y + (footer - hintHeight) / 2, width(of: hintX, inner: inner, pad: pad), hintHeight)
            }
        } else {
            plan.chat = rect(pad, y, chatLabel.naturalWidth + 5 * u, footer)
        }
    }

    private func width(of x: Double, inner: Double, pad: Double) -> Double { inner + pad - x }

    private func place(_ plan: Plan, sink: TileSink) {
        glyphBox = plan.glyph
        beatBox = plan.beat
        sink.place(glyph.widget, plan.glyph)
        sink.place(title.widget, plan.title)
        sink.place(status.widget, plan.status)
        if let meta = plan.meta { sink.place(self.meta.widget, meta) }
        if !words.text.isEmpty { sink.place(words.widget, plan.words) }
        if let detail = plan.detail { sink.place(detailClamp, detail) }
        if let beat = plan.beat { sink.place(beatCanvas.widget, beat) }
        if let deny = plan.deny { sink.place(self.deny, deny) }
        if let approve = plan.approve { sink.place(self.approve, approve) }
        if let chat = plan.chat { sink.place(self.chat, chat) }
        if let hint = plan.hint { sink.place(self.hint.widget, hint) }
        if let steps = plan.steps { sink.place(stepsClamp, steps) }
    }
}

extension WallTile {
    var isAwayState: Bool {
        if case .away = state { return true }
        return false
    }
}

extension WatchLabel {
    func widthFor(_ words: String) -> Double {
        let keep = text
        set(text: words)
        let width = naturalWidth
        set(text: keep)
        return width
    }
}
