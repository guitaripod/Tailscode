import CoreGraphics
import TailscodeCore
import UIKit

/// The head with its nodes, drawn once as a still picture for a poster: the interior the way
/// the stage draws it, the wires and nodes of the turn laid over it, and the chassis and glass over
/// those, which is the order the chat's own stage stacks its layers in. A turn that is settled and
/// shared has no clock, so everything is lit and nothing moves.
///
/// The head itself is the GPU's, read back from the same renderer the stage runs
/// (`NeuralHeadRenderer.snapshot`); the nodes are painted here in Core Graphics from the same
/// `NeuralNodes` draws every client reads, because a poster needs them in the one picture. A
/// machine that cannot draw the head (no Metal, no resident textures) still gets a hero: the small
/// glyph's silhouette and zone dots, drawn large, so the poster is never empty.
enum NeuralShareHero {
    /// The picture's size for a poster of this width in points at this scale: the design's own
    /// aspect, which the poster crops to its box.
    static func size(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * NeuralDesign.height / NeuralDesign.width).rounded())
    }

    @MainActor
    static func render(model: NeuralBrainModel, palette: Palette, size: CGSize) -> UIImage {
        let width = max(16, Int(size.width.rounded()))
        let height = max(16, Int(size.height.rounded()))
        let face = model.face
        let table = NeuralToneTable(palette: palette, face: face)
        guard let pair = snapshot(model: model, table: table, width: width, height: height) else {
            return glyphHero(model: model, palette: palette, size: CGSize(width: width, height: height))
        }
        let inks = NeuralPosterInks(palette: palette, face: face)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let target = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            let cg = context.cgContext
            let bounds = CGRect(origin: .zero, size: target)
            if let interior = image(of: pair.interior, premultiplied: false) {
                drawUpright(interior, in: bounds, context: cg)
            }
            NeuralPosterNodes.paint(model: model, inks: inks, size: target, in: cg)
            if let front = image(of: pair.front, premultiplied: true) {
                drawUpright(front, in: bounds, context: cg)
            }
        }
    }

    /// Draws a picture read back from the GPU the right way up. The renderer's context already has
    /// its origin at the top, and `CGContext.draw` puts a picture's first row at the bottom of the
    /// rectangle it is given, so the picture is turned over first.
    private static func drawUpright(_ picture: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(picture, in: rect)
        context.restoreGState()
    }

    /// Both layers read back from the GPU, or nil where the head cannot be drawn.
    @MainActor
    private static func snapshot(
        model: NeuralBrainModel, table: NeuralToneTable, width: Int, height: Int
    ) -> NeuralSurfacePair? {
        guard let context = NeuralMetalContext.shared, context.isSupported else { return nil }
        context.retain()
        defer { context.release() }
        guard context.prepareSynchronously(), let renderer = NeuralHeadRenderer(context: context)
        else { return nil }
        return renderer.snapshot(
            frame: model.frame(time: 0, reduceMotion: true), table: table, time: 0, width: width,
            height: height)
    }

    private static func image(of surface: NeuralSurface, premultiplied: Bool) -> CGImage? {
        guard surface.width > 0, surface.height > 0,
            let provider = CGDataProvider(data: Data(surface.bytes) as CFData)
        else { return nil }
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedFirst : .noneSkipFirst
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The fallback: the glyph's silhouette large on the page's own ground, with the nodes on it.
    private static func glyphHero(model: NeuralBrainModel, palette: Palette, size: CGSize) -> UIImage {
        let inks = NeuralPosterInks(palette: palette, face: model.face)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            inks.panel.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            let wire = model.glyphWire
            if let plan = wire.plan() {
                let width = size.width * 0.84
                let origin = CGPoint(
                    x: (size.width - width) / 2,
                    y: (size.height - CGFloat(NeuralGlyphGeometry.height(forWidth: Double(width)))) / 2)
                NoticeHead.draw(plan, at: origin, width: width, dark: palette.isDark, in: cg)
            }
        }
    }
}

/// The poster's inks, resolved once from the palette and the model that answered: each zone's own
/// channel colour (lifted for a light palette, which the head's glow needs) and the four tones.
struct NeuralPosterInks {
    let zones: [UIColor]
    let live: UIColor
    let attention: UIColor
    let danger: UIColor
    let quiet: UIColor
    let ink: UIColor
    let dim: UIColor
    let special: UIColor
    let accent: UIColor
    let panel: UIColor
    let isDark: Bool

    init(palette: Palette, face: NeuralFace) {
        let tones = NeuralPalette.channelTones(palette: palette, face: face)
        zones = NeuralZone.allCases.map { Self.encode(tones[$0.rawValue]) }
        live = Self.encode(NeuralPalette.glow(.live, palette: palette, face: face))
        attention = Self.encode(NeuralPalette.glow(.attention, palette: palette, face: face))
        danger = Self.encode(NeuralPalette.glow(.danger, palette: palette, face: face))
        quiet = Self.encode(NeuralPalette.glow(.quiet, palette: palette, face: face))
        ink = Self.hex(palette.text)
        dim = Self.hex(palette.textDim)
        special = Self.hex(palette.special)
        accent = Self.hex(palette.accent)
        isDark = palette.isDark
        let canvas = Contrast.channels(palette.canvas) ?? (0.05, 0.05, 0.05)
        panel =
            palette.isDark
            ? UIColor(red: canvas.red * 0.55, green: canvas.green * 0.55, blue: canvas.blue * 0.55, alpha: 1)
            : UIColor(red: 0.045, green: 0.06, blue: 0.055, alpha: 1)
    }

    func zone(_ zone: NeuralZone) -> UIColor { zones[zone.rawValue] }

    func color(of tone: NeuralNodeTone, zone: NeuralZone) -> UIColor {
        switch tone {
        case .zone: return self.zone(zone)
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        }
    }

    static func mix(_ one: UIColor, _ other: UIColor, _ amount: CGFloat) -> UIColor {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        one.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        other.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return UIColor(
            red: a.0 + (b.0 - a.0) * amount, green: a.1 + (b.1 - a.1) * amount,
            blue: a.2 + (b.2 - a.2) * amount, alpha: 1)
    }

    private static func encode(_ linear: NeuralRGB) -> UIColor {
        func channel(_ value: Float) -> CGFloat { CGFloat(pow(max(0, value), 1 / 2.2)) }
        return UIColor(red: channel(linear.r), green: channel(linear.g), blue: channel(linear.b), alpha: 1)
    }

    private static func hex(_ value: String) -> UIColor {
        guard let c = Contrast.channels(value) else { return .gray }
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

/// The nodes, wires, ties and zone names of a settled turn in Core Graphics, drawn in the head's
/// design space (640 by 420) scaled to the picture. Every decision (where a node is, what shape
/// and tone it wears, which wires exist) is Core's `NeuralNodes`; this chooses only strokes.
enum NeuralPosterNodes {
    static func paint(model: NeuralBrainModel, inks: NeuralPosterInks, size: CGSize, in cg: CGContext) {
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: true)
        let wires = NeuralNodes.wires(model: model, time: 0, reduceMotion: true)
        let used = Set(model.turn.steps.map(\.zone))
        cg.saveGState()
        let scale = size.width / CGFloat(NeuralDesign.width)
        cg.scaleBy(x: scale, y: scale)
        zoneLabels(used: used, inks: inks, scale: scale)
        ties(wires.ties, inks: inks, scale: scale)
        self.wires(wires, inks: inks, crowded: model.nodeCount > NeuralNodes.instancingThreshold, in: cg)
        for node in draws { self.node(node, inks: inks, crowded: model.nodeCount > NeuralNodes.instancingThreshold, in: cg) }
        cg.restoreGState()
    }

    private static func zoneLabels(used: Set<NeuralZone>, inks: NeuralPosterInks, scale: CGFloat) {
        let font = UIFont.monospacedSystemFont(ofSize: max(8.5, 9 * scale) / scale, weight: .bold)
        for zone in NeuralZone.allCases {
            let on = used.contains(zone)
            let width = CGFloat(zone.label.count) * 8 + 10
            let rect = CGRect(
                x: CGFloat(zone.center.x) - width / 2,
                y: CGFloat(zone.center.y - zone.well.ry) - 19, width: width, height: 14)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            NSAttributedString(
                string: zone.label,
                attributes: [
                    .font: font, .kern: 1.2, .paragraphStyle: paragraph,
                    .foregroundColor: (on ? inks.zone(zone) : inks.dim).withAlphaComponent(on ? 1 : 0.55),
                ]
            ).draw(in: rect)
        }
    }

    private static func ties(_ ties: [NeuralTieDraw], inks: NeuralPosterInks, scale: CGFloat) {
        for tie in ties where tie.lit > 0 {
            inks.special.withAlphaComponent(0.55).setStroke()
            for arc in tie.arcs {
                let path = UIBezierPath()
                path.move(to: point(arc.from))
                path.addQuadCurve(to: point(arc.to), controlPoint: point(arc.control))
                path.lineWidth = 1.3
                path.setLineDash([3, 4], count: 2, phase: 0)
                path.stroke()
            }
            guard let last = tie.arcs.last, !tie.label.isEmpty else { continue }
            let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            NSAttributedString(
                string: tie.label,
                attributes: [.font: font, .foregroundColor: inks.special.withAlphaComponent(0.7)]
            ).draw(at: CGPoint(x: last.to.x + 9, y: last.to.y - 11))
        }
    }

    private static func wires(
        _ wires: NeuralWires, inks: NeuralPosterInks, crowded: Bool, in cg: CGContext
    ) {
        for wire in wires.routes where wire.points.count >= 2 {
            let path = UIBezierPath()
            path.move(to: point(wire.points[0]))
            for next in wire.points.dropFirst() { path.addLine(to: point(next)) }
            path.lineWidth = 1.2
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            inks.dim.withAlphaComponent(crowded ? 0.16 : 0.28).setStroke()
            path.stroke()
            inks.zone(wire.zone).withAlphaComponent(crowded ? 0.22 : 0.36).setStroke()
            path.stroke()
        }
        for via in wires.vias {
            let dot = UIBezierPath(
                arcCenter: point(via.point), radius: 3.4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            inks.zone(via.zone).withAlphaComponent(0.85).setFill()
            dot.fill()
        }
    }

    private static func node(
        _ node: NeuralNodeDraw, inks: NeuralPosterInks, crowded: Bool, in cg: CGContext
    ) {
        let color = inks.color(of: node.tone, zone: node.zone)
        let radius = CGFloat(node.radius)
        cg.saveGState()
        cg.translateBy(x: CGFloat(node.point.x), y: CGFloat(node.point.y))
        if !crowded {
            drawGlow(color, radius: radius, in: cg)
        }
        if node.zone == .think && node.ganglionCount == nil {
            let halo = UIBezierPath(
                arcCenter: .zero, radius: radius + 4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            halo.lineWidth = 1
            halo.setLineDash([2, 3], count: 2, phase: 0)
            color.withAlphaComponent(0.7).setStroke()
            halo.stroke()
        }
        let path = shape(node.ganglionCount == nil ? node.shape : .circle, radius: radius)
        NeuralPosterInks.mix(inks.panel, color, 0.17).withAlphaComponent(0.96).setFill()
        path.fill()
        path.lineWidth = node.ganglionCount != nil ? 2 : 1.7
        path.lineJoinStyle = .round
        switch node.status {
        case .stopped: path.setLineDash([3, 3], count: 2, phase: 0)
        case .stalled: path.setLineDash([5, 3], count: 2, phase: 0)
        default:
            if node.ganglionCount != nil { path.setLineDash([4, 3], count: 2, phase: 0) }
        }
        color.setStroke()
        path.stroke()
        if node.zone == .delegate && node.ganglionCount == nil {
            let ring = UIBezierPath(
                arcCenter: .zero, radius: radius * 0.84, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ring.lineWidth = 1
            ring.setLineDash([2, 2], count: 2, phase: 0)
            color.withAlphaComponent(0.8).setStroke()
            ring.stroke()
        }
        let size: CGFloat = node.ganglionCount != nil ? 12 : 9
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSAttributedString(
            string: node.label,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: size, weight: .bold),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ]
        ).draw(in: CGRect(x: -radius * 1.2, y: -size * 0.62, width: radius * 2.4, height: size * 1.4))
        if node.status == .failed {
            let cross = UIBezierPath()
            cross.move(to: CGPoint(x: radius * 0.55, y: -radius * 1.15))
            cross.addLine(to: CGPoint(x: radius * 1.25, y: -radius * 1.85))
            cross.move(to: CGPoint(x: radius * 1.25, y: -radius * 1.15))
            cross.addLine(to: CGPoint(x: radius * 0.55, y: -radius * 1.85))
            cross.lineWidth = 2
            cross.lineCapStyle = .round
            inks.danger.setStroke()
            cross.stroke()
        }
        cg.restoreGState()
    }

    private static func drawGlow(_ color: UIColor, radius: CGFloat, in cg: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [color.withAlphaComponent(0.22).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1])
        else { return }
        cg.drawRadialGradient(
            gradient, startCenter: .zero, startRadius: radius * 0.6, endCenter: .zero,
            endRadius: radius * 2, options: [])
    }

    private static func point(_ p: NeuralPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }

    private static func shape(_ shape: NeuralShape, radius r: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        switch shape {
        case .circle:
            path.addArc(withCenter: .zero, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        case .diamond:
            let k = r * 1.2
            path.move(to: CGPoint(x: 0, y: -k))
            path.addLine(to: CGPoint(x: k, y: 0))
            path.addLine(to: CGPoint(x: 0, y: k))
            path.addLine(to: CGPoint(x: -k, y: 0))
            path.close()
        case .chip:
            let k = r * 0.9
            let c = r * 0.42
            path.move(to: CGPoint(x: -k, y: -k))
            path.addLine(to: CGPoint(x: k - c, y: -k))
            path.addLine(to: CGPoint(x: k, y: -k + c))
            path.addLine(to: CGPoint(x: k, y: k))
            path.addLine(to: CGPoint(x: -k + c, y: k))
            path.addLine(to: CGPoint(x: -k, y: k - c))
            path.close()
        case .hexagon:
            polygon(path, sides: 6, radius: r * 1.12, phase: 0)
        case .octagon:
            polygon(path, sides: 8, radius: r * 1.12, phase: .pi / 8)
        case .bubble:
            let w = r * 1.3
            let h = r * 0.95
            let c = r * 0.5
            path.move(to: CGPoint(x: -w + c, y: -h))
            path.addLine(to: CGPoint(x: w - c, y: -h))
            path.addQuadCurve(to: CGPoint(x: w, y: -h + c), controlPoint: CGPoint(x: w, y: -h))
            path.addLine(to: CGPoint(x: w, y: h - c))
            path.addQuadCurve(to: CGPoint(x: w - c, y: h), controlPoint: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: -w * 0.15, y: h))
            path.addLine(to: CGPoint(x: -w * 0.55, y: h + r * 0.65))
            path.addLine(to: CGPoint(x: -w * 0.5, y: h))
            path.addLine(to: CGPoint(x: -w + c, y: h))
            path.addQuadCurve(to: CGPoint(x: -w, y: h - c), controlPoint: CGPoint(x: -w, y: h))
            path.addLine(to: CGPoint(x: -w, y: -h + c))
            path.addQuadCurve(to: CGPoint(x: -w + c, y: -h), controlPoint: CGPoint(x: -w, y: -h))
            path.close()
        }
        return path
    }

    private static func polygon(_ path: UIBezierPath, sides: Int, radius: CGFloat, phase: CGFloat) {
        for index in 0..<sides {
            let angle = CGFloat.pi * 2 / CGFloat(sides) * CGFloat(index) + phase
            let p = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
    }
}
