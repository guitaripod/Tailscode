import AppKit
import TailscodeCore

extension SelfTest {
    /// Core proves a sky as numbers; what this checks is the half Core cannot see, which is that
    /// the painter the Mac and the phone share turns those numbers into a picture: a sky that is
    /// a whole opaque ground and not one flat fill, stars lit on it, and suns that stand on
    /// their horizon with nothing of them below it.
    static func checkScenery() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        for palette in [AppTheme.outerRim.dark.corrected(), AppTheme.outerRim.light.corrected()] {
            guard let scenery = palette.scenery else {
                throw SelfTestFailure("\(palette.name) reached AppKit without its scenery")
            }
            let side = 480
            let sky = try picture(side: side) { context in
                SceneryPainter.drawSky(
                    scenery, canvas: palette.canvas, in: context,
                    sky: CGRect(x: 0, y: 0, width: side, height: side))
            }
            try expect(sky.allSatisfy { $0 >> 24 == 0xff }, "\(palette.name): its sky is not a whole ground")
            try expect(Set(sky).count > 12, "\(palette.name): its sky is one flat fill")
            switch scenery.sky {
            case .stars(let field):
                let ground = try picture(side: side) { context in
                    SceneryPainter.drawSky(
                        Scenery(
                            sky: .stars(StarField(layers: [], tints: field.tints, washes: [])),
                            bladeGlow: 0, scanLines: 0, castShadow: 0),
                        canvas: palette.canvas, in: context,
                        sky: CGRect(x: 0, y: 0, width: side, height: side))
                }
                let lit = zip(sky, ground).filter { $0 != $1 }.count
                try expect(lit > 40, "\(palette.name): no star is lit on its sky")
            case .suns(let suns):
                let horizon = 200
                let stood = try picture(side: side) { context in
                    SceneryPainter.drawSuns(
                        suns, in: context, horizon: CGFloat(horizon), leading: 120,
                        width: CGFloat(side))
                }
                let above = stood.prefix(horizon * side).contains { $0 >> 24 > 0x80 }
                let below = stood.dropFirst(horizon * side).contains { $0 >> 24 != 0 }
                try expect(above, "\(palette.name): its suns are not drawn")
                try expect(!below, "\(palette.name): a sun is drawn under its horizon")
            }
            checks += 1
        }
        let lines = try picture(side: 60) { context in
            SceneryPainter.drawScanLines(
                tone: SceneryPainter.color("#5fe08a"), share: 0.05, in: context,
                rect: CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        try expect(lines[30] >> 24 > lines[60 + 30] >> 24, "the scan lines are not lines")
        checks += 1
        return checks
    }

    /// A square drawn into with y running down, as the views that use the painter are, and
    /// handed back a pixel at a time, a row at a time from the top, alpha in the top byte.
    private static func picture(side: Int, draw: (CGContext) -> Void) throws -> [UInt32] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw SelfTestFailure("no bitmap to draw a sky into") }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let data = context.data else { throw SelfTestFailure("the sky's bitmap has no bytes") }
        let pixels = data.bindMemory(to: UInt32.self, capacity: side * side)
        return Array(UnsafeBufferPointer(start: pixels, count: side * side))
    }
}
