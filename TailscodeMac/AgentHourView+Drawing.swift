import AppKit
import CodingAgentKit
import TailscodeCore

extension AgentHourView {
    private static let barHeight: CGFloat = 14
    private static let childBarHeight: CGFloat = 10

    func paint(_ dirty: NSRect) {
        guard let hour, let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = geometry
        let now = self.now
        paintGrid(geometry, now: now, height: bounds.height, in: context)
        paintUnseen(hour.unseen, geometry: geometry, now: now, height: bounds.height, in: context)
        var y: CGFloat = 0
        for (index, lane) in hour.lanes.enumerated() {
            let height = lane.parentID == nil ? AgentHourGeometry.topLane : AgentHourGeometry.childLane
            let row = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            guard row.intersects(dirty) else { continue }
            paintLane(lane, index: index, row: row, geometry: geometry, now: now, hourEnd: hour.end)
        }
        let line = geometry.x(now, now: now)
        MacTheme.Color.success.setFill()
        NSRect(x: line - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    private func paintGrid(_ geometry: AgentHourGeometry, now: Date, height: CGFloat, in context: CGContext) {
        context.setFillColor(MacTheme.Color.label.withAlphaComponent(0.1).cgColor)
        for step in 1..<6 {
            let x = geometry.x(now.addingTimeInterval(-Double(step) * 600), now: now)
            context.fill(CGRect(x: x - 0.5, y: 0, width: 1, height: height))
        }
    }

    private func paintUnseen(
        _ gaps: [DateInterval], geometry: AgentHourGeometry, now: Date, height: CGFloat, in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(MacTheme.Color.secondaryLabel.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(1)
        for gap in gaps {
            let left = geometry.x(gap.start, now: now)
            let right = geometry.x(gap.end, now: now)
            guard right - left >= 1 else { continue }
            let rect = CGRect(x: left, y: 0, width: right - left, height: height)
            context.saveGState()
            context.clip(to: rect)
            var offset = -height
            while offset < rect.width {
                context.move(to: CGPoint(x: rect.minX + offset, y: height))
                context.addLine(to: CGPoint(x: rect.minX + offset + height, y: 0))
                offset += 7
            }
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func paintLane(
        _ lane: AgentHourLane, index: Int, row: NSRect, geometry: AgentHourGeometry, now: Date,
        hourEnd: Date
    ) {
        let isChild = lane.parentID != nil
        let key = Self.key(of: lane)
        let waiting = laneState(lane) != nil
        if key == selectedKey {
            MacTheme.Color.accent.withAlphaComponent(0.16).setFill()
            row.fill()
        } else if waiting {
            MacTheme.Color.warning.withAlphaComponent(0.08).setFill()
            row.fill()
        } else if index == hovered {
            MacTheme.Color.label.withAlphaComponent(0.05).setFill()
            row.fill()
        }
        if !isChild, index > 0 {
            MacTheme.Color.label.withAlphaComponent(0.1).setFill()
            NSRect(x: MacTheme.Spacing.m, y: row.minY, width: bounds.width - 2 * MacTheme.Spacing.m, height: 1).fill()
        }
        paintLabel(lane, row: row, geometry: geometry, isChild: isChild, waiting: waiting)
        let height = isChild ? Self.childBarHeight : Self.barHeight
        let bar = NSRect(x: 0, y: row.midY - height / 2, width: 0, height: height)
        for span in lane.spans {
            let open = abs(span.end.timeIntervalSince(hourEnd)) < 2
            let right = geometry.x(open ? now : span.end, now: now)
            let left = geometry.x(span.start, now: now)
            var rect = bar
            rect.origin.x = left
            rect.size.width = max(3, right - left)
            paintSpan(span.phase, in: rect)
        }
        for mark in lane.marks {
            let x = geometry.x(mark.at, now: now)
            paintMark(mark.outcome, at: NSPoint(x: min(x + 11, geometry.chartRight - 8), y: row.midY))
        }
    }

    private func paintSpan(_ phase: AgentHourPhase, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        switch phase {
        case .working:
            MacTheme.Color.success.setFill()
            path.fill()
        case .needsYou:
            MacTheme.Color.warning.setFill()
            path.fill()
        case .background:
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1
            outline.setLineDash([3, 2], count: 2, phase: 0)
            MacTheme.Color.secondaryLabel.setStroke()
            outline.stroke()
        }
    }

    private func paintMark(_ outcome: AgentFinish.Outcome, at center: NSPoint) {
        let radius: CGFloat = 6
        let circle = NSBezierPath(
            ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        circle.lineWidth = 1.2
        let tint: NSColor = outcome == .failed ? MacTheme.Color.danger : MacTheme.Color.secondaryLabel
        tint.setStroke()
        circle.stroke()
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.4
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        switch outcome {
        case .done:
            glyph.move(to: NSPoint(x: center.x - 2.6, y: center.y))
            glyph.line(to: NSPoint(x: center.x - 0.6, y: center.y + 2.2))
            glyph.line(to: NSPoint(x: center.x + 2.8, y: center.y - 2.4))
        case .failed:
            glyph.move(to: NSPoint(x: center.x - 2.4, y: center.y - 2.4))
            glyph.line(to: NSPoint(x: center.x + 2.4, y: center.y + 2.4))
            glyph.move(to: NSPoint(x: center.x + 2.4, y: center.y - 2.4))
            glyph.line(to: NSPoint(x: center.x - 2.4, y: center.y + 2.4))
        case .stopped:
            glyph.appendRect(NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        case .unknown:
            glyph.move(to: NSPoint(x: center.x - 2, y: center.y))
            glyph.line(to: NSPoint(x: center.x + 2, y: center.y))
        }
        glyph.stroke()
    }

    private func paintLabel(
        _ lane: AgentHourLane, row: NSRect, geometry: AgentHourGeometry, isChild: Bool, waiting: Bool
    ) {
        let indent: CGFloat = isChild ? MacTheme.Spacing.xl : 0
        let left = MacTheme.Spacing.l + indent
        let width = geometry.labelWidth - left
        let title = NSMutableParagraphStyle()
        title.lineBreakMode = .byTruncatingTail
        let titleFont = isChild ? MacTheme.Ramp.font(.rowDetail) : MacTheme.Ramp.font(.rowTitleStrong)
        var suffix = ""
        if isChild, lane.spans.last?.phase == .background { suffix = " · " + Localized.text("background") }
        let primary = NSAttributedString(
            string: lane.title + suffix,
            attributes: [
                .font: titleFont, .foregroundColor: MacTheme.Color.label, .paragraphStyle: title,
            ])
        let lineHeight = ceil(titleFont.boundingRectForFont.height)
        let titleHeight = isChild ? lineHeight : lineHeight * 2
        let top = isChild ? row.midY - lineHeight / 2 : row.minY + 6
        primary.draw(
            with: NSRect(x: left, y: top, width: width, height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard !isChild else { return }
        var meta = lane.machine
        var tint = MacTheme.Color.tertiaryLabel
        if waiting {
            meta += " · " + Localized.text("needs you")
            tint = MacTheme.Color.warning
        }
        let sub = NSAttributedString(
            string: meta,
            attributes: [.font: MacTheme.Ramp.font(.rowMeta), .foregroundColor: tint, .paragraphStyle: title])
        sub.draw(
            with: NSRect(x: left, y: row.maxY - 6 - ceil(MacTheme.Ramp.font(.rowMeta).boundingRectForFont.height), width: width, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
