import AppKit
import TailscodeCore

/// Paints `AnalyticsShare.Card` into a PNG. Geometry and every word are Core's; this only
/// turns points into pixels at a Retina scale.
enum AnalyticsCardRenderer {
    static func png(
        _ share: AnalyticsShare, scale: CGFloat = 2, dark: Bool? = nil
    ) -> (data: Data, image: NSImage, filename: String)? {
        let palette: AnalyticsShare.Palette = {
            if ThemeSelection.usesSystemPalette { return .shareDefault }
            let isDark =
                dark
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return .current(dark: isDark)
        }()
        let card = AnalyticsShare.Card(
            blocks: share.card.blocks, palette: palette, height: share.card.height)
        let logical = NSSize(width: AnalyticsShare.Card.width, height: card.height)
        let image = NSImage(size: logical, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            paint(card: card, in: ctx)
            return true
        }
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        // Retina density: redraw into a high-res bitmap so Messages/AirDrop get a sharp PNG.
        if scale > 1.1 {
            let pixelWidth = Int((logical.width * scale).rounded())
            let pixelHeight = Int((logical.height * scale).rounded())
            guard
                let hi = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return (data, image, share.filename) }
            hi.size = logical
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: hi) {
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                // Bitmap origin is bottom-left; flip so paint()'s top-down y matches.
                context.cgContext.translateBy(x: 0, y: logical.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                paint(card: card, in: context.cgContext)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let hiData = hi.representation(using: .png, properties: [:]) {
                let hiImage = NSImage(size: logical)
                hiImage.addRepresentation(hi)
                return (hiData, hiImage, share.filename)
            }
        }
        return (data, image, share.filename)
    }

    static func temporaryFile(_ share: AnalyticsShare) -> URL? {
        guard let rendered = png(share) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-analytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(rendered.filename)
        do {
            try rendered.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func paint(card: AnalyticsShare.Card, in ctx: CGContext) {
        let width = AnalyticsShare.Card.width
        let height = card.height
        let pad = AnalyticsShare.Card.pad
        let contentWidth = AnalyticsShare.Card.contentWidth

        ctx.setFillColor(color(card.palette.canvas))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var y = pad
        for block in card.blocks {
            switch block {
            case .brand(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.brandSize, weight: .bold,
                    color: nsColor(card.palette.accent), tracking: 4)
                y += 22
            case .kicker(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.kickerSize, weight: .semibold,
                    color: nsColor(card.palette.text))
                y += 28
            case .hero(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.heroSize, weight: .bold,
                    color: nsColor(card.palette.text), rounded: true)
                y += 88
            case .body(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.bodySize, weight: .regular,
                    color: nsColor(card.palette.text), lines: 2)
                y += AnalyticsShare.Card.lineHeight(AnalyticsShare.Card.bodySize, lines: 2)
            case .dim(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.dimSize, weight: .regular,
                    color: nsColor(card.palette.textDim), lines: 2)
                y += AnalyticsShare.Card.lineHeight(AnalyticsShare.Card.dimSize, lines: 2)
            case .trend(let text, let tone):
                let ink: NSColor = {
                    switch tone {
                    case .up: return nsColor(card.palette.warn)
                    case .down: return nsColor(card.palette.accent)
                    case .flat: return nsColor(card.palette.textDim)
                    }
                }()
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.bodySize, weight: .semibold, color: ink)
                y += AnalyticsShare.Card.lineHeight(AnalyticsShare.Card.bodySize, lines: 1)
            case .daily(let bars):
                paintBars(
                    bars,
                    in: CGRect(
                        x: pad, y: y, width: contentWidth, height: AnalyticsShare.Card.dailyHeight),
                    barWidth: AnalyticsShare.Card.dailyBarWidth, palette: card.palette, ctx: ctx)
                y += AnalyticsShare.Card.dailyHeight
            case .weekday(let bars):
                paintWeekday(
                    bars,
                    in: CGRect(
                        x: pad, y: y, width: contentWidth,
                        height: AnalyticsShare.Card.weekdayHeight + 22),
                    palette: card.palette, ctx: ctx)
                y += AnalyticsShare.Card.weekdayHeight + 22
            case .section(let text):
                drawText(
                    text.uppercased(), at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.sectionSize, weight: .bold,
                    color: nsColor(card.palette.textDim), tracking: 2)
                y += 26
            case .meter(let meter):
                paintMeter(
                    meter, at: CGPoint(x: pad, y: y), width: contentWidth, palette: card.palette,
                    ctx: ctx)
                y += 44
            case .record(let record):
                paintRecord(
                    record, at: CGPoint(x: pad, y: y), width: contentWidth, palette: card.palette)
                y += 48
            case .insight(let text):
                drawText(
                    "✦  \(text)", at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.bodySize, weight: .regular,
                    color: nsColor(card.palette.text), lines: 3)
                y += AnalyticsShare.Card.lineHeight(AnalyticsShare.Card.bodySize, lines: 3)
            case .rule:
                ctx.setFillColor(color(card.palette.rule))
                ctx.fill(CGRect(x: pad, y: y, width: contentWidth, height: 1))
                y += 1
            case .foot(let text):
                drawText(
                    text, at: CGPoint(x: pad, y: y), width: contentWidth,
                    size: AnalyticsShare.Card.footSize, weight: .regular,
                    color: nsColor(card.palette.textDim), lines: 2)
                y += AnalyticsShare.Card.lineHeight(AnalyticsShare.Card.footSize, lines: 2)
            case .spacer(let gap):
                y += gap
            }
        }
    }

    private static func paintBars(
        _ bars: [AnalyticsShare.DayBar], in rect: CGRect, barWidth: CGFloat,
        palette: AnalyticsShare.Palette, ctx: CGContext
    ) {
        guard !bars.isEmpty else { return }
        let gap = max(
            1, (rect.width - barWidth * CGFloat(bars.count)) / CGFloat(max(bars.count - 1, 1)))
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
        _ bars: [AnalyticsShare.DayBar], in rect: CGRect, palette: AnalyticsShare.Palette,
        ctx: CGContext
    ) {
        guard !bars.isEmpty else { return }
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        let column = rect.width / CGFloat(bars.count)
        let barWidth = min(28, column * 0.45)
        let chartHeight = AnalyticsShare.Card.weekdayHeight
        for (index, bar) in bars.enumerated() {
            let mid = rect.minX + column * (CGFloat(index) + 0.5)
            let height = bar.isEmpty ? 3 : max(4, chartHeight * bar.share)
            let y = rect.minY + chartHeight - height
            let fill: CGColor =
                bar.share >= 1
                ? color(palette.accent)
                : bar.isEmpty ? color(palette.rule) : color(palette.info, alpha: 0.85)
            roundedRect(
                ctx, CGRect(x: mid - barWidth / 2, y: y, width: barWidth, height: height),
                radius: 3, fill: fill)
            if labels.indices.contains(index) {
                drawText(
                    labels[index],
                    at: CGPoint(x: mid - column / 2, y: rect.minY + chartHeight + 6),
                    width: column, size: 16, weight: .medium, color: nsColor(palette.textDim),
                    align: .center)
            }
        }
    }

    private static func paintMeter(
        _ meter: AnalyticsShare.MeterBar, at origin: CGPoint, width: CGFloat,
        palette: AnalyticsShare.Palette, ctx: CGContext
    ) {
        drawText(
            meter.label, at: origin, width: width * 0.55,
            size: AnalyticsShare.Card.meterSize, weight: .semibold, color: nsColor(palette.text))
        if let money = meter.money {
            drawText(
                money, at: origin, width: width, size: AnalyticsShare.Card.meterSize,
                weight: .semibold, color: nsColor(palette.text), align: .trailing)
        }
        let trackY = origin.y + 28
        let trackHeight = AnalyticsShare.Card.meterTrackHeight
        roundedRect(
            ctx, CGRect(x: origin.x, y: trackY, width: width, height: trackHeight),
            radius: trackHeight / 2, fill: color(palette.rule))
        let fillWidth = max(trackHeight, width * min(max(meter.share, 0), 1))
        roundedRect(
            ctx, CGRect(x: origin.x, y: trackY, width: fillWidth, height: trackHeight),
            radius: trackHeight / 2, fill: color(meter.hot ? palette.accent : palette.info))
    }

    private static func paintRecord(
        _ record: AnalyticsShare.RecordLine, at origin: CGPoint, width: CGFloat,
        palette: AnalyticsShare.Palette
    ) {
        drawText(
            record.glyph, at: origin, width: 36, size: AnalyticsShare.Card.recordSize,
            weight: .semibold, color: nsColor(palette.special))
        let textX = origin.x + 40
        drawText(
            record.title, at: CGPoint(x: textX, y: origin.y), width: width - 40, size: 18,
            weight: .medium, color: nsColor(palette.textDim))
        drawText(
            record.value, at: CGPoint(x: textX, y: origin.y + 20), width: width - 40,
            size: AnalyticsShare.Card.recordSize, weight: .semibold, color: nsColor(palette.text))
    }

    private static func drawText(
        _ string: String, at origin: CGPoint, width: CGFloat, size: CGFloat,
        weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0, lines: Int = 1,
        rounded: Bool = false, align: NSTextAlignment = .left
    ) {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font: NSFont = {
            guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded),
                let roundedFont = NSFont(descriptor: descriptor, size: size)
            else { return base }
            return roundedFont
        }()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let rect = CGRect(
            x: origin.x, y: origin.y, width: width,
            height: font.boundingRectForFont.height * CGFloat(lines) + 4)
        NSAttributedString(string: string, attributes: attributes).draw(
            with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func roundedRect(
        _ ctx: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor
    ) {
        let path = CGPath(
            roundedRect: rect, cornerWidth: min(radius, max(rect.width / 2, 0.1)),
            cornerHeight: min(radius, max(rect.height / 2, 0.1)), transform: nil)
        ctx.setFillColor(fill)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        nsColor(hex, alpha: alpha).cgColor
    }

    private static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        guard let channels = Contrast.channels(hex) else {
            return NSColor.gray.withAlphaComponent(alpha)
        }
        return NSColor(
            srgbRed: channels.red, green: channels.green, blue: channels.blue, alpha: alpha)
    }
}
