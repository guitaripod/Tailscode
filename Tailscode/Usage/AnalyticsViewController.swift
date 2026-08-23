import CodingAgentKit
import TailscodeCore
import UIKit

/// The month in numbers: the whole account across every connected server, arranged by
/// `UsageAnalytics` into what the window cost and which way it is heading, a bar per day,
/// the week's rhythm and the day's clock, where the money went and the records worth
/// telling someone about. Every word is Core's; this screen decides only how tall a bar is.
final class AnalyticsViewController: UIViewController {
    private var analytics: UsageAnalytics?
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let refresher = UIRefreshControl()
    private let spinner = ActivityBadgeView(pointSize: 16)
    private let stateLabel = UILabel()
    private let stateStack = UIStackView()
    private var loadTask: Task<Void, Never>?
    private var hasAnimatedBars = false
    private var pendingBars: [(bar: UIView, height: CGFloat)] = []

    private static let chartHeight: CGFloat = 96
    private static let dayBarWidth: CGFloat = 4
    private static let weekdayHeight: CGFloat = 48
    private static let hoursHeight: CGFloat = 32
    private static let dimmedBarAlpha: CGFloat = 0.7

    init(analytics: UsageAnalytics?) {
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "The month in numbers")
        setupScroll()
        setupStateViews()
        refreshShareButton()
        NotificationCenter.default.addObserver(
            self, selector: #selector(gameCenterStandingChanged),
            name: GameCenterCoordinator.standingChanged, object: nil)
        if analytics != nil {
            render()
        } else {
            showLoading()
            startLoad()
        }
    }

    private func refreshShareButton() {
        guard analytics != nil else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self,
            action: #selector(shareTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Share")
    }

    @objc private func shareTapped() {
        guard let analytics else { return }
        let share = AnalyticsShare(analytics)
        var items: [Any] = [share.plainText]
        if let url = AnalyticsCardRenderer.temporaryFile(share) {
            items.insert(url, at: 0)
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        sheet.popoverPresentationController?.sourceView = view
        Theme.Haptics.success()
        present(sheet, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        animateBarsIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func setupScroll() {
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.xl,
            trailing: Theme.Spacing.m)

        scroll.alwaysBounceVertical = true
        refresher.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        scroll.refreshControl = refresher
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func setupStateViews() {
        stateLabel.font = Theme.Ramp.font(.panelLabel)
        stateLabel.textColor = Theme.Color.secondaryLabel
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateStack.axis = .vertical
        stateStack.alignment = .center
        stateStack.spacing = Theme.Spacing.m
        stateStack.isHidden = true
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateStack.addArrangedSubview(spinner)
        stateStack.addArrangedSubview(stateLabel)
        view.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stateStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: Theme.Spacing.xl),
            stateStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    @objc private func pulledToRefresh() {
        startLoad()
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = Task {
            let haul = await AnalyticsFetcher.fetch()
            guard !Task.isCancelled else { return }
            analytics = UsageAnalytics(servers: haul.servers, missingServers: haul.missing)
            GameCenterCoordinator.shared.note(analytics)
            render()
            refreshShareButton()
            refresher.endRefreshing()
            loadTask = nil
        }
    }

    private func showLoading() {
        guard column.arrangedSubviews.isEmpty else { return }
        spinner.working(true)
        stateLabel.text = String(localized: "Reading the ledger…")
        stateStack.isHidden = false
    }

    private func showEmpty() {
        spinner.working(false)
        stateLabel.text = String(localized: "Nothing on the ledger yet")
        stateStack.isHidden = false
    }

    private func render() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pendingBars = []
        guard let analytics else {
            showEmpty()
            return
        }
        spinner.working(false)
        stateStack.isHidden = true

        column.addArrangedSubview(hero(analytics))
        column.addArrangedSubview(daily(analytics))
        column.addArrangedSubview(rhythm(analytics))
        if !analytics.models.isEmpty { column.addArrangedSubview(models(analytics)) }
        if !analytics.projects.isEmpty { column.addArrangedSubview(projects(analytics)) }
        if !analytics.tools.isEmpty { column.addArrangedSubview(tools(analytics)) }
        if !analytics.tiers.isEmpty { column.addArrangedSubview(tiers(analytics)) }
        if !analytics.records.isEmpty { column.addArrangedSubview(records(analytics)) }
        if !analytics.trophies.isEmpty { column.addArrangedSubview(trophyCase(analytics)) }
        if !analytics.machines.isEmpty { column.addArrangedSubview(machines(analytics)) }
        if !analytics.insights.isEmpty { column.addArrangedSubview(insights(analytics)) }

        let source = label(analytics.source, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
        column.addArrangedSubview(source)
        if !analytics.missingServers.isEmpty {
            let names = analytics.missingServers.joined(separator: ", ")
            column.addArrangedSubview(
                label(
                    String(localized: "Not counted: \(names)"), role: .panelFootnote,
                    color: Theme.Color.tertiaryLabel))
        }
        primeBarAnimation()
    }

    private func hero(_ analytics: UsageAnalytics) -> UIView {
        let money = UILabel()
        money.text = analytics.totalMoney
        money.font = Self.roundedFont(size: 44, weight: .bold)
        money.textColor = Theme.Color.label
        money.adjustsFontSizeToFitWidth = true
        money.minimumScaleFactor = 0.6

        let window = label(
            analytics.windowLabel, role: .panelDetail, color: Theme.Color.secondaryLabel)
        let perDay = label(
            analytics.perDayLine, role: .panelLabel, color: Theme.Color.secondaryLabel)
        let activity = label(
            analytics.activityLine, role: .metricDetail, color: Theme.Color.secondaryLabel)

        var views: [UIView] = [money, window, perDay, activity]
        if let deltaLine = analytics.deltaLine {
            views.append(label(deltaLine, role: .metricDetail, color: deltaColor(analytics.trend)))
        }
        return card(views)
    }

    private func deltaColor(_ trend: UsageAnalytics.Trend) -> UIColor {
        switch trend {
        case .up: return Theme.Color.warning
        case .down: return Theme.Color.accent
        case .flat: return Theme.Color.secondaryLabel
        }
    }

    private func daily(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = [
            heading(String(localized: "Day by day"), trailing: nil),
            dailyChart(analytics),
        ]
        var annotations: [UIView] = []
        if let peak = analytics.peakDay, peak.costUSD > 0 {
            annotations.append(
                label(
                    String(localized: "Peak \(peak.weekdayLabel) \(peak.label) · \(peak.money)"),
                    role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        annotations.append(UIView())
        if let today = analytics.days.last(where: \.isToday) {
            annotations.append(
                label(
                    String(localized: "Today \(today.money)"), role: .panelFootnote,
                    color: Theme.Color.tertiaryLabel))
        }
        if annotations.count > 1 {
            let row = UIStackView(arrangedSubviews: annotations)
            row.axis = .horizontal
            row.spacing = Theme.Spacing.s
            views.append(row)
        }
        return card(views)
    }

    private func dailyChart(_ analytics: UsageAnalytics) -> UIView {
        let bars = UIStackView()
        bars.axis = .horizontal
        bars.alignment = .bottom
        bars.distribution = .equalSpacing
        for day in analytics.days {
            let bar = UIView()
            let height = max(2, Self.chartHeight * day.share)
            if day.share > 0 {
                bar.backgroundColor = day.isToday ? Theme.Color.accent : Theme.Color.info
                if !day.isToday { bar.alpha = Self.dimmedBarAlpha }
                pendingBars.append((bar, height))
            } else {
                bar.backgroundColor = Theme.Color.separator
            }
            bar.layer.cornerRadius = 2
            bar.isAccessibilityElement = true
            bar.accessibilityLabel = "\(day.weekdayLabel) \(day.label), \(day.money)"
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: Self.dayBarWidth),
                bar.heightAnchor.constraint(equalToConstant: height),
            ])
            bars.addArrangedSubview(bar)
        }
        bars.heightAnchor.constraint(equalToConstant: Self.chartHeight).isActive = true
        return bars
    }

    private func rhythm(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = [
            heading(String(localized: "The week and the clock"), trailing: nil),
            weekdayColumns(analytics),
            hourColumns(analytics),
        ]
        if let clockLine = analytics.clockLine {
            views.append(label(clockLine, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        return card(views)
    }

    private func weekdayColumns(_ analytics: UsageAnalytics) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        for meter in analytics.weekdays {
            let container = UIView()
            let bar = UIView()
            let height = max(2, Self.weekdayHeight * meter.share)
            if meter.share > 0 {
                bar.backgroundColor = meter.share >= 1 ? Theme.Color.accent : Theme.Color.info
                if meter.share < 1 { bar.alpha = Self.dimmedBarAlpha }
                pendingBars.append((bar, height))
            } else {
                bar.backgroundColor = Theme.Color.separator
            }
            bar.layer.cornerRadius = 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: Self.weekdayHeight),
                bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                bar.widthAnchor.constraint(equalToConstant: 16),
                bar.heightAnchor.constraint(equalToConstant: height),
            ])

            let name = label(meter.label, role: .panelFootnote, color: Theme.Color.secondaryLabel)
            name.textAlignment = .center
            let columnStack = UIStackView(arrangedSubviews: [container, name])
            columnStack.axis = .vertical
            columnStack.spacing = Theme.Spacing.xs
            columnStack.isAccessibilityElement = true
            columnStack.accessibilityLabel = [meter.label, meter.money]
                .compactMap { $0 }.joined(separator: ", ")
            row.addArrangedSubview(columnStack)
        }
        return row
    }

    private func hourColumns(_ analytics: UsageAnalytics) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 2
        for hour in analytics.hours {
            let container = UIView()
            let bar = UIView()
            let height = max(2, Self.hoursHeight * hour.share)
            if hour.share > 0 {
                bar.backgroundColor = Theme.Color.info
                bar.alpha = Self.dimmedBarAlpha
                pendingBars.append((bar, height))
            } else {
                bar.backgroundColor = Theme.Color.separator
            }
            bar.layer.cornerRadius = 1
            bar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(bar)
            container.isAccessibilityElement = true
            container.accessibilityLabel = "\(hour.label), \(hour.turns)"
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: Self.hoursHeight),
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: height),
            ])
            row.addArrangedSubview(container)
        }
        return row
    }

    private func models(_ analytics: UsageAnalytics) -> UIView {
        meterSection(String(localized: "Which model"), meters: analytics.models, caption: nil)
    }

    private func projects(_ analytics: UsageAnalytics) -> UIView {
        meterSection(String(localized: "Which project"), meters: analytics.projects, caption: nil)
    }

    private func tools(_ analytics: UsageAnalytics) -> UIView {
        meterSection(
            String(localized: "Which tools"), meters: analytics.tools,
            caption: analytics.toolsLine)
    }

    private func machines(_ analytics: UsageAnalytics) -> UIView {
        meterSection(String(localized: "Which machine"), meters: analytics.machines, caption: nil)
    }

    private func meterSection(_ title: String, meters: [UsageAnalytics.Meter], caption: String?)
        -> UIView
    {
        var views: [UIView] = [heading(title, trailing: nil)]
        if let caption {
            views.append(label(caption, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        for (index, row) in meters.enumerated() {
            views.append(
                meter(
                    label: row.label, value: row.money ?? "", detail: row.detail,
                    fraction: row.share, hot: index == 0))
        }
        return card(views)
    }

    private func tiers(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = [heading(String(localized: "Where it went"), trailing: nil)]
        for tier in analytics.tiers {
            views.append(
                meter(
                    label: tier.label, value: SessionSpend.money(tier.costUSD),
                    detail: StatusFacts.tokens(tier.tokens), fraction: tier.share,
                    hot: tier.id == "output"))
        }
        if let cacheLine = analytics.cacheLine {
            views.append(label(cacheLine, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        return card(views)
    }

    private func records(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = [heading(String(localized: "The records"), trailing: nil)]
        var index = 0
        while index < analytics.records.count {
            let left = recordTile(analytics.records[index])
            let right =
                index + 1 < analytics.records.count
                ? recordTile(analytics.records[index + 1]) : UIView()
            let row = UIStackView(arrangedSubviews: [left, right])
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Theme.Spacing.m
            views.append(row)
            index += 2
        }
        return card(views)
    }

    private func recordTile(_ record: UsageAnalytics.Record) -> UIView {
        let symbol = UIImageView(image: UIImage(systemName: record.symbolName))
        symbol.tintColor = Theme.Color.accent
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 20, weight: .semibold)
        symbol.contentMode = .scaleAspectFit

        let title = label(record.title, role: .panelDetail, color: Theme.Color.secondaryLabel)
        let value = label(record.value, role: .metricValue, color: Theme.Color.label)

        let tile = UIStackView(arrangedSubviews: [symbol, title, value])
        tile.axis = .vertical
        tile.alignment = .leading
        tile.spacing = Theme.Spacing.xs
        if let detail = record.detail {
            let detailLabel = label(detail, role: .metricDetail, color: Theme.Color.tertiaryLabel)
            detailLabel.numberOfLines = 2
            tile.addArrangedSubview(detailLabel)
        }
        tile.isAccessibilityElement = true
        tile.accessibilityLabel = [record.title, record.value, record.detail]
            .compactMap { $0 }.joined(separator: ", ")
        return tile
    }

    private func trophyCase(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = [
            heading(
                String(localized: "The trophy case"),
                trailing: TrophyRoom.headline(analytics.trophies))
        ]
        let earned = analytics.trophies.filter(\.earned)
        if !earned.isEmpty {
            views.append(earnedStrip(earned))
        }
        for (index, trophy) in TrophyRoom.nextUp(analytics.trophies).enumerated() {
            views.append(
                meter(
                    label: trophy.title, value: "", detail: trophy.progressLine,
                    fraction: trophy.percent / 100, hot: index == 0))
        }
        if let title = GameCenterCoordinator.shared.actionTitle {
            views.append(dashboardButton(title))
        }
        if let line = GameCenterCoordinator.shared.unavailableLine {
            views.append(label(line, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        return card(views)
    }

    private func earnedStrip(_ earned: [Trophy]) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        for trophy in earned.prefix(10) {
            let symbol = UIImageView(image: UIImage(systemName: trophy.symbolName))
            symbol.tintColor = Theme.Color.accent
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 15, weight: .semibold)
            symbol.contentMode = .scaleAspectFit
            row.addArrangedSubview(symbol)
        }
        if earned.count > 10 {
            row.addArrangedSubview(
                label(
                    "+\(earned.count - 10)", role: .panelDetail,
                    color: Theme.Color.secondaryLabel))
        }
        row.addArrangedSubview(UIView())
        row.isAccessibilityElement = true
        row.accessibilityLabel = String(
            localized: "Earned: \(earned.map(\.title).joined(separator: ", "))")
        return row
    }

    private func dashboardButton(_ title: String) -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Theme.Spacing.xs
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold)
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = Theme.Color.accent
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(openGameCenter), for: .touchUpInside)
        return button
    }

    @objc private func openGameCenter() {
        GameCenterCoordinator.shared.openDashboard(from: self)
    }

    @objc private func gameCenterStandingChanged() {
        if analytics != nil {
            hasAnimatedBars = true
            render()
        }
    }

    private func insights(_ analytics: UsageAnalytics) -> UIView {
        var views: [UIView] = []
        for line in analytics.insights {
            let symbol = UIImageView(image: UIImage(systemName: "sparkles"))
            symbol.tintColor = Theme.Color.special
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 13, weight: .medium)
            symbol.contentMode = .scaleAspectFit
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
            let text = label(line, role: .metricDetail, color: Theme.Color.label)
            let row = UIStackView(arrangedSubviews: [symbol, text])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = Theme.Spacing.s
            views.append(row)
        }
        return card(views)
    }

    private func primeBarAnimation() {
        guard !hasAnimatedBars, !UIAccessibility.isReduceMotionEnabled else {
            pendingBars = []
            hasAnimatedBars = true
            return
        }
        for entry in pendingBars {
            entry.bar.transform = CGAffineTransform(translationX: 0, y: entry.height / 2)
                .scaledBy(x: 1, y: 0.001)
        }
    }

    private func animateBarsIfNeeded() {
        guard !hasAnimatedBars, !pendingBars.isEmpty else { return }
        hasAnimatedBars = true
        let bars = pendingBars
        pendingBars = []
        UIView.animate(
            withDuration: 0.5, delay: 0.05, options: [.curveEaseOut],
            animations: {
                for entry in bars { entry.bar.transform = .identity }
            }, completion: nil)
    }

    private func heading(_ text: String, trailing: String?) -> UIView {
        var views: [UIView] = [
            label(text, role: .panelTitle, color: Theme.Color.label), UIView(),
        ]
        if let trailing {
            views.append(label(trailing, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .firstBaseline
        return row
    }

    private func meter(
        label name: String, value: String, detail: String, fraction: Double, hot: Bool
    ) -> UIView {
        let title = label(name, role: .metricDetail, color: Theme.Color.label)
        let count = label(detail, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
        count.setContentHuggingPriority(.required, for: .horizontal)
        let money = UILabel()
        money.text = value
        money.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        money.textColor = Theme.Color.label
        money.setContentHuggingPriority(.required, for: .horizontal)
        money.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [title, UIView(), count, money])
        top.axis = .horizontal
        top.spacing = Theme.Spacing.s
        top.alignment = .firstBaseline

        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = UIView()
        fill.backgroundColor = hot ? Theme.Color.accent : Theme.Color.info
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.01, min(1, fraction))),
        ])

        let block = UIStackView(arrangedSubviews: [top, track])
        block.axis = .vertical
        block.spacing = 4
        block.isAccessibilityElement = true
        block.accessibilityLabel = "\(name), \(value), \(detail)"
        return block
    }

    private func card(_ views: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        stack.backgroundColor = Theme.Color.secondaryBackground
        stack.layer.cornerRadius = Theme.Radius.card
        stack.layer.cornerCurve = .continuous
        return stack
    }

    /// Every reading on this screen is set from the shared ramp: the role decides the size, the
    /// weight, the tracking and whether the digits share a width, so a column of numbers stays a
    /// column while it changes.
    private func label(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(role, color: color))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
