import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Paints `AnalyticsShare.Card` through cairo and Pango. Where a line goes and what it says are
/// Core's: this walks the card's panels, fills and clips each one, stacks its blocks at the
/// heights Core gives them, and decides only how a bar, a number and a track are drawn.
enum AnalyticsCardRenderer {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block

    static let family = "Inter, Cantarell, sans-serif"

    static func png(_ share: AnalyticsShare, selection: ShareSelection, scale: Double = 2) -> Data? {
        render(share, selection: selection, scale: scale)?.png
    }

    static func render(
        _ share: AnalyticsShare, selection: ShareSelection, scale: Double = 2
    ) -> PosterSurface? {
        paint(share.card(selection, dark: MatrixTheme.palette.isDark), scale: scale)
    }

    static func paint(_ card: Card, scale: Double) -> PosterSurface? {
        let poster = PosterSurface(
            width: Int((card.canvasWidth * scale).rounded()),
            height: Int((card.height * scale).rounded()), scale: scale)
        guard poster.isUsable, let cr = cairo_create(poster.surface) else { return nil }
        defer { cairo_destroy(cr) }
        cairo_scale(cr, scale, scale)
        var painter = Painter(cr: cr, card: card)
        painter.canvas()
        for panel in card.panels { painter.panel(panel) }
        painter.footer()
        return poster
    }
}

private struct Painter {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block

    let cr: OpaquePointer
    let card: Card
    var palette: AnalyticsShare.Palette { card.palette }

    private func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        Contrast.channels(hex) ?? (0.5, 0.5, 0.5)
    }

    private func setColor(_ hex: String, alpha: Double = 1) {
        let color = rgb(hex)
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }

    func canvas() {
        cairo_save(cr)
        setColor(palette.canvas)
        cairo_paint(cr)
        if palette.canvasEnd != palette.canvas {
            let top = rgb(palette.canvas)
            let foot = rgb(palette.canvasEnd)
            if let fall = cairo_pattern_create_linear(0, 0, card.canvasWidth * 0.25, card.height) {
                cairo_pattern_add_color_stop_rgb(fall, 0, top.red, top.green, top.blue)
                cairo_pattern_add_color_stop_rgb(fall, 1, foot.red, foot.green, foot.blue)
                cairo_set_source(cr, fall)
                cairo_paint(cr)
                cairo_pattern_destroy(fall)
            }
        }
        cairo_restore(cr)
    }

    func panel(_ panel: Card.Panel) {
        let rect = panel.rect
        cairo_save(cr)
        if panel.surface == .raised {
            BrainPainter.round(cr, rect.x, rect.y, rect.width, rect.height, panel.corner)
            setColor(palette.raised)
            cairo_fill_preserve(cr)
            setColor(palette.rule, alpha: 0.6)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            BrainPainter.round(cr, rect.x, rect.y, rect.width, rect.height, panel.corner)
            cairo_clip(cr)
        } else {
            cairo_new_path(cr)
            cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height)
            cairo_clip(cr)
        }
        let content = panel.content
        var y = content.y
        for block in panel.blocks {
            self.block(block, x: content.x, y: y, metrics: panel.metrics)
            y += Card.height(block, in: panel.metrics)
        }
        cairo_restore(cr)
    }

    func footer() {
        guard let footer = card.footer else { return }
        let rect = footer.rect
        let face = font(footer.size, weight: .regular)
        var rightWidth = 0.0
        var rightHeight = 0.0
        tailscode_text_measure(footer.right, face, 0, 1, &rightWidth, &rightHeight)
        let dim = rgb(palette.textDim)
        let leftWidth = max(40, rect.width - rightWidth - 32)
        _ = tailscode_poster_text_leaded(
            cr, footer.left, face, rect.x, rect.y, leftWidth, 0, Int32(footer.leftLines),
            footer.size * 1.28, 0, dim.red, dim.green, dim.blue, 1)
        _ = tailscode_poster_text(
            cr, footer.right, face, rect.x + rect.width - rightWidth, rect.y, 0, 0, 1, 0, 0,
            dim.red, dim.green, dim.blue, 1)
    }

    enum Weight: String {
        case regular = ""
        case medium = "Medium "
        case semibold = "Semi-Bold "
        case bold = "Bold "
    }

    private func font(_ size: Double, weight: Weight) -> String {
        "\(AnalyticsCardRenderer.family) \(weight.rawValue)\(size)px"
    }

    @discardableResult
    private func text(
        _ string: String, x: Double, y: Double, width: Double = 0, size: Double,
        weight: Weight = .regular, ink: String, alignment: Int32 = 0, lines: Int = 1,
        tracking: Double = 0, tabular: Bool = false
    ) -> Double {
        let face = font(size, weight: weight)
        let color = rgb(ink)
        if tabular {
            let markup = "<span font_features=\"tnum\">\(Self.escape(string))</span>"
            return tailscode_markup_draw(
                cr, markup, face, x, y, width, alignment, Int32(lines), color.red, color.green,
                color.blue, 1)
        }
        return tailscode_poster_text_leaded(
            cr, string, face, x, y, width, alignment, Int32(lines), size * 1.28, tracking,
            color.red, color.green, color.blue, 1)
    }

    private func measured(_ string: String, size: Double, weight: Weight) -> Double {
        var width = 0.0
        var height = 0.0
        tailscode_text_measure(string, font(size, weight: weight), 0, 1, &width, &height)
        return width
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func block(_ block: Block, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        let size = Card.fontSize(block, in: metrics)
        let lines = Card.lines(block, in: metrics)
        switch block {
        case .brand(let string):
            text(string, x: x, y: y, width: width, size: size, weight: .bold, ink: palette.accent, tracking: 4 * s)
        case .kicker(let string):
            text(string, x: x, y: y, width: width, size: size, weight: .semibold, ink: palette.text)
        case .hero(let string):
            text(
                string, x: x, y: y, width: width + size, size: size, weight: .bold, ink: palette.text,
                tabular: true)
        case .body(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.text, lines: lines)
        case .dim(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.textDim, lines: lines)
        case .trend(let string, let tone):
            let ink: String
            switch tone {
            case .up: ink = palette.warn
            case .down: ink = palette.accent
            case .flat: ink = palette.textDim
            }
            text(string, x: x, y: y, width: width, size: size, weight: .semibold, ink: ink)
        case .daily(let chart):
            daily(chart, x: x, y: y, metrics: metrics)
        case .weekday(let bars):
            weekday(bars, x: x, y: y, metrics: metrics)
        case .section(let string):
            text(
                string.uppercased(), x: x, y: y, width: width, size: size, weight: .bold,
                ink: palette.textDim, tracking: 2 * s)
        case .meter(let meter):
            self.meter(meter, x: x, y: y, metrics: metrics)
        case .record(let record):
            self.record(record, x: x, y: y, metrics: metrics)
        case .insight(let string):
            text(
                Card.insightPrefix + string, x: x, y: y, width: width, size: size, ink: palette.text,
                lines: lines)
        case .rule:
            setColor(palette.rule)
            cairo_new_path(cr)
            cairo_rectangle(cr, x, y, width, 1)
            cairo_fill(cr)
        case .foot(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.textDim, lines: lines)
        case .spacer:
            break
        case .stats(let stats):
            self.stats(stats, x: x, y: y, metrics: metrics)
        }
    }

    private func daily(_ chart: AnalyticsShare.DailyChart, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let (barWidth, gap) = Card.barGeometry(count: chart.bars.count, in: metrics)
        let chartHeight = metrics.dailyHeight
        for (index, bar) in chart.bars.enumerated() {
            let left = x + Double(index) * (barWidth + gap)
            var height = bar.isEmpty ? chartHeight * 0.04 : chartHeight * bar.share
            height = max(bar.isEmpty ? 2 : 4 * s, height)
            let accented = bar.isPeak || bar.isToday
            BrainPainter.round(cr, left, y + chartHeight - height, barWidth, height, barWidth * 0.35)
            setColor(bar.isEmpty ? palette.rule : (accented ? palette.accent : palette.info), alpha: !bar.isEmpty && !accented ? 0.85 : 1)
            cairo_fill(cr)
        }
        let axisY = y + chartHeight + 6 * s
        let axisSize = Card.axisSize * s
        text(chart.leading, x: x, y: axisY, width: metrics.contentWidth / 2, size: axisSize, weight: .medium, ink: palette.textDim)
        text(
            chart.trailing, x: x + metrics.contentWidth / 2, y: axisY, width: metrics.contentWidth / 2,
            size: axisSize, weight: .medium, ink: palette.textDim, alignment: 2)
    }

    private func weekday(_ bars: [AnalyticsShare.DayBar], x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        guard !bars.isEmpty else { return }
        let column = metrics.contentWidth / Double(bars.count)
        let barWidth = min(column * 0.45, 28 * s)
        let chartHeight = metrics.weekdayHeight
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        for (index, bar) in bars.enumerated() {
            let middle = x + column * (Double(index) + 0.5)
            let height = bar.isEmpty ? 3 : max(4 * s, chartHeight * bar.share)
            let peak = !bar.isEmpty && bar.share >= 0.999
            BrainPainter.round(cr, middle - barWidth / 2, y + chartHeight - height, barWidth, height, 3 * s)
            setColor(bar.isEmpty ? palette.rule : (peak ? palette.accent : palette.info), alpha: !bar.isEmpty && !peak ? 0.85 : 1)
            cairo_fill(cr)
            if index < letters.count {
                text(
                    letters[index], x: middle - column / 2, y: y + chartHeight + 6 * s, width: column,
                    size: Card.axisSize * s, weight: .medium, ink: palette.textDim, alignment: 1)
            }
        }
    }

    private func meter(_ meter: AnalyticsShare.MeterBar, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        let labelSize = Card.meterSize * s
        let labelRoom = width * 0.55
        text(meter.label, x: x, y: y, width: labelRoom, size: labelSize, weight: .semibold, ink: palette.text)
        let moneyWidth = meter.money.map { measured($0, size: labelSize, weight: .semibold) } ?? 0
        if !meter.detail.isEmpty {
            let ink = min(measured(meter.label, size: labelSize, weight: .semibold), labelRoom)
            let detailX = x + ink + 14 * s
            let detailRoom = x + width - moneyWidth - 16 * s - detailX
            if detailRoom > 60 * s {
                text(
                    meter.detail, x: detailX, y: y + 5 * s, width: detailRoom, size: Card.meterDetailSize * s,
                    ink: palette.textDim)
            }
        }
        if let money = meter.money, !money.isEmpty {
            text(
                money, x: x, y: y, width: width, size: labelSize, weight: .semibold, ink: palette.text,
                alignment: 2, tabular: true)
        }
        let trackY = y + Card.meterTrackOffset * s
        let trackHeight = Card.meterTrackHeight * s
        BrainPainter.round(cr, x, trackY, width, trackHeight, trackHeight / 2)
        setColor(palette.rule)
        cairo_fill(cr)
        let share = min(1, max(0, meter.share))
        if share > 0 {
            BrainPainter.round(cr, x, trackY, max(trackHeight, width * share), trackHeight, trackHeight / 2)
            setColor(meter.hot ? palette.accent : palette.info)
            cairo_fill(cr)
        }
    }

    private func record(_ record: AnalyticsShare.RecordLine, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        text(record.glyph, x: x, y: y, width: 36 * s, size: Card.recordSize * s, weight: .semibold, ink: palette.special)
        text(
            record.caption, x: x + 40 * s, y: y, width: width - 40 * s, size: Card.recordTitleSize * s,
            weight: .medium, ink: palette.textDim)
        text(
            record.value, x: x + 40 * s, y: y + 20 * s, width: width - 40 * s, size: Card.recordSize * s,
            weight: .semibold, ink: palette.text, tabular: true)
    }

    private func stats(_ stats: [AnalyticsShare.Stat], x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let columns = Card.statColumns
        let gap = 20 * s
        let cell = (metrics.contentWidth - gap * Double(columns - 1)) / Double(columns)
        let valueSize = Card.statValueSize * s
        let labelSize = Card.statLabelSize * s
        for (index, stat) in stats.enumerated() {
            let column = Double(index % columns)
            let row = Double(index / columns)
            let left = x + column * (cell + gap)
            let top = y + row * Card.statRowHeight(s)
            text(stat.value, x: left, y: top, width: cell, size: valueSize, weight: .bold, ink: palette.text, tabular: true)
            text(
                stat.label, x: left, y: top + valueSize * 1.15, width: cell, size: labelSize,
                ink: palette.textDim)
        }
    }
}
