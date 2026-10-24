import TailscodeCore
import UIKit

/// The last hour as lanes, one per session with its agents beneath it: bars in the activity tones,
/// an amber bar while it waited on the person, a mark where a turn ended, a now line at the right
/// edge, and the stretches this device did not see hatched. Drawn with Core Graphics straight from
/// `AgentHour` and redrawn about once a second; nothing moves between redraws, because the now line
/// is arithmetic on absolute time.
@MainActor
final class AgentHourView: UIView {
    private enum Swatch {
        case working
        case waiting
        case background
        case unseen
    }

    var onSelect: ((AgentHourLane, CGRect) -> Void)?

    var hour: AgentHour? {
        didSet {
            guard hour != oldValue else { return }
            lanes = hour?.lanes ?? []
            rebuildAccessibility()
            superview?.setNeedsLayout()
            setNeedsDisplay()
        }
    }

    private(set) var selectedID: String?
    private var hoveredID: String?
    private var lanes: [AgentHourLane] = []
    private var labelFont = Theme.Ramp.font(.panelFootnote)
    private var tickFont = Theme.Ramp.font(.rowStamp)
    private var symbols: [String: UIImage] = [:]
    private var legendItems: [(Swatch, String)] {
        [
            (.working, String(localized: "Working")),
            (.waiting, String(localized: "Waiting on you")),
            (.background, String(localized: "Background")),
            (.unseen, String(localized: "Not seen")),
        ]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) {
            (view: AgentHourView, _) in
            view.labelFont = Theme.Ramp.font(.panelFootnote)
            view.tickFont = Theme.Ramp.font(.rowStamp)
            view.symbols.removeAll()
            view.superview?.setNeedsLayout()
            view.rebuildAccessibility()
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var rowHeight: CGFloat { max(34, ceil(labelFont.lineHeight) + 16) }
    private var rulerHeight: CGFloat { ceil(tickFont.lineHeight) + 14 }
    private var gutter: CGFloat {
        let share: CGFloat = AgentsLayout.isLarge(traitCollection) ? 0.42 : 0.28
        return min(max(96, bounds.width * share), 260)
    }
    private var plotMinX: CGFloat { gutter + Theme.Spacing.s }
    private var plotMaxX: CGFloat { bounds.width - Theme.Spacing.l }
    private var lanesBottom: CGFloat { rulerHeight + CGFloat(max(1, lanes.count)) * rowHeight }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        lanesBottom + legendLayout(width: width).height + Theme.Spacing.xl
    }

    func redraw() { setNeedsDisplay() }

    private func x(_ date: Date, now: Date) -> CGFloat {
        let fraction = 1 - now.timeIntervalSince(date) / AgentHour.span
        return plotMinX + CGFloat(min(1, max(0, fraction))) * (plotMaxX - plotMinX)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let now = Date()
        drawUnseen(context, now: now)
        drawLaneBackgrounds(context)
        drawRuler(context)
        if lanes.isEmpty { drawEmpty() }
        for (index, lane) in lanes.enumerated() {
            drawLane(lane, index: index, context: context, now: now)
        }
        context.setStrokeColor(Theme.Color.label.resolvedColor(with: traitCollection).cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: plotMaxX, y: rulerHeight - 4))
        context.addLine(to: CGPoint(x: plotMaxX, y: lanesBottom))
        context.strokePath()
        drawLegend(context)
    }

    private func drawRuler(_ context: CGContext) {
        let grid = Theme.Color.separator.resolvedColor(with: traitCollection)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: tickFont,
            .foregroundColor: Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection),
        ]
        var lastEnd = -CGFloat.infinity
        for step in 0...6 {
            let minutesAgo = 60 - step * 10
            let tickX = plotMinX + CGFloat(step) / 6 * (plotMaxX - plotMinX)
            context.setStrokeColor(grid.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: tickX, y: rulerHeight - 4))
            context.addLine(to: CGPoint(x: tickX, y: lanesBottom))
            context.strokePath()
            let text =
                minutesAgo == 0
                ? String(localized: "now") : StatusFacts.age(TimeInterval(minutesAgo * 60))
            let size = (text as NSString).size(withAttributes: attributes)
            let originX = min(max(tickX - size.width / 2, 0), bounds.width - size.width)
            guard originX > lastEnd + 4 else { continue }
            (text as NSString).draw(at: CGPoint(x: originX, y: 4), withAttributes: attributes)
            lastEnd = originX + size.width
        }
    }

    private func drawUnseen(_ context: CGContext, now: Date) {
        guard let hour else { return }
        let ink = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection)
        for gap in hour.unseen {
            let from = x(gap.start, now: now)
            let to = x(gap.end, now: now)
            guard to - from > 0.5 else { continue }
            Self.hatch(
                context,
                in: CGRect(x: from, y: rulerHeight, width: to - from, height: lanesBottom - rulerHeight),
                ink: ink)
        }
    }

    private static func hatch(_ context: CGContext, in rect: CGRect, ink: UIColor) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(ink.withAlphaComponent(0.08).cgColor)
        context.fill(rect)
        context.setStrokeColor(ink.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        var start = rect.minX - rect.height
        while start < rect.maxX {
            context.move(to: CGPoint(x: start, y: rect.maxY))
            context.addLine(to: CGPoint(x: start + rect.height, y: rect.minY))
            start += 7
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawLaneBackgrounds(_ context: CGContext) {
        let accent = Theme.Color.accent.resolvedColor(with: traitCollection)
        for (index, lane) in lanes.enumerated() where lane.id == selectedID || lane.id == hoveredID {
            let strength: CGFloat = lane.id == selectedID ? 0.16 : 0.07
            context.setFillColor(accent.withAlphaComponent(strength).cgColor)
            context.fill(laneRect(index))
        }
    }

    private func laneRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: rulerHeight + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func drawLane(_ lane: AgentHourLane, index: Int, context: CGContext, now: Date) {
        let row = laneRect(index)
        let isChild = lane.parentID != nil
        let indent: CGFloat = isChild ? Theme.Spacing.m : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: (isChild ? Theme.Color.secondaryLabel : Theme.Color.label)
                .resolvedColor(with: traitCollection),
            .paragraphStyle: paragraph,
        ]
        let labelRect = CGRect(
            x: Theme.Spacing.xs + indent, y: row.midY - labelFont.lineHeight / 2,
            width: gutter - Theme.Spacing.xs - indent, height: labelFont.lineHeight)
        (lane.title as NSString).draw(in: labelRect, withAttributes: attributes)

        let barHeight: CGFloat = isChild ? 9 : 14
        for span in lane.spans {
            let from = x(span.start, now: now)
            let to = x(span.end, now: now)
            guard to - from > 0.5 else { continue }
            let bar = CGRect(x: from, y: row.midY - barHeight / 2, width: to - from, height: barHeight)
            drawBar(bar, phase: span.phase, context: context)
        }
        for mark in lane.marks {
            drawMark(mark, at: CGPoint(x: x(mark.at, now: now), y: row.midY))
        }
    }

    private func drawBar(_ bar: CGRect, phase: AgentHourPhase, context: CGContext) {
        let live = ActivityTone.live.color.resolvedColor(with: traitCollection)
        let radius = min(4, bar.height / 2)
        switch phase {
        case .working:
            context.setFillColor(live.cgColor)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: radius).cgPath)
            context.fillPath()
        case .needsYou:
            context.setFillColor(ActivityTone.attention.color.resolvedColor(with: traitCollection).cgColor)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: radius).cgPath)
            context.fillPath()
        case .background:
            context.setFillColor(live.withAlphaComponent(0.2).cgColor)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: radius).cgPath)
            context.fillPath()
            context.setStrokeColor(live.cgColor)
            context.setLineWidth(1.5)
            context.addPath(
                UIBezierPath(roundedRect: bar.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius).cgPath)
            context.strokePath()
        }
    }

    private func drawMark(_ mark: AgentHourMark, at point: CGPoint) {
        let icon = AgentGlyph.icon(for: mark.outcome)
        let key = icon.symbol + icon.tone.rawValue
        let image: UIImage
        if let kept = symbols[key] {
            image = kept
        } else {
            let configuration = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            let made =
                UIImage(systemName: icon.symbol, withConfiguration: configuration)?
                .withTintColor(
                    icon.tone.color.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                ?? UIImage()
            symbols[key] = made
            image = made
        }
        let size = image.size
        image.draw(
            in: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                height: size.height))
    }

    private func drawEmpty() {
        let text = String(localized: "No agents were seen in the last hour")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: Theme.Color.secondaryLabel.resolvedColor(with: traitCollection),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(
            x: max(Theme.Spacing.l, (bounds.width - size.width) / 2),
            y: rulerHeight + (rowHeight - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func legendLayout(width: CGFloat) -> (frames: [(Swatch, String, CGRect)], height: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let swatch: CGFloat = 16
        var frames: [(Swatch, String, CGRect)] = []
        var cursor = Theme.Spacing.l
        var top = Theme.Spacing.m
        let line = max(swatch, ceil(labelFont.lineHeight))
        for (kind, word) in legendItems {
            let textWidth = ceil((word as NSString).size(withAttributes: attributes).width)
            let itemWidth = swatch + Theme.Spacing.xs + textWidth
            if cursor + itemWidth > width - Theme.Spacing.l, cursor > Theme.Spacing.l {
                cursor = Theme.Spacing.l
                top += line + Theme.Spacing.s
            }
            frames.append((kind, word, CGRect(x: cursor, y: top, width: itemWidth, height: line)))
            cursor += itemWidth + Theme.Spacing.l
        }
        return (frames, top + line)
    }

    private func drawLegend(_ context: CGContext) {
        let layout = legendLayout(width: bounds.width)
        let ink = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: Theme.Color.secondaryLabel.resolvedColor(with: traitCollection),
        ]
        for (kind, word, frame) in layout.frames {
            let origin = CGPoint(x: frame.minX, y: lanesBottom + frame.minY)
            let swatch = CGRect(x: origin.x, y: origin.y + (frame.height - 8) / 2, width: 16, height: 8)
            switch kind {
            case .working: drawBar(swatch, phase: .working, context: context)
            case .waiting: drawBar(swatch, phase: .needsYou, context: context)
            case .background: drawBar(swatch, phase: .background, context: context)
            case .unseen: Self.hatch(context, in: swatch, ink: ink)
            }
            let textOrigin = CGPoint(
                x: origin.x + 16 + Theme.Spacing.xs,
                y: origin.y + (frame.height - labelFont.lineHeight) / 2)
            (word as NSString).draw(at: textOrigin, withAttributes: attributes)
        }
    }

    private func lane(at point: CGPoint) -> (AgentHourLane, CGRect)? {
        guard point.y >= rulerHeight else { return nil }
        let index = Int((point.y - rulerHeight) / rowHeight)
        guard lanes.indices.contains(index) else { return nil }
        return (lanes[index], laneRect(index))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let (lane, rect) = lane(at: gesture.location(in: self)) else { return }
        select(lane, rect: rect)
    }

    func select(_ lane: AgentHourLane, rect: CGRect) {
        Theme.Haptics.selection()
        selectedID = lane.id
        setNeedsDisplay()
        onSelect?(lane, rect)
    }

    func clearSelection() {
        guard selectedID != nil else { return }
        selectedID = nil
        setNeedsDisplay()
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        let ended = gesture.state == .ended || gesture.state == .cancelled
        let id = ended ? nil : lane(at: gesture.location(in: self))?.0.id
        guard id != hoveredID else { return }
        hoveredID = id
        setNeedsDisplay()
    }

    private func rebuildAccessibility() {
        let current = (accessibilityElements ?? []).compactMap { $0 as? AgentHourLaneElement }
        if current.count == lanes.count, zip(current, lanes).allSatisfy({ $0.laneID == $1.id }) {
            for (index, element) in current.enumerated() {
                element.accessibilityLabel = Self.spoken(lanes[index])
                element.accessibilityFrameInContainerSpace = laneRect(index)
            }
            return
        }
        accessibilityElements = lanes.enumerated().map { index, lane in
            let element = AgentHourLaneElement(accessibilityContainer: self)
            element.laneID = lane.id
            element.accessibilityLabel = Self.spoken(lane)
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = laneRect(index)
            element.onActivate = { [weak self] in
                guard let self, let found = self.lanes.firstIndex(where: { $0.id == lane.id }) else { return }
                self.select(self.lanes[found], rect: self.laneRect(found))
            }
            return element
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, element) in (accessibilityElements ?? []).enumerated() {
            (element as? AgentHourLaneElement)?.accessibilityFrameInContainerSpace = laneRect(index)
        }
    }

    private static func spoken(_ lane: AgentHourLane) -> String {
        var parts = [lane.title, lane.machine]
        func said(_ phase: AgentHourPhase) -> String? {
            let seconds = lane.spans.filter { $0.phase == phase }.reduce(0) {
                $0 + $1.end.timeIntervalSince($1.start)
            }
            return seconds >= 30 ? AgentsWords.spokenDuration(seconds) : nil
        }
        if let time = said(.working) {
            parts.append(String(localized: "Working for \(time) of the last hour"))
        }
        if let time = said(.needsYou) { parts.append(String(localized: "Waiting on you for \(time)")) }
        if let time = said(.background) {
            parts.append(String(localized: "In the background for \(time)"))
        }
        for mark in lane.marks { parts.append(AgentGlyph.spoken(for: mark.outcome)) }
        return parts.joined(separator: ". ")
    }
}

private final class AgentHourLaneElement: UIAccessibilityElement {
    var laneID = ""
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
