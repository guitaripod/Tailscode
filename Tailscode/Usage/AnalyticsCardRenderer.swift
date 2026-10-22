import TailscodeCore
import UIKit

/// Paints `AnalyticsShare.Card` through CoreGraphics and UIKit's string drawing. Where a line goes
/// and what it says are Core's: this walks the card's panels, fills and clips each one, stacks its
/// blocks at the heights Core gives them, and decides only how a bar, a number and a track are
/// drawn. Everything is laid out in the card's own points and magnified by one scale, so the
/// preview and the file are the same picture at two sizes.
enum AnalyticsCardRenderer {
    typealias Card = AnalyticsShare.Card

    static let largestSide: CGFloat = 8_192

    /// The magnification a file leaves at: the screen's own, never past 2x for the 1600-wide post
    /// (X shows it no larger) nor past 3x elsewhere, and never so far that the tall column's
    /// bitmap outgrows what the system will encode.
    static func exportScale(for card: Card, displayScale: CGFloat) -> CGFloat {
        let device = max(1, displayScale)
        let wanted = card.format == .post ? min(2, device) : min(3, device)
        let longest = max(card.canvasWidth, card.height)
        return max(1, min(wanted, largestSide / longest))
    }

    static func png(
        _ share: AnalyticsShare, selection: ShareSelection, dark: Bool, displayScale: CGFloat
    ) -> (data: Data, filename: String)? {
        let card = share.card(selection, dark: dark)
        let scale = exportScale(for: card, displayScale: displayScale)
        guard let data = image(card, scale: scale).pngData() else { return nil }
        return (data, share.filename)
    }

    static func temporaryFile(
        _ share: AnalyticsShare, selection: ShareSelection, dark: Bool, displayScale: CGFloat
    ) -> URL? {
        guard let rendered = png(share, selection: selection, dark: dark, displayScale: displayScale)
        else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-analytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)
        let url = directory.appendingPathComponent(rendered.filename)
        do {
            try rendered.data.write(to: url, options: .atomic)
            return url
        } catch {
            AppLogger.ui.error("could not stage analytics share: \(error)")
            return nil
        }
    }

    private static func prune(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-3_600)
        for file in files {
            let date =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: file) }
        }
    }

    /// The card as a bitmap `scale` pixels to the point. Safe off the main thread: nothing here
    /// touches a view.
    static func image(_ card: Card, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(
            width: (card.canvasWidth * scale).rounded(), height: (card.height * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            let painter = Painter(ctx: ctx, card: card)
            painter.canvas()
            for panel in card.panels { painter.panel(panel) }
            painter.footer()
        }
    }

    /// A swatch for the menu: the style's canvas as a disc with its accent as a dot, so a name
    /// like Ember is shown rather than described.
    static func swatch(_ style: CardStyle, size: CGFloat = 22, traits: UITraitCollection) -> UIImage {
        let palette = style.palette(dark: true)
        let format = UIGraphicsImageRendererFormat.matching(traits)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
            .image { context in
                let ctx = context.cgContext
                let rect = CGRect(x: 0, y: 0, width: size, height: size)
                ctx.addEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
                ctx.clip()
                Painter.fall(palette, from: CGPoint(x: rect.midX, y: rect.minY), to: CGPoint(x: rect.midX, y: rect.maxY), in: rect, ctx: ctx)
                ctx.resetClip()
                ctx.setStrokeColor(Painter.color(palette.rule))
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
                ctx.setFillColor(Painter.color(palette.accent))
                ctx.fillEllipse(in: rect.insetBy(dx: size * 0.3, dy: size * 0.3))
            }.withRenderingMode(.alwaysOriginal)
    }
}

private struct Painter {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block

    let ctx: CGContext
    let card: Card
    var palette: AnalyticsShare.Palette { card.palette }

    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let channels = Contrast.channels(hex) ?? (0.5, 0.5, 0.5)
        return CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(channels.red), CGFloat(channels.green), CGFloat(channels.blue), alpha])
            ?? UIColor.gray.cgColor
    }

    private func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        Self.color(hex, alpha: alpha)
    }

    /// The canvas falls from its top colour to its foot colour; a flat palette names the same
    /// colour twice and the fall is invisible.
    static func fall(
        _ palette: AnalyticsShare.Palette, from start: CGPoint, to end: CGPoint, in rect: CGRect,
        ctx: CGContext
    ) {
        ctx.setFillColor(color(palette.canvas))
        ctx.fill(rect)
        guard palette.canvasEnd != palette.canvas,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                colors: [color(palette.canvas), color(palette.canvasEnd)] as CFArray,
                locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(
            gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func canvas() {
        let rect = CGRect(x: 0, y: 0, width: card.canvasWidth, height: card.height)
        Self.fall(
            palette, from: .zero, to: CGPoint(x: card.canvasWidth * 0.25, y: card.height), in: rect,
            ctx: ctx)
    }

    func panel(_ panel: Card.Panel) {
        let rect = CGRect(
            x: panel.rect.x, y: panel.rect.y, width: panel.rect.width, height: panel.rect.height)
        ctx.saveGState()
        if panel.surface == .raised {
            let shape = Self.rounded(rect, radius: panel.corner)
            ctx.addPath(shape)
            ctx.setFillColor(color(palette.raised))
            ctx.fillPath()
            ctx.addPath(shape)
            ctx.setStrokeColor(color(palette.rule, alpha: 0.6))
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.addPath(shape)
        } else {
            ctx.addRect(rect)
        }
        ctx.clip()
        let content = panel.content
        var y = content.y
        for block in panel.blocks {
            paint(block, x: content.x, y: y, metrics: panel.metrics)
            y += Card.height(block, in: panel.metrics)
        }
        ctx.restoreGState()
    }

    func footer() {
        guard let footer = card.footer else { return }
        let rect = footer.rect
        let right = Self.width(footer.right, size: footer.size, weight: .regular)
        text(
            footer.left, x: rect.x, y: rect.y, width: max(40, rect.width - right - 32),
            size: footer.size, ink: palette.textDim, lines: footer.leftLines)
        text(
            footer.right, x: rect.x, y: rect.y, width: rect.width, size: footer.size,
            ink: palette.textDim, alignment: .right)
    }

    private func paint(_ block: Block, x: Double, y: Double, metrics: Card.Metrics) {
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
            hero(string, x: x, y: y, width: width, size: size)
        case .body(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.text, lines: lines)
        case .dim(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.textDim, lines: lines)
        case .trend(let string, let tone):
            text(string, x: x, y: y, width: width, size: size, weight: .semibold, ink: ink(for: tone))
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
            ctx.setFillColor(color(palette.rule))
            ctx.fill(CGRect(x: x, y: y, width: width, height: 1))
        case .foot(let string):
            text(string, x: x, y: y, width: width, size: size, ink: palette.textDim, lines: lines)
        case .spacer:
            break
        case .stats(let stats):
            self.stats(stats, x: x, y: y, metrics: metrics)
        }
    }

    private func ink(for tone: AnalyticsShare.TrendTone) -> String {
        switch tone {
        case .up: return palette.warn
        case .down: return palette.accent
        case .flat: return palette.textDim
        }
    }

    /// The number is set at the size Core chose and, only if this font's digits run wider than
    /// the estimate Core measured with, shrunk to the column rather than cut.
    private func hero(_ string: String, x: Double, y: Double, width: Double, size: Double) {
        let natural = Self.width(string, size: size, weight: .bold, tabular: true)
        let fitted = natural > width && natural > 0 ? size * width / natural : size
        text(
            string, x: x, y: y, width: width + size, size: fitted, weight: .bold, ink: palette.text,
            tabular: true, clips: true)
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
            fillRounded(
                CGRect(x: left, y: y + chartHeight - height, width: barWidth, height: height),
                radius: barWidth * 0.35,
                with: bar.isEmpty
                    ? color(palette.rule)
                    : (accented ? color(palette.accent) : color(palette.info, alpha: 0.85)))
        }
        let axisY = y + chartHeight + 6 * s
        let axisSize = Card.axisSize * s
        text(
            chart.leading, x: x, y: axisY, width: metrics.contentWidth / 2, size: axisSize,
            weight: .medium, ink: palette.textDim)
        text(
            chart.trailing, x: x + metrics.contentWidth / 2, y: axisY, width: metrics.contentWidth / 2,
            size: axisSize, weight: .medium, ink: palette.textDim, alignment: .right)
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
            fillRounded(
                CGRect(x: middle - barWidth / 2, y: y + chartHeight - height, width: barWidth, height: height),
                radius: 3 * s,
                with: bar.isEmpty
                    ? color(palette.rule)
                    : (peak ? color(palette.accent) : color(palette.info, alpha: 0.85)))
            if index < letters.count {
                text(
                    letters[index], x: middle - column / 2, y: y + chartHeight + 6 * s, width: column,
                    size: Card.axisSize * s, weight: .medium, ink: palette.textDim, alignment: .center)
            }
        }
    }

    private func meter(_ meter: AnalyticsShare.MeterBar, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        let labelSize = Card.meterSize * s
        let labelRoom = width * 0.55
        text(
            meter.label, x: x, y: y, width: labelRoom, size: labelSize, weight: .semibold,
            ink: palette.text)
        let moneyWidth = meter.money.map {
            Self.width($0, size: labelSize, weight: .semibold, tabular: true)
        } ?? 0
        if !meter.detail.isEmpty {
            let reach = min(Self.width(meter.label, size: labelSize, weight: .semibold), labelRoom)
            let detailX = x + reach + 14 * s
            let detailRoom = x + width - moneyWidth - 16 * s - detailX
            if detailRoom > 60 * s {
                text(
                    meter.detail, x: detailX, y: y + 5 * s, width: detailRoom,
                    size: Card.meterDetailSize * s, ink: palette.textDim)
            }
        }
        if let money = meter.money, !money.isEmpty {
            text(
                money, x: x, y: y, width: width, size: labelSize, weight: .semibold, ink: palette.text,
                alignment: .right, tabular: true)
        }
        let trackY = y + Card.meterTrackOffset * s
        let trackHeight = Card.meterTrackHeight * s
        fillRounded(
            CGRect(x: x, y: trackY, width: width, height: trackHeight), radius: trackHeight / 2,
            with: color(palette.rule))
        let share = min(1, max(0, meter.share))
        if share > 0 {
            fillRounded(
                CGRect(x: x, y: trackY, width: max(trackHeight, width * share), height: trackHeight),
                radius: trackHeight / 2, with: color(meter.hot ? palette.accent : palette.info))
        }
    }

    private func record(_ record: AnalyticsShare.RecordLine, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        text(
            record.glyph, x: x, y: y, width: 36 * s, size: Card.recordSize * s, weight: .semibold,
            ink: palette.special)
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
            let left = x + Double(index % columns) * (cell + gap)
            let top = y + Double(index / columns) * Card.statRowHeight(s)
            text(
                stat.value, x: left, y: top, width: cell, size: valueSize, weight: .bold,
                ink: palette.text, tabular: true)
            text(
                stat.label, x: left, y: top + valueSize * 1.15, width: cell, size: labelSize,
                ink: palette.textDim)
        }
    }

    private static func font(_ size: Double, _ weight: UIFont.Weight, tabular: Bool) -> UIFont {
        tabular
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func width(
        _ string: String, size: Double, weight: UIFont.Weight, tabular: Bool = false
    ) -> Double {
        NSAttributedString(
            string: string, attributes: [.font: font(size, weight, tabular: tabular)]
        ).size().width
    }

    /// A paragraph is drawn in the leading Core measured it in, wrapping by word and cutting only
    /// its last visible line; a single line is cut at its end. A truncating break mode never
    /// wraps under string drawing, so the two are not one mode.
    private func text(
        _ string: String, x: Double, y: Double, width: Double, size: Double,
        weight: UIFont.Weight = .regular, ink: String, alignment: NSTextAlignment = .left,
        lines: Int = 1, tracking: Double = 0, tabular: Bool = false, clips: Bool = false
    ) {
        guard !string.isEmpty, width > 0, size > 0 else { return }
        let face = Self.font(size, weight, tabular: tabular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [
            .font: face, .foregroundColor: UIColor(cgColor: color(ink)),
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let height: Double
        if lines > 1 {
            let leading = Card.lineHeight(size, lines: 1)
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.minimumLineHeight = leading
            paragraph.maximumLineHeight = leading
            height = leading * Double(lines) + 1
        } else {
            paragraph.lineBreakMode = clips ? .byClipping : .byTruncatingTail
            height = Double(face.lineHeight) + 4
        }
        attributes[.paragraphStyle] = paragraph
        NSAttributedString(string: string, attributes: attributes).draw(
            with: CGRect(x: x, y: y, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil)
    }

    static func rounded(_ rect: CGRect, radius: Double) -> CGPath {
        let limit = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(
            roundedRect: rect, cornerWidth: limit, cornerHeight: limit, transform: nil)
    }

    private func fillRounded(_ rect: CGRect, radius: Double, with fill: CGColor) {
        ctx.addPath(Self.rounded(rect, radius: radius))
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
}
