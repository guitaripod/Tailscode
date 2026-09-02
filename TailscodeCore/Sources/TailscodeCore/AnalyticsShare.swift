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
    public let card: Card

    public init(_ analytics: UsageAnalytics, now: Date = Date(), calendar: Calendar = .current) {
        self.subject = "\(analytics.window.surfaceTitle) · \(analytics.headline)"
        self.filename = Self.filename(
            window: analytics.window, money: analytics.headline, now: now, calendar: calendar)
        self.plainText = Self.plainText(analytics)
        self.markdown = Self.markdown(analytics)
        self.card = Card(analytics: analytics)
    }

    public struct Palette: Sendable, Equatable {
        public let canvas: String
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
            canvas: String, raised: String, rule: String, text: String, textDim: String,
            accent: String, info: String, warn: String, special: String, onAccent: String
        ) {
            self.canvas = canvas
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

        public static func current(dark: Bool) -> Palette {
            let source = ThemeSelection.usesSystemPalette
                ? AppTheme.fallback.palette(dark: dark).corrected()
                : ThemeSelection.palette(dark: dark)
            return Palette(
                canvas: source.canvas, raised: source.canvasRaised, rule: source.rule,
                text: source.text, textDim: source.textDim, accent: source.accent,
                info: source.info, warn: source.warn, special: source.special,
                onAccent: source.onAccent)
        }

        public static let shareDefault = Palette(
            canvas: "#191724", raised: "#1f1d2e", rule: "#26233a",
            text: "#e0def4", textDim: "#908caa", accent: "#ebbcba",
            info: "#9ccfd8", warn: "#f6c177", special: "#c4a7e7", onAccent: "#191724")
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
    }

    /// Logical points at 1×. Clients multiply by a scale factor (2 or 3) when rasterising.
    public struct Card: Sendable, Equatable {
        public static let width: Double = 1080
        public static let pad: Double = 56
        public static let contentWidth: Double = width - pad * 2
        public static let dailyHeight: Double = 120
        public static let dailyBarWidth: Double = 18
        public static let weekdayHeight: Double = 56
        public static let meterTrackHeight: Double = 10
        public static let corner: Double = 36
        public static let innerCorner: Double = 20

        public let palette: Palette
        public let blocks: [Block]
        public let height: Double

        public init(analytics: UsageAnalytics, palette: Palette = .shareDefault) {
            self.palette = palette
            let built = Self.blocks(for: analytics)
            self.blocks = built
            self.height = Self.measure(built)
        }

        public init(blocks: [Block], palette: Palette, height: Double) {
            self.blocks = blocks
            self.palette = palette
            self.height = height
        }

        private static func blocks(for analytics: UsageAnalytics) -> [Block] {
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
                .spacer(4),
                .dim(analytics.activityLine),
            ]
            if let delta = analytics.deltaLine {
                out.append(.spacer(10))
                out.append(
                    .trend(
                        delta,
                        {
                            switch analytics.trend {
                            case .up: return .up
                            case .down: return .down
                            case .flat: return .flat
                            }
                        }()))
            }
            var drawnRecords = analytics.records
            if analytics.days.contains(where: { $0.share > 0 }),
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
            if analytics.weekdays.contains(where: { $0.share > 0 }) {
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
            if !analytics.providers.isEmpty {
                out.append(
                    contentsOf: meterSection(
                        Localized.text("Providers"), analytics.providers.prefix(meterLimit)))
            }
            if !analytics.models.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Models"), analytics.models.prefix(meterLimit)))
                drawnTopics.insert(.model)
            }
            if !analytics.projects.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Projects"), analytics.projects.prefix(meterLimit)))
            }
            if !analytics.tools.isEmpty {
                out.append(contentsOf: meterSection(
                    Localized.text("Tools"), analytics.tools.prefix(meterLimit)))
                drawnTopics.insert(.tool)
            }
            let records = drawnRecords.prefix(recordLimit)
            if !records.isEmpty {
                out.append(.spacer(28))
                out.append(.section(Localized.text("Records")))
                for record in records {
                    out.append(.spacer(12))
                    out.append(
                        .record(
                            RecordLine(
                                glyph: record.glyph, title: record.title, value: record.value,
                                detail: record.detail)))
                    if record.id == "streak" { drawnTopics.insert(.streak) }
                    if record.id == "subagents" { drawnTopics.insert(.subagents) }
                }
            }
            let standouts = standouts(analytics, drawn: drawnTopics)
            if !standouts.isEmpty {
                out.append(.spacer(28))
                out.append(.section(Localized.text("What stands out")))
                for line in standouts {
                    out.append(.spacer(10))
                    out.append(.insight(line))
                }
            }
            out.append(.spacer(28))
            out.append(.rule)
            out.append(.spacer(16))
            if let modelsLine = analytics.modelsLine(shown: meterLimit) {
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

        public static let meterLimit = 4
        public static let recordLimit = 6

        /// What the card can still say once its own sections have spoken: it already shows the
        /// models, the tools and the records, so a line that repeats one of them is a line the
        /// reader has just read. Caching is told from the hit rate rather than the brag, because
        /// the card has no tier chart to carry it.
        private static func standouts(
            _ analytics: UsageAnalytics, drawn: Set<UsageAnalytics.Insight.Topic>
        ) -> [String] {
            var lines: [String] = []
            if let cache = analytics.cacheLine { lines.append(cache) }
            lines.append(
                contentsOf: analytics.findings.filter { !drawn.contains($0.topic) }.map(\.text))
            return Array(lines.prefix(3))
        }

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

        public static func height(_ block: Block) -> Double {
            switch block {
            case .brand: return 22
            case .kicker: return 28
            case .hero: return 88
            case .body, .dim, .trend, .insight, .foot:
                return lineHeight(fontSize(block), lines: lines(block))
            case .daily: return dailyHeight + axisHeight
            case .weekday: return weekdayHeight + axisHeight
            case .section: return 26
            case .meter: return 44
            case .record: return 48
            case .rule: return 1
            case .spacer(let gap): return gap
            }
        }

        /// How many lines a text block is set on. Estimated from its length against a glyph
        /// width wide enough for any of the three faces, so an estimate errs toward a line of
        /// air rather than one paragraph drawn over the next; a client truncates the last line
        /// it is given rather than growing past it.
        public static func lines(_ block: Block) -> Int {
            let (text, maximum): (String, Int) = {
                switch block {
                case .body(let text), .dim(let text): return (text, 2)
                case .trend(let text, _): return (text, 1)
                case .insight(let text): return (insightPrefix + text, 3)
                case .foot(let text): return (text, 3)
                default: return ("", 1)
                }
            }()
            let capacity = contentWidth / (fontSize(block) * glyphWidth)
            let needed = Int((Double(text.count) / capacity).rounded(.up))
            return min(max(1, needed), maximum)
        }

        public static func fontSize(_ block: Block) -> Double {
            switch block {
            case .brand: return brandSize
            case .kicker: return kickerSize
            case .hero: return heroSize
            case .body, .trend, .insight: return bodySize
            case .dim: return dimSize
            case .section: return sectionSize
            case .meter: return meterSize
            case .record: return recordSize
            case .foot: return footSize
            case .daily, .weekday, .rule, .spacer: return 0
            }
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
        if let delta = analytics.deltaLine { lines.append(delta) }
        if let peak = analytics.peakDay, peak.costUSD > 0 {
            lines.append(
                Localized.text("Peak %@ · %@", peak.title, peak.value))
        }
        if let clock = analytics.clockLine { lines.append(clock) }
        appendMeterLines(
            &lines, title: Localized.text("Providers"), meters: analytics.providers, limit: 5)
        appendMeterLines(&lines, title: Localized.text("Models"), meters: analytics.models, limit: 5)
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
        if let delta = analytics.deltaLine {
            lines.append("")
            lines.append(delta)
        }
        if let peak = analytics.peakDay, peak.costUSD > 0 {
            lines.append("")
            lines.append(
                Localized.text("Peak %@ · %@", peak.title, peak.value))
        }
        appendMarkdownMeters(
            &lines, title: Localized.text("Providers"), meters: analytics.providers)
        appendMarkdownMeters(&lines, title: Localized.text("Models"), meters: analytics.models)
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
            let money = meter.money.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("\(meter.label)\(money)\(detail)")
        }
    }

    private static func appendMarkdownMeters(
        _ lines: inout [String], title: String, meters: [UsageAnalytics.Meter]
    ) {
        guard !meters.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        for meter in meters.prefix(5) {
            let money = meter.money.map { " · \($0)" } ?? ""
            let detail = meter.detail.isEmpty ? "" : " · \(meter.detail)"
            lines.append("- **\(meter.label)**\(money)\(detail)")
        }
    }
}
