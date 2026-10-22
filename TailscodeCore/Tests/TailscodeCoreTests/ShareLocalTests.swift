import Foundation
import Testing

@testable import TailscodeCore

@Suite("Share: work on your own machine")
struct ShareLocalTests {
    typealias Card = AnalyticsShare.Card

    private let posters: [ShareFormat] = [.post, .square, .portrait]
    private let localLed = ["localOnly", "localSessions", "localMixed", "localSpeeds"]
    private let hostedLed = [
        "rich", "oneModel", "twelveModels", "longNames", "noDaily", "tinyWindow",
        "partialCoverage", "quarter", "year",
    ]

    private func analytics(_ name: String) throws -> UsageAnalytics {
        try #require(ShareFixtures.analytics(named: name))
    }

    private func share(_ analytics: UsageAnalytics) -> AnalyticsShare {
        AnalyticsShare(analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
    }

    private func tile(
        _ module: ShareModule, of name: String, in format: ShareFormat
    ) throws -> Card.Panel {
        let account = try analytics(name)
        let selection = ShareSelection(format: format, style: .midnight, chosen: [format: [module]])
        let card = share(account).card(selection)
        return try #require(card.panels.first { $0.module == module })
    }

    private func meters(_ panel: Card.Panel) -> [AnalyticsShare.MeterBar] {
        panel.blocks.compactMap { block in
            if case .meter(let meter) = block { return meter }
            return nil
        }
    }

    private func stats(_ panel: Card.Panel) -> [AnalyticsShare.Stat] {
        panel.blocks.flatMap { block -> [AnalyticsShare.Stat] in
            if case .stats(let stats) = block { return stats }
            return []
        }
    }

    @Test("The module is on offer exactly when something ran on the person's own machine")
    func availability() throws {
        for name in localLed + hostedLed {
            let account = try analytics(name)
            #expect(
                ShareModule.local.isAvailable(in: account) == (account.localWork != nil), "\(name)")
        }
        let none = try analytics("oneModel")
        #expect(ShareModule.local.unavailableReason(in: none) == "Nothing ran on your own machine")
        let some = try analytics("rich")
        #expect(some.isLocalLed == false)
        #expect(ShareModule.local.isAvailable(in: some))
        #expect(ShareModule.local.unavailableReason(in: some) == nil)
        #expect(ShareModule.local.title == "On your own machine")
        #expect(ShareModule.local.symbolName == "desktopcomputer")
        #expect(ShareModule.selectable.contains(.local))
        let fit = ShareSelection(format: .post).fit(none)
        #expect(fit.state(of: .local) == .blocked("Nothing ran on your own machine"))
    }

    @Test("A local-led account opens on the section in every poster, and nobody else does")
    func curatedDefaults() throws {
        for name in localLed {
            let account = try analytics(name)
            #expect(account.isLocalLed, "\(name)")
            for format in ShareFormat.allCases {
                let opening = ShareSelection(format: format).fit(account)
                #expect(opening.shown.contains(.local), "\(name) \(format)")
                if let capacity = format.capacity { #expect(opening.shown.count <= capacity) }
            }
        }
        let only = try analytics("localOnly")
        #expect(ShareFormat.post.curated(for: only) == [.daily, .local, .tokens, .records])
        #expect(
            ShareFormat.portrait.curated(for: only)
                == [.activity, .daily, .week, .local, .tokens, .records])
        let mixed = try analytics("localMixed")
        #expect(ShareFormat.post.curated(for: mixed) == [.daily, .local, .models, .records])
        #expect(ShareFormat.square.curated(for: mixed) == [.daily, .local, .models, .records])
        #expect(
            ShareFormat.portrait.curated(for: mixed)
                == [.activity, .daily, .week, .local, .models, .records])
        for name in hostedLed {
            let account = try analytics(name)
            for format in ShareFormat.allCases {
                #expect(format.curated(for: account) == format.curated, "\(name) \(format)")
                #expect(
                    !ShareSelection(format: format).fit(account).shown.contains(.local),
                    "\(name) \(format)")
            }
        }
    }

    @Test("A full poster keeps the section ahead of everything but the chart when the work was local")
    func capacityOrdering() throws {
        let everything = ShareModule.selectable
        for name in localLed + hostedLed {
            let account = try analytics(name)
            let ranked = ShareModule.priority(for: account)
            #expect(Set(ranked) == Set(everything), "\(name)")
            #expect(account.isLocalLed ? ranked[1] == .local : ranked.last == .local, "\(name)")
            if ShareModule.localNamesEveryModel(in: account), account.isLocalLed {
                #expect(ranked.last == .models, "\(name) a models tile repeats the local one")
            }
            for format in ShareFormat.allCases {
                let selection = ShareSelection(format: format, chosen: [format: everything])
                let fit = selection.fit(account)
                let available = ranked.filter { $0.isAvailable(in: account) }
                guard let capacity = format.capacity else {
                    #expect(fit.dropped.isEmpty)
                    #expect(Set(fit.shown) == Set(available), "\(name) \(format)")
                    continue
                }
                #expect(
                    fit.shown == ShareSelection.canonical(Array(available.prefix(capacity))),
                    "\(name) \(format)")
                #expect(fit.shown.contains(.local) == account.isLocalLed, "\(name) \(format)")
            }
        }
    }

    @Test("Pressing the chip adds the section to a hosted-led poster that has room, and refuses when full")
    func toggling() throws {
        let account = try analytics("rich")
        var selection = ShareSelection(format: .post)
        #expect(selection.toggle(.tokens, in: account) == .removed)
        #expect(selection.toggle(.local, in: account) == .added)
        #expect(selection.fit(account).shown == [.daily, .local, .models, .records])
        #expect(selection.toggle(.tools, in: account) != .added)
    }

    @Test("The hero of a local-led card counts tokens and carries the hosted bill as its dim estimate")
    func heroShowsTheHostedLine() throws {
        let mixed = try analytics("localMixed")
        let hosted = try #require(mixed.hostedLine)
        #expect(hosted == "$62.00 of hosted spend, an estimate")
        for format in posters {
            let card = share(mixed).card(ShareSelection(format: format, style: .midnight))
            let hero = card.panels[0]
            #expect(hero.module == .hero)
            let dims = hero.blocks.compactMap { block -> String? in
                if case .dim(let text) = block { return text }
                return nil
            }
            #expect(dims.contains { $0.hasSuffix(hosted) }, "\(format)")
            #expect(dims.first?.hasPrefix("tokens · \(mixed.windowLabel)") == true, "\(format)")
            #expect(hero.fits, "\(format)")
            #expect(hero.metrics.heroSize >= 40, "\(format)")
            let money = hero.blocks.contains { block in
                if case .hero(let text) = block { return text.contains("$") }
                return false
            }
            #expect(!money)
        }
        for name in ["localOnly", "localSessions"] + hostedLed {
            let account = try analytics(name)
            for format in posters {
                let hero = share(account).card(ShareSelection(format: format, style: .midnight))
                    .panels[0]
                #expect(
                    !hero.blocks.contains { block in
                        if case .dim(let text) = block { return text.contains("hosted spend") }
                        return false
                    }, "\(name) \(format)")
            }
        }
    }

    @Test("The tile says what ran, how much, and on which model, in the words the account already has")
    func tileContents() throws {
        for format in posters {
            let panel = try tile(.local, of: "localSpeeds", in: format)
            let account = try analytics("localSpeeds")
            let work = try #require(account.localWork)
            #expect(panel.fits, "\(format)")
            #expect(panel.blocks.first == .section(work.title), "\(format)")
            let rows = meters(panel)
            #expect(rows.first?.label == "Bolt", "\(format)")
            #expect(rows.first?.money == "74 tok/s", "\(format)")
            #expect(rows.first?.hot == true)
            #expect(rows.dropFirst().allSatisfy { !$0.hot })
            #expect(rows.allSatisfy { !$0.label.contains("…") }, "\(format)")
            #expect(rows.allSatisfy { !($0.money ?? "").contains("Local") }, "\(format)")
            let first = try #require(rows.first)
            #expect(first.detail.isEmpty || first.detail.hasPrefix("8.5M tokens"), "\(format)")
            let numbers = stats(panel)
            #expect(numbers.count >= 2, "\(format)")
            #expect(numbers.first?.label == "Share of work")
            #expect(numbers.first?.value == "85%")
            #expect(numbers.allSatisfy { $0.label != "Work" })
        }
    }

    @Test("A roomy tile shows the headline, every number and every model; a cramped one gives up the last first")
    func tileGivesUpInOrder() throws {
        let account = try analytics("localSpeeds")
        let work = try #require(account.localWork)
        var heights: [(Double, Int, Int, Bool)] = []
        for budget in stride(from: 150.0, through: 700.0, by: 25.0) {
            var builder = TileBuilder(
                analytics: account, shown: [.local], budget: budget,
                metrics: Card.Metrics(contentWidth: 440, scale: 1.0))
            let blocks = builder.blocks(for: .local)
            let panel = Card.contentHeight(blocks, in: builder.metrics)
            #expect(panel <= budget, "budget \(budget)")
            let rows = blocks.filter { if case .meter = $0 { return true }; return false }.count
            let numbers = blocks.reduce(0) { total, block in
                if case .stats(let stats) = block { return total + stats.count }
                return total
            }
            let headline = blocks.contains(.dim(work.headline))
            heights.append((budget, rows, numbers, headline))
        }
        for (earlier, later) in zip(heights, heights.dropFirst()) {
            #expect(later.1 >= earlier.1, "models never come back after going")
            #expect(later.2 >= earlier.2, "numbers never come back after going")
        }
        let roomiest = try #require(heights.last)
        #expect(roomiest.1 == work.models.count)
        #expect(roomiest.2 >= 3)
        #expect(roomiest.3)
        let cramped = try #require(heights.first { $0.1 >= 1 })
        #expect(cramped.2 >= 2)
    }

    @Test("An account with one local model draws one row, and a tile with no speed has no speed")
    func oneModel() throws {
        let panel = try tile(.local, of: "localSessions", in: .square)
        let rows = meters(panel)
        #expect(rows.count == 1)
        #expect(rows[0].money == nil)
        #expect(rows[0].hot)
        #expect(panel.fits)
    }

    @Test("The full-length column carries the section for a local-led account and leaves it off for the rest")
    func longColumn() throws {
        let mixed = try analytics("localSpeeds")
        let work = try #require(mixed.localWork)
        let blocks = share(mixed).card.blocks
        #expect(blocks.contains(.section(work.title)))
        #expect(blocks.contains(.body(work.headline)))
        let labels = blocks.compactMap { block -> String? in
            if case .meter(let meter) = block { return meter.label }
            return nil
        }
        #expect(labels.contains("Bolt"))
        #expect(!blocks.contains { if case .stats = $0 { return true }; return false })
        let hosted = share(try analytics("rich")).card.blocks
        #expect(!hosted.contains(.section("On your own machine")))
        let offered = share(try analytics("rich")).card(
            ShareSelection(format: .long, style: .app, chosen: [.long: [.local]]))
        #expect(offered.blocks.contains(.section("On your own machine")))
    }

    @Test("The caption and the description tell the local story when the section is on")
    func captionAndAlt() throws {
        let mixed = try analytics("localSpeeds")
        let package = share(mixed)
        let on = ShareSelection(format: .post)
        #expect(on.fit(mixed).shown.contains(.local))
        let caption = package.caption(on)
        #expect(caption.contains("85% of it ran on my own machine"))
        #expect(AnalyticsShare.xLength(caption) <= AnalyticsShare.captionLimit)
        #expect(caption.contains("$") && caption.hasSuffix("API-equivalent estimate · not a bill"))
        let alt = package.altText(on)
        #expect(alt.contains("On your own machine"))
        #expect(alt.contains("Bolt (74 tok/s)"))
        #expect(alt.contains("$62.00 of hosted spend, an estimate"))
        #expect(alt.contains("not a bill"))
        #expect(alt.count <= AnalyticsShare.altTextLimit)
        let off = ShareSelection(format: .post, chosen: [.post: [.daily]])
        #expect(!package.caption(off).contains("my own machine"))
        #expect(!package.altText(off).contains("Bolt"))
    }

    @Test("The caption fits a post for every local account in every format, the section on or off")
    func captionBound() throws {
        for name in localLed + ["rich"] {
            let package = share(try analytics(name))
            for format in ShareFormat.allCases {
                for modules in [[ShareModule.local], ShareModule.selectable, []] {
                    let selection = ShareSelection(format: format, chosen: [format: modules])
                    let caption = package.caption(selection)
                    #expect(
                        AnalyticsShare.xLength(caption) <= AnalyticsShare.captionLimit,
                        "\(name) \(format)")
                    #expect(
                        !caption.contains("$") || caption.contains("not a bill"),
                        "\(name) \(format) a figure with no word on what it is")
                    #expect(package.altText(selection).count <= AnalyticsShare.altTextLimit)
                }
            }
        }
    }

    @Test("No poster of a local account overflows a tile, cuts a codename or loses its hero")
    func nothingOverflows() throws {
        for name in localLed {
            let account = try analytics(name)
            for format in ShareFormat.allCases {
                let selections: [[ShareModule]] = [
                    [], [.local], ShareModule.selectable, format.curated(for: account),
                    [.local, .models], [.daily, .local, .models, .records],
                ]
                for modules in selections {
                    let selection = ShareSelection(
                        format: format, style: .midnight, chosen: [format: modules])
                    let card = share(account).card(selection)
                    for panel in card.panels {
                        #expect(panel.fits, "\(name) \(format) \(panel.module)")
                        for bar in meters(panel) where panel.module == .local {
                            #expect(!bar.label.contains("…"), "\(name) \(format) \(bar.label)")
                        }
                    }
                    if format == .long {
                        #expect(abs(card.height - Card.measure(card.blocks)) < 0.01)
                    }
                }
            }
        }
    }
}

@Suite("Share: the week's letters and the per-day sentence")
struct ShareLabelTests {
    private func analytics(_ name: String) throws -> UsageAnalytics {
        try #require(ShareFixtures.analytics(named: name))
    }

    private func calendar(_ identifier: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: identifier)
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    @Test("The weekday letters are the calendar's, Monday first, in any language and week start")
    func initials() {
        #expect(
            UsageAnalytics.weekdayInitials(calendar: calendar("en_US"))
                == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(
            UsageAnalytics.weekdayInitials(calendar: calendar("en_US", firstWeekday: 1))
                == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(
            UsageAnalytics.weekdayInitials(calendar: calendar("de_DE"))
                == ["M", "D", "M", "D", "F", "S", "S"])
        #expect(
            UsageAnalytics.weekdayInitials(calendar: calendar("ja_JP"))
                == ["月", "火", "水", "木", "金", "土", "日"])
    }

    @Test("Every week chart carries seven letters in its blocks, the poster tile and the column alike")
    func blocksCarryTheLetters() throws {
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        for fixture in ShareFixtures.all() {
            #expect(fixture.analytics.weekdayInitials == letters, "\(fixture.name)")
            let package = AnalyticsShare(
                fixture.analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
            for format in ShareFormat.allCases {
                let selection = ShareSelection(
                    format: format, style: .midnight, chosen: [format: [.week]])
                let card = package.card(selection)
                for block in card.blocks {
                    if case .weekday(let bars) = block {
                        #expect(bars.map(\.label) == letters, "\(fixture.name) \(format)")
                    }
                }
            }
        }
    }

    @Test("A rate over one day is singular and a rate over none is not a sentence")
    func perDay() {
        #expect(
            UsageAnalytics.perDay(rate: "$5.00", activeDays: 1, today: nil)
                == "$5.00 a day, over 1 active day")
        #expect(
            UsageAnalytics.perDay(rate: "$5.00", activeDays: 2, today: nil)
                == "$5.00 a day, over 2 active days")
        #expect(
            UsageAnalytics.perDay(rate: "$5.00", activeDays: 1, today: "$7.00")
                == "$5.00 a day, over 1 active day · today $7.00")
        #expect(UsageAnalytics.perDay(rate: "$0.00", activeDays: 0, today: nil) == nil)
        #expect(UsageAnalytics.perDay(rate: "$0.00", activeDays: 0, today: "$1.00") == nil)
    }

    @Test("A week with one active day and an account with no daily rows read honestly everywhere")
    func readsHonestly() throws {
        let tiny = try analytics("tinyWindow")
        let line = try #require(tiny.perDayLine)
        #expect(line.contains("over 1 active day"))
        #expect(!line.contains("1 active days"))
        let bare = try analytics("noDaily")
        #expect(bare.perDayLine == nil)
        let package = AnalyticsShare(bare, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
        #expect(!package.plainText.contains("active day"))
        #expect(!package.markdown.contains("active day"))
        for format in ShareFormat.allCases {
            let card = package.card(ShareSelection(format: format, style: .midnight))
            let spoken = card.blocks.compactMap { block -> String? in
                switch block {
                case .body(let text), .dim(let text): return text
                default: return nil
                }
            }
            #expect(!spoken.contains { $0.contains("active day") }, "\(format)")
            #expect(!package.altText(ShareSelection(format: format)).contains("active day"))
        }
    }
}
