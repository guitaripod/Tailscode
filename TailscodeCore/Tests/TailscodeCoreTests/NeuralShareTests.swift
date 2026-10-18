import Foundation
import Testing

@testable import TailscodeCore

@Suite struct NeuralShareTests {
    private let prompt = "Fix the Linux build: it stops in TranscriptRows."

    private func card(
        _ turn: NeuralTurn = ReadingFixtures.buildFix(), prompt: String? = nil,
        style: CardStyle = .neural
    ) -> NeuralShare.Card {
        NeuralShare.Card.make(turn: turn, prompt: prompt ?? self.prompt, style: style)
    }

    @Test func posterIsTheAnalyticsCardsOwnWidthAndPadding() {
        #expect(NeuralShare.Card.width == AnalyticsShare.Card.width)
        #expect(NeuralShare.Card.pad == AnalyticsShare.Card.pad)
        #expect(NeuralShare.Card.corner == AnalyticsShare.Card.corner)
        #expect(NeuralShare.Card.height == 1350)
    }

    @Test func heroSlotIsTheDesignsAndSitsInsideThePadding() {
        let hero = card().hero
        #expect(hero == NeuralShare.Rect(56, 106, 968, 590))
        #expect(hero.maxX == NeuralShare.Card.width - NeuralShare.Card.pad)
    }

    @Test func heightsAddUpInsideThePoster() {
        let made = card()
        let footTop = NeuralShare.Card.height - NeuralShare.Card.pad - NeuralShare.Card.footHeight
        #expect(made.contentBottom <= footTop)
        #expect(made.foot.rect.maxY == NeuralShare.Card.height - NeuralShare.Card.pad)
        #expect(made.hero.maxY < made.count.rect.y)
        #expect(made.count.rect.maxY <= (made.subRect?.y ?? made.meters[0].label.rect.y))
        #expect(made.meters.last!.label.rect.maxY < (made.quote?.rule.y ?? made.contentBottom + 1))
    }

    @Test func theCountAndItsCaption() {
        let made = card()
        #expect(made.count.text == "25")
        #expect(made.count.font.size == 96)
        #expect(made.caption.text == "tools in 8m 25s")
        #expect(made.caption.rect.x > made.count.rect.maxX)
    }

    @Test func theLinesChangedLeadTheSubLine() {
        let made = card()
        #expect(made.sub.first == NeuralShare.Run(text: "+5 −2", slot: .accent))
        #expect(made.sub.last?.text == " · fixed 1 error · 2 notes · 2 thoughts")
    }

    @Test func sixMetersScaleToTheBusiestZone() {
        let made = card()
        #expect(made.meters.map(\.zone) == NeuralZone.allCases)
        let byZone = Dictionary(uniqueKeysWithValues: made.meters.map { ($0.zone, $0) })
        #expect(byZone[.shell]!.count == 18)
        #expect(byZone[.shell]!.share == 1)
        #expect(byZone[.shell]!.bar.width == byZone[.shell]!.track.width)
        #expect(abs(byZone[.sense]!.share - 3.0 / 18.0) < 1e-9)
        #expect(abs(byZone[.act]!.bar.width - byZone[.act]!.track.width * 4.0 / 18.0) < 1e-9)
        #expect(byZone[.delegate]!.count == 0)
        #expect(byZone[.delegate]!.bar.width == 0)
        #expect(byZone[.shell]!.label.text == "SHELL")
        #expect(byZone[.shell]!.value.text == "18")
    }

    @Test func aBusyZoneAlwaysShowsABar() {
        var steps = (0..<100).map { ReadingFixtures.step($0, .shell, "Bash") }
        steps.append(ReadingFixtures.step(100, .sense, "Read"))
        let made = card(NeuralTurn(id: "m", steps: steps))
        let sense = made.meters.first { $0.zone == .sense }!
        #expect(sense.share == NeuralShare.Card.meterMinimumShare)
    }

    @Test func aTurnWithOneToolStillLaysOut() {
        let turn = NeuralTurn(id: "m", steps: [ReadingFixtures.step(0, .sense, "Read", detail: "a")])
        let made = NeuralShare.Card.make(turn: turn, prompt: nil, style: .neural)
        #expect(made.count.text == "1")
        #expect(made.caption.text == "tool in 0s" || made.caption.text == "tool")
        #expect(made.subRect == nil)
        #expect(made.quote == nil)
        #expect(made.meters.count == 6)
        #expect(made.meters.first { $0.zone == .sense }!.share == 1)
        #expect(made.contentBottom < made.foot.rect.y)
    }

    @Test func aTurnWithNoStepsHasEmptyMeters() {
        let made = NeuralShare.Card.make(turn: NeuralTurn(id: "m"), prompt: "hi", style: .app)
        #expect(made.count.text == "0")
        #expect(made.meters.allSatisfy { $0.share == 0 && $0.bar.width == 0 })
        #expect(made.quote?.label.text == "hi")
    }

    @Test func theQuoteIsThePromptsFirstNinetyCharacters() {
        let long = String(repeating: "word ", count: 60)
        let made = card(prompt: long)
        let text = made.quote!.label.text
        #expect(text.hasSuffix("…"))
        #expect(text.count <= NeuralShare.Card.quoteLimit + 1)
        #expect(made.quote!.label.maxLines <= NeuralShare.Card.quoteLines)
        #expect(made.quote!.label.rect.height <= 2 * 23 * 1.45 + 0.001)
    }

    @Test func aShortPromptIsQuotedWhole() {
        #expect(NeuralShare.Card.quoteText("  Fix\n the   build ") == "Fix the build")
        #expect(NeuralShare.Card.quoteText("   ") == nil)
        #expect(NeuralShare.Card.quoteText(nil) == nil)
        #expect(NeuralShare.Card.quoteLineCount("short") == 1)
    }

    @Test func footerSaysWhereTheNumbersCameFrom() {
        let made = card()
        #expect(made.foot.text == "counted from the transcript")
        #expect(made.brand.text == "TAILSCODE")
        #expect(made.tag.text == "ONE TURN")
    }

    @Test func twoLooksAndEverySlotResolvesFromThePalette() {
        #expect(NeuralShare.looks.map(\.id) == [CardStyle.appID, "neural"])
        let poster = card(style: .neural)
        let app = card(style: .app)
        #expect(poster.palette.canvas == CardStyle.published(CardStyle.neural.authored!).canvas)
        #expect(poster.color(.accent) == poster.palette.accent)
        #expect(poster.palette != app.palette)
        for slot in [NeuralShare.Slot.text, .textDim, .accent, .info, .warn, .special, .raised, .rule] {
            #expect(!poster.color(slot).isEmpty)
        }
    }

    @Test func theMeterToneIsReadableOnThePosterCanvas() {
        let made = card(style: .neural)
        for meter in made.meters {
            let ratio = Contrast.ratio(made.color(meter.slot), on: made.palette.canvas) ?? 0
            #expect(ratio >= Contrast.secondary, "\(meter.zone) \(ratio)")
        }
    }
}

@Suite("Neural share head palette")
struct NeuralShareHeadTests {
    @Test("the poster look widens to a palette that carries its own colours and a danger of the app's")
    func authored() {
        let palette = NeuralShare.headPalette(style: .neural, dark: true)
        let share = CardStyle.neural.palette(dark: true)
        #expect(palette.canvas == share.canvas)
        #expect(palette.isDark)
        #expect(palette.danger.count == 7)
        #expect(palette.accent == palette.corrected().accent)
    }

    @Test("a light look is a light palette, so the head lifts its glow for it")
    func light() {
        let paper = CardStyle.all.first { $0.id == "paper" }
        #expect(paper.map { NeuralShare.headPalette(style: $0, dark: true).isDark } == false)
    }

    @Test("the app's look answers with the app's theme")
    func app() {
        let palette = NeuralShare.headPalette(style: .app, dark: true)
        #expect(palette.canvas == ThemeSelection.palette(dark: true).canvas
            || ThemeSelection.usesSystemPalette)
    }
}
