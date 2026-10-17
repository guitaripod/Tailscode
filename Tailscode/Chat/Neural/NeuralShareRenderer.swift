import TailscodeCore
import UIKit

/// Paints `NeuralShare.Card` into a poster. The geometry and every word are Core's, so the Mac and
/// Linux posters are the same picture; this turns points into pixels, sets the text in the
/// monospace the geometry was measured for and lays the hero (the head with its nodes, drawn by
/// `NeuralShareHero`) into the rounded box the geometry names.
enum NeuralShareRenderer {
    static func image(
        turn: NeuralTurn, prompt: String, look: CardStyle, dark: Bool, hero: UIImage,
        scale: CGFloat = 2, now: Date = Date()
    ) -> UIImage {
        let card = NeuralShare.Card.make(
            turn: turn, prompt: prompt.isEmpty ? nil : prompt, style: look, dark: dark, now: now)
        let size = CGSize(
            width: NeuralShare.Card.width * scale, height: NeuralShare.Card.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            paint(card, hero: hero, scale: scale, in: context.cgContext)
        }
    }

    static func png(
        turn: NeuralTurn, prompt: String, look: CardStyle, dark: Bool, hero: UIImage,
        scale: CGFloat = 2
    ) -> Data? {
        image(turn: turn, prompt: prompt, look: look, dark: dark, hero: hero, scale: scale)
            .pngData()
    }

    /// The poster as a file the share sheet can hand over, named for the turn so a saved copy
    /// says what it is. Older ones are cleared on the way, an hour after they were made.
    static func temporaryFile(
        turn: NeuralTurn, prompt: String, look: CardStyle, dark: Bool, hero: UIImage
    ) -> URL? {
        guard let data = png(turn: turn, prompt: prompt, look: look, dark: dark, hero: hero)
        else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-turns", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)
        let url = directory.appendingPathComponent("tailscode-turn-\(slug(turn.id)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            AppLogger.ui.error("could not stage turn share: \(error)")
            return nil
        }
    }

    private static func slug(_ id: String) -> String {
        let kept = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let text = String(String.UnicodeScalarView(kept))
        return text.isEmpty ? "turn" : String(text.suffix(8))
    }

    private static func prune(_ directory: URL) {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
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

    private static func paint(
        _ card: NeuralShare.Card, hero: UIImage, scale: CGFloat, in ctx: CGContext
    ) {
        let bounds = CGRect(
            x: 0, y: 0, width: NeuralShare.Card.width * scale, height: NeuralShare.Card.height * scale)
        paintCanvas(card.palette, in: bounds, scale: scale, ctx: ctx)
        paint(card.brand, card, scale, ctx)
        paint(card.tag, card, scale, ctx)
        paintHero(hero, in: rect(card.hero, scale), corner: NeuralShare.Card.corner * scale, ctx: ctx)
        paint(card.count, card, scale, ctx)
        paint(card.caption, card, scale, ctx)
        paintSub(card, scale: scale, ctx: ctx)
        for meter in card.meters {
            paint(meter.label, card, scale, ctx)
            fill(rect(meter.track, scale), radius: meter.track.height * scale / 2,
                color: color(card.palette.rule), ctx: ctx)
            if meter.share > 0 {
                fill(rect(meter.bar, scale), radius: meter.bar.height * scale / 2,
                    color: color(card.color(meter.slot)), ctx: ctx)
            }
            paint(meter.value, card, scale, ctx)
        }
        if let quote = card.quote {
            fill(rect(quote.rule, scale), radius: 0, color: color(card.palette.accent), ctx: ctx)
            paint(quote.label, card, scale, ctx)
        }
        paint(card.foot, card, scale, ctx)
        paint(card.footTag, card, scale, ctx)
    }

    /// The canvas falls from its top colour to its foot colour on the diagonal the mock's poster
    /// uses, with a faint pool of the accent in the upper right where the head's eye is.
    private static func paintCanvas(
        _ palette: AnalyticsShare.Palette, in rect: CGRect, scale: CGFloat, ctx: CGContext
    ) {
        ctx.setFillColor(color(palette.canvas))
        ctx.fill(rect)
        let space = CGColorSpaceCreateDeviceRGB()
        ctx.saveGState()
        ctx.clip(to: rect)
        if palette.canvasEnd != palette.canvas,
            let gradient = CGGradient(
                colorsSpace: space, colors: [color(palette.canvas), color(palette.canvasEnd)] as CFArray,
                locations: [0, 1])
        {
            ctx.drawLinearGradient(
                gradient, start: CGPoint(x: rect.width * 0.3, y: 0),
                end: CGPoint(x: rect.width * 0.7, y: rect.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if let glow = CGGradient(
            colorsSpace: space,
            colors: [color(palette.accent, alpha: 0.10), color(palette.accent, alpha: 0)] as CFArray,
            locations: [0, 1])
        {
            ctx.translateBy(x: rect.width * 0.85, y: rect.height * 0.12)
            ctx.scaleBy(x: 1, y: 520.0 / 900.0)
            ctx.drawRadialGradient(
                glow, startCenter: .zero, startRadius: 0, endCenter: .zero,
                endRadius: 900 * scale, options: [])
        }
        ctx.restoreGState()
    }

    /// The hero fits its box whole rather than being cropped to it, because a head with its top
    /// cut off is not the picture the poster promises; what is left over at the sides is the
    /// picture's own ground, taken from its edge so there is no seam.
    private static func paintHero(_ hero: UIImage, in rect: CGRect, corner: CGFloat, ctx: CGContext) {
        guard hero.size.width > 0, hero.size.height > 0 else { return }
        ctx.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: corner).addClip()
        edgeColor(of: hero).setFill()
        ctx.fill(rect)
        let fit = min(rect.width / hero.size.width, rect.height / hero.size.height)
        let drawn = CGSize(width: hero.size.width * fit, height: hero.size.height * fit)
        hero.draw(
            in: CGRect(
                x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height))
        ctx.restoreGState()
    }

    /// The colour at the middle of the picture's left edge.
    private static func edgeColor(of image: UIImage) -> UIColor {
        guard let cg = image.cgImage,
            let edge = cg.cropping(
                to: CGRect(x: 0, y: cg.height / 2, width: 1, height: 1))
        else { return .black }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .black }
        context.draw(edge, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// The qualifying line is one line in two inks: what was written in the accent, and what
    /// else the turn did in the dim ink, the second starting where the first ends.
    private static func paintSub(_ card: NeuralShare.Card, scale: CGFloat, ctx: CGContext) {
        guard let box = card.subRect else { return }
        var x = box.x * scale
        for run in card.sub {
            let font = font(NeuralShare.FontRole(NeuralShare.Card.subSize), scale: scale)
            let width = NSAttributedString(string: run.text, attributes: [.font: font]).size().width
            drawText(
                run.text, in: CGRect(x: x, y: box.y * scale, width: box.maxX * scale - x, height: box.height * scale),
                font: font, color: color(card.color(run.slot)), tracking: 0, align: .left, lines: 1)
            x += width
        }
    }

    private static func paint(
        _ label: NeuralShare.Label, _ card: NeuralShare.Card, _ scale: CGFloat, _ ctx: CGContext
    ) {
        var box = rect(label.rect, scale)
        if label.maxLines == 1 && label.alignment == .leading {
            box.size.width += label.font.size * scale * NeuralShare.Card.glyphWidth * 2
        }
        drawText(
            label.text, in: box, font: font(label.font, scale: scale),
            color: color(card.color(label.slot)), tracking: label.font.tracking * label.font.size * scale,
            align: label.alignment == .trailing ? .right : .left, lines: label.maxLines)
    }

    private static func font(_ role: NeuralShare.FontRole, scale: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(
            ofSize: role.size * scale, weight: role.bold ? .bold : .regular)
    }

    private static func drawText(
        _ text: String, in rect: CGRect, font: UIFont, color: CGColor, tracking: CGFloat,
        align: NSTextAlignment, lines: Int
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        if lines > 1 { paragraph.lineHeightMultiple = NeuralShare.Card.quoteLeading / 1.2 }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor(cgColor: color), .paragraphStyle: paragraph,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let room = CGRect(
            x: rect.minX, y: rect.minY, width: rect.width,
            height: max(rect.height, font.lineHeight * CGFloat(lines) + 2))
        NSAttributedString(string: text, attributes: attributes).draw(
            with: room,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil)
    }

    private static func fill(_ rect: CGRect, radius: CGFloat, color: CGColor, ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    private static func rect(_ rect: NeuralShare.Rect, _ scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
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
