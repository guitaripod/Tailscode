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
    private let column = FillingStack()
    private let scroll = NSScrollView()
    private var analytics: UsageAnalytics?
    private var loading = false
    private var paintedDark = false
    /// The sharing picker points at the control that was pressed, not at the window it lives in —
    /// a menu that opens from the far edge of a resizable window reads as one that came from
    /// nowhere. The footer is rebuilt with every render, so the button is remembered rather than
    /// looked up.
    private weak var shareAnchor: NSView?

    private static let chartHeight: CGFloat = 100
    private static let weekdayHeight: CGFloat = 56
    private static let weekdayBarWidth: CGFloat = 30
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
        let host = NSViewController(nibName: nil, bundle: nil)
        host.view = makeContent()
        window.contentViewController = host
        paintedDark = window.effectiveAppearance.isDark
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(standingChanged), name: MacGameCenter.standingChanged,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The window opens at the size the surface was drawn for. Its content is a scroll view pinned
    /// to every edge and so has no height of its own to fit to, which leaves a window left to size
    /// itself sitting at `contentMinSize` — the hero fills it and the month's shape, which is the
    /// whole reason to open this, starts below the fold.
    func present() {
        if let window, !window.isVisible, let screen = window.screen ?? NSScreen.main {
            let room = screen.visibleFrame
            let size = NSSize(
                width: min(Self.openingSize.width, room.width - 80),
                height: min(Self.openingSize.height, room.height - 80))
            window.setFrame(
                NSRect(
                    x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                    width: size.width, height: size.height),
                display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    private static let openingSize = NSSize(width: 760, height: 980)

    private func makeContent() -> NSView {
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

        let container = AnalyticsContentView(frame: .zero)
        container.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
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
        if analytics == nil { render() }
        Task { [weak self] in
            guard let self else { return }
            self.analytics = await self.fetch()
            MacGameCenter.shared.note(self.analytics)
            self.loading = false
            self.render()
        }
    }

    @objc private func standingChanged() {
        if !loading, analytics != nil {
            render()
        }
    }

    @objc private func repaint() {
        scroll.backgroundColor = MacTheme.Color.canvas
        render()
    }

    /// AppKit re-resolves an `NSColor` when the light changes and can do nothing for a `CGColor`
    /// already sitting in a layer — which is every card, bar and track here. A flip therefore draws
    /// the report again, on the next turn of the loop so the colours are asked under the appearance
    /// that has actually taken hold, and only when the face genuinely changed: a theme change
    /// arrives on its own notification and must not be answered twice.
    private func appearanceChanged() {
        guard let window, window.effectiveAppearance.isDark != paintedDark else { return }
        paintedDark = window.effectiveAppearance.isDark
        Task { @MainActor [weak self] in self?.repaint() }
    }

    private func renderMessage(_ text: String) {
        clearColumn()
        column.addArrangedSubview(
            RowKit.label(text, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel))
        column.addArrangedSubview(footer())
    }

    private func render() {
        clearColumn()
        guard let analytics else {
            renderMessage(
                loading
                    ? Localized.text("Reading the ledger…")
                    : Localized.text("Nothing on the ledger yet."))
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
        if !analytics.trophies.isEmpty { column.addArrangedSubview(trophySection(analytics)) }
        if !analytics.machines.isEmpty {
            column.addArrangedSubview(
                meterSection(title: Localized.text("Machines"), meters: analytics.machines))
        }
        column.addArrangedSubview(insightsSection(analytics))
        column.addArrangedSubview(footer())
    }

    private func heroSection(_ analytics: UsageAnalytics) -> NSView {
        let windowLabel = RowKit.label(
            analytics.windowLabel, font: MacTheme.Ramp.font(.metricLabel),
            color: MacTheme.Color.tertiaryLabel)
        let money = RowKit.label(
            analytics.totalMoney, font: Self.heroFont(), color: MacTheme.Color.label)
        let perDay = RowKit.label(
            analytics.perDayLine, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel)
        let activity = RowKit.label(
            analytics.activityLine, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        var views: [NSView] = [windowLabel, money, perDay, activity]
        if let delta = analytics.deltaLine {
            views.append(
                RowKit.label(
                    delta, font: MacTheme.Ramp.font(.cardTitle), color: trendColor(analytics.trend)))
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
        bars.distribution = .fill
        bars.spacing = 2
        bars.translatesAutoresizingMaskIntoConstraints = false
        for day in analytics.days {
            let zero = day.costUSD <= 0
            let fill =
                day.isToday
                ? MacTheme.Color.accent : zero ? MacTheme.Color.separator : MacTheme.Color.info
            let bar = AnalyticsBar(fill: fill)
            bar.toolTip = "\(day.weekdayLabel) \(day.label) · \(day.money)"
            bar.speak(bar.toolTip)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 10),
                bar.heightAnchor.constraint(
                    equalToConstant: zero ? 2 : max(2, Self.chartHeight * day.share)),
            ])
            bars.addArrangedSubview(bar)
        }
        bars.addArrangedSubview(RowKit.spacer())
        bars.heightAnchor.constraint(equalToConstant: Self.chartHeight).isActive = true

        var annotations: [NSView] = []
        if let peak = analytics.peakDay, peak.costUSD > 0 {
            annotations.append(
                RowKit.label(
                    Localized.text("Peak %@ %@ · %@", peak.weekdayLabel, peak.label, peak.money),
                    font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        annotations.append(RowKit.spacer())
        if let today = analytics.days.last(where: { $0.isToday }) {
            annotations.append(
                RowKit.label(
                    Localized.text("Today %@", today.money), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
        let annotation = NSStackView(views: annotations)
        annotation.orientation = .horizontal
        annotation.spacing = MacTheme.Spacing.s

        return card(views: [heading(Localized.text("Day by day")), bars, annotation])
    }

    /// Two charts, not one heap. The week and the clock answer different questions — which day the
    /// work lands on, and what hour of it — so each gets its own caption instead of sharing a single
    /// line that could only ever describe the second.
    ///
    /// Both rows pin their own height. A bar chart is read along its baseline, and a row left to its
    /// intrinsic height lets every column settle where its own bar puts it: the tallest day sat high,
    /// the quietest sat low, and no two bars could be compared by eye. The hours row always had this
    /// constraint and read correctly; the weekday row did not.
    private func rhythmSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = [heading(Localized.text("Rhythm"))]
        if !analytics.weekdays.isEmpty {
            views.append(chartLabel(Localized.text("The week")))
            let bars = NSStackView()
            bars.orientation = .horizontal
            bars.alignment = .bottom
            bars.distribution = .fill
            bars.spacing = MacTheme.Spacing.m
            let labels = NSStackView()
            labels.orientation = .horizontal
            labels.distribution = .fill
            labels.spacing = MacTheme.Spacing.m
            for day in analytics.weekdays {
                let bar = AnalyticsBar(fill: MacTheme.Color.info)
                bar.speak("\(day.label) · \(day.money)")
                bar.toolTip = day.money
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: Self.weekdayBarWidth),
                    bar.heightAnchor.constraint(
                        equalToConstant: max(2, Self.weekdayHeight * day.share)),
                ])
                bars.addArrangedSubview(bar)
                let label = RowKit.label(
                    day.label, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel)
                label.alignment = .center
                label.widthAnchor.constraint(equalToConstant: Self.weekdayBarWidth).isActive = true
                labels.addArrangedSubview(label)
            }
            bars.addArrangedSubview(RowKit.spacer())
            labels.addArrangedSubview(RowKit.spacer())
            bars.heightAnchor.constraint(equalToConstant: Self.weekdayHeight).isActive = true
            views.append(bars)
            views.append(labels)
            if let busiest = analytics.weekdays.max(by: { $0.share < $1.share }),
                let money = busiest.money
            {
                views.append(caption(Localized.text("Busiest on %@ · %@", busiest.label, money)))
            }
        }
        if !analytics.hours.isEmpty {
            views.append(chartLabel(Localized.text("The day")))
            let hours = NSStackView()
            hours.orientation = .horizontal
            hours.alignment = .bottom
            hours.distribution = .fill
            hours.spacing = 2
            for hour in analytics.hours {
                let zero = hour.turns <= 0
                let bar = AnalyticsBar(fill: zero ? MacTheme.Color.separator : MacTheme.Color.info)
                bar.toolTip = "\(hour.label):00 · " + Localized.text("%d turns", hour.turns)
                bar.speak(bar.toolTip)
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 14),
                    bar.heightAnchor.constraint(
                        equalToConstant: zero ? 2 : max(2, Self.hourHeight * hour.share)),
                ])
                hours.addArrangedSubview(bar)
            }
            hours.addArrangedSubview(RowKit.spacer())
            hours.heightAnchor.constraint(equalToConstant: Self.hourHeight).isActive = true
            views.append(hours)
            if let clock = analytics.clockLine { views.append(caption(clock)) }
        }
        return card(views: views)
    }

    /// The name of one chart inside a card that holds two of them: small, quiet, and above the
    /// thing it names rather than under it.
    private func chartLabel(_ text: String) -> NSView {
        let label = RowKit.label(
            text, font: MacTheme.Ramp.font(.sectionLabel), color: MacTheme.Color.secondaryLabel)
        let row = NSStackView(views: [label, RowKit.spacer()])
        row.orientation = .horizontal
        return row
    }

    private func caption(_ text: String) -> NSView {
        RowKit.label(
            text, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
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
                    footnote, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
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
                    cache, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
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
            record.title, font: MacTheme.Ramp.font(.metricLabel),
            color: MacTheme.Color.tertiaryLabel)
        let value = RowKit.label(
            record.value, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        var views: [NSView] = [symbol, title, value]
        var caption: NSTextField?
        if let detail = record.detail {
            let text = RowKit.wrapping(
                detail, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
            text.maximumNumberOfLines = 2
            text.cell?.truncatesLastVisibleLine = true
            caption = text
            views.append(text)
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
        if let caption {
            caption.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * MacTheme.Spacing.s).isActive = true
        }
        return stack
    }

    private func trophySection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = [
            heading(
                Localized.text("The trophy case"),
                trailing: TrophyRoom.headline(analytics.trophies))
        ]
        let earned = analytics.trophies.filter(\.earned)
        if !earned.isEmpty {
            views.append(earnedStrip(earned))
        }
        for trophy in TrophyRoom.nextUp(analytics.trophies) {
            views.append(
                meterRow(
                    label: trophy.title, detail: trophy.progressLine, money: nil,
                    share: trophy.percent / 100, hot: false))
        }
        if let title = MacGameCenter.shared.actionTitle {
            let open = RowKit.ActionButton(title: title) { [weak self] in
                MacGameCenter.shared.openDashboard(from: self?.window)
            }
            open.bezelStyle = .rounded
            open.controlSize = .small
            let row = NSStackView(views: [open, RowKit.spacer()])
            row.orientation = .horizontal
            views.append(row)
        }
        if let line = MacGameCenter.shared.unavailableLine {
            views.append(
                RowKit.wrapping(
                    line, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        return card(views: views)
    }

    private func earnedStrip(_ earned: [Trophy]) -> NSView {
        var views: [NSView] = []
        for trophy in earned.prefix(12) {
            let symbol = NSImageView()
            symbol.image = NSImage(
                systemSymbolName: trophy.symbolName, accessibilityDescription: trophy.title)
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 13, weight: .semibold)
            symbol.contentTintColor = MacTheme.Color.accent
            symbol.toolTip = trophy.title
            symbol.translatesAutoresizingMaskIntoConstraints = false
            views.append(symbol)
        }
        if earned.count > 12 {
            views.append(
                RowKit.label(
                    "+\(earned.count - 12)", font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        views.append(RowKit.spacer())
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }

    private func insightsSection(_ analytics: UsageAnalytics) -> NSView {
        var views: [NSView] = []
        for line in analytics.insights {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            icon.contentTintColor = MacTheme.Color.accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            let text = RowKit.wrapping(line, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
            let row = NSStackView(views: [icon, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = MacTheme.Spacing.s
            views.append(row)
        }
        views.append(
            RowKit.wrapping(
                analytics.source, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.tertiaryLabel))
        if !analytics.missingServers.isEmpty {
            views.append(
                RowKit.wrapping(
                    Localized.text(
                        "Not counted: %@", analytics.missingServers.joined(separator: ", ")),
                    font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.warning))
        }
        return card(views: views)
    }

    private func meterRow(
        label: String, detail: String, money: String?, share: Double, hot: Bool
    ) -> NSView {
        let name = RowKit.label(label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
        name.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let count = RowKit.label(
            detail, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
        count.setContentHuggingPriority(.required, for: .horizontal)
        var topViews: [NSView] = [name, RowKit.spacer(), count]
        if let money {
            let amount = RowKit.label(
                money, font: MacTheme.Ramp.font(.metricValue), color: MacTheme.Color.label)
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

        let block = FillingStack(views: [top, track])
        block.spacing = 3
        return block
    }

    private func heading(_ text: String, trailing: String? = nil) -> NSView {
        let title = RowKit.label(text, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        var views: [NSView] = [title, RowKit.spacer()]
        if let trailing {
            views.append(
                RowKit.label(
                    trailing, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    private func card(views: [NSView]) -> NSView {
        let stack = FillingStack(views: views)
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
        var views: [NSView] = [RowKit.spacer()]
        if analytics != nil {
            let share = RowKit.ActionButton(title: Localized.text("Share")) { [weak self] in
                self?.share(from: self?.shareAnchor)
            }
            shareAnchor = share
            share.bezelStyle = .rounded
            share.controlSize = .small
            views.append(share)
        }
        let refresh = RowKit.ActionButton(title: Localized.text("Refresh")) { [weak self] in
            self?.reload()
        }
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        views.append(refresh)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }

    private func share(from anchor: NSView?) {
        guard let analytics else { return }
        let package = AnalyticsShare(analytics)
        var items: [Any] = [package.plainText]
        if let rendered = AnalyticsCardRenderer.png(package) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-analytics", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(rendered.filename)
            if (try? rendered.data.write(to: url, options: .atomic)) != nil {
                items.insert(url, at: 0)
            } else {
                items.insert(rendered.image, at: 0)
            }
        }
        let picker = NSSharingServicePicker(items: items)
        let source = anchor ?? window?.contentView
        guard let source else { return }
        let rect =
            anchor.map { $0.bounds }
            ?? NSRect(x: source.bounds.midX - 1, y: source.bounds.minY + 12, width: 2, height: 2)
        picker.show(relativeTo: rect, of: source, preferredEdge: .minY)
    }

    private func clearColumn() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    /// The month's one big number, in the ramp's own hero size — rounded is a design, not a size,
    /// so the descriptor is redrawn at the size the ramp already scaled for the type preference.
    private static func heroFont() -> NSFont {
        let base = MacTheme.Ramp.font(.metricHero)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
            let rounded = NSFont(descriptor: descriptor, size: base.pointSize)
        else { return base }
        return rounded
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

    /// A chart says everything in its heights, and a height says nothing to a screen reader — so
    /// the bar carries the sentence its tooltip carries, which is a pointer's affordance alone.
    func speak(_ sentence: String?) {
        guard let sentence, !sentence.isEmpty else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(sentence)
    }
}

/// The window's own content, which is where a change of light is heard: AppKit tells a view its
/// effective appearance changed and tells a window controller nothing at all.
@MainActor
private final class AnalyticsContentView: NSView {
    var onAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
