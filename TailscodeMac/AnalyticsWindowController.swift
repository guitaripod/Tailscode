import AppKit
import CodingAgentKit
import TailscodeCore

/// The month in numbers, in its own titled window: every connected Claude machine reports the
/// ledger it already holds, Core's `UsageAnalytics` merges them and generates every word, and
/// this window decides only how tall a bar is. The content is opaque canvas — prose never sits
/// on glass — and a server too old for the route is named at the foot rather than left a silent
/// hole in the numbers.
@MainActor
final class AnalyticsWindowController: NSWindowController {
    private let fetch: () async -> UsageAnalytics?
    private let column = NSStackView()
    private let scroll = NSScrollView()
    private var analytics: UsageAnalytics?
    private var loading = false

    private static let chartHeight: CGFloat = 100
    private static let weekdayHeight: CGFloat = 56
    private static let hourHeight: CGFloat = 32

    init(fetch: @escaping () async -> UsageAnalytics?) {
        self.fetch = fetch
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("The month in numbers")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    private func makeContent() -> NSView {
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        renderMessage(Localized.text("Reading the ledger…"))
        Task { [weak self] in
            guard let self else { return }
            self.analytics = await self.fetch()
            self.loading = false
            self.render()
        }
    }

    @objc private func repaint() {
        scroll.backgroundColor = MacTheme.Color.canvas
        if loading {
            renderMessage(Localized.text("Reading the ledger…"))
        } else {
            render()
        }
    }

    private func renderMessage(_ text: String) {
        clearColumn()
        column.addArrangedSubview(
            RowKit.label(text, font: MacTheme.Font.body(), color: MacTheme.Color.secondaryLabel))
        column.addArrangedSubview(footer())
    }

    private func render() {
        clearColumn()
        guard let analytics else {
            renderMessage(Localized.text("Nothing on the ledger yet."))
            return
        }
        column.addArrangedSubview(heroSection(analytics))
        if !analytics.days.isEmpty { column.addArrangedSubview(dailySection(analytics)) }
        if !analytics.weekdays.isEmpty || !analytics.hours.isEmpty {
            column.addArrangedSubview(rhythmSection(analytics))
        }
        if !analytics.models.isEmpty {
            column.addArrangedSubview(
                meterSection(title: Localized.text("Models"), meters: analytics.models))
        }
        if !analytics.projects.isEmpty {
            column.addArrangedSubview(
                meterSection(title: Localized.text("Projects"), meters: analytics.projects))
        }
        if !analytics.tools.isEmpty {
            column.addArrangedSubview(
                meterSection(
                    title: Localized.text("Tools"), meters: analytics.tools,
                    footnote: analytics.toolsLine))
        }
        if !analytics.tiers.isEmpty { column.addArrangedSubview(tiersSection(analytics)) }
        if !analytics.records.isEmpty { column.addArrangedSubview(recordsSection(analytics)) }
        if !analytics.machines.isEmpty {
            column.addArrangedSubview(
                meterSection(title: Localized.text("Machines"), meters: analytics.machines))
        }
        column.addArrangedSubview(insightsSection(analytics))
        column.addArrangedSubview(footer())
    }

    private func heroSection(_ analytics: UsageAnalytics) -> NSView {
        let windowLabel = RowKit.label(
            analytics.windowLabel, font: .systemFont(ofSize: 10, weight: .semibold),
            color: MacTheme.Color.tertiaryLabel)
        let money = RowKit.label(
            analytics.totalMoney, font: Self.heroFont(), color: MacTheme.Color.label)
        let perDay = RowKit.label(
            analytics.perDayLine, font: MacTheme.Font.body(), color: MacTheme.Color.secondaryLabel)
        let activity = RowKit.label(
            analytics.activityLine, font: MacTheme.Font.caption(),
            color: MacTheme.Color.secondaryLabel)
        var views: [NSView] = [windowLabel, money, perDay, activity]
        if let delta = analytics.deltaLine {
            views.append(
                RowKit.label(
                    delta, font: MacTheme.Font.emphasis(), color: trendColor(analytics.trend)))
        }
        return card(views: views)
    }

    private func trendColor(_ trend: UsageAnalytics.Trend) -> NSColor {
        switch trend {
        case .up: return MacTheme.Color.warning
        case .down: return MacTheme.Color.accent
        case .flat: return MacTheme.Color.secondaryLabel
        }
    }

    private func dailySection(_ analytics: UsageAnalytics) -> NSView {
        let bars = NSStackView()
        bars.orientation = .horizontal
        bars.alignment = .bottom
        bars.distribution = .equalSpacing
        bars.spacing = 2
        bars.translatesAutoresizingMaskIntoConstraints = false
        for day in analytics.days {
            let zero = day.costUSD <= 0
            let fill =
                day.isToday
                ? MacTheme.Color.accent : zero ? MacTheme.Color.separator : MacTheme.Color.info
            let bar = AnalyticsBar(fill: fill)
            bar.toolTip = "\(day.weekdayLabel) \(day.label) · \(day.money)"
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 10),
                bar.heightAnchor.constraint(
                    equalToConstant: zero ? 2 : max(2, Self.chartHeight * day.share)),
            ])
            bars.addArrangedSubview(bar)
        }
        bars.heightAnchor.constraint(equalToConstant: Self.chartHeight).isActive = true

        var annotations: [NSView] = []
        if let peak = analytics.peakDay, peak.costUSD > 0 {
            annotations.append(
                RowKit.label(
                    Localized.text("Peak %@ %@ · %@", peak.weekdayLabel, peak.label, peak.money),
                    font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        annotations.append(RowKit.spacer())
        if let today = analytics.days.last(where: { $0.isToday }) {
            annotations.append(
                RowKit.label(
                    Localized.text("Today %@", today.money), font: MacTheme.Font.caption(),
                    color: MacTheme.Color.tertiaryLabel))
        }
        let annotation = NSStackView(views: annotations)
        annotation.orientation = .horizontal
        annotation.spacing = MacTheme.Spacing.s

        return card(views: [heading(Localized.text("Day by day")), bars, annotation])
    }

    private func rhythmSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = [heading(Localized.text("Rhythm"))]
        if !analytics.weekdays.isEmpty {
            let week = NSStackView()
            week.orientation = .horizontal
            week.alignment = .bottom
            week.distribution = .fillEqually
            week.spacing = MacTheme.Spacing.s
            for day in analytics.weekdays {
                let bar = AnalyticsBar(fill: MacTheme.Color.info)
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 26),
                    bar.heightAnchor.constraint(
                        equalToConstant: max(2, Self.weekdayHeight * day.share)),
                ])
                let label = RowKit.label(
                    day.label, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
                let dayColumn = NSStackView(views: [bar, label])
                dayColumn.orientation = .vertical
                dayColumn.alignment = .centerX
                dayColumn.spacing = 3
                dayColumn.toolTip = day.money
                week.addArrangedSubview(dayColumn)
            }
            views.append(week)
        }
        if !analytics.hours.isEmpty {
            let hours = NSStackView()
            hours.orientation = .horizontal
            hours.alignment = .bottom
            hours.distribution = .equalSpacing
            hours.spacing = 2
            for hour in analytics.hours {
                let zero = hour.turns <= 0
                let bar = AnalyticsBar(fill: zero ? MacTheme.Color.separator : MacTheme.Color.info)
                bar.toolTip = "\(hour.label):00 · " + Localized.text("%d turns", hour.turns)
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 14),
                    bar.heightAnchor.constraint(
                        equalToConstant: zero ? 2 : max(2, Self.hourHeight * hour.share)),
                ])
                hours.addArrangedSubview(bar)
            }
            hours.heightAnchor.constraint(equalToConstant: Self.hourHeight).isActive = true
            views.append(hours)
        }
        if let clock = analytics.clockLine {
            views.append(
                RowKit.label(
                    clock, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        return card(views: views)
    }

    private func meterSection(
        title: String, meters: [UsageAnalytics.Meter], footnote: String? = nil
    ) -> NSView {
        var views: [NSView] = [heading(title)]
        for meter in meters {
            views.append(
                meterRow(
                    label: meter.label, detail: meter.detail, money: meter.money,
                    share: meter.share, hot: false))
        }
        if let footnote {
            views.append(
                RowKit.label(
                    footnote, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        return card(views: views)
    }

    private func tiersSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = [heading(Localized.text("Where it went"))]
        for tier in analytics.tiers {
            views.append(
                meterRow(
                    label: tier.label, detail: StatusFacts.tokens(tier.tokens),
                    money: SessionSpend.money(tier.costUSD), share: tier.share,
                    hot: tier.id == "output"))
        }
        if let cache = analytics.cacheLine {
            views.append(
                RowKit.label(
                    cache, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        return card(views: views)
    }

    private func recordsSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = [heading(Localized.text("Records"))]
        var index = 0
        while index < analytics.records.count {
            let pair = Array(analytics.records[index..<min(index + 2, analytics.records.count)])
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = MacTheme.Spacing.s
            for record in pair { row.addArrangedSubview(recordCard(record)) }
            if pair.count == 1 {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(filler)
            }
            views.append(row)
            index += 2
        }
        return card(views: views)
    }

    private func recordCard(_ record: UsageAnalytics.Record) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(
            systemSymbolName: record.symbolName, accessibilityDescription: record.title)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        symbol.contentTintColor = MacTheme.Color.accent
        symbol.translatesAutoresizingMaskIntoConstraints = false
        let title = RowKit.label(
            record.title, font: .systemFont(ofSize: 10, weight: .semibold),
            color: MacTheme.Color.tertiaryLabel)
        let value = RowKit.label(
            record.value, font: MacTheme.Font.emphasis(), color: MacTheme.Color.label)
        var views: [NSView] = [symbol, title, value]
        if let detail = record.detail {
            let caption = RowKit.wrapping(
                detail, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
            caption.maximumNumberOfLines = 2
            caption.cell?.truncatesLastVisibleLine = true
            caption.preferredMaxLayoutWidth = 210
            views.append(caption)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = MacTheme.Radius.control
        stack.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func insightsSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = []
        for line in analytics.insights {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            icon.contentTintColor = MacTheme.Color.accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            let text = RowKit.wrapping(line, font: MacTheme.Font.body(), color: MacTheme.Color.label)
            let row = NSStackView(views: [icon, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = MacTheme.Spacing.s
            views.append(row)
        }
        views.append(
            RowKit.wrapping(
                analytics.source, font: MacTheme.Font.caption(),
                color: MacTheme.Color.tertiaryLabel))
        if !analytics.missingServers.isEmpty {
            views.append(
                RowKit.wrapping(
                    Localized.text(
                        "Not counted: %@", analytics.missingServers.joined(separator: ", ")),
                    font: MacTheme.Font.caption(), color: MacTheme.Color.warning))
        }
        return card(views: views)
    }

    private func meterRow(
        label: String, detail: String, money: String?, share: Double, hot: Bool
    ) -> NSView {
        let name = RowKit.label(label, font: MacTheme.Font.caption(), color: MacTheme.Color.label)
        name.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let count = RowKit.label(
            detail, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
        count.setContentHuggingPriority(.required, for: .horizontal)
        var topViews: [NSView] = [name, RowKit.spacer(), count]
        if let money {
            let amount = RowKit.label(money, font: Self.moneyFont(), color: MacTheme.Color.label)
            amount.setContentHuggingPriority(.required, for: .horizontal)
            topViews.append(amount)
        }
        let top = NSStackView(views: topViews)
        top.orientation = .horizontal
        top.spacing = MacTheme.Spacing.s
        top.alignment = .firstBaseline

        let track = AnalyticsBar(fill: MacTheme.Color.separator)
        let fill = AnalyticsBar(fill: hot ? MacTheme.Color.accent : MacTheme.Color.info)
        track.addSubview(fill)
        let proportional = fill.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: min(max(share, 0), 1))
        proportional.priority = .defaultHigh
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            proportional,
            fill.widthAnchor.constraint(greaterThanOrEqualToConstant: 2),
        ])

        let block = NSStackView(views: [top, track])
        block.orientation = .vertical
        block.alignment = .width
        block.spacing = 3
        return block
    }

    private func heading(_ text: String, trailing: String? = nil) -> NSView {
        let title = RowKit.label(text, font: MacTheme.Font.emphasis(), color: MacTheme.Color.label)
        var views: [NSView] = [title, RowKit.spacer()]
        if let trailing {
            views.append(
                RowKit.label(
                    trailing, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    private func card(views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = MacTheme.Radius.control
        stack.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func footer() -> NSView {
        let refresh = RowKit.ActionButton(title: Localized.text("Refresh")) { [weak self] in
            self?.reload()
        }
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let row = NSStackView(views: [RowKit.spacer(), refresh])
        row.orientation = .horizontal
        return row
    }

    private func clearColumn() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private static func heroFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: 34, weight: .bold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
            let rounded = NSFont(descriptor: descriptor, size: 34)
        else { return base }
        return rounded
    }

    private static func moneyFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: 12 * MacTheme.UIScale.factor, weight: .semibold)
    }
}

/// A plain filled rectangle — the same shape `SpendPanelView` draws its bars with, because the
/// chart needs a rounded fill whose height is the whole message and AppKit has no bar.
@MainActor
private final class AnalyticsBar: NSView {
    init(fill: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 2
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
