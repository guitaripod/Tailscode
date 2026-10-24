import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension AgentHourView {
    static func dashedBar(
        _ cr: OpaquePointer, x: Double, y: Double, width: Double, height: Double, ink: PartyInk
    ) {
        agentsRoundedRect(cr, x: x, y: y, width: width, height: height, radius: 3)
        ink.set(cr, alpha: 0.9)
        var dashes: [Double] = [3, 2]
        cairo_set_dash(cr, &dashes, 2, 0)
        cairo_set_line_width(cr, 1.4)
        cairo_stroke(cr)
        cairo_set_dash(cr, nil, 0, 0)
    }

    static func hatch(
        _ cr: OpaquePointer, x: Double, y: Double, width: Double, height: Double, inks: AgentsInks
    ) {
        cairo_save(cr)
        cairo_rectangle(cr, x, y, width, height)
        cairo_clip(cr)
        inks.quiet.set(cr, alpha: 0.12)
        cairo_rectangle(cr, x, y, width, height)
        cairo_fill(cr)
        inks.quiet.set(cr, alpha: 0.75)
        cairo_set_line_width(cr, 1)
        var stripe = x - height
        while stripe < x + width {
            cairo_move_to(cr, stripe, y + height)
            cairo_line_to(cr, stripe + height, y)
            stripe += 5
        }
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let now = Date()
        var geometry = layout
        geometry.width = width
        let inks = AgentsInks()
        paintRows(cr, geometry, inks, now: now)
        paintUnseen(cr, geometry, inks, now: now)
        paintGrid(cr, geometry, inks, now: now)
        paintBars(cr, geometry, inks, now: now)
        paintNow(cr, geometry, inks, now: now)
        paintLabels(cr, geometry, inks, now: now)
    }

    func paintRows(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        for (index, lane) in geometry.lanes.enumerated() {
            let top = geometry.top(ofLane: index)
            let rowHeight = geometry.height(of: lane)
            let waiting = lane.spans.last.map { $0.phase == .needsYou && now.timeIntervalSince($0.end) < 3 } ?? false
            if waiting {
                inks.attention.set(cr, alpha: 0.08)
                cairo_rectangle(cr, 0, top, geometry.width, rowHeight)
                cairo_fill(cr)
            }
            if index == hovered || lane.id == selectedID {
                (lane.id == selectedID ? inks.live : inks.text).set(cr, alpha: lane.id == selectedID ? 0.12 : 0.06)
                cairo_rectangle(cr, 0, top, geometry.width, rowHeight)
                cairo_fill(cr)
            }
            if lane.id == selectedID {
                inks.live.set(cr)
                cairo_rectangle(cr, 0, top, 3, rowHeight)
                cairo_fill(cr)
            }
            if lane.parentID == nil, index > 0 {
                inks.rule.set(cr, alpha: 0.8)
                cairo_rectangle(cr, 0, top - 0.5, geometry.width, 1)
                cairo_fill(cr)
            }
        }
    }

    func paintUnseen(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        guard let hour else { return }
        let bottom = max(geometry.contentHeight, geometry.rulerHeight + 4)
        for gap in hour.unseen {
            let left = max(geometry.x(of: gap.start, now: now), geometry.trackLeft)
            let right = min(geometry.x(of: gap.end, now: now), geometry.trackRight)
            guard right - left > 1 else { continue }
            Self.hatch(cr, x: left, y: 0, width: right - left, height: bottom, inks: inks)
        }
    }

    func paintGrid(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        let bottom = max(geometry.contentHeight, geometry.rulerHeight + 4)
        for minutes in AgentHourLayout.tickMinutes {
            let x = geometry.x(of: now.addingTimeInterval(-Double(minutes) * 60), now: now)
            inks.rule.set(cr, alpha: 0.9)
            cairo_rectangle(cr, x - 0.5, geometry.rulerHeight - 6, 1, bottom - geometry.rulerHeight + 6)
            cairo_fill(cr)
            let words = minutes == 0 ? Localized.text("now") : Localized.text("%dm", minutes)
            let size = AgentsText.size(canvas.widget, words, style: .init(scale: 0.8))
            let left =
                minutes == 0
                ? x - size.width - 6
                : minutes == 60 ? x + 4 : x - size.width / 2
            agentsRoundedRect(
                cr, x: left - 3, y: 2, width: size.width + 6, height: size.height + 2, radius: 4)
            inks.canvas.set(cr, alpha: 0.82)
            cairo_fill(cr)
            AgentsText.draw(
                cr, canvas.widget, words, x: left, y: 3, ink: minutes == 0 ? inks.live : inks.quiet,
                style: .init(scale: 0.8))
        }
    }

    func paintBars(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        for (index, lane) in geometry.lanes.enumerated() {
            let top = geometry.top(ofLane: index)
            let rowHeight = geometry.height(of: lane)
            let barHeight = lane.parentID == nil ? 11.0 : 8.0
            let y = top + rowHeight / 2 - barHeight / 2
            for span in lane.spans {
                let left = max(geometry.x(of: span.start, now: now), geometry.trackLeft)
                let right = min(geometry.x(of: span.end, now: now), geometry.trackRight)
                guard right > left else { continue }
                let barWidth = max(right - left, 3)
                switch span.phase {
                case .working:
                    agentsRoundedRect(cr, x: left, y: y, width: barWidth, height: barHeight, radius: 3)
                    inks.live.set(cr, alpha: 0.92)
                    cairo_fill(cr)
                case .needsYou:
                    agentsRoundedRect(cr, x: left, y: y - 1, width: barWidth, height: barHeight + 2, radius: 3)
                    inks.attention.set(cr)
                    cairo_fill(cr)
                case .background:
                    Self.dashedBar(cr, x: left + 0.5, y: y + 0.5, width: barWidth - 1, height: barHeight - 1, ink: inks.live)
                }
            }
            for mark in lane.marks {
                let x = geometry.x(of: mark.at, now: now)
                guard x >= geometry.trackLeft - 2, x <= geometry.trackRight + 2 else { continue }
                paintMark(cr, mark, x: x + 9, y: top + rowHeight / 2, inks: inks)
            }
        }
    }

    func paintMark(_ cr: OpaquePointer, _ mark: AgentHourMark, x: Double, y: Double, inks: AgentsInks) {
        let face = AgentsParts.finishGlyph(mark.outcome)
        let ink = inks.ink(face.tone)
        cairo_new_path(cr)
        cairo_arc(cr, x, y, 6.5, 0, 2 * .pi)
        inks.canvas.set(cr, alpha: 0.85)
        cairo_fill_preserve(cr)
        ink.set(cr)
        cairo_set_line_width(cr, 1.3)
        cairo_stroke(cr)
        cairo_set_line_width(cr, 1.5)
        switch mark.outcome {
        case .done:
            cairo_move_to(cr, x - 2.6, y + 0.2)
            cairo_line_to(cr, x - 0.7, y + 2.3)
            cairo_line_to(cr, x + 3, y - 2.2)
        case .failed:
            cairo_move_to(cr, x - 2.4, y - 2.4)
            cairo_line_to(cr, x + 2.4, y + 2.4)
            cairo_move_to(cr, x + 2.4, y - 2.4)
            cairo_line_to(cr, x - 2.4, y + 2.4)
        case .stopped:
            cairo_rectangle(cr, x - 2.2, y - 2.2, 4.4, 4.4)
        case .unknown:
            cairo_move_to(cr, x - 2.4, y)
            cairo_line_to(cr, x + 2.4, y)
        }
        cairo_stroke(cr)
    }

    func paintNow(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        let x = geometry.trackRight
        let bottom = max(geometry.contentHeight, geometry.rulerHeight + 4)
        inks.live.set(cr, alpha: 0.28)
        cairo_rectangle(cr, x - 3, 0, 6, bottom)
        cairo_fill(cr)
        inks.live.set(cr)
        cairo_rectangle(cr, x - 1, 0, 2, bottom)
        cairo_fill(cr)
    }

    func paintLabels(_ cr: OpaquePointer, _ geometry: AgentHourLayout, _ inks: AgentsInks, now: Date) {
        for (index, lane) in geometry.lanes.enumerated() {
            let top = geometry.top(ofLane: index)
            let rowHeight = geometry.height(of: lane)
            let indent = lane.parentID == nil ? 14.0 : 30.0
            let room = geometry.labelWidth - indent
            let titleStyle = AgentsText.Style(
                scale: lane.parentID == nil ? 1 : 0.92, bold: lane.parentID == nil, lines: lane.parentID == nil ? 2 : 1,
                width: room)
            let subtitle = AgentHourWords.subtitle(lane, now: now)
            let subStyle = AgentsText.Style(scale: 0.86, width: room)
            let titleHeight = AgentsText.size(canvas.widget, lane.title, style: titleStyle).height
            let subHeight = AgentsText.size(canvas.widget, subtitle, style: subStyle).height
            let y = top + max(3, (rowHeight - titleHeight - subHeight - 1) / 2)
            AgentsText.draw(cr, canvas.widget, lane.title, x: indent, y: y, ink: inks.text, style: titleStyle)
            let waiting = lane.spans.last.map { $0.phase == .needsYou && now.timeIntervalSince($0.end) < 3 } ?? false
            AgentsText.draw(
                cr, canvas.widget, subtitle, x: indent, y: y + titleHeight + 1,
                ink: waiting ? inks.attention : inks.quiet, style: subStyle)
        }
    }
}
