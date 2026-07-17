import CodingAgentKit
import CodingAgentKitApple
import UIKit

private struct UsageWindow {
    let name: String
    let seconds: TimeInterval
    let cap: Double
}

private struct QuotaUnavailableError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Claude quota is unavailable right now — the bridge couldn't reach api.anthropic.com."
    }
}

private struct CredentialsUnavailableError: LocalizedError, Sendable {
    let profileName: String
    var errorDescription: String? { "Couldn't read stored credentials for \(profileName)." }
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

    private let claudeCard = ProviderCard(title: "Claude Code", accent: Theme.Color.claude)
    private let grokCard = ProviderCard(title: "Grok", accent: Theme.Color.grok)
    private let opencodeCard = ProviderCard(title: "opencode go", accent: Theme.Color.opencode)

    private lazy var emptyStateView = EmptyStateView(
        symbol: "gauge.with.dots.needle.67percent",
        title: "Not connected",
        message: "Connect to a Claude Code or opencode server to see usage.")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Usage"
        view.backgroundColor = Theme.Color.groupedBackground
        setupScroll()
        setupEmptyState()
        buildContent()
        startLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshUpdatedLabel()
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) > Self.staleInterval,
            loadTask == nil
        {
            startLoad()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            loadTask?.cancel()
            loadTask = nil
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
            ? "Updated just now"
            : "Updated \(lastRefreshed.formatted(.relative(presentation: .named)))"
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
        claudeCard.setLoading(claudeProfile != nil)
        grokCard.setLoading(claudeProfile != nil)
        opencodeCard.setLoading(opencodeProfile != nil)
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
            claudeCard.renderError()
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
            return nil
        }
        guard !Task.isCancelled else { return nil }
        AppLogger.session.info("usage: no Claude usage API reachable from any bridge")
        claudeCard.renderError()
        return QuotaUnavailableError()
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
            return
        }
        guard !Task.isCancelled else { return }
        AppLogger.session.info("usage: no Grok quota from any Claude Code bridge")
        grokCard.isHidden = true
    }

    private func fillOpencode(profile: ConnectionProfile?, controller: ConnectionController) async -> Error? {
        guard let profile else { return nil }
        guard let backend = controller.makeBackend(for: profile) else {
            opencodeCard.renderError()
            return CredentialsUnavailableError(profileName: profile.name)
        }
        guard let result = await UsageScanner.scanOpencode(backend: backend) else {
            guard !Task.isCancelled else { return nil }
            opencodeCard.renderError()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        opencodeCard.apply(Self.opencodeModel(result))
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
            pill: "LIVE",
            accent: accent,
            gauges: Array(gauges),
            details: quota.details.map { ($0.key, $0.value) },
            note: "Live rolling rate limits straight from \(quota.source). Percentages are your "
                + "actual plan consumption, not an estimate.")
    }

    private static func opencodeModel(_ result: UsageScanResult) -> CardModel {
        let windows = [
            UsageWindow(name: "5-hour", seconds: 5 * 3600, cap: 12),
            UsageWindow(name: "Weekly", seconds: 7 * 24 * 3600, cap: 30),
            UsageWindow(name: "Monthly", seconds: 30 * 24 * 3600, cap: 60),
        ]
        let samples = result.samples
        let totalSpend = samples.reduce(0) { $0 + $1.cost }
        let totalTokens = samples.reduce(0) { $0 + $1.tokens }
        return CardModel(
            subtitle: "$10/mo · estimated from this server",
            pill: "EST",
            accent: Theme.Color.opencode,
            gauges: gaugeVMs(samples: samples, windows: windows),
            details: [
                ("All-time spend", currency(totalSpend)),
                ("Requests", "\(samples.count)"),
                ("Tokens (in + out)", tokenCount(totalTokens)),
            ],
            note: unavailableSuffix(
                "No usage API — estimated from this server's opencode.db against Go's rolling dollar "
                    + "caps. May miss usage on other machines and server-side accounting.",
                result: result))
    }

    private static func unavailableSuffix(_ note: String, result: UsageScanResult) -> String {
        guard result.unavailable > 0 else { return note }
        let plural = result.unavailable == 1 ? "session" : "sessions"
        return note + " \(result.unavailable) \(plural) unavailable — totals are incomplete."
    }

    private static func gaugeVMs(samples: [UsageSample], windows: [UsageWindow]) -> [GaugeVM] {
        let now = Date()
        return windows.map { window in
            let cutoff = now.addingTimeInterval(-window.seconds)
            let inWindow = samples.filter { $0.createdAt >= cutoff }
            let spend = inWindow.reduce(0) { $0 + $1.cost }
            let fraction = window.cap > 0 ? min(1, spend / window.cap) : 0
            return GaugeVM(
                name: window.name,
                fraction: fraction,
                percentText: "\(Int((fraction * 100).rounded()))%",
                caption: "\(currency(spend)) / \(currency(window.cap)) · \(inWindow.count) req")
        }
    }

    private static func resetCaption(_ gauge: UsageQuota.Gauge) -> String {
        guard let resetsAt = gauge.resetsAt else { return "—" }
        let prefix = gauge.trustedReset ? "resets " : "~resets "
        return prefix + humanize(until: resetsAt)
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
        errorLabel.text = "Couldn't load usage: \(error.localizedDescription)"
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
