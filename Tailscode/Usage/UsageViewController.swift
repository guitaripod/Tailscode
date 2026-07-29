import CodingAgentKit
import CodingAgentKitApple
import UIKit

private struct QuotaUnavailableError: LocalizedError, Sendable {
    var errorDescription: String? {
        String(
            localized:
                "Claude quota is unavailable right now — the bridge couldn't reach api.anthropic.com."
        )
    }
}

private struct CredentialsUnavailableError: LocalizedError, Sendable {
    let profileName: String
    var errorDescription: String? {
        String(localized: "Couldn't read stored credentials for \(profileName).")
    }
}

private struct GaugeVM {
    let name: String
    let fraction: Double
    let percentText: String
    let caption: String
}

private struct CardModel {
    let subtitle: String
    let pill: String
    let accent: UIColor
    let gauges: [GaugeVM]
    let details: [(String, String)]
    let note: String
}

@MainActor
final class UsageViewController: UIViewController {
    private static let staleInterval: TimeInterval = 5 * 60

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let refresher = UIRefreshControl()
    private let errorLabel = UILabel()
    private let updatedLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var lastRefreshed: Date?
    /// Cards currently showing real numbers, whether from the saved snapshot or
    /// a live answer. A refresh that fails must leave these alone.
    private var filledCards: Set<CardKind> = []
    private var hasSeeded = false

    private let claudeCard = ProviderCard(title: "Claude Code", accent: Theme.Color.claude)
    private let grokCard = ProviderCard(title: "Grok", accent: Theme.Color.grok)
    private let opencodeCard = ProviderCard(title: "opencode go", accent: Theme.Color.opencode)

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
        startLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshUpdatedLabel()
        guard loadTask == nil else { return }
        if loadedCaps != GoCaps.signature {
            startLoad()
            return
        }
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) > Self.staleInterval {
            startLoad()
        }
    }

    /// The caps the gauges on screen were computed against. Editing them in
    /// Settings changes what every opencode percentage means, so coming back
    /// here recomputes instead of waiting out the staleness window.
    private var loadedCaps = GoCaps.signature

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        loadedCaps = GoCaps.signature
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
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
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
        updatedLabel.font = Theme.Font.caption()
        updatedLabel.textColor = Theme.Color.secondaryLabel
        updatedLabel.textAlignment = .center
        updatedLabel.isHidden = true

        errorLabel.font = Theme.Font.subheadline()
        errorLabel.textColor = Theme.Color.danger
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        contentStack.addArrangedSubview(updatedLabel)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(claudeCard)
        contentStack.addArrangedSubview(grokCard)
        contentStack.addArrangedSubview(opencodeCard)
        contentStack.isHidden = true
    }

    @objc private func pulledToRefresh() {
        startLoad()
    }

    private func refreshUpdatedLabel() {
        guard let lastRefreshed else {
            updatedLabel.isHidden = true
            return
        }
        let age = Date().timeIntervalSince(lastRefreshed)
        updatedLabel.text = age < 60
            ? String(localized: "Updated just now")
            : String(
                localized: "Updated \(lastRefreshed.formatted(.relative(presentation: .named)))")
        updatedLabel.isHidden = false
    }

    private func load() async {
        let controller = ConnectionController.shared
        let profiles = controller.profiles
        let claudeProfile = preferredProfile(.claudeCode, profiles: profiles, controller: controller)
        let opencodeProfile = preferredProfile(.openCode, profiles: profiles, controller: controller)

        guard claudeProfile != nil || opencodeProfile != nil else {
            AppLogger.session.info("usage: no Claude Code or opencode profile connected")
            showEmptyState()
            return
        }

        emptyStateView.isHidden = true
        scrollView.isHidden = false
        errorLabel.isHidden = true
        seedFromSnapshot()
        claudeCard.setLoading(claudeProfile != nil && !filledCards.contains(.claude))
        grokCard.setLoading(claudeProfile != nil && !filledCards.contains(.grok))
        opencodeCard.setLoading(opencodeProfile != nil && !filledCards.contains(.opencode))
        claudeCard.isHidden = claudeProfile == nil
        grokCard.isHidden = claudeProfile == nil
        opencodeCard.isHidden = opencodeProfile == nil
        contentStack.isHidden = false

        let claudeProfiles = orderedProfiles(.claudeCode, profiles: profiles, controller: controller)
        async let claudeFailure: Error? = fillClaude(profiles: claudeProfiles, controller: controller)
        async let grokDone: Void = fillGrok(profiles: claudeProfiles, controller: controller)
        async let opencodeFailure: Error? = fillOpencode(profile: opencodeProfile, controller: controller)
        let failures = await (claudeFailure, opencodeFailure, grokDone)
        guard !Task.isCancelled else { return }
        if let failure = failures.0 ?? failures.1 { showError(failure) }

        lastRefreshed = Date()
        refreshUpdatedLabel()
        refresher.endRefreshing()
    }

    private enum CardKind {
        case claude, grok, opencode
    }

    /// Opens every card on the last numbers the app landed anywhere — the shared
    /// snapshot the widget, the background refresh, and silent pushes all write
    /// — instead of three spinners re-derived from scratch on every visit. Runs
    /// once per screen: a later pull-to-refresh must not roll live cards back to
    /// the older saved figures on its way to fetching new ones.
    private func seedFromSnapshot() {
        guard !hasSeeded else { return }
        hasSeeded = true
        guard let entry = UsageWidgetStore.read() else { return }
        for provider in entry.providers where !provider.gauges.isEmpty {
            let kind = Self.kind(for: provider.providerName)
            card(for: kind).apply(Self.snapshotModel(provider, accent: Self.accent(for: kind)))
            filledCards.insert(kind)
        }
        guard lastRefreshed == nil, !filledCards.isEmpty else { return }
        lastRefreshed = entry.date
        refreshUpdatedLabel()
    }

    private static func kind(for providerName: String) -> CardKind {
        switch providerName {
        case "Grok": return .grok
        case UsageWidgetStore.opencodeProviderName: return .opencode
        default: return .claude
        }
    }

    private static func accent(for kind: CardKind) -> UIColor {
        switch kind {
        case .claude: return Theme.Color.claude
        case .grok: return Theme.Color.grok
        case .opencode: return Theme.Color.opencode
        }
    }

    private func card(for kind: CardKind) -> ProviderCard {
        switch kind {
        case .claude: return claudeCard
        case .grok: return grokCard
        case .opencode: return opencodeCard
        }
    }

    private static func snapshotModel(
        _ provider: UsageWidgetEntry.ProviderSnapshot, accent: UIColor
    ) -> CardModel {
        CardModel(
            subtitle: provider.subtitle,
            pill: provider.isLive ? String(localized: "LIVE") : String(localized: "EST"),
            accent: accent,
            gauges: provider.gauges.prefix(3).map {
                GaugeVM(
                    name: UsageGaugeFormat.gaugeLabel($0.label), fraction: $0.fraction,
                    percentText: $0.percentText, caption: $0.caption)
            },
            details: [],
            note: String(localized: "Last saved figures — refreshing from the server now."))
    }

    private func preferredProfile(
        _ backend: AgentType, profiles: [ConnectionProfile], controller: ConnectionController
    ) -> ConnectionProfile? {
        orderedProfiles(backend, profiles: profiles, controller: controller).first
    }

    private func orderedProfiles(
        _ backend: AgentType, profiles: [ConnectionProfile], controller: ConnectionController
    ) -> [ConnectionProfile] {
        let matching = profiles.filter { $0.backend == backend }
        return matching.sorted { lhs, _ in lhs.id == controller.activeProfileID }
    }

    private func fillClaude(profiles: [ConnectionProfile], controller: ConnectionController) async -> Error? {
        guard let primary = profiles.first else { return nil }
        guard controller.makeBackend(for: primary) != nil else {
            renderFailure(.claude, on: claudeCard)
            return CredentialsUnavailableError(profileName: primary.name)
        }
        for profile in profiles {
            guard let candidate = controller.makeBackend(for: profile),
                let quota = try? await candidate.usageQuota()
            else { continue }
            guard !Task.isCancelled else { return nil }
            AppLogger.session.info(
                "usage: Claude live quota from \(profile.name) — \(quota.gauges.count) gauges (\(quota.subtitle))")
            claudeCard.apply(Self.liveModel(quota, accent: Theme.Color.claude))
            filledCards.insert(.claude)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        AppLogger.session.info("usage: no Claude usage API reachable from any bridge")
        renderFailure(.claude, on: claudeCard)
        return QuotaUnavailableError()
    }

    /// A card that is already showing saved numbers keeps them: wiping it to
    /// dashes because one refresh missed is strictly less information than
    /// leaving the last known reading up.
    private func renderFailure(_ kind: CardKind, on card: ProviderCard) {
        card.setLoading(false)
        guard !filledCards.contains(kind) else { return }
        card.renderError()
    }

    /// Grok quota rides on the Claude Code bridge, which reads the server machine's grok
    /// login; older bridges (or hosts without one) return nothing and the card hides itself.
    private func fillGrok(profiles: [ConnectionProfile], controller: ConnectionController) async {
        for profile in profiles {
            guard let backend = controller.makeBackend(for: profile),
                let quota = (try? await backend.additionalUsageQuotas())?
                    .first(where: { $0.providerName == "Grok" })
            else { continue }
            guard !Task.isCancelled else { return }
            AppLogger.session.info(
                "usage: Grok live quota from \(profile.name) — \(quota.gauges.count) gauges (\(quota.subtitle))")
            grokCard.apply(Self.liveModel(quota, accent: Theme.Color.grok))
            filledCards.insert(.grok)
            grokCard.isHidden = false
            return
        }
        guard !Task.isCancelled else { return }
        AppLogger.session.info("usage: no Grok quota from any Claude Code bridge")
        grokCard.setLoading(false)
        grokCard.isHidden = !filledCards.contains(.grok)
    }

    private func fillOpencode(profile: ConnectionProfile?, controller: ConnectionController) async -> Error? {
        guard let profile else { return nil }
        let entries = controller.opencodeBackends()
        guard !entries.isEmpty else {
            renderFailure(.opencode, on: opencodeCard)
            return CredentialsUnavailableError(profileName: profile.name)
        }
        guard
            let result = await UsageScanner.scanOpencode(
                backends: entries.map { ($0.profile.name, $0.backend) })
        else {
            guard !Task.isCancelled else { return nil }
            renderFailure(.opencode, on: opencodeCard)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        opencodeCard.apply(Self.opencodeModel(result))
        filledCards.insert(.opencode)
        return nil
    }

    private static func liveModel(_ quota: UsageQuota, accent: UIColor) -> CardModel {
        let gauges = quota.gauges.prefix(3).map { gauge -> GaugeVM in
            let percent = Int((gauge.fraction * 100).rounded())
            return GaugeVM(
                name: gauge.label,
                fraction: gauge.fraction,
                percentText: "\(percent)%",
                caption: resetCaption(gauge))
        }
        return CardModel(
            subtitle: quota.subtitle,
            pill: String(localized: "LIVE"),
            accent: accent,
            gauges: Array(gauges),
            details: quota.details.map { ($0.key, $0.value) },
            note: String(
                localized:
                    "Live rolling rate limits straight from \(quota.source). Percentages are your actual plan consumption, not an estimate."
            ))
    }

    private static func opencodeModel(_ result: UsageScanResult) -> CardModel {
        let samples = result.samples
        let totalSpend = samples.reduce(0) { $0 + $1.cost }
        let totalTokens = samples.reduce(0) { $0 + $1.tokens }
        let hosts = result.scannedHosts.count
        var details: [(String, String)] = []
        if hosts > 1 || !result.failedHosts.isEmpty {
            details.append((String(localized: "Servers"), serverCoverage(result)))
        }
        details += [
            (String(localized: "Spend (31 days)"), currency(totalSpend)),
            (String(localized: "Requests"), "\(samples.count)"),
            (String(localized: "Tokens (in + out)"), tokenCount(totalTokens)),
        ]
        return CardModel(
            subtitle: UsageScanner.quota(from: result).subtitle,
            pill: String(localized: "EST"),
            accent: Theme.Color.opencode,
            gauges: gaugeVMs(result: result),
            details: details,
            note: unavailableSuffix(opencodeNote(result), result: result))
    }

    private static func serverCoverage(_ result: UsageScanResult) -> String {
        var text = result.scannedHosts.joined(separator: " + ")
        if !result.failedHosts.isEmpty {
            text += " · " + String(localized: "\(result.failedHosts.joined(separator: ", ")) unreachable")
        }
        return text
    }

    private static func opencodeNote(_ result: UsageScanResult) -> String {
        let scope = result.scannedHosts.count > 1
            ? String(
                localized:
                    "estimated from the opencode.db on \(result.scannedHosts.joined(separator: " and "))"
            )
            : String(localized: "estimated from this server's opencode.db")
        var note = String(
            localized:
                "No usage API — \(scope) against Go's dollar caps: an anchored 5-hour block, the trailing week, and the billing month. May miss usage on machines without a profile here and server-side accounting."
        )
        if let multipliers = multiplierNote(result.multipliers) { note += " \(multipliers)" }
        for host in result.failedHosts {
            note += " " + String(localized: "\(host) unreachable — its spend is not included.")
        }
        return note
    }

    /// Names the models Go bills above face value, so weighted spend reading
    /// higher than the raw dollar cost is explained rather than mysterious.
    private static func multiplierNote(_ multipliers: [String: UsageMultiplier]) -> String? {
        let weighted = multipliers.values.sorted { $0.weight > $1.weight }
        guard !weighted.isEmpty else { return nil }
        let list = weighted.map {
            String(
                localized:
                    "\(baseModelName($0.displayName)) counts \(String(format: "%g", $0.weight))x")
        }
        return String(localized: "Model multipliers applied (\(list.joined(separator: ", "))).")
    }

    private static func baseModelName(_ displayName: String) -> String {
        guard let suffix = displayName.range(of: " (") else { return displayName }
        return String(displayName[..<suffix.lowerBound])
    }

    private static func unavailableSuffix(_ note: String, result: UsageScanResult) -> String {
        guard result.unavailable > 0 else { return note }
        return note + " "
            + String(
                localized: "\(result.unavailable) sessions unavailable — totals are incomplete.")
    }

    private static func gaugeVMs(result: UsageScanResult) -> [GaugeVM] {
        let now = Date()
        return UsageScanner.windows.map { window in
            let stats = UsageScanner.windowStats(window, samples: result.samples, now: now)
            var caption = UsageGaugeFormat.spendCaption(
                spend: currency(stats.spend), cap: currency(window.cap),
                requests: stats.requests)
            if let resetsAt = stats.resetsAt {
                caption += "\n" + String(localized: "~resets \(humanize(until: resetsAt))")
            }
            return GaugeVM(
                name: UsageGaugeFormat.gaugeLabel(window.name),
                fraction: stats.fraction,
                percentText: "\(Int((stats.fraction * 100).rounded()))%",
                caption: caption)
        }
    }

    private static func resetCaption(_ gauge: UsageQuota.Gauge) -> String {
        guard let resetsAt = gauge.resetsAt else { return "—" }
        let elapsed = humanize(until: resetsAt)
        return gauge.trustedReset
            ? String(localized: "resets \(elapsed)") : String(localized: "~resets \(elapsed)")
    }

    private static func humanize(until date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func tokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
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

@MainActor
private final class ProviderCard: UIView {
    private let cardTitle: String
    private let accent: UIColor
    private var ringViews: [RingGaugeView] = []
    private var ringColumns: [UIView] = []
    private var ringNames: [UILabel] = []
    private var ringCaptions: [UILabel] = []
    private let subtitleLabel = UILabel()
    private let pillLabel = UILabel()
    private let pillBackground = UIView()
    private let noteLabel = UILabel()
    private let detailsStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(title: String, accent: UIColor) {
        self.cardTitle = title
        self.accent = accent
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    func renderError() {
        spinner.stopAnimating()
        for caption in ringCaptions { caption.text = "—" }
    }

    func apply(_ model: CardModel) {
        spinner.stopAnimating()
        subtitleLabel.text = model.subtitle
        pillLabel.text = model.pill
        pillBackground.backgroundColor = model.accent
        pillLabel.textColor = Self.contrastingText(on: model.accent)

        for (index, ring) in ringViews.enumerated() {
            if index < model.gauges.count {
                let gauge = model.gauges[index]
                ringColumns[index].isHidden = false
                ring.configure(
                    fraction: gauge.fraction, color: color(for: gauge.fraction, accent: model.accent),
                    percentText: gauge.percentText)
                ringNames[index].text = gauge.name
                ringCaptions[index].text = gauge.caption
            } else {
                ringColumns[index].isHidden = true
            }
        }

        noteLabel.text = model.note
        detailsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, value) in model.details {
            detailsStack.addArrangedSubview(detailRow(key, value))
        }
    }

    private func build() {
        let stack = UIStackView(arrangedSubviews: [quotaCard(), noteLabelView(), detailsCard()])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func quotaCard() -> UIView {
        let title = UILabel()
        title.text = cardTitle
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = Theme.Color.label
        title.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.hidesWhenStopped = true
        let header = UIStackView(arrangedSubviews: [title, spacer, spinner, pill()])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        subtitleLabel.text = "—"
        subtitleLabel.font = Theme.Font.caption()
        subtitleLabel.textColor = Theme.Color.secondaryLabel
        subtitleLabel.numberOfLines = 0

        var columns: [UIView] = []
        for _ in 0..<3 {
            let ring = RingGaugeView()
            ringViews.append(ring)

            let name = UILabel()
            name.font = Theme.Font.subheadline()
            name.textColor = Theme.Color.label
            name.textAlignment = .center
            name.numberOfLines = 2
            name.text = "—"
            ringNames.append(name)

            let caption = UILabel()
            caption.font = Theme.Font.mono(11)
            caption.textColor = Theme.Color.secondaryLabel
            caption.textAlignment = .center
            caption.numberOfLines = 2
            caption.text = "—"
            ringCaptions.append(caption)

            let column = UIStackView(arrangedSubviews: [ring, name, caption])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = Theme.Spacing.xs
            ringColumns.append(column)
            columns.append(column)
        }

        let rings = UIStackView(arrangedSubviews: columns)
        rings.axis = .horizontal
        rings.distribution = .fillEqually
        rings.alignment = .top
        rings.spacing = Theme.Spacing.s

        return card([header, subtitleLabel, rings], spacing: Theme.Spacing.l)
    }

    private func pill() -> UIView {
        pillLabel.text = "—"
        pillLabel.font = .systemFont(ofSize: 11, weight: .bold)
        pillLabel.textColor = .black
        pillLabel.translatesAutoresizingMaskIntoConstraints = false

        pillBackground.backgroundColor = accent
        pillBackground.layer.cornerRadius = 9
        pillBackground.layer.cornerCurve = .continuous
        pillBackground.setContentHuggingPriority(.required, for: .horizontal)
        pillBackground.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillBackground.heightAnchor.constraint(equalToConstant: 18),
            pillLabel.centerYAnchor.constraint(equalTo: pillBackground.centerYAnchor),
            pillLabel.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: Theme.Spacing.s),
            pillLabel.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -Theme.Spacing.s),
        ])
        return pillBackground
    }

    private func noteLabelView() -> UILabel {
        noteLabel.text = " "
        noteLabel.font = Theme.Font.caption()
        noteLabel.textColor = Theme.Color.secondaryLabel
        noteLabel.numberOfLines = 0
        return noteLabel
    }

    private func detailsCard() -> UIView {
        detailsStack.axis = .vertical
        detailsStack.spacing = Theme.Spacing.s
        return card([detailsStack], spacing: Theme.Spacing.s)
    }

    private func detailRow(_ title: String, _ value: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.Font.subheadline()
        label.textColor = Theme.Color.label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = Theme.Font.mono(13)
        valueLabel.textColor = Theme.Color.secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, valueLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        return row
    }

    private func card(_ views: [UIView], spacing: CGFloat) -> UIView {
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

    private static func contrastingText(on accent: UIColor) -> UIColor {
        UIColor { traits in
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            accent.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
            return luminance > 0.5 ? .black : .white
        }
    }

    private func color(for fraction: Double, accent: UIColor) -> UIColor {
        if fraction > 0.85 { return Theme.Color.danger }
        if fraction >= 0.6 { return Theme.Color.warning }
        return accent
    }
}
