import AppKit
import TailscodeCore

/// Paints `AnalyticsShare.Card` into a bitmap. Where a line goes and what it says are Core's: this
/// walks the card's panels, fills and clips each one, stacks its blocks at the heights Core gives
/// them, and decides only how a bar, a number and a track are drawn. A card is a poster rather than
/// a window, so nothing here asks the theme for a colour.
enum AnalyticsCardRenderer {
    typealias Card = AnalyticsShare.Card

    /// A painted card: the pixels, and enough of them kept to look at, so a check can ask what is
    /// at a point of the canvas without decoding a PNG.
    final class Poster: @unchecked Sendable {
        let image: CGImage
        let width: Int
        let height: Int
        let scale: CGFloat
        private let bytes: Data
        private let rowBytes: Int

        fileprivate init(image: CGImage, bytes: Data, rowBytes: Int, scale: CGFloat) {
            self.image = image
            self.bytes = bytes
            self.rowBytes = rowBytes
            self.scale = scale
            width = image.width
            height = image.height
        }

        var logicalSize: NSSize { NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }

        var png: Data? {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = logicalSize
            return rep.representation(using: .png, properties: [:])
        }

        var nsImage: NSImage {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = logicalSize
            let picture = NSImage(size: logicalSize)
            picture.addRepresentation(rep)
            return picture
        }

        /// The colour at a point given in the card's own points, as 0...255 channels.
        func pixel(x: Double, y: Double) -> (red: Int, green: Int, blue: Int) {
            let column = min(max(Int((x * scale).rounded(.down)), 0), width - 1)
            let row = min(max(Int((y * scale).rounded(.down)), 0), height - 1)
            let offset = row * rowBytes + column * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        /// How many pixels of a rectangle of the card (in points) are further than `tolerance`
        /// from `reference` in any channel: the ink a panel carries over its own ground.
        func pixels(
            in rect: AnalyticsShare.Rect, notNear reference: (red: Int, green: Int, blue: Int),
            tolerance: Int = 6
        ) -> Int {
            var count = 0
            forEachPixel(in: rect) { red, green, blue, _, _ in
                if abs(red - reference.red) > tolerance || abs(green - reference.green) > tolerance
                    || abs(blue - reference.blue) > tolerance
                {
                    count += 1
                }
            }
            return count
        }

        /// How many pixels of `rect` are not what `other` has at the same place.
        func pixels(in rect: AnalyticsShare.Rect, differingFrom other: Poster, tolerance: Int = 2) -> Int {
            var count = 0
            forEachPixel(in: rect) { red, green, blue, column, row in
                let there = other.pixel(
                    x: (Double(column) + 0.5) / Double(scale), y: (Double(row) + 0.5) / Double(scale))
                if abs(red - there.red) > tolerance || abs(green - there.green) > tolerance
                    || abs(blue - there.blue) > tolerance
                {
                    count += 1
                }
            }
            return count
        }

        func forEachPixel(
            in rect: AnalyticsShare.Rect, step: Int = 1, _ visit: (Int, Int, Int, Int, Int) -> Void
        ) {
            let left = max(0, Int((rect.x * scale).rounded(.down)))
            let right = min(width, Int((rect.maxX * scale).rounded(.up)))
            let top = max(0, Int((rect.y * scale).rounded(.down)))
            let bottom = min(height, Int((rect.maxY * scale).rounded(.up)))
            guard left < right, top < bottom else { return }
            for row in stride(from: top, to: bottom, by: step) {
                for column in stride(from: left, to: right, by: step) {
                    let offset = row * rowBytes + column * 4
                    visit(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), column, row)
                }
            }
        }
    }

    /// The card for a choice as PNG bytes, at `scale` pixels per point.
    static func png(
        _ share: AnalyticsShare, selection: ShareSelection, scale: CGFloat = 2, dark: Bool
    ) -> Data? {
        render(share, selection: selection, scale: scale, dark: dark)?.png
    }

    static func render(
        _ share: AnalyticsShare, selection: ShareSelection, scale: CGFloat = 2, dark: Bool
    ) -> Poster? {
        paint(share.card(selection, dark: dark), scale: scale)
    }

    static func paint(_ card: Card, scale: CGFloat, panels: Bool = true) -> Poster? {
        let pixelWidth = Int((card.canvasWidth * Double(scale)).rounded())
        let pixelHeight = Int((card.height * Double(scale)).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        graphics.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let painter = Painter(ctx: ctx, card: card)
        painter.canvas()
        if panels {
            for panel in card.panels { painter.panel(panel) }
            painter.footer()
        }
        guard let image = ctx.makeImage(), let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        return Poster(
            image: image, bytes: Data(bytes: data, count: rowBytes * pixelHeight), rowBytes: rowBytes,
            scale: scale)
    }

    /// A swatch for the menu: the style's canvas as a disc with its accent as a dot, so a name
    /// like Ember is shown rather than described.
    static func swatch(_ style: CardStyle, size: CGFloat = 16) -> NSImage {
        let palette = style.palette(dark: true)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.addEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.clip()
            Painter.fall(palette, in: rect, ctx: ctx, toward: CGPoint(x: rect.midX, y: rect.maxY))
            ctx.restoreGState()
            ctx.setStrokeColor(Painter.color(palette.rule))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.setFillColor(Painter.color(palette.accent))
            ctx.fillEllipse(in: rect.insetBy(dx: size * 0.3, dy: size * 0.3))
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct Painter {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block

    let ctx: CGContext
    let card: Card
    var palette: AnalyticsShare.Palette { card.palette }

    static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        guard let channels = Contrast.channels(hex) else {
            return NSColor.gray.withAlphaComponent(alpha)
        }
        return NSColor(
            srgbRed: channels.red, green: channels.green, blue: channels.blue, alpha: alpha)
    }

    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        nsColor(hex, alpha: alpha).cgColor
    }

    /// The canvas falls from its top colour to its foot colour along a line; a flat palette names
    /// the same colour twice and the fall is invisible.
    static func fall(
        _ palette: AnalyticsShare.Palette, in rect: CGRect, ctx: CGContext, toward end: CGPoint,
        from start: CGPoint? = nil
    ) {
        ctx.setFillColor(color(palette.canvas))
        ctx.fill(rect)
        guard palette.canvasEnd != palette.canvas,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [color(palette.canvas), color(palette.canvasEnd)] as CFArray,
                locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(
            gradient, start: start ?? CGPoint(x: rect.midX, y: rect.minY), end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func canvas() {
        Self.fall(
            palette, in: CGRect(x: 0, y: 0, width: card.canvasWidth, height: card.height), ctx: ctx,
            toward: CGPoint(x: card.canvasWidth * 0.25, y: card.height), from: .zero)
    }

    private func rounded(_ rect: CGRect, radius: Double) -> CGPath {
        CGPath(
            roundedRect: rect, cornerWidth: min(radius, rect.width / 2),
            cornerHeight: min(radius, rect.height / 2), transform: nil)
    }

    private func fill(_ rect: CGRect, radius: Double, with color: CGColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.addPath(rounded(rect, radius: radius))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    func panel(_ panel: Card.Panel) {
        let rect = CGRect(
            x: panel.rect.x, y: panel.rect.y, width: panel.rect.width, height: panel.rect.height)
        ctx.saveGState()
        if panel.surface == .raised {
            let shape = rounded(rect, radius: panel.corner)
            ctx.addPath(shape)
            ctx.setFillColor(Self.color(palette.raised))
            ctx.fillPath()
            ctx.addPath(shape)
            ctx.setStrokeColor(Self.color(palette.rule, alpha: 0.6))
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.addPath(shape)
            ctx.clip()
        } else {
            ctx.clip(to: rect)
        }
        let content = panel.content
        var y = content.y
        for block in panel.blocks {
            self.block(block, x: content.x, y: y, metrics: panel.metrics)
            y += Card.height(block, in: panel.metrics)
        }
        ctx.restoreGState()
    }

    func footer() {
        guard let footer = card.footer else { return }
        let rect = footer.rect
        let rightWidth = width(of: footer.right, size: footer.size, weight: .regular)
        let leftWidth = max(40, rect.width - rightWidth - 32)
        text(
            footer.left, x: rect.x, y: rect.y, width: leftWidth, size: footer.size, ink: palette.textDim,
            lines: footer.leftLines)
        text(
            footer.right, x: rect.x + rect.width - rightWidth - 1, y: rect.y, width: rightWidth + 2,
            size: footer.size, ink: palette.textDim, alignment: .right)
    }

    private func font(_ size: Double, weight: NSFont.Weight, tabular: Bool) -> NSFont {
        tabular
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    /// Draws `string` in a box `width` wide (0 for as wide as it is) and `lines` lines tall. The
    /// lines are leaded at Core's 1.28 so a paragraph takes the height Core reserved for it, and
    /// the last one is cut with an ellipsis rather than the paragraph growing past its box.
    @discardableResult
    private func text(
        _ string: String, x: Double, y: Double, width: Double = 0, size: Double,
        weight: NSFont.Weight = .regular, ink: String, alignment: NSTextAlignment = .left,
        lines: Int = 1, tracking: Double = 0, tabular: Bool = false
    ) -> Double {
        let face = font(size, weight: weight, tabular: tabular)
        let leading = Card.lineHeight(size, lines: 1)
        let natural = face.ascender - face.descender
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        paragraph.lineSpacing = max(0, leading - natural)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: face, .foregroundColor: Self.nsColor(ink), .paragraphStyle: paragraph,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let box = CGRect(
            x: x, y: y, width: width > 0 ? width : 4000, height: leading * Double(lines))
        NSAttributedString(string: string, attributes: attributes).draw(
            with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return box.height
    }

    private func width(of string: String, size: Double, weight: NSFont.Weight) -> Double {
        Double(
            NSAttributedString(
                string: string, attributes: [.font: font(size, weight: weight, tabular: false)]
            ).size().width.rounded(.up))
    }

    private func block(_ block: Block, x: Double, y: Double, metrics: Card.Metrics) {
        let s = metrics.scale
        let width = metrics.contentWidth
        let size = Card.fontSize(block, in: metrics)
        let lines = Card.lines(block, in: metrics)
        switch block {
        case .brand(let string):
            text(
                string, x: x, y: y, width: width, size: size, weight: .bold, ink: palette.accent,
                tracking: 4 * s)
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
            ctx.setFillColor(Self.color(palette.rule))
            ctx.fill(CGRect(x: x, y: y, width: width, height: 1))
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
            let ink: CGColor =
                bar.isEmpty
                ? Self.color(palette.rule)
                : accented ? Self.color(palette.accent) : Self.color(palette.info, alpha: 0.85)
            fill(
                CGRect(x: left, y: y + chartHeight - height, width: barWidth, height: height),
                radius: barWidth * 0.35, with: ink)
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
            let ink: CGColor =
                bar.isEmpty
                ? Self.color(palette.rule)
                : peak ? Self.color(palette.accent) : Self.color(palette.info, alpha: 0.85)
            fill(
                CGRect(x: middle - barWidth / 2, y: y + chartHeight - height, width: barWidth, height: height),
                radius: 3 * s, with: ink)
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
        let moneyWidth = meter.money.map { self.width(of: $0, size: labelSize, weight: .semibold) } ?? 0
        if !meter.detail.isEmpty {
            let ink = min(self.width(of: meter.label, size: labelSize, weight: .semibold), labelRoom)
            let detailX = x + ink + 14 * s
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
        fill(
            CGRect(x: x, y: trackY, width: width, height: trackHeight), radius: trackHeight / 2,
            with: Self.color(palette.rule))
        let share = min(1, max(0, meter.share))
        if share > 0 {
            fill(
                CGRect(x: x, y: trackY, width: max(trackHeight, width * share), height: trackHeight),
                radius: trackHeight / 2, with: Self.color(meter.hot ? palette.accent : palette.info))
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
            record.value, x: x + 40 * s, y: y + 20 * s, width: width - 40 * s,
            size: Card.recordSize * s, weight: .semibold, ink: palette.text, tabular: true)
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
            text(
                stat.value, x: left, y: top, width: cell, size: valueSize, weight: .bold,
                ink: palette.text, tabular: true)
            text(
                stat.label, x: left, y: top + valueSize * 1.15, width: cell, size: labelSize,
                ink: palette.textDim)
        }
    }
}
