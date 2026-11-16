import Foundation
import Testing

@testable import TailscodeCore

/// Scenery is the one part of a theme that means nothing, so what is held here is that it stays
/// that way: behind the words, still, in no signal's colour, and only where it can be drawn.
@Suite struct ThemeSceneryTests {
    private static var skies: [(palette: Palette, scenery: Scenery)] {
        [AppTheme.outerRim.dark, AppTheme.outerRim.light].compactMap { palette in
            palette.scenery.map { (palette, $0) }
        }
    }

    private static var field: StarField {
        guard case .stars(let field) = Scenery.deepSpace.sky else {
            return StarField(layers: [], tints: [], washes: [])
        }
        return field
    }

    private static var suns: TwinSuns {
        guard case .suns(let suns) = Scenery.twinSuns.sky else {
            return TwinSuns(suns: [], washes: [], dunes: [])
        }
        return suns
    }

    @Test func theSkyIsTheSameSkyEveryTime() {
        let field = Self.field
        #expect(!field.layers.isEmpty)
        for layer in field.layers {
            let stars = field.stars(in: layer)
            #expect(stars == field.stars(in: layer))
            #expect(stars.count == layer.count)
            #expect(field.bitmap(layer) == field.bitmap(layer))
        }
        let first = field.stars(in: field.layers[0])[0]
        #expect(Int(first.x * 1000) == 342_668 && Int(first.y * 1000) == 339_210)
    }

    @Test func everyStarIsInsideItsTile() {
        let field = Self.field
        for layer in field.layers {
            for star in field.stars(in: layer) {
                #expect(star.x >= 0 && star.x < Double(layer.tile))
                #expect(star.y >= 0 && star.y < Double(layer.tile))
                #expect(layer.radius.contains(star.radius))
                #expect(star.alpha <= Scenery.starAlphaCeiling)
                #expect(field.tints.contains(star.tint))
            }
        }
    }

    /// Layers whose tiles shared a factor would line up again within a window's width, and the
    /// eye would find the repeat.
    @Test func theTilesShareNoFactor() {
        func common(_ one: Int, _ other: Int) -> Int { other == 0 ? one : common(other, one % other) }
        let tiles = Self.field.layers.map(\.tile)
        for (index, one) in tiles.enumerated() {
            for other in tiles.dropFirst(index + 1) {
                #expect(common(one, other) == 1, "\(one) and \(other) repeat together")
            }
        }
    }

    @Test func theSkyStaysBehindTheWords() {
        let field = Self.field
        for layer in field.layers {
            let picture = field.bitmap(layer)
            #expect(picture.side == layer.tile)
            #expect(picture.rgba.count == layer.tile * layer.tile * 4)
            #expect(picture.peakAlpha <= Scenery.starAlphaCeiling + 0.01)
            #expect(picture.peakAlpha > 0.1, "a layer nobody can see is not a layer")
            #expect(
                picture.litShare <= Scenery.litShareCeiling,
                "\(layer.tile): \(picture.litShare) of the tile is lit")
        }
        for wash in field.washes + Self.suns.washes where wash.reach > 0 {
            #expect((0...1).contains(wash.x) && (0...1).contains(wash.y))
        }
        for wash in field.washes { #expect(wash.alpha <= 0.12) }
    }

    @Test func aStarOnTheEdgeIsDrawnOnBothSides() {
        var canvas = SceneryCanvas(side: 32)
        canvas.light(
            StarField.Star(x: 0.3, y: 16, radius: 1.4, alpha: 0.7, tint: "#ffffff"), halo: 0)
        let picture = canvas.bitmap
        func alpha(_ column: Int, _ row: Int) -> UInt8 { picture.rgba[(row * 32 + column) * 4 + 3] }
        #expect(alpha(0, 16) > 0)
        #expect(alpha(31, 16) > 0, "the far edge did not take the star's other half")
        #expect(alpha(16, 16) == 0)
    }

    /// Two stars on one pixel add their light, and the pixel stays their colour: only its
    /// opacity is held to the ceiling.
    @Test func starsThatOverlapKeepTheirColour() {
        var canvas = SceneryCanvas(side: 16)
        let star = StarField.Star(x: 8.5, y: 8.5, radius: 1.2, alpha: 0.7, tint: "#808080")
        canvas.light(star, halo: 0)
        canvas.light(star, halo: 0)
        let picture = canvas.bitmap
        let index = (8 * 16 + 8) * 4
        for channel in 0..<3 {
            #expect(abs(Int(picture.rgba[index + channel]) - 0x80) <= 1)
        }
        #expect(Double(picture.rgba[index + 3]) / 255 <= Scenery.starAlphaCeiling + 0.01)
        #expect(picture.rgba[index + 3] > 0)
    }

    /// A star in the accent would be saying that something is running.
    @Test func sceneryWearsNoSignal() {
        for (palette, scenery) in Self.skies {
            let published = palette.corrected()
            let signals = Set(
                [
                    palette.accent, palette.accentDim, palette.warn, palette.danger, palette.info,
                    palette.special, published.accent, published.accentDim, published.warn,
                    published.danger, published.info, published.special,
                ].map { $0.lowercased() })
            var worn: [String] = []
            switch scenery.sky {
            case .stars(let field):
                worn = field.tints + field.washes.map(\.color)
            case .suns(let suns):
                worn =
                    suns.suns.flatMap { [$0.core, $0.corona] } + suns.washes.map(\.color)
                    + suns.dunes.flatMap { [$0.color, $0.crest] }
            }
            for colour in worn {
                #expect(Contrast.channels(colour) != nil, "\(colour) is not a colour")
                #expect(!signals.contains(colour.lowercased()), "\(colour) is a signal")
            }
        }
    }

    @Test func theSunsStandOnTheHorizon() {
        let suns = Self.suns
        #expect(suns.suns.count == 2)
        for sun in suns.suns {
            #expect(sun.x > sun.radius, "a sun cut by the bar's leading edge")
            #expect(sun.rise > -sun.radius, "a sun wholly under the horizon is not drawn")
            #expect(sun.radius > 0 && sun.alpha > 0 && sun.alpha <= 1)
        }
        #expect(suns.suns[0].radius > suns.suns[1].radius)
    }

    /// A dune is under the words that cross it, so it may only be a shade: both registers of
    /// text and every signal the transcript sets as words still read on the sand it deepens.
    /// The agents' own colours are not asked, because they name quota cards and never a line of
    /// a conversation.
    @Test func theDunesStayUnderTheWords() {
        let palette = AppTheme.outerRim.light.corrected()
        let written: [(String, String, Double)] = [
            ("text", palette.text, Contrast.readable),
            ("textDim", palette.textDim, Contrast.secondary),
            ("accent", palette.accent, Contrast.readable),
            ("accentDim", palette.accentDim, Contrast.readable),
            ("warn", palette.warn, Contrast.readable),
            ("danger", palette.danger, Contrast.readable),
            ("info", palette.info, Contrast.readable),
            ("special", palette.special, Contrast.readable),
        ]
        let dunes = Self.suns.dunes
        #expect(!dunes.isEmpty)
        for dune in dunes {
            #expect((0...1).contains(dune.x) && dune.reach > 0 && dune.height > 0)
            #expect(dune.alpha > 0 && dune.alpha <= TwinSuns.duneAlphaCeiling)
            let sand = Contrast.blend(palette.canvas, dune.color, dune.alpha) ?? palette.canvas
            for (slot, colour, needs) in written {
                let ratio = Contrast.ratio(colour, on: sand) ?? 0
                #expect(ratio >= needs, "\(slot) reads at \(ratio) on a dune")
            }
        }
        if let far = dunes.first, let near = dunes.last, dunes.count > 1 {
            #expect(far.alpha < near.alpha, "the far dune is the fainter one")
        }
    }

    /// Night is lit and day is ink: nothing glows at noon, and nothing casts a shadow in space.
    @Test func eachFaceIsItsOwnPlace() {
        let night = AppTheme.outerRim.dark.scenery
        let day = AppTheme.outerRim.light.scenery
        #expect(night == .deepSpace && day == .twinSuns)
        #expect(Scenery.deepSpace.bladeGlow > 0 && Scenery.deepSpace.castShadow == 0)
        #expect(Scenery.twinSuns.bladeGlow == 0 && Scenery.twinSuns.castShadow > 0)
        #expect(Scenery.deepSpace.scanLines > 0 && Scenery.twinSuns.scanLines == 0)
        #expect(AppTheme.outerRim.dark.corrected().scenery == night)
    }

    /// A theme with scenery is in the catalog every client reads, which is a promise that
    /// every client draws it; the capability registry is where a client that does not says so.
    @Test func theCatalogOffersItEverywhere() {
        #expect(AppTheme.all.contains(.outerRim))
        #expect(AppTheme.named("outerrim") == .outerRim)
        #expect(AppTheme.all.filter { $0.dark.scenery != nil || $0.light.scenery != nil } == [.outerRim])
    }
}
