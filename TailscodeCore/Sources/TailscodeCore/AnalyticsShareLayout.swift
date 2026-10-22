import Foundation

extension AnalyticsShare {
    /// The picture for a choice: the format's canvas, the headline in its hero panel, the
    /// modules the choice holds in tiles, and the footer that says what the numbers are. The
    /// full-length format is the column it always was, made of the same blocks, with only the
    /// modules chosen.
    public func card(_ selection: ShareSelection, dark: Bool = true) -> Card {
        Card(analytics: analytics, selection: selection, palette: selection.style.palette(dark: dark))
    }
}

extension AnalyticsShare.Card {
    public init(analytics: UsageAnalytics, selection: ShareSelection, palette: AnalyticsShare.Palette) {
        let fit = selection.fit(analytics)
        if selection.format == .long {
            let blocks = Self.longBlocks(for: analytics, modules: Set(fit.shown))
            let height = Self.measure(blocks)
            let panel = Panel(
                module: .hero, rect: AnalyticsShare.Rect(0, 0, Self.width, height), surface: .bare, corner: 0,
                inset: Self.pad, metrics: .long, blocks: blocks)
            self.init(
                palette: palette, format: .long, canvasWidth: Self.width, height: height,
                panels: [panel], footer: nil, fit: fit)
            return
        }
        let plan = PosterPlan(format: selection.format, analytics: analytics, modules: fit.shown)
        self.init(
            palette: palette, format: selection.format, canvasWidth: selection.format.canvasWidth,
            height: plan.height, panels: plan.panels, footer: plan.footer, fit: fit)
    }

    /// An estimate of how wide a run of text is, in points, which is how a tile decides what to
    /// cut before a toolkit is asked anything.
    static func estimatedWidth(_ text: String, size: Double) -> Double {
        Double(text.count) * size * glyphWidth
    }

    /// Text cut with an ellipsis to the width it will be given, at the same estimate every
    /// client uses, so one label is shortened to the same letter on every desk.
    static func truncated(_ text: String, toWidth width: Double, size: Double) -> String {
        let capacity = Int(width / (size * glyphWidth))
        guard text.count > capacity else { return text }
        guard capacity > 1 else { return capacity == 1 ? "…" : "" }
        return String(text.prefix(capacity - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Splits a rendered `"%@ tokens"`-style phrase into its number and the words around it,
    /// by rendering the phrase's own format with a marker and cutting the marker out. It works
    /// in any language the phrase is translated into, whichever side of the number the words
    /// fall on.
    static func split(_ text: String, format: String) -> (value: String, label: String)? {
        let marker = "\u{1}"
        let rendered = Localized.text(format, marker)
        guard let range = rendered.range(of: marker) else { return nil }
        let prefix = String(rendered[..<range.lowerBound])
        let suffix = String(rendered[range.upperBound...])
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
            text.count > prefix.count + suffix.count
        else { return nil }
        let value = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        let label = (prefix + suffix).trimmingCharacters(in: .whitespaces)
        return (value, label)
    }
}

/// Everything a poster-shaped format decides: where the panels go, what the hero says and how
/// each module is cut to the tile it was given. Geometry is a function of the format alone, and
/// content is a function of the tile, so a card is the same on every desk and a test can walk
/// every account through every format.
struct PosterPlan {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block
    typealias Rect = AnalyticsShare.Rect

    struct Geometry {
        let margin: Double
        let gap: Double
        let heroShare: Double?
        let bandHeight: Double
        let inset: Double
        let corner: Double
        let tileScale: Double
        let heroScale: Double
        let heroMaximum: Double

        static func of(_ format: ShareFormat) -> Geometry {
            switch format {
            case .post:
                return Geometry(
                    margin: 44, gap: 22, heroShare: 0.38, bandHeight: 0, inset: 28, corner: 28,
                    tileScale: 1.2, heroScale: 1.1, heroMaximum: 150)
            case .square:
                return Geometry(
                    margin: 40, gap: 20, heroShare: nil, bandHeight: 330, inset: 24, corner: 24,
                    tileScale: 1.0, heroScale: 1.0, heroMaximum: 130)
            case .portrait, .long:
                return Geometry(
                    margin: 40, gap: 20, heroShare: nil, bandHeight: 400, inset: 24, corner: 24,
                    tileScale: 1.0, heroScale: 1.05, heroMaximum: 150)
            }
        }
    }

    static let footerSize: Double = 20
    static let footerGap: Double = 20
    static let footerColumnGap: Double = 32
    static let digitWidth: Double = 0.62

    let analytics: UsageAnalytics
    let format: ShareFormat
    let geometry: Geometry
    let height: Double
    let panels: [Card.Panel]
    let footer: Card.Footer

    init(format: ShareFormat, analytics: UsageAnalytics, modules: [ShareModule]) {
        self.analytics = analytics
        self.format = format
        let geometry = Geometry.of(format)
        self.geometry = geometry
        let width = format.canvasWidth
        let height = format.canvasHeight ?? 1080
        self.height = height

        let footer = Self.footer(analytics, width: width, height: height, geometry: geometry)
        self.footer = footer
        let top = geometry.margin
        let bottom = footer.rect.y - Self.footerGap
        let region = Rect(geometry.margin, top, width - geometry.margin * 2, bottom - top)

        var panels: [Card.Panel] = []
        let tileRects: [Rect]
        let heroRect: Rect
        if modules.isEmpty {
            heroRect = region
            tileRects = []
        } else if let share = geometry.heroShare {
            let heroWidth = ((region.width - geometry.gap) * share).rounded()
            heroRect = Rect(region.x, region.y, heroWidth, region.height)
            let side = Rect(
                region.x + heroWidth + geometry.gap, region.y,
                region.width - heroWidth - geometry.gap, region.height)
            tileRects = Self.grid(count: modules.count, in: side, gap: geometry.gap)
        } else {
            heroRect = Rect(region.x, region.y, region.width, geometry.bandHeight)
            let body = Rect(
                region.x, region.y + geometry.bandHeight + geometry.gap, region.width,
                region.height - geometry.bandHeight - geometry.gap)
            tileRects = Self.grid(count: modules.count, in: body, gap: geometry.gap)
        }
        panels.append(Self.heroPanel(analytics, rect: heroRect, geometry: geometry))
        for (module, rect) in zip(modules, tileRects) {
            panels.append(Self.tilePanel(module, rect: rect, analytics: analytics, modules: modules, geometry: geometry))
        }
        self.panels = panels
    }

    static func grid(count: Int, in area: Rect, gap: Double) -> [Rect] {
        guard count > 0 else { return [] }
        let rows: [Int]
        switch count {
        case 1: rows = [1]
        case 2: rows = [1, 1]
        default:
            rows = count % 2 == 1 ? [1] + [Int](repeating: 2, count: count / 2) : [Int](repeating: 2, count: count / 2)
        }
        let rowHeight = (area.height - gap * Double(rows.count - 1)) / Double(rows.count)
        var out: [Rect] = []
        var y = area.y
        for columns in rows {
            let cellWidth = (area.width - gap * Double(columns - 1)) / Double(columns)
            for column in 0..<columns {
                out.append(Rect(area.x + Double(column) * (cellWidth + gap), y, cellWidth, rowHeight))
            }
            y += rowHeight + gap
        }
        return out
    }

    static func footer(
        _ analytics: UsageAnalytics, width: Double, height: Double, geometry: Geometry
    ) -> Card.Footer {
        let right = Localized.text("API-equivalent estimate · not a bill")
        var notes: [String] = []
        if let coverage = analytics.coverageNote { notes.append(coverage) }
        notes.append(analytics.source)
        if !analytics.missingServers.isEmpty {
            notes.append(
                Localized.text("Not counted: %@", analytics.missingServers.joined(separator: ", ")))
        }
        let left = notes.joined(separator: " · ")
        let total = width - geometry.margin * 2
        let rightWidth = Card.estimatedWidth(right, size: footerSize)
        let room = max(1, total - rightWidth - footerColumnGap)
        let needed = Int((Card.estimatedWidth(left, size: footerSize) / room).rounded(.up))
        let lines = min(max(1, needed), 2)
        let rectHeight = Card.lineHeight(footerSize, lines: lines)
        return Card.Footer(
            rect: Rect(geometry.margin, height - geometry.margin - rectHeight, total, rectHeight),
            left: left, right: right, size: footerSize, leftLines: lines)
    }

    static func heroPanel(
        _ analytics: UsageAnalytics, rect: Rect, geometry: Geometry
    ) -> Card.Panel {
        var metrics = Card.Metrics(contentWidth: rect.width, scale: geometry.heroScale)
        let parts = Card.split(analytics.headline, format: "%@ tokens")
        let number = parts?.value ?? analytics.headline
        let unit = parts?.label
        let label = [unit, analytics.windowLabel].compactMap { $0 }.joined(separator: " · ")

        let brand: [Block] = [.brand("TAILSCODE"), .spacer(12 * geometry.heroScale)]
        var cluster: [Block] = [
            .kicker(analytics.window.surfaceTitle), .spacer(14 * geometry.heroScale), .hero(number),
            .spacer(16 * geometry.heroScale), .dim(label),
        ]
        if let delta = analytics.deltaLine {
            cluster.append(.spacer(16 * geometry.heroScale))
            cluster.append(.trend(delta, Card.tone(analytics.trend)))
        }
        cluster.append(.spacer(8 * geometry.heroScale))
        cluster.append(.body(analytics.perDayLine))

        let maximum = geometry.heroMaximum
        metrics.heroSize = 60
        let others = Card.contentHeight(brand, in: metrics)
            + Card.contentHeight(cluster.filter { if case .hero = $0 { return false }; return true }, in: metrics)
        let byWidth = rect.width / (Double(number.count) * digitWidth)
        let byHeight = (rect.height - others) / (88.0 / 84.0)
        metrics.heroSize = max(40, min(maximum, byWidth, byHeight).rounded(.down))

        let used = Card.contentHeight(brand + cluster, in: metrics)
        let slack = max(0, rect.height - used)
        let lead: [Block] = slack > 0 ? [.spacer((slack * 0.42).rounded())] : []
        return Card.Panel(
            module: .hero, rect: rect, surface: .bare, corner: 0, inset: 0, metrics: metrics,
            blocks: brand + lead + cluster)
    }

    static func tilePanel(
        _ module: ShareModule, rect: Rect, analytics: UsageAnalytics, modules: [ShareModule],
        geometry: Geometry
    ) -> Card.Panel {
        let metrics = Card.Metrics(
            contentWidth: rect.width - geometry.inset * 2, scale: geometry.tileScale)
        let budget = rect.height - geometry.inset * 2
        var builder = TileBuilder(
            analytics: analytics, shown: modules, budget: budget, metrics: metrics)
        let blocks = builder.blocks(for: module)
        return Card.Panel(
            module: module, rect: rect, surface: .raised, corner: geometry.corner,
            inset: geometry.inset, metrics: builder.metrics, blocks: blocks)
    }
}

/// Cuts one module to the tile it has. The rule is the same for all of them: the title always
/// stays; rows, lines and captions are added while the next one still fits the tile's height,
/// so a module gives up its last rows before any text is clipped; and a chart takes whatever
/// height the text leaves. A tile never overflows because nothing is added that does not fit.
struct TileBuilder {
    typealias Card = AnalyticsShare.Card
    typealias Block = AnalyticsShare.Block

    let analytics: UsageAnalytics
    let shown: [ShareModule]
    let budget: Double
    var metrics: Card.Metrics

    private var scale: Double { metrics.scale }
    private var width: Double { metrics.contentWidth }
    private var rowGap: Double { 10 * scale }

    mutating func blocks(for module: ShareModule) -> [Block] {
        switch module {
        case .hero: return []
        case .activity: return activity()
        case .daily: return daily()
        case .week: return week()
        case .models:
            return meters(
                Localized.text("Models"), analytics.models.map(meterBar),
                caption: analytics.modelsLine(shown: Card.meterLimit))
        case .providers:
            return meters(Localized.text("Providers"), analytics.providers.map(meterBar))
        case .projects:
            return meters(Localized.text("Projects"), analytics.projects.map(meterBar))
        case .tools:
            return meters(
                Localized.text("Tools"), analytics.tools.map(meterBar), caption: analytics.toolsLine)
        case .tokens: return tokens()
        case .records: return records()
        case .insights: return insights()
        }
    }

    private func title(_ text: String) -> [Block] {
        [.section(text), .spacer(12 * scale)]
    }

    private var titleHeight: Double { 38 * scale }

    private func height(_ blocks: [Block]) -> Double {
        Card.contentHeight(blocks, in: metrics)
    }

    /// A meter row as a tile draws it: the label takes the room the trailing value leaves it,
    /// and the detail is whatever whole phrases of it still fit after both, cut at a separator and
    /// never mid-word, or nothing at all.
    private func meterBar(_ meter: UsageAnalytics.Meter) -> AnalyticsShare.MeterBar {
        let labelSize = Card.meterSize * scale
        let moneyWidth = meter.money.map { Card.estimatedWidth($0, size: labelSize) } ?? 0
        let gap = 20 * scale
        let label = Card.truncated(
            meter.label, toWidth: width - moneyWidth - gap, size: labelSize)
        let room = width - Card.estimatedWidth(label, size: labelSize) - moneyWidth - gap * 2
        return AnalyticsShare.MeterBar(
            label: label,
            detail: Self.phrases(of: meter.detail, fittingIn: room, size: Card.meterDetailSize * scale),
            money: meter.money, share: meter.share, hot: false)
    }

    private static func phrases(of detail: String, fittingIn room: Double, size: Double) -> String {
        var kept: [String] = []
        for phrase in detail.components(separatedBy: " · ") {
            let candidate = (kept + [phrase]).joined(separator: " · ")
            guard Card.estimatedWidth(candidate, size: size) <= room else { break }
            kept.append(phrase)
        }
        return kept.joined(separator: " · ")
    }

    private func meters(
        _ heading: String, _ bars: [AnalyticsShare.MeterBar], caption: String? = nil
    ) -> [Block] {
        var out = title(heading)
        let pitch = 44 * scale + rowGap
        let rows = max(0, min(bars.count, 8, Int((budget - titleHeight + rowGap + 1) / pitch)))
        for (index, bar) in bars.prefix(rows).enumerated() {
            if index > 0 { out.append(.spacer(rowGap)) }
            out.append(
                .meter(
                    AnalyticsShare.MeterBar(
                        label: bar.label, detail: bar.detail, money: bar.money, share: bar.share,
                        hot: index == 0)))
        }
        appendCaption(caption, to: &out)
        return out
    }

    private func captionBlock(_ text: String) -> Block { .dim(text) }

    private func captionHeight(_ text: String) -> Double {
        rowGap * 0.8 + Card.height(captionBlock(text), in: metrics)
    }

    /// Whether a caption can be set whole: a caption that would be cut short to fit its lines is
    /// left off instead, because half a sentence about money reads worse than none.
    private func captionIsWhole(_ text: String) -> Bool {
        let size = Card.fontSize(captionBlock(text), in: metrics)
        let needed = Int((Card.estimatedWidth(text, size: size) / width).rounded(.up))
        return needed <= Card.maximumLines(captionBlock(text))
    }

    private func appendCaption(_ caption: String?, to out: inout [Block]) {
        guard let caption, !caption.isEmpty, captionIsWhole(caption) else { return }
        let extra = captionHeight(caption)
        if height(out) + extra <= budget {
            out.append(.spacer(rowGap * 0.8))
            out.append(captionBlock(caption))
        }
    }

    private func activity() -> [Block] {
        let formats = ["%@ turns", "%@ conversations", "%@ tool calls", "%@ tokens"]
        let clauses = analytics.activityLine.components(separatedBy: " · ")
        var stats: [AnalyticsShare.Stat] = []
        for format in formats {
            for clause in clauses {
                if let part = Card.split(clause, format: format) {
                    stats.append(AnalyticsShare.Stat(value: part.value, label: part.label))
                    break
                }
            }
        }
        var out = title(Localized.text("Activity"))
        let rowHeight = Card.statRowHeight(scale)
        let rows = max(
            0, min((stats.count + Card.statColumns - 1) / Card.statColumns,
                Int((budget - titleHeight + Card.statRowGap * scale + 1) / rowHeight)))
        let kept = Array(stats.prefix(rows * Card.statColumns))
        if !kept.isEmpty { out.append(.stats(kept)) }
        return out
    }

    private mutating func daily() -> [Block] {
        var out = title(analytics.window.chartTitle)
        guard let first = analytics.days.first, let last = analytics.days.last else { return out }
        let peakIndex = analytics.days.indices.max { analytics.days[$0].share < analytics.days[$1].share }
        let bars = analytics.days.enumerated().map { index, day in
            AnalyticsShare.DayBar(
                share: day.share, isToday: false, isEmpty: day.share <= 0,
                isPeak: index == peakIndex && day.share > 0)
        }
        var caption: String?
        if let peak = analytics.peakDay, peak.share > 0 {
            caption = Localized.text("Peak %@ · %@", peak.title, peak.value)
        }
        let axis = Card.axisHeight * scale
        let minimum = 44 * scale
        let maximum = 240 * scale
        var extra = caption.map { captionIsWhole($0) ? captionHeight($0) : 0 } ?? 0
        var chart = budget - titleHeight - axis - extra
        if chart < minimum, caption != nil {
            caption = nil
            extra = 0
            chart = budget - titleHeight - axis
        }
        metrics.dailyHeight = max(minimum, min(maximum, chart.rounded(.down)))
        out.append(
            .daily(
                AnalyticsShare.DailyChart(
                    bars: bars, leading: first.title,
                    trailing: last.isToday ? Localized.text("Today") : last.title)))
        appendCaption(caption, to: &out)
        return out
    }

    private mutating func week() -> [Block] {
        var out = title(Localized.text("The week"))
        let bars = analytics.weekdays.map {
            AnalyticsShare.DayBar(share: $0.share, isToday: false, isEmpty: $0.share <= 0)
        }
        var captions: [String] = []
        if let busiest = analytics.weekdays.max(by: { $0.share < $1.share }), busiest.share > 0,
            let money = busiest.money
        {
            captions.append(Localized.text("Busiest on %@ · %@", busiest.label, money))
        }
        if let clock = analytics.clockLine { captions.append(clock) }
        let axis = Card.axisHeight * scale
        let minimum = 44 * scale
        let maximum = 200 * scale
        var kept = captions
        func chartRoom(_ lines: [String]) -> Double {
            budget - titleHeight - axis - lines.reduce(0) { $0 + captionHeight($1) }
        }
        while chartRoom(kept) < minimum, !kept.isEmpty { kept.removeLast() }
        metrics.weekdayHeight = max(minimum, min(maximum, chartRoom(kept).rounded(.down)))
        out.append(.weekday(bars))
        for line in kept { appendCaption(line, to: &out) }
        return out
    }

    private func tokens() -> [Block] {
        var out = title(Localized.text("Tokens"))
        var bars = Card.tierMeters(analytics)
        let cache = analytics.cacheLine
        let pitch = 44 * scale + rowGap
        let reserved = cache.flatMap { captionIsWhole($0) ? captionHeight($0) : nil } ?? 0
        let room = Int((budget - titleHeight - reserved + rowGap + 1) / pitch)
        let rows = max(1, min(bars.count, room))
        if rows < bars.count {
            let keep = Set(
                bars.indices.sorted { bars[$0].share > bars[$1].share }.prefix(rows))
            bars = bars.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }
        for (index, bar) in bars.enumerated() {
            if index > 0 { out.append(.spacer(rowGap)) }
            out.append(
                .meter(
                    AnalyticsShare.MeterBar(
                        label: bar.label, detail: "", money: bar.money, share: bar.share,
                        hot: index == 0)))
        }
        appendCaption(cache, to: &out)
        return out
    }

    private func records() -> [Block] {
        var out = title(Localized.text("Records"))
        var rows = analytics.records
        if shown.contains(.daily) { rows.removeAll { $0.id == "busiestDay" } }
        let pitch = 48 * scale + rowGap
        let count = max(0, min(rows.count, Card.recordLimit, Int((budget - titleHeight + rowGap + 1) / pitch)))
        for (index, record) in rows.prefix(count).enumerated() {
            if index > 0 { out.append(.spacer(rowGap)) }
            let line = Card.recordLine(record)
            let size = Card.recordTitleSize * scale
            let valueRoom = width - 40 * scale
            out.append(
                .record(
                    AnalyticsShare.RecordLine(
                        glyph: line.glyph,
                        title: Card.truncated(line.title, toWidth: width - 40 * scale, size: size),
                        value: Card.truncated(line.value, toWidth: valueRoom, size: Card.recordSize * scale),
                        detail: line.detail.map {
                            Card.truncated($0, toWidth: width - 40 * scale, size: size)
                        })))
        }
        return out
    }

    private func insights() -> [Block] {
        var out = title(Localized.text("What stands out"))
        var drawn: Set<UsageAnalytics.Insight.Topic> = [.cache]
        if shown.contains(.models) { drawn.insert(.model) }
        if shown.contains(.tools) { drawn.insert(.tool) }
        if shown.contains(.records) {
            let ids = Set(analytics.records.map(\.id))
            if ids.contains("streak") { drawn.insert(.streak) }
            if ids.contains("subagents") { drawn.insert(.subagents) }
        }
        let lines = AnalyticsShare.standouts(
            analytics, drawn: drawn, includesCache: !shown.contains(.tokens))
        for (index, line) in lines.prefix(3).enumerated() {
            let block = Block.insight(line)
            let needed = Card.estimatedWidth(Card.insightPrefix + line, size: Card.fontSize(block, in: metrics)) / width
            guard Int(needed.rounded(.up)) <= Card.maximumLines(block) else { continue }
            let extra = (index > 0 ? rowGap : 0) + Card.height(block, in: metrics)
            guard height(out) + extra <= budget else { break }
            if index > 0 { out.append(.spacer(rowGap)) }
            out.append(block)
        }
        return out
    }
}
