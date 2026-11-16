import CoreGraphics
import Foundation
import TailscodeCore

/// Core's scenery drawn with Core Graphics, once, for the two clients that have it.
///
/// Everything here is drawn into a context whose origin is the top leading corner with y running
/// down, which is UIKit's own and what a flipped AppKit view gives. A sky is drawn for the whole
/// window and seen through whichever view asked, so two panes side by side show one sky rather
/// than the same stars twice: the caller says where the window's sky lies in its own
/// coordinates and the context's clip does the rest. Nothing is kept between draws: a sky is a
/// few hundred discs and a handful of gradients, and a view that draws it does so once for a
/// size.
enum SceneryPainter {
    /// The ground and everything on it: the canvas colour, the washes, and then the stars or the
    /// dunes. Opaque, so the view that draws it needs nothing behind it.
    static func drawSky(_ scenery: Scenery, canvas: String, in context: CGContext, sky: CGRect) {
        context.saveGState()
        context.setFillColor(color(canvas))
        context.fill(context.boundingBoxOfClipPath)
        switch scenery.sky {
        case .stars(let field):
            for wash in field.washes { draw(wash, in: context, sky: sky) }
            for layer in field.layers { draw(layer, of: field, in: context, sky: sky) }
        case .suns(let suns):
            for wash in suns.washes { draw(wash, in: context, sky: sky) }
            for dune in suns.dunes { draw(dune, in: context, sky: sky) }
        }
        context.restoreGState()
    }

    /// One layer of stars, each lit as its own disc wherever its tile repeats inside what is
    /// being drawn. Core's tile is a picture for a client that can only lay pictures; here a
    /// star is a few points of geometry, so nothing is kept between draws and a star is as
    /// sharp as the display it is on. A star with a halo spills the share of its light Core
    /// gives it, falling away the way Core's own tile does.
    private static func draw(
        _ layer: StarField.Layer, of field: StarField, in context: CGContext, sky: CGRect
    ) {
        let side = CGFloat(layer.tile)
        guard side > 0 else { return }
        let stars = field.stars(in: layer)
        let reach = CGFloat(layer.radius.upperBound) * (layer.halo > 0 ? 3.2 : 1) + 1
        let seen = context.boundingBoxOfClipPath.intersection(sky).insetBy(dx: -reach, dy: -reach)
        guard !seen.isNull, !seen.isEmpty else { return }
        let columns = Int(((seen.minX - sky.minX) / side).rounded(.down))...Int(
            ((seen.maxX - sky.minX) / side).rounded(.down))
        let rows = Int(((seen.minY - sky.minY) / side).rounded(.down))...Int(
            ((seen.maxY - sky.minY) / side).rounded(.down))
        for row in rows {
            for column in columns {
                let origin = CGPoint(
                    x: sky.minX + CGFloat(column) * side, y: sky.minY + CGFloat(row) * side)
                for star in stars {
                    let centre = CGPoint(x: origin.x + CGFloat(star.x), y: origin.y + CGFloat(star.y))
                    guard seen.contains(centre) else { continue }
                    light(star, halo: layer.halo, at: centre, in: context)
                }
            }
        }
    }

    private static func light(
        _ star: StarField.Star, halo: Double, at centre: CGPoint, in context: CGContext
    ) {
        let radius = CGFloat(star.radius)
        if halo > 0,
            let spill = gradient(
                [(0, 1), (0.25, 0.78), (0.5, 0.37), (0.75, 0.1), (1, 0)].map {
                    ($0.0, star.tint, star.alpha * halo * $0.1)
                })
        {
            context.drawRadialGradient(
                spill, startCenter: centre, startRadius: 0, endCenter: centre,
                endRadius: radius * 3.2, options: [])
        }
        context.setFillColor(color(star.tint, alpha: min(star.alpha, Scenery.starAlphaCeiling)))
        context.fillEllipse(
            in: CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A wash is a circle of light in the sky's own unit square, which makes it the ellipse a
    /// wide window needs without a second set of numbers.
    private static func draw(_ wash: SkyWash, in context: CGContext, sky: CGRect) {
        guard sky.width > 0, sky.height > 0,
            let gradient = gradient([(0, wash.color, wash.alpha), (1, wash.color, 0)])
        else { return }
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]
        let farthest = corners.map { hypot($0.0 - wash.x, $0.1 - wash.y) }.max() ?? 1
        context.saveGState()
        context.translateBy(x: sky.minX, y: sky.minY)
        context.scaleBy(x: sky.width, y: sky.height)
        let centre = CGPoint(x: wash.x, y: wash.y)
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0, endCenter: centre,
            endRadius: CGFloat(farthest * wash.reach), options: [])
        context.restoreGState()
    }

    /// A dune is the upper arc of a wide ellipse resting on the sky's lower edge: one flat tint,
    /// and a line of light along its crest.
    private static func draw(_ dune: TwinSuns.Dune, in context: CGContext, sky: CGRect) {
        let radiusX = CGFloat(dune.reach) * sky.width
        let radiusY = CGFloat(dune.height)
        let bounds = CGRect(
            x: sky.minX + CGFloat(dune.x) * sky.width - radiusX, y: sky.maxY - radiusY,
            width: radiusX * 2, height: radiusY * 2)
        context.saveGState()
        context.clip(to: sky)
        context.setFillColor(color(dune.color, alpha: dune.alpha))
        context.fillEllipse(in: bounds)
        context.setStrokeColor(color(dune.crest, alpha: 0.55))
        context.setLineWidth(1.25)
        context.strokeEllipse(in: bounds.insetBy(dx: 0.6, dy: 0.6))
        context.restoreGState()
    }

    /// The suns, standing on a horizon: nothing of them is drawn below it, so a sun whose rise is
    /// less than its radius is going down. `leading` is where their own distances are counted
    /// from.
    static func drawSuns(
        _ suns: TwinSuns, in context: CGContext, horizon: CGFloat, leading: CGFloat, width: CGFloat
    ) {
        context.saveGState()
        context.clip(to: CGRect(x: leading - 400, y: horizon - 400, width: width + 800, height: 400))
        for sun in suns.suns {
            let reach = sun.radius * 3.4
            let rim = sun.radius / reach
            guard
                let gradient = gradient([
                    (0, sun.core, sun.alpha), (rim * 0.9, sun.core, sun.alpha),
                    (rim * 1.08, sun.corona, sun.alpha * 0.72),
                    (rim * 1.8, sun.corona, sun.alpha * 0.26), (1, sun.corona, 0),
                ])
            else { continue }
            let centre = CGPoint(x: leading + CGFloat(sun.x), y: horizon - CGFloat(sun.rise))
            context.drawRadialGradient(
                gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                endRadius: CGFloat(reach), options: [])
        }
        context.restoreGState()
    }

    /// How wide the pair stands, from the leading sun's corona to the trailing one's, for a client
    /// that has to make room for them rather than being handed a bar's whole width.
    static func span(of suns: TwinSuns) -> ClosedRange<CGFloat> {
        let edges = suns.suns.flatMap { [$0.x - $0.radius * 3.4, $0.x + $0.radius * 3.4] }
        return CGFloat(edges.min() ?? 0)...CGFloat(edges.max() ?? 0)
    }

    /// The scan lines over what the agent delegated: a line a point tall every three, and the
    /// projector's light in the corner the card's edge starts from, in the colour that edge is
    /// wearing now.
    static func drawScanLines(tone: CGColor, share: Double, in context: CGContext, rect: CGRect) {
        guard share > 0, let line = tone.copy(alpha: CGFloat(share)),
            let bright = tone.copy(alpha: CGFloat(share * 2.2)), let clear = tone.copy(alpha: 0)
        else { return }
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(line)
        var y = rect.minY
        while y < rect.maxY {
            context.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1))
            y += 3
        }
        if let lamp = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bright, clear] as CFArray,
            locations: [0, 1])
        {
            context.drawRadialGradient(
                lamp, startCenter: rect.origin, startRadius: 0, endCenter: rect.origin,
                endRadius: hypot(rect.width, rect.height) * 0.62, options: [])
        }
        context.restoreGState()
    }

    /// A theme's card in a picker: a few of its own stars, taken from each layer in the order it
    /// draws them, or its suns going down behind a horizon near the card's foot. `footing` is
    /// how far above the card's lower edge that horizon lies: a card keeps its row of signals
    /// along its foot, and a sun behind that row is a sun nobody sees. A card is looked at
    /// rather than read, so the sky is a little brighter here than it is behind a conversation.
    static func drawCard(
        _ scenery: Scenery, in context: CGContext, rect: CGRect, footing: CGFloat
    ) {
        context.saveGState()
        context.clip(to: rect)
        switch scenery.sky {
        case .stars(let field):
            let shown = [9, 8, 4]
            for (index, layer) in field.layers.enumerated() {
                let side = CGFloat(layer.tile)
                for star in field.stars(in: layer).prefix(index < shown.count ? shown[index] : 3) {
                    let centre = CGPoint(
                        x: rect.minX + CGFloat(star.x) / side * rect.width,
                        y: rect.minY + CGFloat(star.y) / side * rect.height)
                    let radius = max(0.7, CGFloat(star.radius) * 0.95)
                    context.setFillColor(
                        color(star.tint, alpha: min(Scenery.starAlphaCeiling, star.alpha * 1.5)))
                    context.fillEllipse(
                        in: CGRect(
                            x: centre.x - radius, y: centre.y - radius, width: radius * 2,
                            height: radius * 2))
                }
            }
        case .suns(let suns):
            let room = span(of: suns)
            drawSuns(
                suns, in: context, horizon: rect.maxY - footing,
                leading: rect.maxX - room.upperBound - 26, width: room.upperBound)
        }
        context.restoreGState()
    }

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        let channels = Contrast.channels(hex) ?? (red: 0.5, green: 0.5, blue: 0.5)
        return CGColor(
            srgbRed: CGFloat(channels.red), green: CGFloat(channels.green),
            blue: CGFloat(channels.blue), alpha: CGFloat(alpha))
    }

    private static func gradient(_ stops: [(Double, String, Double)]) -> CGGradient? {
        let colors = stops.map { color($0.1, alpha: $0.2) } as CFArray
        let locations = stops.map { CGFloat($0.0) }
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
            locations: locations)
    }
}
