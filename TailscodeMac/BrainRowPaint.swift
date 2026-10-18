import AppKit
import TailscodeCore

/// The fonts the step list and the filter chips draw with, one value read from the type ramp so a
/// change of the type scale is one rebuild of it and no list invents a size.
@MainActor
struct BrainListFonts {
    let title = MacTheme.Ramp.font(.rowTitleStrong)
    let argument = MacTheme.Ramp.font(.toolDetail)
    let number = MacTheme.Ramp.font(.rowMeta)
    let note = MacTheme.Ramp.font(.thought)
    let status = MacTheme.Ramp.font(.rowMeta)
    let count = MacTheme.Ramp.font(.rowStamp)
    let cap = MacTheme.Ramp.font(.rowStamp)
    let chipCount = MacTheme.Ramp.font(.gauge)
    let pill = MacTheme.Ramp.font(.rowMeta)
    let control = MacTheme.Ramp.font(.control)
    let said = MacTheme.Ramp.attributes(.sectionLabel)
    let monoWidth: CGFloat

    init() {
        let probe = ("MMMMMMMMMMMMMMMMMMMM" as NSString).size(withAttributes: [.font: argument])
        monoWidth = max(1, probe.width / 20)
    }

    func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func saidWidth(_ word: String) -> CGFloat {
        ceil((word as NSString).size(withAttributes: said).width)
    }
}

/// Every colour the list and the chips draw with, resolved once from the palette the head wears.
@MainActor
struct BrainListColors {
    let accent: NSColor
    let warn: NSColor
    let danger: NSColor
    let ink: NSColor
    let dim: NSColor
    let rule: NSColor
    let rule2: NSColor
    let card: NSColor
    let canvas: NSColor
    let zones: [NSColor]
    let dangerWash: NSColor
    let warnWash: NSColor
    let cursorWash: NSColor
    let hoverWash: NSColor
    let highlight: NSColor
    let pressed: NSColor
    let saidRest: NSColor

    init(inks: BrainInks) {
        let palette = inks.palette
        accent = NSColor(hex: palette.accent) ?? .controlAccentColor
        warn = NSColor(hex: palette.warn) ?? .systemOrange
        danger = NSColor(hex: palette.danger) ?? .systemRed
        ink = inks.text
        dim = inks.textDim
        rule = inks.rule
        let blended = Contrast.blend(palette.canvas, palette.textDim, 0.34) ?? palette.rule
        let edge = NSColor(hex: blended) ?? inks.rule
        rule2 = edge
        card = inks.raised
        canvas = inks.canvas
        zones = NeuralZone.allCases.map { inks.page($0) }
        dangerWash = danger.withAlphaComponent(0.08)
        warnWash = warn.withAlphaComponent(0.08)
        cursorWash = accent.withAlphaComponent(0.14)
        hoverWash = inks.text.withAlphaComponent(0.06)
        highlight = warn.withAlphaComponent(0.34)
        pressed = inks.rule.withAlphaComponent(0.6)
        saidRest = edge.blended(withFraction: 0.55, of: accent) ?? edge
    }

    func zone(_ zone: NeuralZone) -> NSColor { zones[zone.rawValue] }

    func verdict(_ verdict: NeuralVerdict.Step) -> NSColor {
        switch verdict {
        case .done, .running: return accent
        case .fixed, .tryingAgain, .waiting, .stalled: return warn
        case .failed: return danger
        case .stopped: return dim
        }
    }
}

/// How one row of the step list is drawn, written once: a row, a width and what the pointer is
/// doing to it. Everything a row would otherwise measure again on every frame (its title and
/// argument as attributed strings, where the argument starts, where the mark stands) is held by
/// row, width and theme, so scrolling a long turn costs the rows on screen and not their text.
@MainActor
final class BrainRowPainter {
    struct State {
        var isCursor = false
        var isHovered = false
        var pointerHere = false
        var copied = false
        var copyHot = false
        var alpha: CGFloat = 1
        var query = ""
        var wide = false
        /// A layer carries this row's running or waiting mark, so the row leaves it out.
        var markIsLayer = false
    }

    static let titleMax: CGFloat = 168
    static let titleX: CGFloat = 83
    static let glyphX: CGFloat = 34
    static let numberRight: CGFloat = 75
    static let numberWidth: CGFloat = 24
    static let markInset: CGFloat = 12
    /// The retry wording needs a column this wide; below it the mark stands alone.
    static let wideColumn: CGFloat = 400

    private(set) var fonts = BrainListFonts()
    private(set) var colors: BrainListColors
    private(set) var generation = 0

    private struct Key: Hashable {
        let id: String
        let width: Int
        let wide: Bool
        let copyShown: Bool
        let copied: Bool
        let query: String
        let stamp: Int
        let verdict: String
    }

    private struct Prepared {
        var title: NSAttributedString?
        var titleWidth: CGFloat = 0
        var titleHighlight: (x: CGFloat, width: CGFloat)?
        var argument: NSAttributedString?
        var argumentX: CGFloat = 0
        var argumentRoom: CGFloat = 0
        var argumentHighlight: (x: CGFloat, width: CGFloat)?
        var body: NSAttributedString?
        var bodyRoom: CGFloat = 0
        var mark: Mark?
    }

    struct Mark {
        var text: NSAttributedString?
        var textWidth: CGFloat = 0
        var glyphX: CGFloat = 0
        var left: CGFloat = 0
    }

    private var cache: [Key: Prepared] = [:]

    init(inks: BrainInks) {
        colors = BrainListColors(inks: inks)
    }

    func reset(inks: BrainInks) {
        fonts = BrainListFonts()
        colors = BrainListColors(inks: inks)
        cache.removeAll(keepingCapacity: true)
        generation += 1
    }

    var cachedCount: Int { cache.count }

    func copyRect(for row: NeuralStepList.Row, width: CGFloat, copied: Bool) -> CGRect {
        let label = copied ? BrainListWords.copied : BrainListWords.copy
        let size = fonts.width(label, fonts.status) + 18
        let height = CGFloat(row.height())
        return CGRect(x: width - 6 - size, y: (height - 24) / 2, width: size, height: 24)
    }

    /// Where the mark stands at the right of a row, and how far left of it the text may reach.
    func markPlan(for row: NeuralStepList.Row, width: CGFloat, wide: Bool) -> Mark? {
        guard row.verdict.isMarked else { return nil }
        let right = width - Self.markInset
        let color = colors.verdict(row.verdict)
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.status, .foregroundColor: color]
        var text: String?
        if case .fixed = row.verdict {
            if wide {
                text = BrainListWords.markWord(for: row)
            } else if let related = row.related {
                text = "\u{2192}\(related.number)"
            }
        } else if wide {
            text = BrainListWords.markWord(for: row)
        }
        guard let text else {
            return Mark(text: nil, textWidth: 0, glyphX: right - 6, left: right - 20)
        }
        let size = fonts.width(text, fonts.status)
        let glyph = right - size - 6 - 6
        return Mark(
            text: NSAttributedString(string: text, attributes: attributes), textWidth: size,
            glyphX: glyph, left: glyph - 12)
    }

    private func prepare(_ row: NeuralStepList.Row, width: CGFloat, state: State) -> Prepared {
        let copyShown = state.pointerHere || state.copied
        let key = Key(
            id: row.id, width: Int(width), wide: state.wide, copyShown: copyShown,
            copied: state.copied, query: state.query,
            stamp: row.title.utf8.count &* 31 &+ row.argument.utf8.count &+ row.lines.count,
            verdict: row.verdict.word)
        if let held = cache[key] { return held }
        var made = Prepared()
        var statusLeft = width - Self.markInset
        if copyShown {
            statusLeft = copyRect(for: row, width: width, copied: state.copied).minX
        } else if let mark = markPlan(for: row, width: width, wide: state.wide) {
            made.mark = mark
            statusLeft = mark.left
        }
        let limit = statusLeft - 12
        switch row.kind {
        case .tool:
            prepareTool(row, limit: limit, query: state.query, into: &made)
        case .note:
            made.bodyRoom = max(0, limit - Self.titleX)
            made.body = said(row, query: state.query)
        case .thought:
            made.bodyRoom = max(0, limit - Self.titleX)
            made.body = NSAttributedString(
                string: row.argument,
                attributes: [
                    .font: fonts.note, .foregroundColor: colors.dim, .paragraphStyle: tail,
                ])
        }
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        return made
    }

    private var tail: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private func prepareTool(
        _ row: NeuralStepList.Row, limit: CGFloat, query: String, into made: inout Prepared
    ) {
        let measured = fonts.width(row.title, fonts.title)
        let titleWidth = min(measured, Self.titleMax)
        made.titleWidth = titleWidth
        made.title = NSAttributedString(
            string: row.title,
            attributes: [.font: fonts.title, .foregroundColor: colors.ink, .paragraphStyle: tail])
        if !query.isEmpty, let range = row.title.range(of: query, options: .caseInsensitive) {
            let before = String(row.title[..<range.lowerBound])
            let hit = String(row.title[range])
            let start = fonts.width(before, fonts.title)
            let end = min(start + fonts.width(hit, fonts.title), titleWidth)
            if start < titleWidth { made.titleHighlight = (Self.titleX + start - 1, end - start + 2) }
        }
        let argumentX = Self.titleX + titleWidth + 10
        let room = max(0, limit - argumentX)
        made.argumentX = argumentX
        made.argumentRoom = room
        guard !row.argument.isEmpty else { return }
        let chars = max(0, Int(room / fonts.monoWidth))
        let shown = row.argument(fittingChars: chars)
        made.argument = NSAttributedString(
            string: shown,
            attributes: [.font: fonts.argument, .foregroundColor: colors.dim, .paragraphStyle: tail])
        if !query.isEmpty, let range = shown.range(of: query, options: .caseInsensitive) {
            let start = shown.distance(from: shown.startIndex, to: range.lowerBound)
            let length = shown.distance(from: range.lowerBound, to: range.upperBound)
            made.argumentHighlight = (
                argumentX + CGFloat(start) * fonts.monoWidth - 1,
                CGFloat(length) * fonts.monoWidth + 2
            )
        }
    }

    private func said(_ row: NeuralStepList.Row, query: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString(
            string: row.lines.joined(separator: " "),
            attributes: [.font: fonts.note, .foregroundColor: colors.ink, .paragraphStyle: style])
        if !query.isEmpty {
            let whole = text.string
            if let range = whole.range(of: query, options: .caseInsensitive) {
                text.addAttribute(.backgroundColor, value: colors.highlight, range: NSRange(range, in: whole))
            }
        }
        return text
    }

    func paint(
        _ row: NeuralStepList.Row, previous: NeuralStepList.Row?, next: NeuralStepList.Row?,
        y: CGFloat, width: CGFloat, state: State
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = CGFloat(row.height())
        let prepared = prepare(row, width: width, state: state)
        context.saveGState()
        if state.alpha < 1 { context.setAlpha(max(state.alpha, 0)) }
        paintGround(row, y: y, width: width, height: height, state: state)
        paintBracket(row, previous: previous, next: next, y: y, height: height)
        let band: CGFloat = row.isSaid ? 28 : height
        let mid = y + band / 2
        if row.isSaid {
            BrainRowGlyphs.quote(at: CGPoint(x: Self.glyphX, y: y + 14), color: colors.accent)
        } else {
            BrainRowGlyphs.zone(row.zone, at: CGPoint(x: Self.glyphX, y: mid), color: colors.zone(row.zone))
        }
        paintNumber(row, y: y, band: band)
        paintStatus(row, prepared: prepared, y: y, band: band, width: width, state: state)
        paintText(row, prepared: prepared, y: y, height: height)
        context.restoreGState()
    }

    private func paintGround(
        _ row: NeuralStepList.Row, y: CGFloat, width: CGFloat, height: CGFloat, state: State
    ) {
        switch row.verdict {
        case .failed:
            colors.dangerWash.setFill()
            NSBezierPath.fill(CGRect(x: 0, y: y, width: width, height: height))
        case .fixed, .tryingAgain:
            colors.warnWash.setFill()
            NSBezierPath.fill(CGRect(x: 0, y: y, width: width, height: height))
        default:
            break
        }
        if state.isCursor {
            colors.cursorWash.setFill()
            NSBezierPath.fill(CGRect(x: 0, y: y, width: width, height: height))
        } else if state.isHovered {
            colors.hoverWash.setFill()
            NSBezierPath.fill(CGRect(x: 0, y: y, width: width, height: height))
        }
        colors.zone(row.zone).setFill()
        NSBezierPath.fill(CGRect(x: 0, y: y, width: 3, height: height))
        guard state.isCursor else { return }
        colors.accent.setFill()
        NSBezierPath.fill(CGRect(x: 3, y: y, width: 2, height: height))
        let ring = NSBezierPath(
            roundedRect: CGRect(x: 0.5, y: y + 0.5, width: width - 1, height: height - 1),
            xRadius: 2, yRadius: 2)
        ring.lineWidth = 1
        colors.accent.withAlphaComponent(0.9).setStroke()
        ring.stroke()
    }

    private func paintBracket(
        _ row: NeuralStepList.Row, previous: NeuralStepList.Row?, next: NeuralStepList.Row?,
        y: CGFloat, height: CGFloat
    ) {
        guard row.bracket != .none else { return }
        let above = previous.map { $0.group == row.group && $0.bracket != .none } ?? false
        let below = next.map { $0.group == row.group && $0.bracket != .none } ?? false
        guard above || below else { return }
        let mid = y + height / 2
        let path = NSBezierPath()
        let x: CGFloat = 9.5
        path.move(to: CGPoint(x: x, y: above ? y : mid))
        path.line(to: CGPoint(x: x, y: below ? y + height : mid))
        path.move(to: CGPoint(x: x, y: mid))
        path.line(to: CGPoint(x: x + 6, y: mid))
        path.lineWidth = 1
        colors.dim.withAlphaComponent(0.75).setStroke()
        path.stroke()
    }

    private func paintNumber(_ row: NeuralStepList.Row, y: CGFloat, band: CGFloat) {
        let text = "\(row.number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.number, .foregroundColor: colors.dim]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: Self.numberRight - size.width, y: y + (band - size.height) / 2),
            withAttributes: attributes)
    }

    private func paintStatus(
        _ row: NeuralStepList.Row, prepared: Prepared, y: CGFloat, band: CGFloat, width: CGFloat,
        state: State
    ) {
        if state.pointerHere || state.copied {
            paintCopy(row, y: y, width: width, state: state)
            return
        }
        guard let mark = prepared.mark else { return }
        let right = width - Self.markInset
        let center = y + band / 2
        if let text = mark.text {
            let height = text.size().height
            text.draw(at: CGPoint(x: right - mark.textWidth, y: center - height / 2))
        }
        if !state.markIsLayer {
            BrainRowGlyphs.verdict(
                row.verdict, at: CGPoint(x: mark.glyphX, y: center), size: 13,
                color: colors.verdict(row.verdict))
        }
    }

    private func paintCopy(_ row: NeuralStepList.Row, y: CGFloat, width: CGFloat, state: State) {
        let rect = copyRect(for: row, width: width, copied: state.copied)
        let shape = NSBezierPath(
            roundedRect: CGRect(x: rect.minX + 0.5, y: y + rect.minY + 0.5, width: rect.width - 1, height: rect.height - 1),
            xRadius: 12, yRadius: 12)
        colors.card.withAlphaComponent(0.95).setFill()
        shape.fill()
        (state.copyHot ? colors.accent : colors.rule2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let label = (state.copied ? BrainListWords.copied : BrainListWords.copy) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.status, .foregroundColor: colors.ink]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: y + rect.midY - size.height / 2),
            withAttributes: attributes)
    }

    private func paintText(_ row: NeuralStepList.Row, prepared: Prepared, y: CGFloat, height: CGFloat) {
        switch row.kind {
        case .tool:
            if let title = prepared.title {
                drawHighlight(prepared.titleHighlight, y: y, height: height)
                drawLine(title, x: Self.titleX, width: prepared.titleWidth, y: y, height: height)
            }
            if let argument = prepared.argument, prepared.argumentRoom > 4 {
                drawHighlight(prepared.argumentHighlight, y: y, height: height)
                drawLine(
                    argument, x: prepared.argumentX, width: prepared.argumentRoom, y: y, height: height)
            }
        case .thought:
            guard let body = prepared.body, prepared.bodyRoom > 4 else { return }
            drawLine(body, x: Self.titleX, width: prepared.bodyRoom, y: y, height: height)
        case .note:
            guard let body = prepared.body, prepared.bodyRoom > 4 else { return }
            let line = fonts.lineHeight(fonts.note)
            body.draw(
                with: CGRect(x: Self.titleX, y: y + 4, width: prepared.bodyRoom, height: line * 2),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawLine(_ text: NSAttributedString, x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) {
        let line = ceil(text.size().height)
        text.draw(
            with: CGRect(x: x, y: y + (height - line) / 2, width: width, height: line),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawHighlight(_ span: (x: CGFloat, width: CGFloat)?, y: CGFloat, height: CGFloat) {
        guard let span, span.width > 0 else { return }
        colors.highlight.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: span.x, y: y + 5, width: span.width, height: height - 10),
            xRadius: 3, yRadius: 3
        ).fill()
    }
}
