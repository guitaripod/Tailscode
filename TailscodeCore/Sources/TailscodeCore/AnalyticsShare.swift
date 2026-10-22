import Foundation

/// Everything a client needs to hand the month in numbers to another app: words for a paste,
/// a filename for a file, and a card laid out in pure geometry so three toolkits paint the same
/// picture. The numbers and every sentence come from ``UsageAnalytics``; this only arranges them
/// for leaving the app.
public struct AnalyticsShare: Sendable, Equatable {
    public let subject: String
    public let filename: String
    public let plainText: String
    public let markdown: String
    /// The full-length column with every module it has always carried: what a client that has
    /// not learned formats yet paints. ``card(_:palette:)`` makes the picture for a choice.
    public let card: Card
    public let analytics: UsageAnalytics

    public init(_ analytics: UsageAnalytics, now: Date = Date(), calendar: Calendar = .current) {
        self.analytics = analytics
        self.subject = "\(analytics.window.surfaceTitle) · \(analytics.headline)"
        self.filename = Self.filename(
            window: analytics.window, money: analytics.headline, now: now, calendar: calendar)
        self.plainText = Self.plainText(analytics)
        self.markdown = Self.markdown(analytics)
        self.card = Card(analytics: analytics)
    }

    public struct Palette: Sendable, Equatable {
        public let canvas: String
        /// Where the canvas ends at the foot of the card; the same as `canvas` for a flat one.
        public let canvasEnd: String
        public let raised: String
        public let rule: String
        public let text: String
        public let textDim: String
        public let accent: String
        public let info: String
        public let warn: String
        public let special: String
        public let onAccent: String

        public init(
            canvas: String, canvasEnd: String? = nil, raised: String, rule: String, text: String,
            textDim: String, accent: String, info: String, warn: String, special: String,
            onAccent: String
        ) {
            self.canvas = canvas
            self.canvasEnd = canvasEnd ?? canvas
            self.raised = raised
            self.rule = rule
            self.text = text
            self.textDim = textDim
            self.accent = accent
            self.info = info
            self.warn = warn
            self.special = special
            self.onAccent = onAccent
        }

        /// A palette authored from its canvas and ink alone: the raised surface and the rule
        /// are the ink let into the canvas, and ink on a fill is the canvas itself.
        public init(
            canvas: String, canvasEnd: String, text: String, textDim: String, accent: String,
            info: String, warn: String, special: String
        ) {
            self.canvas = canvas
            self.canvasEnd = canvasEnd
            self.raised = Contrast.blend(canvas, text, 0.06) ?? canvas
            self.rule = Contrast.blend(canvas, text, 0.13) ?? textDim
            self.text = text
            self.textDim = textDim
            self.accent = accent
            self.info = info
            self.warn = warn
            self.special = special
            self.onAccent = canvas
        }

        public static func current(dark: Bool) -> Palette {
            let source = ThemeSelection.usesSystemPalette
                ? AppTheme.fallback.palette(dark: dark).corrected()
                : ThemeSelection.palette(dark: dark)
            return Palette(
                canvas: source.canvas,
                canvasEnd: Contrast.blend(source.canvas, source.canvasRaised, 0.7),
                raised: source.canvasRaised, rule: source.rule,
                text: source.text, textDim: source.textDim, accent: source.accent,
                info: source.info, warn: source.warn, special: source.special,
                onAccent: source.onAccent)
        }

        public static let shareDefault = Palette(
            canvas: "#191724", canvasEnd: "#1f1b31", raised: "#1f1d2e", rule: "#26233a",
            text: "#e0def4", textDim: "#908caa", accent: "#ebbcba",
            info: "#9ccfd8", warn: "#f6c177", special: "#c4a7e7", onAccent: "#191724")
    }

    public typealias Rect = NeuralShare.Rect

    /// What the card can still say once its own sections have spoken: it already shows the
    /// models, the tools and the records, so a line that repeats one of them is a line the
    /// reader has just read. Caching is told from the hit rate rather than the brag, because
    /// the card has no tier chart to carry it, unless the tokens module is on the card and
    /// carries it itself.
    static func standouts(
        _ analytics: UsageAnalytics, drawn: Set<UsageAnalytics.Insight.Topic> = [.cache],
        includesCache: Bool = true
    ) -> [String] {
        var lines: [String] = []
        if includesCache, let cache = analytics.cacheLine { lines.append(cache) }
        lines.append(contentsOf: analytics.findings.filter { !drawn.contains($0.topic) }.map(\.text))
        return lines
    }

    public enum TrendTone: Sendable, Equatable {
        case up
        case down
        case flat
    }

    public struct DayBar: Sendable, Equatable {
        public let share: Double
        public let isToday: Bool
        public let isEmpty: Bool
        /// The tallest bar, which a tile paints in the accent: the one thing in a chart the eye
        /// is meant to land on. The full-length column marks today instead and leaves this false.
        public var isPeak: Bool = false
    }

    public struct MeterBar: Sendable, Equatable {
        public let label: String
        public let detail: String
        public let money: String?
        public let share: Double
        public let hot: Bool
    }

    public struct RecordLine: Sendable, Equatable {
        public let glyph: String
        public let title: String
        public let value: String
        public let detail: String?

        /// The dim line over the value: the record's name, and what it was set by — the
        /// conversation, the prompt — because a priciest conversation with no name is a number.
        public var caption: String {
            guard let detail, !detail.isEmpty else { return title }
            return "\(title) · \(detail)"
        }
    }

    /// The bars over time with the two dates that anchor them; thirty unlabelled columns are a
    /// texture, not a chart.
    public struct DailyChart: Sendable, Equatable {
        public let bars: [DayBar]
        public let leading: String
        public let trailing: String
    }

    /// One big number with the word for what it counts, laid out two across.
    public struct Stat: Sendable, Equatable {
        public let value: String
        public let label: String
    }

    public enum Block: Sendable, Equatable {
        case brand(String)
        case kicker(String)
        case hero(String)
        case body(String)
        case dim(String)
        case trend(String, TrendTone)
        case daily(DailyChart)
        case weekday([DayBar])
        case section(String)
        case meter(MeterBar)
        case record(RecordLine)
        case insight(String)
        case rule
        case foot(String)
        case spacer(Double)
        case stats([Stat])
    }

    /// Logical points at 1×. Clients multiply by a scale factor (2 or 3) when rasterising.
    ///
    /// A card is a canvas holding panels. Each panel is a rectangle with its own flow of blocks,
    /// laid out in the panel's own content width; the full-length format is one panel as wide as
    /// the canvas, which is the picture the card was before it had formats. A painter walks
    /// `panels` in order, fills and clips each one, and stacks its blocks from the top of the
    /// panel's content rectangle at the heights the `height(_:in:)` functions give; nothing in a
    /// painter decides where a line goes.
    public struct Card: Sendable, Equatable {
        public static let width: Double = 1080
        public static let pad: Double = 56
        public static let contentWidth: Double = width - pad * 2
        public static let dailyHeight: Double = 120
        public static let dailyBarWidth: Double = 18
        public static let weekdayHeight: Double = 56
        public static let meterTrackHeight: Double = 10
        public static let meterTrackOffset: Double = 32
        public static let corner: Double = 36
        public static let innerCorner: Double = 20

        /// The type and spacing a panel's blocks are measured in: how wide their column is, how
        /// much every size is magnified, how tall the charts and the number are. The full-length
        /// column's is ``long``; a tile of a poster has its own, chosen so its text is as large
        /// as the tile allows.
        public struct Metrics: Sendable, Equatable {
            public var contentWidth: Double
            public var scale: Double
            public var heroSize: Double
            public var dailyHeight: Double
            public var weekdayHeight: Double

            public init(
                contentWidth: Double, scale: Double = 1, heroSize: Double = Card.heroSize,
                dailyHeight: Double = Card.dailyHeight,
                weekdayHeight: Double = Card.weekdayHeight
            ) {
                self.contentWidth = contentWidth
                self.scale = scale
                self.heroSize = heroSize
                self.dailyHeight = dailyHeight
                self.weekdayHeight = weekdayHeight
            }

            public static let long = Metrics(contentWidth: Card.contentWidth)
        }

        /// A rectangle of the canvas and what is stacked in it.
        public struct Panel: Sendable, Equatable {
            public enum Surface: Sendable, Equatable {
                case bare
                case raised
            }

            public let module: ShareModule
            public let rect: Rect
            public let surface: Surface
            public let corner: Double
            public let inset: Double
            public let metrics: Metrics
            public let blocks: [Block]

            /// Where the blocks go: the rectangle less its inset. A painter clips to `rect`'s
            /// rounded shape and starts stacking at this rectangle's top-left.
            public var content: Rect {
                Rect(
                    rect.x + inset, rect.y + inset, max(0, rect.width - inset * 2),
                    max(0, rect.height - inset * 2))
            }

            public var contentHeight: Double { Card.contentHeight(blocks, in: metrics) }

            public var fits: Bool { contentHeight <= content.height + 0.5 }
        }

        /// The one line at the foot of a poster: where the numbers came from on the left, what
        /// they are on the right. The left wraps to `leftLines` lines and ends in an ellipsis
        /// rather than run under the right.
        public struct Footer: Sendable, Equatable {
            public let rect: Rect
            public let left: String
            public let right: String
            public let size: Double
            public let leftLines: Int
        }

        public let palette: Palette
        public let format: ShareFormat
        public let canvasWidth: Double
        public let height: Double
        public let panels: [Panel]
        public let footer: Footer?
        public let fit: ShareFit?

        /// Every block of every panel, in painting order; for the full-length column, its blocks.
        public var blocks: [Block] { panels.flatMap(\.blocks) }

        init(
            palette: Palette, format: ShareFormat, canvasWidth: Double, height: Double,
            panels: [Panel], footer: Footer?, fit: ShareFit?
        ) {
            self.palette = palette
            self.format = format
            self.canvasWidth = canvasWidth
            self.height = height
            self.panels = panels
            self.footer = footer
            self.fit = fit
        }

        /// The full-length column with the modules it has always had.
        public init(analytics: UsageAnalytics, palette: Palette = .shareDefault) {
            let built = Self.longBlocks(for: analytics, modules: Set(ShareFormat.long.curated))
            self.init(blocks: built, palette: palette, height: Self.measure(built))
        }

        public init(blocks: [Block], palette: Palette, height: Double) {
            let panel = Panel(
                module: .hero, rect: Rect(0, 0, Self.width, height), surface: .bare, corner: 0,
                inset: Self.pad, metrics: .long, blocks: blocks)
            self.init(
                palette: palette, format: .long, canvasWidth: Self.width, height: height,
                panels: [panel], footer: nil, fit: nil)
        }

        public func with(palette: Palette) -> Card {
            Card(
                palette: palette, format: format, canvasWidth: canvasWidth, height: height,
                panels: panels, footer: footer, fit: fit)
        }

        static func longBlocks(
            for analytics: UsageAnalytics, modules: Set<ShareModule>
        ) -> [Block] {
            var out: [Block] = [
                .brand("TAILSCODE"),
                .spacer(6),
                .kicker(analytics.window.surfaceTitle),
                .spacer(18),
                .hero(analytics.headline),
                .spacer(10),
                .dim(analytics.windowLabel),
                .spacer(6),
                .body(analytics.perDayLine),
            ]
            if modules.contains(.activity) {
                out.append(.spacer(4))
                out.append(.dim(analytics.activityLine))
            }
            if let delta = analytics.deltaLine {
                out.append(.spacer(10))
                out.append(.trend(delta, tone(analytics.trend)))
            }
            var drawnRecords = analytics.records
            if modules.contains(.daily), analytics.days.contains(where: { $0.share > 0 }),
                let first = analytics.days.first, let last = analytics.days.last
            {
                out.append(.spacer(28))
                out.append(.section(analytics.window.chartTitle))
                out.append(.spacer(14))
                out.append(
                    .daily(
                        DailyChart(
                            bars: analytics.days.map {
                                DayBar(share: $0.share, isToday: $0.isToday, isEmpty: $0.share <= 0)
                            },
                            leading: first.title,
                            trailing: last.isToday ? Localized.text("Today") : last.title)))
                if let peak = analytics.peakDay, peak.share > 0 {
                    var caption = Localized.text("Peak %@ · %@", peak.title, peak.value)
                    if let busiest = drawnRecords.first(where: { $0.id == "busiestDay" }) {
                        if let detail = busiest.detail, !detail.isEmpty {
                            caption += " · \(detail)"
                        }
                        drawnRecords.removeAll { $0.id == "busiestDay" }
                    }
                    out.append(.spacer(6))
                    out.append(.dim(caption))
                }
            }
            if modules.contains(.week), analytics.weekdays.contains(where: { $0.share > 0 }) {
                out.append(.spacer(28))
                out.append(.section(Localized.text("The week")))
                out.append(.spacer(14))
                out.append(
                    .weekday(
                        analytics.weekdays.map {
                            DayBar(share: $0.share, isToday: false, isEmpty: $0.share <= 0)
                        }))
                if let busiest = analytics.weekdays.max(by: { $0.share < $1.share }),
                    busiest.share > 0, let money = busiest.money
                {
                    out.append(.spacer(6))
                    out.append(.dim(Localized.text("Busiest on %@ · %@", busiest.label, money)))
                }
            }
            var drawnTopics: Set<UsageAnalytics.Insight.Topic> = [.cache]
            if modules.contains(.providers), !analytics.providers.isEmpty {
                out.append(
                    contentsOf: meterSection(
                        Localized.text("Providers"), analytics.providers.prefix(meterLimit)))
            }
            if modules.contains(.models), !analytics.models.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Models"), analytics.models.prefix(meterLimit)))
                drawnTopics.insert(.model)
            }
            if modules.contains(.projects), !analytics.projects.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Projects"), analytics.projects.prefix(meterLimit)))
            }
            if modules.contains(.tools), !analytics.tools.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Tools"), analytics.tools.prefix(meterLimit)))
                drawnTopics.insert(.tool)
            }
            let tokensDrawn = modules.contains(.tokens) && analytics.tiers.contains { $0.tokens > 0 }
            if tokensDrawn {
                out.append(.spacer(28))
                out.append(.section(Localized.text("Tokens")))
                for tier in tierMeters(analytics) {
                    out.append(.spacer(12))
                    out.append(.meter(tier))
                }
                if let cache = analytics.cacheLine {
                    out.append(.spacer(10))
                    out.append(.dim(cache))
                }
            }
            if modules.contains(.records) {
                let records = drawnRecords.prefix(recordLimit)
                if !records.isEmpty {
                    out.append(.spacer(28))
                    out.append(.section(Localized.text("Records")))
                    for record in records {
                        out.append(.spacer(12))
                        out.append(.record(recordLine(record)))
                        if record.id == "streak" { drawnTopics.insert(.streak) }
                        if record.id == "subagents" { drawnTopics.insert(.subagents) }
                    }
                }
            }
            if modules.contains(.insights) {
                let lines = AnalyticsShare.standouts(
                    analytics, drawn: drawnTopics, includesCache: !tokensDrawn)
                if !lines.isEmpty {
                    out.append(.spacer(28))
                    out.append(.section(Localized.text("What stands out")))
                    for line in lines.prefix(3) {
                        out.append(.spacer(10))
                        out.append(.insight(line))
                    }
                }
            }
            out.append(.spacer(28))
            out.append(.rule)
            out.append(.spacer(16))
            if modules.contains(.models), let modelsLine = analytics.modelsLine(shown: meterLimit) {
                out.append(.foot(modelsLine))
                out.append(.spacer(8))
            }
            if let coverageNote = analytics.coverageNote {
                out.append(.foot(coverageNote))
                out.append(.spacer(8))
            }
            out.append(.foot(analytics.source))
            out.append(.spacer(8))
            out.append(.foot(Localized.text("API-equivalent estimate · not a bill")))
            if !analytics.missingServers.isEmpty {
                out.append(.spacer(8))
                out.append(
                    .foot(
                        Localized.text(
                            "Not counted: %@", analytics.missingServers.joined(separator: ", "))))
            }
            return out
        }

        static func tone(_ trend: UsageAnalytics.Trend) -> TrendTone {
            switch trend {
            case .up: return .up
            case .down: return .down
            case .flat: return .flat
            }
        }

        static func recordLine(_ record: UsageAnalytics.Record) -> RecordLine {
            RecordLine(
                glyph: record.glyph, title: record.title, value: record.value,
                detail: record.detail)
        }

        /// The four token tiers as meter rows: the bar is each tier's share of what the window
        /// cost (of its tokens in an account that cost nothing), the trailing value is the money
        /// it came to or, with no money, the tokens themselves.
        static func tierMeters(_ analytics: UsageAnalytics) -> [MeterBar] {
            let tiers = analytics.tiers.filter { $0.tokens > 0 }
            let priced = tiers.contains { $0.costUSD > 0 }
            let weights = tiers.map { priced ? $0.costUSD : Double($0.tokens) }
            let peak = weights.max() ?? 0
            let prefix = analytics.totalMoney.hasPrefix("~") ? "~" : ""
            return tiers.enumerated().map { index, tier in
                MeterBar(
                    label: tier.label,
                    detail: priced ? StatusFacts.tokens(tier.tokens) : "",
                    money: priced
                        ? prefix + SessionSpend.money(tier.costUSD)
                        : StatusFacts.tokens(tier.tokens),
                    share: peak > 0 ? weights[index] / peak : 0, hot: index == 0)
            }
        }

        public static let meterLimit = 4
        public static let recordLimit = 6

        private static func meterSection<S: Sequence>(
            _ title: String, _ meters: S
        ) -> [Block] where S.Element == UsageAnalytics.Meter {
            var out: [Block] = [.spacer(28), .section(title)]
            for (index, meter) in meters.enumerated() {
                out.append(.spacer(12))
                out.append(
                    .meter(
                        MeterBar(
                            label: meter.label, detail: meter.detail, money: meter.money,
                            share: meter.share, hot: index == 0)))
            }
            return out
        }

        /// Fixed metrics so three clients land every line on the same Y without asking a toolkit
        /// for font bounds. A share card is typeset, not reflowed: a paragraph's line count is
        /// estimated once here from its length, and every client wraps it to exactly that many.
        public static func measure(_ blocks: [Block]) -> Double {
            blocks.reduce(pad) { $0 + height($1) } + pad
        }

        /// The height of a stack of blocks in a panel's own metrics, with no padding.
        public static func contentHeight(_ blocks: [Block], in metrics: Metrics) -> Double {
            blocks.reduce(0) { $0 + height($1, in: metrics) }
        }

        public static func height(_ block: Block) -> Double {
            height(block, in: .long)
        }

        public static func height(_ block: Block, in metrics: Metrics) -> Double {
            let scale = metrics.scale
            switch block {
            case .brand: return 22 * scale
            case .kicker: return 28 * scale
            case .hero: return metrics.heroSize * 88 / 84
            case .body, .dim, .trend, .insight, .foot:
                return lineHeight(fontSize(block, in: metrics), lines: lines(block, in: metrics))
            case .daily: return metrics.dailyHeight + axisHeight * scale
            case .weekday: return metrics.weekdayHeight + axisHeight * scale
            case .section: return 26 * scale
            case .meter: return 44 * scale
            case .record: return 48 * scale
            case .rule: return 1
            case .spacer(let gap): return gap
            case .stats(let stats):
                let rows = Double((stats.count + statColumns - 1) / statColumns)
                return rows * statRowHeight(scale) - statRowGap * scale
            }
        }

        /// How many lines a text block is set on. Estimated from its length against a glyph
        /// width wide enough for any of the three faces, so an estimate errs toward a line of
        /// air rather than one paragraph drawn over the next; a client truncates the last line
        /// it is given rather than growing past it.
        ///
        /// The foot is given four: it carries the models line, which names both what the list
        /// left out and what each door of the account actually did, and a fact cut off at
        /// "Aliba…" is a fact the card did not tell.
        public static func lines(_ block: Block) -> Int {
            lines(block, in: .long)
        }

        public static func lines(_ block: Block, in metrics: Metrics) -> Int {
            let (text, maximum): (String, Int) = {
                switch block {
                case .body(let text), .dim(let text): return (text, maximumLines(block))
                case .trend(let text, _): return (text, 1)
                case .insight(let text): return (insightPrefix + text, maximumLines(block))
                case .foot(let text): return (text, maximumLines(block))
                default: return ("", 1)
                }
            }()
            let capacity = metrics.contentWidth / (fontSize(block, in: metrics) * glyphWidth)
            let needed = Int((Double(text.count) / capacity).rounded(.up))
            return min(max(1, needed), maximum)
        }

        /// The most lines a text block is ever set on; a client truncates the last one.
        public static func maximumLines(_ block: Block) -> Int {
            switch block {
            case .body, .dim: return 2
            case .insight: return 3
            case .foot: return 4
            default: return 1
            }
        }

        public static func fontSize(_ block: Block) -> Double {
            fontSize(block, in: .long)
        }

        public static func fontSize(_ block: Block, in metrics: Metrics) -> Double {
            let scale = metrics.scale
            switch block {
            case .brand: return brandSize * scale
            case .kicker: return kickerSize * scale
            case .hero: return metrics.heroSize
            case .body, .trend, .insight: return bodySize * scale
            case .dim: return dimSize * scale
            case .section: return sectionSize * scale
            case .meter: return meterSize * scale
            case .record: return recordSize * scale
            case .foot: return footSize * scale
            case .stats: return statValueSize * scale
            case .daily, .weekday, .rule, .spacer: return 0
            }
        }

        /// The width of a bar in a chart and the gap after it. The full-length column's thirty
        /// bars keep their eighteen points; a narrow tile narrows them rather than letting the
        /// last ones run past its edge.
        public static func barGeometry(count: Int, in metrics: Metrics) -> (width: Double, gap: Double) {
            guard count > 0 else { return (0, 0) }
            let wanted = dailyBarWidth * metrics.scale
            let minimumGap = max(2, 3 * metrics.scale)
            let room = (metrics.contentWidth - minimumGap * Double(count - 1)) / Double(count)
            let width = max(2, min(wanted, room))
            let gap = count > 1 ? max(1, (metrics.contentWidth - width * Double(count)) / Double(count - 1)) : 0
            return (width, gap)
        }

        public static let insightPrefix = "✦  "
        public static let glyphWidth: Double = 0.56
        public static let axisHeight: Double = 22
        public static let axisSize: Double = 16
        public static let meterDetailSize: Double = 18
        public static let recordTitleSize: Double = 18
        /// Room the trailing value keeps on a meter row, so a label's detail never runs under
        /// the money.
        public static let meterValueWidth: Double = 180

        public static let brandSize: Double = 18
        public static let kickerSize: Double = 24
        public static let heroSize: Double = 84
        public static let bodySize: Double = 28
        public static let dimSize: Double = 24
        public static let sectionSize: Double = 22
        public static let meterSize: Double = 24
        public static let recordSize: Double = 24
        public static let footSize: Double = 20
        public static let statValueSize: Double = 44
        public static let statLabelSize: Double = 20
        public static let statColumns = 2
        public static let statRowGap: Double = 14

        /// The pitch of one row of stats: the number, the word under it and the gap.
        public static func statRowHeight(_ scale: Double) -> Double {
            (statValueSize * 1.15 + statLabelSize * 1.35 + statRowGap) * scale
        }

        public static func lineHeight(_ size: Double, lines: Int) -> Double {
            size * 1.28 * Double(lines)
        }
    }

    private static func filename(
        window: UsageWindow, money: String, now: Date, calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        let safeMoney = money
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return "tailscode-\(window.rawValue)-\(day)-\(safeMoney).png"
    }

    private static func plainText(_ analytics: UsageAnalytics) -> String {
        var lines: [String] = [
            analytics.window.surfaceTitle,
            analytics.headline,
            analytics.windowLabel,
            analytics.perDayLine,
            analytics.activityLine,
        ]
        if let hosted = analytics.hostedLine { lines.append(hosted) }
        if let delta = analytics.deltaLine { lines.append(delta) }
        if let peak = analytics.peakDay, peak.share > 0 {
            lines.append(
                Localized.text("Peak %@ · %@", peak.title, peak.value))
        }
        if let clock = analytics.clockLine { lines.append(clock) }
        if analytics.isLocalLed { appendLocalLines(&lines, analytics.localWork) }
        appendMeterLines(
            &lines, title: Localized.text("Providers"), meters: analytics.providers, limit: 5)
        appendMeterLines(&lines, title: Localized.text("Models"), meters: analytics.models, limit: 5)
        if !analytics.isLocalLed { appendLocalLines(&lines, analytics.localWork) }
        appendMeterLines(
            &lines, title: Localized.text("Projects"), meters: analytics.projects, limit: 5)
        appendMeterLines(&lines, title: Localized.text("Tools"), meters: analytics.tools, limit: 5)
        if !analytics.records.isEmpty {
            lines.append("")
            lines.append(Localized.text("Records"))
            for record in analytics.records {
                var row = "\(record.title): \(record.value)"
                if let detail = record.detail, !detail.isEmpty { row += " — \(detail)" }
                lines.append(row)
            }
        }
        if !analytics.insights.isEmpty {
            lines.append("")
            lines.append(Localized.text("What stands out"))
            for insight in analytics.insights { lines.append("• \(insight)") }
        }
        lines.append("")
        if let modelsLine = analytics.modelsLine { lines.append(""); lines.append(modelsLine) }
        if let coverageNote = analytics.coverageNote {
            lines.append("")
            lines.append(coverageNote)
        }
        lines.append(analytics.source)
        lines.append(Localized.text("API-equivalent estimate · not a bill"))
        if !analytics.missingServers.isEmpty {
            lines.append(
                Localized.text(
                    "Not counted: %@", analytics.missingServers.joined(separator: ", ")))
        }
        lines.append("")
        lines.append("— Tailscode")
        return lines.joined(separator: "\n")
    }

    private static func markdown(_ analytics: UsageAnalytics) -> String {
        var lines: [String] = [
            "# \(analytics.window.surfaceTitle)",
            "",
            "**\(analytics.headline)** · \(analytics.windowLabel)",
            "",
            analytics.perDayLine,
            "",
            analytics.activityLine,
        ]
        if let hosted = analytics.hostedLine {
            lines.append("")
            lines.append("_\(hosted)_")
        }
        if let delta = analytics.deltaLine {
            lines.append("")
            lines.append(delta)
        }
        if let peak = analytics.peakDay, peak.share > 0 {
            lines.append("")
            lines.append(
                Localized.text("Peak %@ · %@", peak.title, peak.value))
        }
        if analytics.isLocalLed { appendMarkdownLocal(&lines, analytics.localWork) }
        appendMarkdownMeters(
            &lines, title: Localized.text("Providers"), meters: analytics.providers)
        appendMarkdownMeters(&lines, title: Localized.text("Models"), meters: analytics.models)
        if !analytics.isLocalLed { appendMarkdownLocal(&lines, analytics.localWork) }
        appendMarkdownMeters(&lines, title: Localized.text("Projects"), meters: analytics.projects)
        appendMarkdownMeters(&lines, title: Localized.text("Tools"), meters: analytics.tools)
        if !analytics.records.isEmpty {
            lines.append("")
            lines.append("## \(Localized.text("Records"))")
            for record in analytics.records {
                var row = "- **\(record.title):** \(record.value)"
                if let detail = record.detail, !detail.isEmpty { row += " — \(detail)" }
                lines.append(row)
            }
        }
        if !analytics.insights.isEmpty {
            lines.append("")
            lines.append("## \(Localized.text("What stands out"))")
            for insight in analytics.insights { lines.append("- \(insight)") }
        }
        lines.append("")
        if let modelsLine = analytics.modelsLine { lines.append(""); lines.append(modelsLine) }
        if let coverageNote = analytics.coverageNote {
            lines.append("")
            lines.append("_\(coverageNote)_")
        }
        lines.append("_\(analytics.source)_")
        lines.append("")
        lines.append("_\(Localized.text("API-equivalent estimate · not a bill"))_")
        if !analytics.missingServers.isEmpty {
            lines.append("")
            lines.append(
                "_\(Localized.text("Not counted: %@", analytics.missingServers.joined(separator: ", ")))_"
            )
        }
        lines.append("")
        lines.append("— *Tailscode*")
        return lines.joined(separator: "\n")
    }

    private static func appendMeterLines(
        _ lines: inout [String], title: String, meters: [UsageAnalytics.Meter], limit: Int
    ) {
        guard !meters.isEmpty else { return }
        lines.append("")
        lines.append(title)
        for meter in meters.prefix(limit) {
            let money = meter.trailing.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("\(meter.label)\(money)\(detail)")
        }
    }

    /// What ran on the person's own machine, as the same stats and rows the screen draws: a
    /// pasted summary of a month spent mostly on a local GPU is about that GPU.
    private static func appendLocalLines(_ lines: inout [String], _ work: UsageAnalytics.LocalWork?) {
        guard let work else { return }
        lines.append("")
        lines.append(work.title)
        lines.append(work.headline)
        lines.append(statLine(work))
        for meter in work.models {
            let money = meter.trailing.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("\(meter.label)\(money)\(detail)")
        }
        if let caption = work.caption { lines.append(caption) }
    }

    private static func appendMarkdownLocal(
        _ lines: inout [String], _ work: UsageAnalytics.LocalWork?
    ) {
        guard let work else { return }
        lines.append("")
        lines.append("## \(work.title)")
        lines.append("")
        lines.append("**\(work.headline)**")
        lines.append("")
        lines.append(statLine(work))
        for meter in work.models {
            let money = meter.trailing.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("- **\(meter.label)**\(money)\(detail)")
        }
        if let caption = work.caption {
            lines.append("")
            lines.append("_\(caption)_")
        }
    }

    private static func statLine(_ work: UsageAnalytics.LocalWork) -> String {
        work.stats.map { stat in
            "\(stat.label) \(stat.value)" + (stat.detail.map { " \($0)" } ?? "")
        }.joined(separator: " · ")
    }

    private static func appendMarkdownMeters(
        _ lines: inout [String], title: String, meters: [UsageAnalytics.Meter]
    ) {
        guard !meters.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        for meter in meters.prefix(5) {
            let money = meter.trailing.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("- **\(meter.label)**\(money)\(detail)")
        }
    }
}
