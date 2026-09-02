import Foundation
import Testing
@testable import TailscodeCore

@Suite("Card styles")
struct CardStyleTests {
    @Test("Every style is readable on both ends of its canvas, once published")
    func everyStyleReads() {
        for style in CardStyle.all where style.authored != nil {
            let palette = style.palette(dark: true)
            for ground in [palette.canvas, palette.canvasEnd] {
                #expect(
                    Contrast.ratio(palette.text, on: ground) ?? 0 >= 4.5,
                    "\(style.id) text on \(ground)")
                #expect(
                    Contrast.ratio(palette.textDim, on: ground) ?? 0 >= 4.5,
                    "\(style.id) dim on \(ground)")
                for slot in [palette.accent, palette.info, palette.warn, palette.special] {
                    #expect(
                        Contrast.ratio(slot, on: ground) ?? 0 >= 3, "\(style.id) \(slot) on \(ground)")
                }
            }
            #expect(palette.rule != palette.canvas)
            #expect(palette.onAccent == palette.canvas)
        }
    }

    @Test("Publishing keeps a style's hue: only lightness moves, and only where it had to")
    func publishingIsGentle() {
        let ember = CardStyle.ember
        let authored = try! #require(ember.authored)
        let published = ember.palette(dark: true)
        #expect(published.canvas == authored.canvas)
        #expect(published.canvasEnd == authored.canvasEnd)
        #expect(published.accent == authored.accent)
    }

    @Test("The catalog leads with the app's own theme, ids are unique, and a stranger falls back")
    func catalogShape() {
        #expect(CardStyle.all.first?.id == CardStyle.appID)
        #expect(Set(CardStyle.all.map(\.id)).count == CardStyle.all.count)
        #expect(CardStyle.named("no-such-style").id == CardStyle.appID)
        #expect(CardStyle.named(nil).id == CardStyle.appID)
        #expect(CardStyle.all.filter(\.isLight).map(\.id) == ["paper", "frost"])
        #expect(CardStyle.all.count >= 8)
    }

    @Test("The app style answers with a real palette even when the app wears System")
    func appStyleNeverInvisible() {
        let palette = CardStyle.app.palette(dark: true)
        #expect(palette.canvas.hasPrefix("#"))
        #expect(Contrast.ratio(palette.text, on: palette.canvas) ?? 0 >= 4.5)
    }
}
