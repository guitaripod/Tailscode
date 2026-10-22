import Foundation
import Testing
@testable import TailscodeCore

@Suite("Share layout")
struct ShareLayoutTests {
    typealias Card = AnalyticsShare.Card

    private func share(_ analytics: UsageAnalytics) -> AnalyticsShare {
        AnalyticsShare(analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
    }

    private func cards(for format: ShareFormat) -> [(String, Card)] {
        var out: [(String, Card)] = []
        for fixture in ShareFixtures.all() {
            let package = share(fixture.analytics)
            for (name, modules) in ShareTestSupport.allSelections {
                var selection = ShareSelection(format: format, style: .midnight)
                selection = ShareSelection(
                    format: format, style: .midnight, chosen: [format: modules])
                out.append(("\(fixture.name)/\(name)", package.card(selection)))
            }
            out.append(
                (
                    "\(fixture.name)/curated",
                    package.card(ShareSelection(format: format, style: .midnight))
                ))
        }
        return out
    }

    @Test("The full-length format reproduces the old card, block for block and point for point")
    func longReproducesTheOldCard() throws {
        let golden: [(String, Int, Double, UInt64)] = [
            ("rich", 87, 2566.28, 16531550103546521188),
            ("oneModel", 67, 2008.28, 16054255526380622137),
            ("twelveModels", 83, 2433.88, 16136486078972869222),
            ("longNames", 81, 2398.28, 10786998483671902042),
            ("noDaily", 65, 1851.0, 13889980715033891329),
            ("localOnly", 67, 1974.6, 3167643613813908979),
            ("tinyWindow", 81, 2394.28, 7350596591293990516),
            ("partialCoverage", 93, 2692.68, 4610502490482796064),
            ("quarter", 87, 2566.28, 4762300423976403436),
            ("year", 87, 2566.28, 6934635237041340523),
            ("localSessions", 47, 1423.96, 3960120816126441618),
        ]
        for (name, count, height, hash) in golden {
            let analytics = try #require(ShareFixtures.analytics(named: name))
            let package = share(analytics)
            let print = ShareTestSupport.fingerprint(package.card.blocks)
            #expect(print.count == count, "\(name) block count")
            #expect(print.hash == hash, "\(name) blocks changed")
            #expect(abs(package.card.height - height) < 0.01, "\(name) height")
            var legacy = ShareSelection(format: .long, style: .app)
            legacy = ShareSelection(
                format: .long, style: .app, chosen: [.long: ShareFormat.long.curated])
            let chosen = package.card(legacy)
            #expect(chosen.blocks == package.card.blocks, "\(name) selection card")
            #expect(chosen.panels.count == 1)
            #expect(chosen.panels[0].metrics == .long)
        }
    }

    @Test("The long format draws exactly the modules chosen")
    func longHonoursTheSelection() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "rich"))
        let package = share(analytics)
        let selection = ShareSelection(format: .long, style: .app, chosen: [.long: [.models]])
        let blocks = package.card(selection).blocks
        #expect(blocks.contains { if case .meter = $0 { return true }; return false })
        #expect(!blocks.contains { if case .daily = $0 { return true }; return false })
        #expect(!blocks.contains { if case .weekday = $0 { return true }; return false })
        #expect(!blocks.contains { if case .record = $0 { return true }; return false })
        #expect(blocks.contains { if case .hero = $0 { return true }; return false })
        let tokens = package.card(
            ShareSelection(format: .long, style: .app, chosen: [.long: [.tokens]]))
        let tierRows = tokens.blocks.filter { if case .meter = $0 { return true }; return false }
        #expect(tierRows.count == analytics.tiers.filter { $0.tokens > 0 }.count)
    }

    @Test("Every format has the canvas the brief gives it")
    func canvases() throws {
        let package = share(try #require(ShareFixtures.analytics(named: "rich")))
        let sizes: [ShareFormat: (Double, Double)] = [
            .post: (1600, 900), .square: (1080, 1080), .portrait: (1080, 1350),
        ]
        for (format, size) in sizes {
            let card = package.card(ShareSelection(format: format, style: .midnight))
            #expect(card.canvasWidth == size.0)
            #expect(card.height == size.1)
        }
        let long = package.card(ShareSelection(format: .long, style: .midnight))
        #expect(long.canvasWidth == 1080)
        #expect(long.height > 1500)
    }

    @Test("No panel of any account in any format holds more than it can show")
    func nothingOverflowsAPanel() {
        for format in ShareFormat.allCases {
            for (name, card) in cards(for: format) {
                for panel in card.panels {
                    #expect(
                        panel.fits,
                        "\(format) \(name) \(panel.module): \(panel.contentHeight) > \(panel.content.height)")
                }
                if format == .long {
                    #expect(abs(card.height - Card.measure(card.blocks)) < 0.01)
                }
            }
        }
    }

    @Test("Panels sit inside the canvas, never overlap, and leave the footer alone")
    func geometry() {
        for format in [ShareFormat.post, .square, .portrait] {
            for (name, card) in cards(for: format) {
                let footer = try! #require(card.footer)
                #expect(footer.rect.maxY <= card.height + 0.01, "\(name) footer")
                #expect(footer.rect.x >= 0 && footer.rect.maxX <= card.canvasWidth)
                #expect(footer.size >= 18)
                #expect(footer.leftLines >= 1 && footer.leftLines <= 2)
                for (index, panel) in card.panels.enumerated() {
                    let rect = panel.rect
                    #expect(rect.x >= 0 && rect.y >= 0, "\(name) origin")
                    #expect(rect.maxX <= card.canvasWidth + 0.01, "\(name) right edge")
                    #expect(rect.maxY <= footer.rect.y + 0.01, "\(name) \(panel.module) over footer")
                    for other in card.panels[(index + 1)...] {
                        let apart =
                            rect.maxX <= other.rect.x + 0.01 || other.rect.maxX <= rect.x + 0.01
                            || rect.maxY <= other.rect.y + 0.01 || other.rect.maxY <= rect.y + 0.01
                        #expect(apart, "\(name) \(panel.module) overlaps \(other.module)")
                    }
                }
            }
        }
    }

    @Test("Every tile is at least as big as its module's footprint, and the hero is the only big type")
    func footprintsAndType() {
        for format in [ShareFormat.post, .square, .portrait] {
            for (name, card) in cards(for: format) {
                for panel in card.panels {
                    if panel.module != .hero {
                        let need = panel.module.footprint(in: format)
                        #expect(panel.rect.width >= need.width, "\(format) \(name) \(panel.module) width")
                        #expect(panel.rect.height >= need.height, "\(format) \(name) \(panel.module) height")
                    }
                    for block in panel.blocks {
                        if case .hero = block {
                            #expect(panel.module == .hero)
                            #expect(panel.metrics.heroSize <= 150)
                        } else {
                            #expect(Card.fontSize(block, in: panel.metrics) <= 100)
                        }
                    }
                }
            }
        }
    }

    @Test("The headline number fits its panel's width on every account")
    func heroFits() {
        for format in [ShareFormat.post, .square, .portrait] {
            for (name, card) in cards(for: format) {
                let panel = card.panels[0]
                guard case .hero(let number)? = panel.blocks.first(where: {
                    if case .hero = $0 { return true }
                    return false
                }) else {
                    Issue.record("\(name) has no hero")
                    continue
                }
                let width = Double(number.count) * panel.metrics.heroSize * PosterPlan.digitWidth
                #expect(width <= panel.content.width + 0.5, "\(format) \(name) \(number)")
                #expect(panel.metrics.heroSize >= 40)
            }
        }
    }

    @Test("A single line of text never outgrows the width it is given")
    func singleLinesFit() {
        for format in [ShareFormat.post, .square, .portrait] {
            for (name, card) in cards(for: format) {
                for panel in card.panels {
                    let width = panel.content.width
                    for block in panel.blocks {
                        switch block {
                        case .meter(let meter):
                            let size = Card.meterSize * panel.metrics.scale
                            let money = Card.estimatedWidth(meter.money ?? "", size: size)
                            #expect(
                                Card.estimatedWidth(meter.label, size: size) + money <= width,
                                "\(format) \(name) label \(meter.label)")
                            if !meter.detail.isEmpty {
                                let detail = Card.estimatedWidth(
                                    meter.detail, size: Card.meterDetailSize * panel.metrics.scale)
                                #expect(
                                    Card.estimatedWidth(meter.label, size: size) + detail + money <= width,
                                    "\(format) \(name) detail \(meter.detail)")
                            }
                        case .record(let record):
                            let size = Card.recordTitleSize * panel.metrics.scale
                            #expect(
                                Card.estimatedWidth(record.caption, size: size) <= width * 2 + size,
                                "\(format) \(name) record \(record.title)")
                        case .kicker(let text):
                            #expect(
                                Card.estimatedWidth(text, size: Card.fontSize(block, in: panel.metrics))
                                    <= width, "\(format) \(name) kicker")
                        default: break
                        }
                    }
                }
            }
        }
    }

    @Test("A meter section gives up rows, not text: the first rows stay whole")
    func metersDropRows() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "twelveModels"))
        let package = share(analytics)
        var rowCounts: [Int] = []
        for format in [ShareFormat.post, .square, .portrait] {
            let selection = ShareSelection(format: format, style: .midnight, chosen: [format: [.models]])
            let card = package.card(selection)
            let models = try #require(card.panels.first { $0.module == .models })
            let rows = models.blocks.compactMap { block -> AnalyticsShare.MeterBar? in
                if case .meter(let meter) = block { return meter }
                return nil
            }
            rowCounts.append(rows.count)
            #expect(rows.count >= 3)
            #expect(rows.count <= 8)
            #expect(rows.first?.hot == true)
            #expect(rows.dropFirst().allSatisfy { !$0.hot })
            #expect(models.fits)
        }
        #expect(Set(rowCounts).count >= 1)
    }

    @Test("One tile fills its space, two stack, three are one wide and two, four are a grid")
    func packing() {
        let area = AnalyticsShare.Rect(0, 0, 1000, 800)
        let one = PosterPlan.grid(count: 1, in: area, gap: 20)
        #expect(one == [area])
        let two = PosterPlan.grid(count: 2, in: area, gap: 20)
        #expect(two.count == 2 && two[0].width == 1000 && two[1].y > two[0].maxY)
        let three = PosterPlan.grid(count: 3, in: area, gap: 20)
        #expect(three[0].width == 1000 && three[1].width == 490 && three[2].x > three[1].x)
        let four = PosterPlan.grid(count: 4, in: area, gap: 20)
        #expect(four.allSatisfy { $0.width == 490 && $0.height == 390 })
        let five = PosterPlan.grid(count: 5, in: area, gap: 20)
        #expect(five.count == 5 && five[0].width == 1000)
        let six = PosterPlan.grid(count: 6, in: area, gap: 20)
        #expect(six.count == 6 && Set(six.map(\.y)).count == 3)
    }

    @Test("A poster says where its numbers came from, honestly, in its footer")
    func footerIsHonest() throws {
        let coarse = try #require(ShareFixtures.analytics(named: "partialCoverage"))
        let card = share(coarse).card(ShareSelection(format: .post, style: .midnight))
        let footer = try #require(card.footer)
        #expect(footer.right == "API-equivalent estimate · not a bill")
        #expect(footer.left.contains("laptop · opencode"))
        #expect(footer.left.contains("Not counted: old-mac"))
        #expect(footer.left.contains("across 2 machines"))
        let plain = try #require(ShareFixtures.analytics(named: "rich"))
        let simple = try #require(share(plain).card(ShareSelection(format: .post, style: .midnight)).footer)
        #expect(simple.left == plain.source)
        #expect(simple.leftLines == 1)
    }

    @Test("Big numbers are the account's own: a local-led account's hero is the count, with its unit beside the window")
    func localHeadline() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "localOnly"))
        let card = share(analytics).card(ShareSelection(format: .post, style: .midnight))
        let blocks = card.panels[0].blocks
        let hero = blocks.compactMap { block -> String? in
            if case .hero(let text) = block { return text }
            return nil
        }.first
        #expect(hero == String(analytics.headline.dropLast(" tokens".count)))
        let label = blocks.compactMap { block -> String? in
            if case .dim(let text) = block { return text }
            return nil
        }.first
        #expect(label == "tokens · \(analytics.windowLabel)")
    }

    @Test("The activity tile reads its numbers out of the activity line in any language")
    func activityStats() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "rich"))
        let selection = ShareSelection(format: .portrait, style: .midnight, chosen: [.portrait: [.activity]])
        let card = share(analytics).card(selection)
        let tile = try #require(card.panels.first { $0.module == .activity })
        guard case .stats(let stats)? = tile.blocks.first(where: {
            if case .stats = $0 { return true }
            return false
        }) else {
            Issue.record("no stats")
            return
        }
        #expect(stats.map(\.label) == ["turns", "conversations", "tool calls", "tokens"])
        #expect(analytics.activityLine.contains(stats[0].value))
    }

    @Test("The peak bar and the lead meter are the only accents in a tile")
    func oneAccentPerTile() throws {
        let analytics = try #require(ShareFixtures.analytics(named: "rich"))
        let selection = ShareSelection(
            format: .post, style: .midnight, chosen: [.post: [.daily, .models, .tools, .tokens]])
        let card = share(analytics).card(selection)
        for panel in card.panels where panel.module != .hero {
            var accents = 0
            for block in panel.blocks {
                switch block {
                case .daily(let chart):
                    accents += chart.bars.filter { $0.isPeak || $0.isToday }.count
                case .meter(let meter): accents += meter.hot ? 1 : 0
                default: break
                }
            }
            #expect(accents == 1, "\(panel.module) has \(accents) accents")
        }
    }

    @Test("Bars are narrowed to their tile and never run past its edge")
    func barsStayInside() {
        let narrow = Card.Metrics(contentWidth: 391, scale: 1.2)
        let (width, gap) = Card.barGeometry(count: 30, in: narrow)
        #expect(width * 30 + gap * 29 <= 391.5)
        #expect(width >= 2)
        let wide = Card.barGeometry(count: 30, in: .long)
        #expect(wide.width == 18)
    }
}

@Suite("Share look")
struct ShareLookTests {
    @Test("Every look reads on the tiles as well as on the canvas")
    func looksReadOnTiles() {
        for style in CardStyle.all where style.authored != nil {
            let palette = style.palette(dark: true)
            #expect(Contrast.ratio(palette.text, on: palette.raised) ?? 0 >= 4.5, "\(style.id) text")
            #expect(Contrast.ratio(palette.textDim, on: palette.raised) ?? 0 >= 4.5, "\(style.id) dim")
            for slot in [palette.accent, palette.info, palette.warn, palette.special] {
                #expect(Contrast.ratio(slot, on: palette.raised) ?? 0 >= 3, "\(style.id) \(slot)")
            }
        }
    }

    @Test("A poster opens in Aurora, the column in the app's look, and a stored choice wins")
    func defaults() throws {
        #expect(CardStyleSelection.defaultStyle(for: .post).id == "aurora")
        #expect(CardStyleSelection.defaultStyle(for: .square).id == "aurora")
        #expect(CardStyleSelection.defaultStyle(for: .portrait).id == "aurora")
        #expect(CardStyleSelection.defaultStyle(for: .long).id == CardStyle.appID)
        let suite = try #require(UserDefaults(suiteName: "share-look-\(UUID().uuidString)"))
        #expect(CardStyleSelection.current(for: .post, defaults: suite).id == "aurora")
        suite.set("paper", forKey: CardStyleSelection.storageKey)
        #expect(CardStyleSelection.current(for: .post, defaults: suite).id == "paper")
        #expect(CardStyleSelection.current(for: .long, defaults: suite).id == "paper")
        suite.set("no-such-look", forKey: CardStyleSelection.storageKey)
        #expect(CardStyleSelection.current(for: .post, defaults: suite).id == "aurora")
    }

    @Test("The poster default clears a high bar for its accent and its ink on every ground it sits on")
    func posterDefaultReads() {
        let style = CardStyleSelection.defaultStyle(for: .post)
        let palette = style.palette(dark: true)
        for ground in [palette.canvas, palette.canvasEnd, palette.raised] {
            #expect(Contrast.ratio(palette.accent, on: ground) ?? 0 >= 7)
            #expect(Contrast.ratio(palette.text, on: ground) ?? 0 >= 7)
            #expect(Contrast.ratio(palette.textDim, on: ground) ?? 0 >= 4.5)
        }
    }
}
