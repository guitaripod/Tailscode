import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

private struct QuotaUnavailableError: LocalizedError, Sendable {
    var errorDescription: String? {
        String(
            localized:
                "Claude quota is unavailable right now — the bridge couldn't reach api.anthropic.com."
        )
    }
}

private struct GaugeVM {
    let name: String
    let fraction: Double
    let percentText: String
    let caption: String
    let isBalance: Bool
}

private func rampColor(for fraction: Double, accent: UIColor) -> UIColor {
    if fraction > 0.85 { return Theme.Color.danger }
    if fraction >= 0.6 { return Theme.Color.warning }
    return accent
}

/// The account's quota picture, arranged the way the person keeps it. The board's switches lead —
/// every provider the account reported or this phone can offer a key for, shown or hidden with one
/// tap, the arrangement and the lead behind one menu — then the tightest window as the ring, then
/// a card per provider with its windows as bars, its reset, its money and the facts the provider
/// reports. Which cards, in what order and whether the lead shows is ``QuotaBoard``'s; this
/// screen draws them, opens on the last figures the app landed anywhere, and asks every bridge
/// again while it is up.
@MainActor
final class UsageViewController: UIViewController {
    private static let staleInterval: TimeInterval = 5 * 60
    private static let fetchDeadline: TimeInterval = 10

    private let scrollView = UIScrollView()
    private var rail: ReadableRail?
    private let contentStack = UIStackView()
    private let refresher = UIRefreshControl()
    private let errorLabel = UILabel()
    private let updatedLabel = UILabel()
    private let boardBar = BoardBar()
    private let heroCard = HeroCard()
    private let cardsStack = UIStackView()
    private let monthCard = MonthCard()
    private var loadTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var lastRefreshed: Date?
    private var analytics: UsageAnalytics?
    private var hasSeeded = false
    private var refreshing = false
    private var hasClaudeProfile = false
    private var hasOpencodeProfile = false

    /// What every bridge reported, by the server that answered — kept as reports so a second
    /// machine refines the account's numbers instead of replacing them.
    private var reports: [(String, UsageQuota)] = []
    /// This phone's own readings: doors no bridge holds a key for.
    private var deepseek: UsageQuota?
    private var ollama: UsageQuota?

    private lazy var emptyStateView = EmptyStateView(
        symbol: "gauge.with.dots.needle.67percent",
        title: String(localized: "Not connected"),
        message: String(localized: "Connect to a Claude Code or opencode server to see usage."))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Usage")
        view.backgroundColor = Theme.Color.groupedBackground
        setupScroll()
        setupEmptyState()
        buildContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardChanged), name: QuotaBoardStore.didChange, object: nil)
        startLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshUpdatedLabel()
        guard loadTask == nil else { return }
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) > Self.staleInterval {
            startLoad()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            loadTask?.cancel()
            loadTask = nil
            analyticsTask?.cancel()
            analyticsTask = nil
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
            if !Task.isCancelled { loadTask = nil }
        }
    }

    private func setupScroll() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        refresher.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        scrollView.refreshControl = refresher
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = Theme.Spacing.l
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.l, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.centerXAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        rail = ReadableRail(
            host: view,
            compact: [
                contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
            ],
            regular: [
                contentStack.widthAnchor.constraint(equalTo: view.readableContentGuide.widthAnchor)
            ])
    }

    private func setupEmptyState() {
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildContent() {
        updatedLabel.font = Theme.Ramp.font(.panelFootnote)
        updatedLabel.textColor = Theme.Color.secondaryLabel
        updatedLabel.textAlignment = .center
        updatedLabel.isHidden = true

        errorLabel.font = Theme.Ramp.font(.panelLabel)
        errorLabel.textColor = Theme.Color.danger
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        heroCard.isHidden = true
        cardsStack.axis = .vertical
        cardsStack.spacing = Theme.Spacing.l
        monthCard.addTarget(self, action: #selector(openAnalytics), for: .touchUpInside)

        contentStack.addArrangedSubview(updatedLabel)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(boardBar)
        contentStack.addArrangedSubview(heroCard)
        contentStack.addArrangedSubview(cardsStack)
        contentStack.addArrangedSubview(monthCard)
        contentStack.isHidden = true
    }

    @objc private func pulledToRefresh() {
        startLoad()
    }

    @objc private func boardChanged() {
        render()
    }

    @objc private func openAnalytics() {
        Theme.Haptics.tap()
        navigationController?.pushViewController(
            AnalyticsViewController(analytics: analytics), animated: true)
    }

    private func openDeepSeekEditor() {
        Theme.Haptics.tap()
        navigationController?.pushViewController(DeepSeekKeyViewController(), animated: true)
    }

    private func openOllamaEditor() {
        Theme.Haptics.tap()
        navigationController?.pushViewController(OllamaKeyViewController(), animated: true)
    }

    private func refreshUpdatedLabel() {
        guard let lastRefreshed else {
            updatedLabel.isHidden = refreshing ? false : true
            updatedLabel.text = refreshing ? String(localized: "Asking the providers…") : nil
            return
        }
        let age = Date().timeIntervalSince(lastRefreshed)
        var text =
            age < 60
            ? String(localized: "Updated just now")
            : String(
                localized: "Updated \(lastRefreshed.formatted(.relative(presentation: .named)))")
        if refreshing { text += " · " + String(localized: "refreshing") }
        updatedLabel.text = text
        updatedLabel.isHidden = false
    }

    private func load() async {
        let controller = ConnectionController.shared
        let profiles = controller.profiles
        let claudeProfiles = profiles.filter { $0.backend == .claudeCode }
            .sorted { lhs, _ in lhs.id == controller.activeProfileID }
        hasClaudeProfile = !claudeProfiles.isEmpty
        hasOpencodeProfile = profiles.contains { $0.backend == .openCode }

        guard hasClaudeProfile || hasOpencodeProfile else {
            AppLogger.session.info("usage: no Claude Code or opencode profile connected")
            showEmptyState()
            return
        }

        emptyStateView.isHidden = true
        scrollView.isHidden = false
        errorLabel.isHidden = true
        contentStack.isHidden = false
        seedFromSnapshot()
        refreshing = true
        refreshUpdatedLabel()
        render()

        async let bridges = fetchReports(
            profiles: claudeProfiles, controller: controller, deadline: Self.fetchDeadline)
        async let deepseekReading = DeepSeekBalance.refresh()
        async let ollamaReading = OllamaUsage.refresh()
        let fetched = await bridges
        let readings = await (deepseekReading, ollamaReading)
        guard !Task.isCancelled else { return }

        if !fetched.isEmpty { reports = fetched }
        if let reading = readings.0 {
            deepseek = Self.deepseekQuota(reading)
        } else if deepseek == nil {
            deepseek = Self.savedQuota(named: DeepSeekBalance.providerName)
        }
        if let reading = readings.1 {
            ollama = OllamaCloud.snapshot(for: reading)
        } else if ollama == nil {
            ollama = Self.savedQuota(named: OllamaCloud.providerName)
        }
        if !DeepSeekCredentials.hasToken { deepseek = nil }
        if !OllamaCredentials.hasToken { ollama = nil }

        refreshing = false
        if hasClaudeProfile, fetched.isEmpty, reports.isEmpty {
            AppLogger.session.info("usage: no Claude usage API reachable from any bridge")
            showError(QuotaUnavailableError())
        } else if hasClaudeProfile, fetched.isEmpty {
            AppLogger.session.info("usage: bridges did not answer; keeping the last figures")
        }
        if !fetched.isEmpty { lastRefreshed = Date() }
        refreshUpdatedLabel()
        refresher.endRefreshing()
        render()
        if hasClaudeProfile { loadAnalytics() }
    }

    /// Every bridge asked at once, each answer landing as it arrives and the haul kept when the
    /// deadline fires, so a dead bridge cannot starve the reachable ones. A bridge answers with
    /// what its machine can read, and where the provider's own usage API is unreachable that
    /// includes a reading it worked out from a local database — not the account's number, and
    /// indistinguishable from one once stored beside it — so the screen takes the measurement or
    /// nothing.
    private func fetchReports(
        profiles: [ConnectionProfile], controller: ConnectionController, deadline: TimeInterval
    ) async -> [(String, UsageQuota)] {
        let bridges = profiles.enumerated().compactMap { index, profile in
            controller.makeBackend(for: profile).map { (index, profile.name, $0) }
        }
        guard !bridges.isEmpty else { return [] }
        let results = await withTaskGroup(
            of: (index: Int, server: String, quotas: [UsageQuota])?.self
        ) { group in
            for (index, name, backend) in bridges {
                group.addTask {
                    var fetched: [UsageQuota] = []
                    if let primary = try? await backend.usageQuota() { fetched.append(primary) }
                    if let extra = try? await backend.additionalUsageQuotas() {
                        fetched.append(contentsOf: extra)
                    }
                    return (
                        index, name,
                        fetched.filter { !$0.source.lowercased().contains("estimated") }
                    )
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            var collected: [(index: Int, server: String, quotas: [UsageQuota])] = []
            while collected.count < bridges.count, let outcome = await group.next() {
                guard let outcome else { break }
                collected.append(outcome)
            }
            group.cancelAll()
            return collected
        }
        for entry in results {
            AppLogger.session.info(
                "usage: \(entry.server) answered with \(entry.quotas.count) quota(s)")
        }
        return results.sorted { $0.index < $1.index }
            .flatMap { entry in entry.quotas.map { (entry.server, $0) } }
    }

    /// The sparkline is a preview and the analytics screen is the point: one fetch feeds both,
    /// cached here so the push opens on numbers it already has.
    private func loadAnalytics() {
        guard analyticsTask == nil else { return }
        analyticsTask = Task {
            let haul = await AnalyticsFetcher.fetch()
            guard !Task.isCancelled else { return }
            analytics = UsageAnalytics(
                servers: haul.servers, missingServers: haul.missing, window: UsageWindow.current)
            GameCenterCoordinator.shared.note(analytics)
            monthCard.render(analytics)
            analyticsTask = nil
        }
    }

    /// Opens on the last numbers the app landed anywhere — the shared snapshot the widget, the
    /// background refresh and silent pushes all write — instead of spinners re-derived from
    /// scratch on every visit. Runs once per screen: a later pull-to-refresh must not roll live
    /// cards back to the older saved figures on its way to fetching new ones.
    private func seedFromSnapshot() {
        guard !hasSeeded else { return }
        hasSeeded = true
        guard let entry = UsageWidgetStore.read() else { return }
        var seeded: [(String, UsageQuota)] = []
        for provider in entry.providers where !provider.gauges.isEmpty {
            switch ProviderBrand.brand(provider.providerName) {
            case "deepseek": deepseek = Self.quota(from: provider)
            case "ollama-cloud": ollama = Self.quota(from: provider)
            default: seeded.append(("", Self.quota(from: provider)))
            }
        }
        if reports.isEmpty { reports = seeded }
        if lastRefreshed == nil, !seeded.isEmpty { lastRefreshed = entry.date }
    }

    private static func savedQuota(named name: String) -> UsageQuota? {
        UsageWidgetStore.read()?.providers.first { $0.providerName == name }.map(quota(from:))
    }

    /// A stored snapshot as a report: whatever name the server that answered used, its windows as
    /// gauges, and a source that says the figures were saved rather than just measured.
    private static func quota(from provider: UsageWidgetEntry.ProviderSnapshot) -> UsageQuota {
        UsageQuota(
            providerName: provider.providerName,
            subtitle: provider.subtitle,
            source: String(localized: "saved figures"),
            live: provider.isLive,
            gauges: provider.gauges.map { gauge in
                UsageQuota.Gauge(
                    key: gauge.label, label: gauge.label, fraction: gauge.fraction,
                    resetsAt: gauge.resetsAt, trustedReset: false, usedUSD: gauge.usedUSD,
                    limitUSD: gauge.limitUSD, currency: gauge.currency)
            },
            details: [])
    }

    /// The prepaid balance as a report: money with no ceiling, which every renderer draws as the
    /// number itself, with what the money is made of behind the card.
    private static func deepseekQuota(_ reading: DeepSeekBalance.Reading) -> UsageQuota {
        UsageQuota(
            providerName: DeepSeekBalance.providerName,
            subtitle: String(localized: "Prepaid balance · direct API"),
            source: "api.deepseek.com",
            live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "balance", label: String(localized: "Balance"),
                    fraction: reading.isAvailable ? 0 : 1, resetsAt: nil, trustedReset: false,
                    usedUSD: reading.total, limitUSD: nil, currency: reading.currency)
            ],
            details: [
                UsageQuota.Detail(
                    key: String(localized: "Topped up"),
                    value: DeepSeekBalance.currency(reading.toppedUp, reading.currency)),
                UsageQuota.Detail(
                    key: String(localized: "Granted"),
                    value: DeepSeekBalance.currency(reading.granted, reading.currency)),
            ])
    }

    private func allReports() -> [(String, UsageQuota)] {
        var all = reports
        if let deepseek { all.append(("", deepseek)) }
        if let ollama { all.append(("", ollama)) }
        return all
    }

    /// The doors this phone can only offer a key for, offered only where they could matter — an
    /// opencode server is what fronts these models.
    private func offers(reported: Set<String>) -> [QuotaBoard.Offer] {
        var out: [QuotaBoard.Offer] = []
        if !reported.contains("deepseek"), hasOpencodeProfile || DeepSeekCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "deepseek", name: DeepSeekBalance.providerName))
        }
        if !reported.contains("ollama-cloud"), hasOpencodeProfile || OllamaCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "ollama-cloud", name: OllamaCloud.providerName))
        }
        return out
    }

    private func render() {
        let preferences = QuotaBoardStore.current
        let holdings = QuotaRollup.account(from: allReports())
        let offers = offers(reported: Set(holdings.map(QuotaBoard.key)))
        boardBar.render(
            QuotaBoard.choices(holdings: holdings, offers: offers, preferences: preferences),
            preferences: preferences
        ) { [weak self] change in
            QuotaBoardStore.update(change)
            self?.render()
        }

        let visible = QuotaBoard.arrange(holdings, preferences: preferences)
        let keys = visible.map(QuotaBoard.key)
        if let lead = QuotaBoard.lead(visible, preferences: preferences) {
            heroCard.isHidden = false
            heroCard.apply(
                provider: lead.holding.providerName,
                gauge: Self.gaugeVM(lead.gauge, in: lead.holding.quota),
                accent: Self.accent(for: QuotaBoard.key(lead.holding)))
        } else {
            heroCard.isHidden = true
        }

        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if holdings.isEmpty, offers.isEmpty {
            cardsStack.addArrangedSubview(
                Self.note(
                    refreshing
                        ? String(localized: "Asking the providers…")
                        : String(localized: "No provider reports a quota.")))
        } else if visible.isEmpty, !holdings.isEmpty {
            cardsStack.addArrangedSubview(
                Self.note(String(localized: "Every provider is hidden — switch one on above.")))
        }
        for (index, holding) in visible.enumerated() {
            let key = QuotaBoard.key(holding)
            let card = ProviderCard(
                holding: holding, accent: Self.accent(for: key),
                gauges: holding.gauges.map { Self.gaugeVM($0, in: holding.quota) })
            card.onMenu = { [weak self] in
                self?.cardMenu(for: key, position: index, of: keys) ?? UIMenu()
            }
            cardsStack.addArrangedSubview(card)
        }
        for offer in offers where QuotaBoard.shows(offer, preferences: preferences) {
            let card = OfferCard(offer: offer, accent: Self.accent(for: offer.key))
            card.onOpenEditor = { [weak self] in
                if offer.key == "deepseek" {
                    self?.openDeepSeekEditor()
                } else {
                    self?.openOllamaEditor()
                }
            }
            card.onHide = { [weak self] in
                QuotaBoardStore.update { $0.setHidden(offer.key, true) }
                self?.render()
            }
            cardsStack.addArrangedSubview(card)
        }
        monthCard.isHidden = !hasClaudeProfile
    }

    /// The verbs a card owns: its place on the board, and whether it is on it at all.
    private func cardMenu(for key: String, position: Int, of keys: [String]) -> UIMenu {
        let up = UIAction(
            title: String(localized: "Move up"), image: UIImage(systemName: "chevron.up"),
            attributes: position > 0 ? [] : .disabled
        ) { [weak self] _ in
            QuotaBoardStore.update { $0.move(key, by: -1, among: keys) }
            self?.render()
        }
        let down = UIAction(
            title: String(localized: "Move down"), image: UIImage(systemName: "chevron.down"),
            attributes: position < keys.count - 1 ? [] : .disabled
        ) { [weak self] _ in
            QuotaBoardStore.update { $0.move(key, by: 1, among: keys) }
            self?.render()
        }
        let hide = UIAction(
            title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")
        ) { [weak self] _ in
            QuotaBoardStore.update { $0.setHidden(key, true) }
            self?.render()
        }
        return UIMenu(children: [up, down, hide])
    }

    private static func accent(for key: String) -> UIColor {
        switch key {
        case "claude": return Theme.Color.claude
        case "grok": return Theme.Color.grok
        case "opencode": return Theme.Color.opencode
        case "deepseek": return Theme.Color.modelFamily(.deepseek)
        case "ollama-cloud": return Theme.Color.ollamaCloud
        default: return Theme.Color.accent
        }
    }

    private static func gaugeVM(_ gauge: UsageQuota.Gauge, in quota: UsageQuota) -> GaugeVM {
        let isBalance = QuotaBoard.isBalance(gauge)
        let percent: String
        if isBalance {
            percent =
                gauge.fraction >= QuotaSurface.exhaustedFloor
                ? String(localized: "Empty")
                : QuotaGlance.money(gauge.usedUSD ?? 0, gauge.currency)
        } else {
            percent = QuotaSurface.amountLabel(
                fraction: gauge.fraction,
                percentText: "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%")
        }
        return GaugeVM(
            name: UsageGaugeFormat.gaugeLabel(gauge.label), fraction: gauge.fraction,
            percentText: percent, caption: caption(gauge, in: quota), isBalance: isBalance)
    }

    /// One line under the bar: the money where the window is money, and the reset where the
    /// provider said when it comes — never two stacked lines of fine print. A balance's caption
    /// is what the money is made of.
    private static func caption(_ gauge: UsageQuota.Gauge, in quota: UsageQuota) -> String {
        if QuotaBoard.isBalance(gauge) {
            if gauge.fraction >= QuotaSurface.exhaustedFloor {
                return String(localized: "Top up to keep DeepSeek models running")
            }
            let made = quota.details.map { "\($0.key) \($0.value)" }
            return made.isEmpty ? "—" : made.joined(separator: " · ")
        }
        var parts: [String] = []
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            parts.append(
                "\(QuotaGlance.money(used, gauge.currency)) / \(QuotaGlance.money(limit, gauge.currency))"
            )
        }
        if let resetsAt = gauge.resetsAt {
            let remaining = QuotaSurface.countdown(to: resetsAt)
            parts.append(
                gauge.trustedReset
                    ? String(localized: "resets \(remaining)")
                    : String(localized: "~resets \(remaining)"))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private static func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.panelLabel)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    private func showEmptyState() {
        refresher.endRefreshing()
        scrollView.isHidden = true
        emptyStateView.isHidden = false
    }

    private func showError(_ error: Error) {
        errorLabel.text = String(localized: "Couldn't load usage: \(error.localizedDescription)")
        errorLabel.isHidden = false
    }
}

/// The board's switches: one chip per provider, lit in its brand's colour while shown and dimmed
/// while hidden — never removed, because a switch that vanishes when it is off cannot be switched
/// back — with the arrangement and the lead behind one menu at the end.
@MainActor
private final class BoardBar: UIView {
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let arrangeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)

        var arrange = UIButton.Configuration.plain()
        arrange.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        arrange.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20)
        arrangeButton.configuration = arrange
        arrangeButton.showsMenuAsPrimaryAction = true
        arrangeButton.accessibilityLabel = String(localized: "Arrange the board")
        arrangeButton.setContentHuggingPriority(.required, for: .horizontal)
        arrangeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroller)
        addSubview(arrangeButton)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.trailingAnchor.constraint(
                equalTo: arrangeButton.leadingAnchor, constant: -Theme.Spacing.s),
            arrangeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            arrangeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(
        _ choices: [QuotaBoard.Choice], preferences: QuotaBoardPreferences,
        change: @escaping ((inout QuotaBoardPreferences) -> Void) -> Void
    ) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for choice in choices {
            let accent = Self.accent(for: choice)
            var configuration =
                choice.isHidden ? UIButton.Configuration.plain() : UIButton.Configuration.tinted()
            configuration.title = choice.name
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.baseForegroundColor = choice.isHidden ? Theme.Color.secondaryLabel : accent
            configuration.baseBackgroundColor = accent
            configuration.background.strokeWidth = 1
            configuration.background.strokeColor =
                choice.isHidden ? Theme.Color.separator : accent.withAlphaComponent(0.4)
            if !choice.isReported {
                configuration.image = UIImage(systemName: "key")
                configuration.imagePadding = 4
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 10)
            }
            let chip = UIButton(configuration: configuration)
            chip.accessibilityLabel = choice.name
            chip.accessibilityValue =
                choice.isHidden ? String(localized: "Hidden") : String(localized: "Shown")
            chip.accessibilityHint =
                choice.isHidden
                ? String(localized: "Shows this provider on the board")
                : String(localized: "Hides this provider from the board")
            let key = choice.key
            let hidden = choice.isHidden
            chip.addAction(
                UIAction { _ in
                    Theme.Haptics.selection()
                    change { $0.setHidden(key, !hidden) }
                }, for: .touchUpInside)
            row.addArrangedSubview(chip)
        }

        let arrangements = QuotaBoardPreferences.Arrangement.allCases.map { option in
            UIAction(
                title: option.title, state: option == preferences.arrangement ? .on : .off
            ) { _ in
                change { $0.arrangement = option }
            }
        }
        let lead = UIAction(
            title: String(localized: "Lead with the tightest window"),
            state: preferences.leadsWithTightest ? .on : .off
        ) { _ in
            change { $0.leadsWithTightest.toggle() }
        }
        arrangeButton.menu = UIMenu(children: [
            UIMenu(title: String(localized: "Arrange"), options: .displayInline, children: arrangements),
            UIMenu(options: .displayInline, children: [lead]),
        ])
    }

    private static func accent(for choice: QuotaBoard.Choice) -> UIColor {
        switch choice.key {
        case "claude": return Theme.Color.claude
        case "grok": return Theme.Color.grok
        case "opencode": return Theme.Color.opencode
        case "deepseek": return Theme.Color.modelFamily(.deepseek)
        case "ollama-cloud": return Theme.Color.ollamaCloud
        default: return Theme.Color.accent
        }
    }
}

/// The tightest window across every provider, worn big: the one number a visit to this screen
/// is usually for.
@MainActor
private final class HeroCard: UIView {
    private let ring = RingGaugeView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(provider: String, gauge: GaugeVM, accent: UIColor) {
        ring.configure(
            fraction: gauge.fraction,
            color: rampColor(for: gauge.fraction, accent: accent),
            percentText: gauge.percentText)
        titleLabel.text = "\(provider) · \(gauge.name)"
        captionLabel.text = gauge.caption
        accessibilityLabel = "\(titleLabel.text ?? ""), \(gauge.percentText), \(gauge.caption)"
    }

    private func build() {
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        isAccessibilityElement = true

        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 132),
            ring.heightAnchor.constraint(equalToConstant: 132),
        ])

        let caption = UILabel()
        caption.text = String(localized: "Tightest window")
        caption.font = Theme.Ramp.font(.metricLabel)
        caption.textColor = Theme.Color.secondaryLabel
        caption.textAlignment = .center

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.text = "—"

        captionLabel.font = Theme.Ramp.font(.toolOutput)
        captionLabel.textColor = Theme.Color.secondaryLabel
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2
        captionLabel.text = "—"

        let stack = UIStackView(arrangedSubviews: [caption, ring, titleLabel, captionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Spacing.s
        stack.setCustomSpacing(Theme.Spacing.m, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }
}

/// One provider's card. Every provider wears the same anatomy — name, plan, provenance, windows
/// as labelled bars, a menu for its place on the board, and the fine print folded behind a
/// chevron — so the screen reads as one repeated shape rather than five cards that each invented
/// their own. A balance is the one exception the shape allows: money with no ceiling is drawn as
/// the number itself rather than a bar against a cap nobody stated.
@MainActor
private final class ProviderCard: UIView {
    var onMenu: (() -> UIMenu)?

    private let disclosure = DisclosureRow(title: String(localized: "How this is counted"))
    private let noteLabel = UILabel()
    private let detailsStack = UIStackView()
    private var detailsExpanded = false
    private let menuButton = UIButton(type: .system)

    init(holding: QuotaHolding, accent: UIColor, gauges: [GaugeVM]) {
        super.init(frame: .zero)
        build(holding: holding, accent: accent, gauges: gauges)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build(holding: QuotaHolding, accent: UIColor, gauges: [GaugeVM]) {
        let quota = holding.quota
        let gaugeStack = UIStackView()
        gaugeStack.axis = .vertical
        gaugeStack.spacing = Theme.Spacing.m
        for gauge in gauges {
            gaugeStack.addArrangedSubview(
                gauge.isBalance ? balanceRow(gauge) : gaugeRow(gauge, accent: accent))
        }
        let container = Self.card(
            [header(quota, accent: accent), gaugeStack, fold(holding)], spacing: Theme.Spacing.l)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func header(_ quota: UsageQuota, accent: UIColor) -> UIView {
        let title = UILabel()
        title.text = quota.providerName
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = accent
        title.setContentHuggingPriority(.required, for: .horizontal)

        let subtitle = UILabel()
        subtitle.text = quota.subtitle.isEmpty ? " " : quota.subtitle
        subtitle.font = Theme.Ramp.font(.panelFootnote)
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 1

        let names = UIStackView(arrangedSubviews: [title, subtitle])
        names.axis = .vertical
        names.spacing = 2
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
        configuration.contentInsets = .zero
        menuButton.configuration = configuration
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion([self?.onMenu?() ?? UIMenu()])
            }
        ])
        menuButton.accessibilityLabel = String(localized: "Card options")
        menuButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [
            names, spacer, Self.pill(QuotaSurface.badge(quota), live: quota.live, accent: accent),
            menuButton,
        ])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        return header
    }

    private static func pill(_ text: String, live: Bool, accent: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.metricLabel)
        label.textColor = live ? accent : Theme.Color.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.backgroundColor =
            (live ? accent : Theme.Color.secondaryLabel).withAlphaComponent(0.14)
        background.layer.cornerRadius = 9
        background.layer.cornerCurve = .continuous
        background.setContentHuggingPriority(.required, for: .horizontal)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            background.heightAnchor.constraint(equalToConstant: 18),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Theme.Spacing.s),
        ])
        return background
    }

    private func gaugeRow(_ gauge: GaugeVM, accent: UIColor) -> UIView {
        let name = UILabel()
        name.text = gauge.name
        name.font = Theme.Ramp.font(.panelLabel)
        name.textColor = Theme.Color.label
        name.numberOfLines = 1
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.7
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 4
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = UIView()
        fill.backgroundColor = rampColor(for: gauge.fraction, accent: accent)
        fill.layer.cornerRadius = 4
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 8),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.01, min(1, gauge.fraction))),
        ])

        let percent = UILabel()
        percent.text = gauge.percentText
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percent.textColor =
            gauge.fraction >= QuotaSurface.exhaustedFloor ? Theme.Color.danger : Theme.Color.label
        percent.textAlignment = .right
        percent.setContentHuggingPriority(.required, for: .horizontal)
        percent.setContentCompressionResistancePriority(.required, for: .horizontal)

        let line = UIStackView(arrangedSubviews: [name, track, percent])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Theme.Spacing.s

        let caption = UILabel()
        caption.text = gauge.caption
        caption.font = Theme.Ramp.font(.toolOutput)
        caption.textColor = Theme.Color.secondaryLabel
        caption.numberOfLines = 1
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.8

        let row = UIStackView(arrangedSubviews: [line, caption])
        row.axis = .vertical
        row.spacing = Theme.Spacing.xs
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(gauge.name), \(gauge.percentText), \(gauge.caption)"
        return row
    }

    private func balanceRow(_ gauge: GaugeVM) -> UIView {
        let value = UILabel()
        value.text = gauge.percentText
        value.font = Theme.Ramp.font(.metricLarge)
        value.textColor =
            gauge.fraction >= QuotaSurface.exhaustedFloor ? Theme.Color.danger : Theme.Color.label
        value.numberOfLines = 1

        let caption = UILabel()
        caption.text = gauge.caption
        caption.font = Theme.Ramp.font(.toolOutput)
        caption.textColor = Theme.Color.secondaryLabel
        caption.numberOfLines = 2

        let row = UIStackView(arrangedSubviews: [value, caption])
        row.axis = .vertical
        row.spacing = Theme.Spacing.xs
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(gauge.name), \(gauge.percentText), \(gauge.caption)"
        return row
    }

    /// The fine print folds away: the bars answer the daily question, and the counting — caps,
    /// hosts, the source the numbers came from — is there for the visit that asks.
    private func fold(_ holding: QuotaHolding) -> UIView {
        disclosure.addTarget(self, action: #selector(toggleDetails), for: .touchUpInside)
        noteLabel.font = Theme.Ramp.font(.panelFootnote)
        noteLabel.textColor = Theme.Color.secondaryLabel
        noteLabel.numberOfLines = 0
        noteLabel.text = Self.provenanceNote(holding)
        noteLabel.isHidden = true
        noteLabel.alpha = 0

        detailsStack.axis = .vertical
        detailsStack.spacing = Theme.Spacing.s
        detailsStack.isHidden = true
        detailsStack.alpha = 0
        for detail in holding.quota.details {
            detailsStack.addArrangedSubview(detailRow(detail.key, detail.value))
        }

        let stack = UIStackView(arrangedSubviews: [disclosure, noteLabel, detailsStack])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        return stack
    }

    /// Where the numbers came from, in a sentence: the provider's own source, the machines that
    /// answered when more than one did, and what a live reading is.
    private static func provenanceNote(_ holding: QuotaHolding) -> String {
        let source = QuotaRollup.provenance(holding)
        guard holding.quota.live else {
            return String(localized: "Last saved figures from \(source) — refreshed from the server while this screen is up.")
        }
        return String(
            localized:
                "Live from \(source). Percentages are the account's actual consumption, not an estimate.")
    }

    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        disclosure.setExpanded(detailsExpanded)
        Theme.Haptics.selection()
        UIView.animate(withDuration: 0.25) {
            self.noteLabel.isHidden = !self.detailsExpanded
            self.noteLabel.alpha = self.detailsExpanded ? 1 : 0
            self.detailsStack.isHidden = !self.detailsExpanded
            self.detailsStack.alpha = self.detailsExpanded ? 1 : 0
        }
    }

    private func detailRow(_ title: String, _ value: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.Ramp.font(.panelLabel)
        label.textColor = Theme.Color.label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = Theme.Ramp.font(.code)
        valueLabel.textColor = Theme.Color.secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, valueLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        return row
    }

    fileprivate static func card(_ views: [UIView], spacing: CGFloat) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.Color.secondaryBackground
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }
}

/// A door with no reading to draw: a key nobody has set is a quiet invitation to add one rather
/// than an error, and a key that has been set but not answered for says exactly that — the
/// surface stays whole either way, and the invitation can be hidden like any card.
@MainActor
private final class OfferCard: UIView {
    var onOpenEditor: (() -> Void)?
    var onHide: (() -> Void)?

    init(offer: QuotaBoard.Offer, accent: UIColor) {
        super.init(frame: .zero)
        let deepseek = offer.key == "deepseek"
        let hasKey = deepseek ? DeepSeekCredentials.hasToken : OllamaCredentials.hasToken

        let title = UILabel()
        title.text = offer.name
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = accent

        let subtitle = UILabel()
        subtitle.text =
            deepseek
            ? String(localized: "Billed per token — no plan caps")
            : String(localized: "Plan-metered — session and weekly windows")
        subtitle.font = Theme.Ramp.font(.panelFootnote)
        subtitle.textColor = Theme.Color.secondaryLabel
        let names = UIStackView(arrangedSubviews: [title, subtitle])
        names.axis = .vertical
        names.spacing = 2

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
        configuration.contentInsets = .zero
        let menu = UIButton(configuration: configuration)
        menu.showsMenuAsPrimaryAction = true
        menu.menu = UIMenu(children: [
            UIAction(title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")) {
                [weak self] _ in self?.onHide?()
            }
        ])
        menu.accessibilityLabel = String(localized: "Card options")
        menu.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [names, UIView(), menu])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        let words = UILabel()
        words.numberOfLines = 0
        words.font = Theme.Ramp.font(.panelFootnote)
        words.textColor = Theme.Color.secondaryLabel
        if deepseek {
            words.text =
                hasKey
                ? String(
                    localized:
                        "The key is set and api.deepseek.com has not answered yet — the prepaid balance appears here as soon as it does.")
                : String(
                    localized:
                        "DeepSeek models billed straight to your own platform account are metered by a prepaid balance rather than by a plan. Add the key and the balance joins these numbers.")
        } else {
            words.text =
                hasKey
                ? String(
                    localized:
                        "The key is set and ollama.com has not answered yet — the plan's windows appear here as soon as it does.")
                : String(
                    localized:
                        "Ollama models served by ollama.com are metered by your plan. Add the account's API key and the session and weekly windows join these numbers.")
        }

        let button = UIButton(type: .system)
        button.setTitle(
            hasKey ? String(localized: "Edit API key") : String(localized: "Add API key"),
            for: .normal)
        button.titleLabel?.font = Theme.Ramp.font(.panelLabel)
        button.setTitleColor(Theme.Color.accent, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in self?.onOpenEditor?() }, for: .touchUpInside)

        let container = ProviderCard.card([header, words, button], spacing: Theme.Spacing.m)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class DisclosureRow: UIControl {
    private let titleLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.textColor = Theme.Color.secondaryLabel

        chevron.tintColor = Theme.Color.secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold)
        chevron.contentMode = .scaleAspectFit

        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = titleLabel.text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    func setExpanded(_ expanded: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.chevron.transform =
                expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        }
    }
}

/// The doorway to the analytics screen, wearing a month of days as its own preview: the
/// sparkline appears once a ledger has been read and the total rides beside the chevron.
@MainActor
private final class MonthCard: UIControl {
    private let totalLabel = UILabel()
    private let sparkline = UIStackView()
    private static let sparkHeight: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "The month in numbers")
        title.font = Theme.Ramp.font(.panelTitle)
        title.textColor = Theme.Color.label

        totalLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        totalLabel.textColor = Theme.Color.secondaryLabel
        totalLabel.textAlignment = .right
        totalLabel.setContentHuggingPriority(.required, for: .horizontal)
        totalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Theme.Color.secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 13, weight: .semibold)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [title, UIView(), totalLabel, chevron])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        sparkline.axis = .horizontal
        sparkline.distribution = .fillEqually
        sparkline.spacing = 2
        sparkline.isHidden = true

        let stack = UIStackView(arrangedSubviews: [header, sparkline])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title.text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func render(_ analytics: UsageAnalytics?) {
        totalLabel.text = analytics?.headline
        sparkline.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let analytics else {
            sparkline.isHidden = true
            return
        }
        sparkline.isHidden = false
        for day in analytics.days {
            let holder = UIView()
            let bar = UIView()
            let height = max(2, Self.sparkHeight * day.share)
            if day.share > 0 {
                bar.backgroundColor = day.isToday ? Theme.Color.accent : Theme.Color.info
                if !day.isToday { bar.alpha = 0.7 }
            } else {
                bar.backgroundColor = Theme.Color.separator
            }
            bar.layer.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(bar)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: Self.sparkHeight),
                bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: height),
            ])
            sparkline.addArrangedSubview(holder)
        }
        accessibilityValue = analytics.headline
    }
}
