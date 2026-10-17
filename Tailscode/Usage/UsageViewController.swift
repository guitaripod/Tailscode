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
    private let titleView = UsageTitleView()
    private let boardBar = BoardBar()
    private let heroCard = HeroCard()
    private let cardsStack = UIStackView()
    private let moreCard = MoreProvidersCard()
    private let countingFooter = CountingFooter()
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
        message: String(localized: "Connect to a Claude Code, opencode or Oh My Pi server to see usage."))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Usage")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = titleView
        view.backgroundColor = Theme.Color.groupedBackground
        setupScroll()
        setupEmptyState()
        buildContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardChanged), name: QuotaBoardStore.didChange, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: UsageViewController, _: UITraitCollection) in
            controller.render()
        }
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
        contentStack.spacing = Theme.Spacing.m
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
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
            emptyStateView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildContent() {
        errorLabel.font = Theme.Ramp.font(.panelLabel)
        errorLabel.textColor = Theme.Color.danger
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        heroCard.isHidden = true
        cardsStack.axis = .vertical
        cardsStack.spacing = Theme.Spacing.m
        moreCard.isHidden = true
        countingFooter.isHidden = true
        monthCard.addTarget(self, action: #selector(openAnalytics), for: .touchUpInside)

        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(boardBar)
        contentStack.addArrangedSubview(heroCard)
        contentStack.addArrangedSubview(cardsStack)
        contentStack.addArrangedSubview(moreCard)
        contentStack.addArrangedSubview(monthCard)
        contentStack.addArrangedSubview(countingFooter)
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
            titleView.subtitle = refreshing ? String(localized: "Asking the providers…") : nil
            return
        }
        let age = Date().timeIntervalSince(lastRefreshed)
        var text =
            age < 60
            ? String(localized: "Updated just now")
            : String(
                localized: "Updated \(lastRefreshed.formatted(.relative(presentation: .named)))")
        if refreshing { text += " · " + String(localized: "refreshing") }
        titleView.subtitle = text
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
        if !fetched.isEmpty {
            lastRefreshed = Date()
            RangeRecorder.observe(quotas: QuotaRollup.account(from: allReports()).map(\.quota))
        }
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
        let applyChange: ((inout QuotaBoardPreferences) -> Void) -> Void = {
            [weak self] change in
            QuotaBoardStore.update(change)
            self?.render()
        }
        boardBar.render(
            QuotaBoard.choices(holdings: holdings, offers: offers, preferences: preferences),
            change: applyChange)
        navigationItem.rightBarButtonItem = BoardBar.arrangeItem(
            preferences: preferences, change: applyChange)

        let trail = RangeStore.trail
        let visible = QuotaBoard.arrange(holdings, preferences: preferences)
        let keys = visible.map(QuotaBoard.key)
        if let lead = QuotaBoard.lead(visible, preferences: preferences) {
            heroCard.isHidden = false
            heroCard.apply(
                provider: lead.holding.providerName,
                gauge: Self.gaugeVM(lead.gauge, in: lead.holding.quota, trail: trail),
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
                gauges: holding.gauges.map { Self.gaugeVM($0, in: holding.quota, trail: trail) })
            card.onMenu = { [weak self] in
                self?.cardMenu(for: key, position: index, of: keys) ?? UIMenu()
            }
            cardsStack.addArrangedSubview(card)
        }
        let shownOffers = offers.filter { QuotaBoard.shows($0, preferences: preferences) }
        moreCard.isHidden = shownOffers.isEmpty
        moreCard.render(
            offers: shownOffers, accent: Self.accent(for:),
            open: { [weak self] key in
                if key == "deepseek" {
                    self?.openDeepSeekEditor()
                } else {
                    self?.openOllamaEditor()
                }
            },
            hide: { [weak self] key in
                QuotaBoardStore.update { $0.setHidden(key, true) }
                self?.render()
            })
        countingFooter.isHidden = visible.isEmpty
        countingFooter.render(visible)
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
        PaceBar.brand(slug: key)
    }

    private static func gaugeVM(
        _ gauge: UsageQuota.Gauge, in quota: UsageQuota, trail: QuotaTrail
    ) -> GaugeVM {
        let isBalance = QuotaBoard.isBalance(gauge)
        let slug = ProviderBrand.brand(quota.providerName)
        let pace =
            isBalance
            ? PaceRow.balance(provider: quota.providerName, slug: slug, gauge: gauge, trail: trail)
            : PaceRow.window(provider: quota.providerName, slug: slug, gauge: gauge, trail: trail)
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
            percentText: percent, caption: caption(gauge, in: quota), isBalance: isBalance,
            pace: pace)
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

