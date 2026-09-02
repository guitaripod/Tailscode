import TailscodeCore
import UIKit

/// Paints `AnalyticsShare.Card` into a PNG. Geometry and every word are Core's; this only
/// turns points into pixels at the scale the phone's screen can actually show.
enum AnalyticsCardRenderer {
    static func png(
        _ share: AnalyticsShare, scale: CGFloat = 3, dark: Bool? = nil
    ) -> (data: Data, filename: String)? {
        let palette: AnalyticsShare.Palette = {
            if ThemeSelection.usesSystemPalette { return .shareDefault }
            let isDark = dark ?? (UITraitCollection.current.userInterfaceStyle == .dark)
            return .current(dark: isDark)
        }()
        let card = AnalyticsShare.Card(
            blocks: share.card.blocks, palette: palette, height: share.card.height)
        let size = CGSize(
            width: AnalyticsShare.Card.width * scale,
            height: card.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            paint(card: card, scale: scale, in: context.cgContext)
        }
        guard let data = image.pngData() else { return nil }
        return (data, share.filename)
    }

    static func temporaryFile(_ share: AnalyticsShare) -> URL? {
        guard let rendered = png(share) else { return nil }
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

    private static func paint(card: AnalyticsShare.Card, scale: CGFloat, in ctx: CGContext) {
        let width = AnalyticsShare.Card.width * scale
        let height = card.height * scale
        let pad = AnalyticsShare.Card.pad * scale
        let contentWidth = AnalyticsShare.Card.contentWidth * scale

        ctx.setFillColor(color(card.palette.canvas))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        roundedRect(
            ctx, CGRect(x: 0, y: 0, width: width, height: height),
            radius: AnalyticsShare.Card.corner * scale, fill: color(card.palette.canvas))

        var y = pad
        for block in card.blocks {
            let lines = AnalyticsShare.Card.lines(block)
            switch block {
            case .brand(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.brandSize * scale, weight: .bold,
                    color: color(card.palette.accent), tracking: 4 * scale, ctx: ctx)
            case .kicker(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.kickerSize * scale, weight: .semibold,
                    color: color(card.palette.text), ctx: ctx)
            case .hero(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.heroSize * scale, weight: .bold,
                    color: color(card.palette.text), rounded: true, ctx: ctx)
            case .body(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.bodySize * scale, weight: .regular,
                    color: color(card.palette.text), lines: lines, ctx: ctx)
            case .dim(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.dimSize * scale, weight: .regular,
                    color: color(card.palette.textDim), lines: lines, ctx: ctx)
            case .trend(let text, let tone):
                let ink: CGColor = {
                    switch tone {
                    case .up: return color(card.palette.warn)
                    case .down: return color(card.palette.accent)
                    case .flat: return color(card.palette.textDim)
                    }
                }()
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.bodySize * scale, weight: .semibold,
                    color: ink, ctx: ctx)
            case .daily(let chart):
                paintBars(
                    chart.bars, in: CGRect(
                        x: pad, y: y, width: contentWidth,
                        height: AnalyticsShare.Card.dailyHeight * scale),
                    barWidth: AnalyticsShare.Card.dailyBarWidth * scale,
                    palette: card.palette, ctx: ctx)
                let axisY = y + (AnalyticsShare.Card.dailyHeight + 6) * scale
                drawText(
                    chart.leading, at: CGPoint(x: pad, y: axisY), width: contentWidth / 2,
                    size: AnalyticsShare.Card.axisSize * scale, weight: .medium,
                    color: color(card.palette.textDim), ctx: ctx)
                drawText(
                    chart.trailing, at: CGPoint(x: pad + contentWidth / 2, y: axisY),
                    width: contentWidth / 2, size: AnalyticsShare.Card.axisSize * scale,
                    weight: .medium, color: color(card.palette.textDim), align: .right, ctx: ctx)
            case .weekday(let bars):
                paintWeekday(
                    bars, in: CGRect(
                        x: pad, y: y, width: contentWidth,
                        height: AnalyticsShare.Card.weekdayHeight * scale),
                    palette: card.palette, scale: scale, ctx: ctx)
            case .section(let text):
                drawText(
                    text.uppercased(), at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.sectionSize * scale, weight: .bold,
                    color: color(card.palette.textDim), tracking: 2 * scale, ctx: ctx)
            case .meter(let meter):
                paintMeter(
                    meter, at: CGPoint(x: pad, y: y), width: contentWidth,
                    palette: card.palette, scale: scale, ctx: ctx)
            case .record(let record):
                paintRecord(
                    record, at: CGPoint(x: pad, y: y), width: contentWidth,
                    palette: card.palette, scale: scale, ctx: ctx)
            case .insight(let text):
                drawText(
                    AnalyticsShare.Card.insightPrefix + text, at: CGPoint(x: pad, y: y),
                    width: contentWidth, size: AnalyticsShare.Card.bodySize * scale,
                    weight: .regular, color: color(card.palette.text), lines: lines, ctx: ctx)
            case .rule:
                ctx.setFillColor(color(card.palette.rule))
                ctx.fill(CGRect(x: pad, y: y, width: contentWidth, height: 1 * scale))
            case .foot(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.footSize * scale, weight: .regular,
                    color: color(card.palette.textDim), lines: lines, ctx: ctx)
            case .spacer:
                break
            }
            y += AnalyticsShare.Card.height(block) * scale
        }
    }

    private static func paintBars(
        _ bars: [AnalyticsShare.DayBar], in rect: CGRect, barWidth: CGFloat,
        palette: AnalyticsShare.Palette, ctx: CGContext
    ) {
        guard !bars.isEmpty else { return }
        let gap = max(1, (rect.width - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1))
        for (index, bar) in bars.enumerated() {
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let height = bar.isEmpty ? max(2, rect.height * 0.04) : max(4, rect.height * bar.share)
            let y = rect.maxY - height
            let fill: CGColor = {
                if bar.isEmpty { return color(palette.rule) }
                if bar.isToday { return color(palette.accent) }
                return color(palette.info, alpha: 0.85)
            }()
            roundedRect(
                ctx, CGRect(x: x, y: y, width: barWidth, height: height), radius: barWidth * 0.35,
                fill: fill)
        }
    }

    private static func paintWeekday(
        _ bars: [AnalyticsShare.DayBar], in rect: CGRect,
        palette: AnalyticsShare.Palette, scale: CGFloat, ctx: CGContext
    ) {
        guard !bars.isEmpty else { return }
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        let column = rect.width / CGFloat(bars.count)
        let barWidth = min(28 * scale, column * 0.45)
        let chartHeight = rect.height
        for (index, bar) in bars.enumerated() {
            let mid = rect.minX + column * (CGFloat(index) + 0.5)
            let height = bar.isEmpty ? 3 * scale : max(4 * scale, chartHeight * bar.share)
            let y = rect.minY + chartHeight - height
            let fill =
                bar.share >= 1
                ? color(palette.accent)
                : bar.isEmpty ? color(palette.rule) : color(palette.info, alpha: 0.85)
            roundedRect(
                ctx, CGRect(x: mid - barWidth / 2, y: y, width: barWidth, height: height),
                radius: 3 * scale, fill: fill)
            if labels.indices.contains(index) {
                drawText(
                    labels[index],
                    at: CGPoint(x: mid - column / 2, y: rect.minY + chartHeight + 6 * scale),
                    width: column, size: AnalyticsShare.Card.axisSize * scale, weight: .medium,
                    color: color(palette.textDim), align: .center, ctx: ctx)
            }
        }
    }

    private static func paintMeter(
        _ meter: AnalyticsShare.MeterBar, at origin: CGPoint, width: CGFloat,
        palette: AnalyticsShare.Palette, scale: CGFloat, ctx: CGContext
    ) {
        let labelWidth = width * 0.55
        let labelSize = AnalyticsShare.Card.meterSize * scale
        drawText(
            meter.label, at: origin, width: labelWidth, size: labelSize, weight: .semibold,
            color: color(palette.text), ctx: ctx)
        if !meter.detail.isEmpty {
            let labelInk = min(labelWidth, textWidth(meter.label, size: labelSize, weight: .semibold))
            let detailX = origin.x + labelInk + 14 * scale
            let detailWidth =
                origin.x + width - AnalyticsShare.Card.meterValueWidth * scale - detailX
            if detailWidth > 60 * scale {
                drawText(
                    meter.detail, at: CGPoint(x: detailX, y: origin.y + 5 * scale),
                    width: detailWidth, size: AnalyticsShare.Card.meterDetailSize * scale,
                    weight: .regular, color: color(palette.textDim), ctx: ctx)
            }
        }
        if let money = meter.money {
            drawText(
                money, at: origin, width: width,
                size: AnalyticsShare.Card.meterSize * scale, weight: .semibold,
                color: color(palette.text), align: .right, ctx: ctx)
        }
        let trackY = origin.y + 28 * scale
        let trackHeight = AnalyticsShare.Card.meterTrackHeight * scale
        roundedRect(
            ctx, CGRect(x: origin.x, y: trackY, width: width, height: trackHeight),
            radius: trackHeight / 2, fill: color(palette.rule))
        let fillWidth = max(trackHeight, width * min(max(meter.share, 0), 1))
        roundedRect(
            ctx, CGRect(x: origin.x, y: trackY, width: fillWidth, height: trackHeight),
            radius: trackHeight / 2,
            fill: color(meter.hot ? palette.accent : palette.info))
    }

    private static func paintRecord(
        _ record: AnalyticsShare.RecordLine, at origin: CGPoint, width: CGFloat,
        palette: AnalyticsShare.Palette, scale: CGFloat, ctx: CGContext
    ) {
        drawText(
            record.glyph, at: origin, width: 36 * scale,
            size: AnalyticsShare.Card.recordSize * scale, weight: .semibold,
            color: color(palette.special), ctx: ctx)
        let textX = origin.x + 40 * scale
        drawText(
            record.caption, at: CGPoint(x: textX, y: origin.y), width: width - 40 * scale,
            size: AnalyticsShare.Card.recordTitleSize * scale, weight: .medium,
            color: color(palette.textDim), ctx: ctx)
        drawText(
            record.value, at: CGPoint(x: textX, y: origin.y + 20 * scale),
            width: width - 40 * scale,
            size: AnalyticsShare.Card.recordSize * scale, weight: .semibold,
            color: color(palette.text), ctx: ctx)
    }

    private static func drawText(
        _ string: String, at origin: CGPoint, width: CGFloat, size: CGFloat,
        weight: UIFont.Weight, color: CGColor, tracking: CGFloat = 0, lines: Int = 1,
        rounded: Bool = false, align: NSTextAlignment = .left, ctx: CGContext
    ) {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font: UIFont = {
            guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded)
            else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(cgColor: color),
        ]
        if tracking != 0 {
            attributes[.kern] = tracking
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = breakMode(lines: lines)
        attributes[.paragraphStyle] = paragraph
        let rect = CGRect(
            x: origin.x, y: origin.y, width: width,
            height: font.lineHeight * CGFloat(lines) + 4)
        NSAttributedString(string: string, attributes: attributes).draw(with: rect, options: [
            .usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine,
        ], context: nil)
    }

    /// A truncating break mode never wraps under string drawing — a paragraph given three lines
    /// came out as one line and an ellipsis — so a paragraph wraps by word and only its last
    /// visible line is cut.
    private static func breakMode(lines: Int) -> NSLineBreakMode {
        lines > 1 ? .byWordWrapping : .byTruncatingTail
    }

    private static func textWidth(_ string: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        NSAttributedString(
            string: string, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]
        ).size().width
    }

    private static func roundedRect(
        _ ctx: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor
    ) {
        let path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(fill)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        guard let channels = Contrast.channels(hex) else {
            return UIColor.gray.withAlphaComponent(alpha).cgColor
        }
        return UIColor(
            red: channels.red, green: channels.green, blue: channels.blue, alpha: alpha
        ).cgColor
    }
}
