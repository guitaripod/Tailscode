import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What one frame of the nodes layer draws: everything Core decided about the nodes, wires and
/// card at one instant, and how the head is zoomed. A painter decides only how a shape is stroked.
struct BrainScene {
    var draws: [NeuralNodeDraw] = []
    var wires: NeuralWires?
    var time = 0.0
    var reduceMotion = false
    var hasSelection = false
    var usedZones: Set<NeuralZone> = []
    var card: NeuralReading.Card?
    var cardNode: String?
    var zoom = 1.0
    var zoomCenter = NeuralPoint(320, 210)
    var orbit = false
    var crowded = false
    var hotZone: NeuralZone?
    var focused = false
}

enum BrainPainter {
    static let mono = "Monospace"
    static let sans = "Sans"

    /// The wires and nodes, drawn between the interior and the front so they sit inside the glass.
    static func paint(
        _ cr: OpaquePointer, width: Int32, height: Int32, scene: BrainScene, inks: BrainInks
    ) {
        let scale = Double(width) / NeuralDesign.width
        cairo_save(cr)
        cairo_translate(cr, scene.zoomCenter.x * scale, scene.zoomCenter.y * scale)
        cairo_scale(cr, scene.zoom, scene.zoom)
        cairo_translate(cr, -scene.zoomCenter.x * scale, -scene.zoomCenter.y * scale)
        cairo_scale(cr, scale, scale)
        zoneLabels(cr, scene: scene, inks: inks, scale: scale)
        ties(cr, scene: scene, inks: inks)
        wires(cr, scene: scene, inks: inks)
        for node in scene.draws { self.node(cr, node, scene: scene, inks: inks) }
        if scene.orbit { satellite(cr, scene: scene, inks: inks) }
        cairo_restore(cr)
    }

    /// The card of the node being pointed at, drawn over the front so the chassis never cuts it.
    static func paintCard(
        _ cr: OpaquePointer, width: Int32, height: Int32, scene: BrainScene, inks: BrainInks
    ) {
        guard let card = scene.card, let id = scene.cardNode,
            let node = scene.draws.first(where: { $0.id == id })
        else { return }
        let scale = Double(width) / NeuralDesign.width
        let anchor = screen(node.point, scene: scene, scale: scale)
        _ = Self.card(
            cr, card: card, anchor: anchor, reach: node.radius * scale * scene.zoom,
            bounds: (Double(width), Double(height)), inks: inks,
            others: scene.draws.filter { $0.id != id }.map {
                screen($0.point, scene: scene, scale: scale)
            })
    }

    static func screen(_ point: NeuralPoint, scene: BrainScene, scale: Double) -> NeuralPoint {
        NeuralPoint(
            (scene.zoomCenter.x + (point.x - scene.zoomCenter.x) * scene.zoom) * scale,
            (scene.zoomCenter.y + (point.y - scene.zoomCenter.y) * scene.zoom) * scale)
    }

    static func zoneLabelRect(_ zone: NeuralZone) -> (x: Double, y: Double, width: Double, height: Double) {
        let well = zone.well
        let width = Double(zone.label.count) * 8.2 + 8
        return (zone.center.x - width / 2, zone.center.y - well.ry - 8 - 11, width, 14)
    }

    private static func zoneLabels(
        _ cr: OpaquePointer, scene: BrainScene, inks: BrainInks, scale: Double
    ) {
        let size = max(8.5, 9 * scale) / scale
        for zone in NeuralZone.allCases {
            let on = scene.usedZones.contains(zone)
            let color = on ? inks.zone(zone) : inks.domeDim
            let alpha = on ? (scene.hotZone == nil || scene.hotZone == zone ? 1.0 : 0.4) : 0.55
            let rect = zoneLabelRect(zone)
            var spaced = ""
            for character in zone.label { spaced += "\(character)\u{200A}" }
            var measured = 0.0
            var height = 0.0
            tailscode_text_measure(spaced, "\(mono) Bold \(size)px", 0, 1, &measured, &height)
            _ = tailscode_text_draw(
                cr, spaced, "\(mono) Bold \(size)px", zone.center.x - measured / 2, rect.y, 0, 0, 1,
                color.red, color.green, color.blue, alpha)
        }
    }

    private static func setColor(_ cr: OpaquePointer, _ color: BrainInks.RGB, _ alpha: Double) {
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }

    private static func dash(_ cr: OpaquePointer, _ pattern: [Double]) {
        if pattern.isEmpty {
            cairo_set_dash(cr, nil, 0, 0)
        } else {
            pattern.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32(pattern.count), 0) }
        }
    }

    private static func wires(_ cr: OpaquePointer, scene: BrainScene, inks: BrainInks) {
        let crowded = scene.crowded
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        for wire in scene.wires?.routes ?? [] {
            guard wire.points.count >= 2 else { continue }
            let faded = (scene.hasSelection && !wire.hot) || wire.dimmed
            let fade = faded ? 0.1 : 1.0
            let tone = inks.zone(wire.zone)
            path(cr, wire.points)
            cairo_set_line_width(cr, wire.hot ? 2.4 : 1.2)
            setColor(cr, inks.domeDim, (crowded ? 0.16 : 0.28) * fade)
            cairo_stroke(cr)
            let lit = Double(wire.lit)
            guard lit > 0 else { continue }
            if lit >= 1 {
                path(cr, wire.points)
                cairo_set_line_width(cr, wire.hot ? 2.4 : 1.2)
                setColor(cr, tone, wire.hot ? 1 : (crowded ? 0.22 : 0.36) * fade)
                cairo_stroke(cr)
            } else {
                partial(cr, wire.points, from: 0, to: lit)
                cairo_set_line_width(cr, 1.2)
                setColor(cr, tone, 0.36 * fade)
                cairo_stroke(cr)
                partial(cr, wire.points, from: max(0, lit - 0.22), to: lit)
                cairo_set_line_width(cr, 3.2)
                setColor(cr, tone, 0.95 * fade)
                cairo_stroke(cr)
            }
        }
        for via in scene.wires?.vias ?? [] {
            let fade = (scene.hasSelection && !via.hot) || via.dimmed ? 0.1 : 1.0
            cairo_new_path(cr)
            cairo_arc(cr, via.point.x, via.point.y, 3.4, 0, 2 * .pi)
            if via.lit > 0 {
                setColor(cr, inks.zone(via.zone), (via.hot ? 1 : 0.85) * fade)
            } else {
                setColor(cr, inks.domeDim, 0.4 * fade)
            }
            cairo_fill(cr)
        }
    }

    private static func path(_ cr: OpaquePointer, _ points: [NeuralPoint]) {
        cairo_new_path(cr)
        guard let first = points.first else { return }
        cairo_move_to(cr, first.x, first.y)
        for point in points.dropFirst() { cairo_line_to(cr, point.x, point.y) }
    }

    /// The stretch of a polyline between two fractions of its length.
    private static func partial(
        _ cr: OpaquePointer, _ points: [NeuralPoint], from start: Double, to end: Double
    ) {
        cairo_new_path(cr)
        var length = 0.0
        for index in 1..<points.count {
            length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        guard length > 0 else { return }
        let from = start * length
        let to = end * length
        var walked = 0.0
        var started = false
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let segment = hypot(b.x - a.x, b.y - a.y)
            let next = walked + segment
            if next >= from, walked <= to, segment > 0 {
                let lo = max(from, walked)
                let hi = min(to, next)
                let p = NeuralPoint(
                    a.x + (b.x - a.x) * (lo - walked) / segment,
                    a.y + (b.y - a.y) * (lo - walked) / segment)
                let q = NeuralPoint(
                    a.x + (b.x - a.x) * (hi - walked) / segment,
                    a.y + (b.y - a.y) * (hi - walked) / segment)
                if !started {
                    cairo_move_to(cr, p.x, p.y)
                    started = true
                }
                cairo_line_to(cr, q.x, q.y)
            }
            walked = next
        }
    }

    private static func ties(_ cr: OpaquePointer, scene: BrainScene, inks: BrainInks) {
        for tie in scene.wires?.ties ?? [] where tie.lit > 0 {
            let faded = (scene.hasSelection && !tie.hot) || tie.dimmed && !tie.hot
            let alpha = (tie.hot ? 1.0 : 0.55) * (faded ? 0.15 : 1) * Double(tie.lit)
            dash(cr, [3, 4])
            cairo_set_line_width(cr, tie.hot ? 1.8 : 1.3)
            for arc in tie.arcs {
                cairo_new_path(cr)
                cairo_move_to(cr, arc.from.x, arc.from.y)
                cairo_curve_to(
                    cr, arc.from.x + 2.0 / 3 * (arc.control.x - arc.from.x),
                    arc.from.y + 2.0 / 3 * (arc.control.y - arc.from.y),
                    arc.to.x + 2.0 / 3 * (arc.control.x - arc.to.x),
                    arc.to.y + 2.0 / 3 * (arc.control.y - arc.to.y), arc.to.x, arc.to.y)
                setColor(cr, inks.domeSpecial, alpha)
                cairo_stroke(cr)
            }
            dash(cr, [])
            if let last = tie.arcs.last, !tie.label.isEmpty, tie.hot || !faded {
                label(
                    cr, tie.label, at: NeuralPoint(last.to.x + 9, last.to.y - 11), inks: inks,
                    alpha: tie.hot ? 1 : 0.7 * Double(tie.lit))
            }
        }
    }

    private static func label(
        _ cr: OpaquePointer, _ text: String, at point: NeuralPoint, inks: BrainInks, alpha: Double
    ) {
        for (dx, dy) in [(-1.2, 0.0), (1.2, 0), (0, -1.2), (0, 1.2)] {
            _ = tailscode_text_draw(
                cr, text, "\(mono) 9px", point.x + dx, point.y + dy, 0, 0, 1, inks.panel.red,
                inks.panel.green, inks.panel.blue, alpha * 0.9)
        }
        _ = tailscode_text_draw(
            cr, text, "\(mono) 9px", point.x, point.y, 0, 0, 1, inks.domeSpecial.red, inks.domeSpecial.green,
            inks.domeSpecial.blue, alpha)
    }

    private static func satellite(_ cr: OpaquePointer, scene: BrainScene, inks: BrainInks) {
        let angle = scene.reduceMotion ? 0 : scene.time * 2 * .pi / 6
        let x = 320 + 262 * cos(angle)
        let y = 186 + 168 * sin(angle)
        let glow = cairo_pattern_create_radial(x, y, 0, x, y, 12)
        cairo_pattern_add_color_stop_rgba(glow, 0, inks.live.red, inks.live.green, inks.live.blue, 0.6)
        cairo_pattern_add_color_stop_rgba(glow, 1, inks.live.red, inks.live.green, inks.live.blue, 0)
        cairo_set_source(cr, glow)
        cairo_new_path(cr)
        cairo_arc(cr, x, y, 12, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_pattern_destroy(glow)
        setColor(cr, inks.live, 1)
        cairo_new_path(cr)
        cairo_arc(cr, x, y, 5, 0, 2 * .pi)
        cairo_fill(cr)
    }

    static func shape(_ cr: OpaquePointer, _ shape: NeuralShape, radius r: Double) {
        cairo_new_path(cr)
        switch shape {
        case .circle:
            cairo_arc(cr, 0, 0, r, 0, 2 * .pi)
        case .diamond:
            let k = r * 1.2
            cairo_move_to(cr, 0, -k)
            cairo_line_to(cr, k, 0)
            cairo_line_to(cr, 0, k)
            cairo_line_to(cr, -k, 0)
            cairo_close_path(cr)
        case .chip:
            let k = r * 0.9
            let c = r * 0.42
            cairo_move_to(cr, -k, -k)
            cairo_line_to(cr, k - c, -k)
            cairo_line_to(cr, k, -k + c)
            cairo_line_to(cr, k, k)
            cairo_line_to(cr, -k + c, k)
            cairo_line_to(cr, -k, k - c)
            cairo_close_path(cr)
        case .hexagon:
            let k = r * 1.12
            for index in 0..<6 {
                let angle = Double.pi / 3 * Double(index)
                if index == 0 {
                    cairo_move_to(cr, cos(angle) * k, sin(angle) * k)
                } else {
                    cairo_line_to(cr, cos(angle) * k, sin(angle) * k)
                }
            }
            cairo_close_path(cr)
        case .octagon:
            let k = r * 1.12
            for index in 0..<8 {
                let angle = Double.pi / 4 * Double(index) + Double.pi / 8
                if index == 0 {
                    cairo_move_to(cr, cos(angle) * k, sin(angle) * k)
                } else {
                    cairo_line_to(cr, cos(angle) * k, sin(angle) * k)
                }
            }
            cairo_close_path(cr)
        case .bubble:
            let w = r * 1.3
            let h = r * 0.95
            let c = r * 0.5
            cairo_move_to(cr, -w + c, -h)
            cairo_line_to(cr, w - c, -h)
            quadratic(cr, from: (w - c, -h), control: (w, -h), to: (w, -h + c))
            cairo_line_to(cr, w, h - c)
            quadratic(cr, from: (w, h - c), control: (w, h), to: (w - c, h))
            cairo_line_to(cr, -w * 0.15, h)
            cairo_line_to(cr, -w * 0.55, h + r * 0.65)
            cairo_line_to(cr, -w * 0.5, h)
            cairo_line_to(cr, -w + c, h)
            quadratic(cr, from: (-w + c, h), control: (-w, h), to: (-w, h - c))
            cairo_line_to(cr, -w, -h + c)
            quadratic(cr, from: (-w, -h + c), control: (-w, -h), to: (-w + c, -h))
            cairo_close_path(cr)
        }
    }

    private static func quadratic(
        _ cr: OpaquePointer, from a: (Double, Double), control c: (Double, Double),
        to b: (Double, Double)
    ) {
        cairo_curve_to(
            cr, a.0 + 2.0 / 3 * (c.0 - a.0), a.1 + 2.0 / 3 * (c.1 - a.1),
            b.0 + 2.0 / 3 * (c.0 - b.0), b.1 + 2.0 / 3 * (c.1 - b.1), b.0, b.1)
    }

    private static func node(
        _ cr: OpaquePointer, _ node: NeuralNodeDraw, scene: BrainScene, inks: BrainInks
    ) {
        let color = inks.color(of: node.tone, zone: node.zone)
        let moving = node.motion.level(at: scene.time, reduceMotion: scene.reduceMotion)
        let floor: Double
        switch node.motion {
        case .breath: floor = 0.34
        case .heartbeat: floor = 0.42
        default: floor = 1
        }
        let swing = floor < 1 ? (moving - floor) / (1 - floor) : 1
        let pulseScale: Double
        switch node.motion {
        case .breath: pulseScale = 0.94 + 0.14 * swing
        case .heartbeat: pulseScale = 0.96 + 0.16 * swing
        default: pulseScale = 1
        }
        var alpha = floor < 1 ? moving : 1.0
        let lit = Double(node.lit)
        let unfired = lit < 1
        let dimmed = node.dimmed || unfired
        if scene.hasSelection && !node.hot { alpha *= 0.42 }
        alpha *= unfired ? 0.18 + 0.82 * lit : 1
        let radius = node.radius
        cairo_save(cr)
        cairo_translate(cr, node.point.x, node.point.y)
        if node.hot || node.pinned || node.flash > 0 {
            let reach = radius * 2.6
            let glow = cairo_pattern_create_radial(0, 0, radius * 0.4, 0, 0, reach)
            let strength = node.pinned ? 0.55 : (node.hot ? 0.45 : 0.3 * Double(node.flash))
            cairo_pattern_add_color_stop_rgba(glow, 0, color.red, color.green, color.blue, strength)
            cairo_pattern_add_color_stop_rgba(glow, 1, color.red, color.green, color.blue, 0)
            cairo_set_source(cr, glow)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, reach, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(glow)
        } else if !dimmed && !scene.crowded {
            let glow = cairo_pattern_create_radial(0, 0, radius * 0.6, 0, 0, radius * 2)
            cairo_pattern_add_color_stop_rgba(glow, 0, color.red, color.green, color.blue, 0.22 * alpha)
            cairo_pattern_add_color_stop_rgba(glow, 1, color.red, color.green, color.blue, 0)
            cairo_set_source(cr, glow)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, radius * 2, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(glow)
        }
        cairo_scale(cr, pulseScale, pulseScale)
        if node.zone == .think && node.ganglionCount == nil {
            dash(cr, [2, 3])
            cairo_set_line_width(cr, 1)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, radius + 4, 0, 2 * .pi)
            setColor(cr, color, (dimmed ? 0.25 : 0.7) * alpha)
            cairo_stroke(cr)
            dash(cr, [])
        }
        let drawn = node.ganglionCount == nil ? node.shape : .circle
        shape(cr, drawn, radius: radius)
        let fillBase = dimmed ? inks.panel : BrainInks.mix(inks.panel, color, 0.17)
        setColor(cr, fillBase, 0.96 * (scene.hasSelection && !node.hot ? 0.6 : 1))
        cairo_fill_preserve(cr)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        let outline = dimmed ? BrainInks.mix(inks.domeDim, inks.panel, 0.4) : color
        setColor(cr, outline, alpha)
        cairo_set_line_width(cr, node.ganglionCount != nil ? 2 : (node.hot || node.pinned ? 2.4 : 1.7))
        switch node.status {
        case .stopped: dash(cr, [3, 3])
        case .stalled: dash(cr, [5, 3])
        default: dash(cr, node.ganglionCount != nil ? [4, 3] : [])
        }
        cairo_stroke(cr)
        dash(cr, [])
        if node.zone == .delegate && node.ganglionCount == nil {
            dash(cr, [2, 2])
            cairo_set_line_width(cr, 1)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, radius * 0.84, 0, 2 * .pi)
            setColor(cr, color, (dimmed ? 0.25 : 0.8) * alpha)
            cairo_stroke(cr)
            dash(cr, [])
        }
        let numberColor = dimmed ? inks.domeDim : color
        let size = node.ganglionCount != nil ? 12.0 : 9.0
        _ = tailscode_text_draw(
            cr, node.label, "\(mono) Bold \(size)px", -radius * 1.2, -size * 0.62, radius * 2.4, 1, 1,
            numberColor.red, numberColor.green, numberColor.blue, alpha)
        if node.status == .failed {
            cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
            cairo_set_line_width(cr, 2)
            setColor(cr, inks.danger, node.isRecovered ? alpha * 0.6 : alpha)
            cairo_new_path(cr)
            cairo_move_to(cr, radius * 0.55, -radius * 1.15)
            cairo_rel_line_to(cr, radius * 0.7, -radius * 0.7)
            cairo_move_to(cr, radius * 1.25, -radius * 1.15)
            cairo_rel_line_to(cr, -radius * 0.7, -radius * 0.7)
            cairo_stroke(cr)
        }
        if node.pinned {
            cairo_set_line_width(cr, 1.2)
            setColor(cr, inks.domeAccent, 0.9)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, radius * 1.45 + 3, 0, 2 * .pi)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    static let cardWidth = 300.0

    private static func card(
        _ cr: OpaquePointer, card: NeuralReading.Card, anchor: NeuralPoint, reach: Double,
        bounds: (Double, Double), inks: BrainInks, others: [NeuralPoint]
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let width = min(cardWidth, bounds.0 - 12)
        let pad = 11.0
        let inner = width - pad * 2
        let color = inks.zone(card.zone)
        var content = pad
        var heights: [(kind: Int, height: Double)] = []
        func measure(_ text: String, _ font: String, lines: Int, available: Double) -> Double {
            var w = 0.0
            var h = 0.0
            tailscode_text_measure(text, font, available, Int32(lines), &w, &h)
            return h
        }
        let headerHeight = 22.0
        content += headerHeight + 6
        heights.append((0, headerHeight))
        let thought = card.zone == .think || card.zone == .say
        let bodyFont = "\(sans) 11px"
        let bodyHeight =
            card.body.isEmpty ? 0 : measure(card.body, bodyFont, lines: thought ? 4 : 3, available: inner)
        if bodyHeight > 0 { content += bodyHeight + 4 }
        if card.tally != nil { content += 16 }
        var outputHeight = 0.0
        if !card.output.isEmpty {
            outputHeight = measure(
                card.output.joined(separator: "\n"), "\(mono) 10px", lines: 4, available: inner - 10)
            content += outputHeight + 8
        }
        let footerHeight = measure(card.footer, "\(sans) 10px", lines: 3, available: inner)
        content += footerHeight + 17
        let height = content
        let gap = reach + 10
        let candidates: [(Double, Double)] = [
            (anchor.x + gap, anchor.y - 20), (anchor.x - gap - width, anchor.y - 20),
            (anchor.x - width / 2, anchor.y + gap), (anchor.x - width / 2, anchor.y - gap - height),
        ]
        var best = candidates[0]
        var bestScore = Int.max
        for candidate in candidates {
            let x = min(max(6, candidate.0), max(6, bounds.0 - width - 6))
            let y = min(max(6, candidate.1), max(6, bounds.1 - height - 6))
            let covers = others.filter {
                $0.x > x - 8 && $0.x < x + width + 8 && $0.y > y - 8 && $0.y < y + height + 8
            }.count
            let coversAnchor =
                anchor.x > x - 4 && anchor.x < x + width + 4 && anchor.y > y - 4
                && anchor.y < y + height + 4
            let score = covers * 10 + (coversAnchor ? 1000 : 0)
            if score < bestScore {
                bestScore = score
                best = (x, y)
            }
        }
        let x = best.0
        let y = best.1
        cairo_save(cr)
        round(cr, x + 1, y + 3, width, height, 9)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.35)
        cairo_fill(cr)
        round(cr, x, y, width, height, 9)
        setColor(cr, inks.isDark ? BrainInks.mix(inks.card, inks.panel, 0.35) : inks.panel, 0.98)
        cairo_fill_preserve(cr)
        setColor(cr, inks.isDark ? inks.rule : inks.domeDim, 0.55)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        var top = y + pad
        cairo_save(cr)
        cairo_translate(cr, x + pad + 10, top + 11)
        shape(cr, shapeOf(card.zone), radius: 7)
        setColor(cr, BrainInks.mix(inks.panel, color, 0.2), 1)
        cairo_fill_preserve(cr)
        setColor(cr, color, 1)
        cairo_set_line_width(cr, 1.4)
        cairo_stroke(cr)
        cairo_restore(cr)
        let titleColor = inks.domeInk
        _ = tailscode_text_draw(
            cr, card.title, "\(sans) Bold 12px", x + pad + 26, top + 3, inner - 120, 0, 1,
            titleColor.0, titleColor.1, titleColor.2, 1)
        let statusColor = statusInk(card.status, inks: inks)
        var pillWidth = 0.0
        var pillHeight = 0.0
        tailscode_text_measure(card.statusWord.uppercased(), "\(sans) 9px", 0, 1, &pillWidth, &pillHeight)
        let px = x + width - pad - pillWidth - 14
        round(cr, px, top + 3, pillWidth + 14, 16, 8)
        setColor(cr, statusColor, 0.9)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        _ = tailscode_text_draw(
            cr, card.statusWord.uppercased(), "\(sans) 9px", px + 7, top + 5.5, 0, 0, 1,
            statusColor.red, statusColor.green, statusColor.blue, 1)
        top += headerHeight + 6
        let ink = inks.domeInk
        let bodyInk = thought ? ink : color
        if bodyHeight > 0 {
            _ = tailscode_text_draw(
                cr, card.body, bodyFont, x + pad, top, inner, 0, thought ? 4 : 3, bodyInk.0, bodyInk.1,
                bodyInk.2, 1)
            top += bodyHeight + 4
        }
        if let tally = card.tally {
            _ = tailscode_text_draw(
                cr, tally, "\(mono) 10px", x + pad, top, 0, 0, 1, inks.domeAccent.red, inks.domeAccent.green,
                inks.domeAccent.blue, 1)
            top += 16
        }
        if !card.output.isEmpty {
            let failed = card.status == .failed
            let tint = failed ? inks.danger : inks.domeDim
            setColor(cr, tint, 0.8)
            cairo_set_line_width(cr, 2)
            cairo_new_path(cr)
            cairo_move_to(cr, x + pad + 1, top + 2)
            cairo_line_to(cr, x + pad + 1, top + outputHeight + 2)
            cairo_stroke(cr)
            _ = tailscode_text_draw(
                cr, card.output.joined(separator: "\n"), "\(mono) 10px", x + pad + 9, top + 2,
                inner - 10, 0, 4, tint.red, tint.green, tint.blue, 1)
            top += outputHeight + 8
        }
        setColor(cr, inks.domeDim, 0.3)
        cairo_set_line_width(cr, 1)
        cairo_new_path(cr)
        cairo_move_to(cr, x + pad, top + 3.5)
        cairo_line_to(cr, x + width - pad, top + 3.5)
        cairo_stroke(cr)
        _ = tailscode_text_draw(
            cr, card.footer, "\(sans) 10px", x + pad, top + 8, inner, 0, 3, inks.domeDim.red, inks.domeDim.green,
            inks.domeDim.blue, 1)
        cairo_restore(cr)
        return (x, y, width, height)
    }

    private static func shapeOf(_ zone: NeuralZone) -> NeuralShape { zone.shape }

    private static func statusInk(_ status: NeuralStatus, inks: BrainInks) -> BrainInks.RGB {
        switch status {
        case .ok: return inks.domeAccent
        case .failed: return inks.danger
        case .running: return inks.live
        case .stopped: return inks.domeDim
        case .waitingApproval, .waitingAnswer, .stalled: return inks.attention
        }
    }

    static func round(
        _ cr: OpaquePointer, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ radius: Double
    ) {
        let r = min(radius, min(width, height) / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + width - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + width - r, y + height - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + height - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, .pi * 3 / 2)
        cairo_close_path(cr)
    }

    /// The 28 pt head beside a collapsed turn: outline, one dot per zone that has steps, the rings
    /// where the work is or a failure stands, and the eye. Drawn from `NeuralGlyph`, which every
    /// client reads the same way.
    static func glyph(
        _ cr: OpaquePointer, glyph: NeuralGlyph, width: Double, height: Double, inks: BrainInks,
        time: Double, reduceMotion: Bool
    ) {
        let box = NeuralGlyph.viewBox
        let scale = width / box.width
        cairo_save(cr)
        cairo_scale(cr, scale, scale)
        cairo_translate(cr, -box.x, -box.y)
        cairo_new_path(cr)
        for (index, point) in NeuralGlyph.outline.enumerated() {
            if index == 0 {
                cairo_move_to(cr, point.x, point.y)
            } else {
                cairo_line_to(cr, point.x, point.y)
            }
        }
        cairo_close_path(cr)
        setColor(cr, inks.panel, 0.9)
        cairo_fill_preserve(cr)
        setColor(cr, inks.isDark ? inks.ink : inks.dim, 0.9)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_set_line_width(cr, 1.7 / scale)
        cairo_stroke(cr)
        for dot in glyph.dots {
            let tone = inks.zone(dot.zone)
            var alpha = dot.opacity
            if dot.isLive && !reduceMotion {
                let level = NeuralMotion.breath.level(at: time)
                alpha *= 0.34 + 0.66 * (level - 0.34) / 0.66
            }
            cairo_new_path(cr)
            cairo_arc(cr, dot.center.x, dot.center.y, dot.radius, 0, 2 * .pi)
            setColor(cr, tone, alpha)
            cairo_fill(cr)
            if let ring = dot.activeRing {
                cairo_new_path(cr)
                cairo_arc(cr, dot.center.x, dot.center.y, ring.radius, 0, 2 * .pi)
                setColor(cr, inks.live, 1)
                cairo_set_line_width(cr, ring.strokeWidth)
                cairo_stroke(cr)
            }
            if let ring = dot.failureRing {
                cairo_new_path(cr)
                cairo_arc(cr, dot.center.x, dot.center.y, ring.radius, 0, 2 * .pi)
                setColor(cr, inks.danger, 1)
                cairo_set_line_width(cr, ring.strokeWidth)
                cairo_stroke(cr)
            }
        }
        let eye = inks.tone(glyph.eyeTone)
        let halo = NeuralGlyph.eyeHalo
        cairo_new_path(cr)
        cairo_arc(cr, halo.center.x, halo.center.y, halo.radius, 0, 2 * .pi)
        setColor(cr, eye, halo.opacity)
        cairo_fill(cr)
        cairo_new_path(cr)
        for (index, point) in NeuralGlyph.eyeBar.enumerated() {
            if index == 0 {
                cairo_move_to(cr, point.x, point.y)
            } else {
                cairo_line_to(cr, point.x, point.y)
            }
        }
        cairo_close_path(cr)
        setColor(cr, eye, 1)
        cairo_fill(cr)
        cairo_restore(cr)
    }
}
