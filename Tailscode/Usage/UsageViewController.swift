import CodingAgentKit
import CodingAgentKitApple
import UIKit

private struct UsageWindow {
    let name: String
    let seconds: TimeInterval
    let cap: Double
}

private struct UsageSample: Sendable {
    let cost: Double
    let createdAt: Date
    let tokens: Int
}

private struct ScanResult {
    var samples: [UsageSample]
    var timedOut: Int
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
    private static let sessionLimit = 40
    private static let concurrency = 6
    private static let perRequestTimeout: TimeInterval = 12
    private static let opencodeProviderID = "opencode-go"
    private static let claudePlanUSD: Double = 100

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let refresher = UIRefreshControl()
    private let errorLabel = UILabel()

    private let claudeCard = ProviderCard(title: "Claude Code", accent: Theme.Color.claude)
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
        setupActivityIndicator()
        buildContent()
        Task { await load() }
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

    private func setupActivityIndicator() {
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func buildContent() {
        errorLabel.font = Theme.Font.subheadline()
        errorLabel.textColor = Theme.Color.danger
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(claudeCard)
        contentStack.addArrangedSubview(opencodeCard)
        contentStack.isHidden = true
    }

    @objc private func pulledToRefresh() {
        Task { await load() }
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
        opencodeCard.setLoading(opencodeProfile != nil)
        claudeCard.isHidden = claudeProfile == nil
        opencodeCard.isHidden = opencodeProfile == nil
        activityIndicator.stopAnimating()
        contentStack.isHidden = false

        let claudeProfiles = orderedProfiles(.claudeCode, profiles: profiles, controller: controller)
        async let claudeFailure: Error? = fillClaude(profiles: claudeProfiles, controller: controller)
        async let opencodeFailure: Error? = fillOpencode(profile: opencodeProfile, controller: controller)
        let failures = await (claudeFailure, opencodeFailure)
        if let failure = failures.0 ?? failures.1 { showError(failure) }

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
        guard let primary = profiles.first, let backend = controller.makeBackend(for: primary) else {
            return nil
        }
        for profile in profiles {
            guard let candidate = controller.makeBackend(for: profile),
                let quota = try? await candidate.usageQuota()
            else { continue }
            AppLogger.session.info(
                "usage: Claude live quota from \(profile.name) — \(quota.gauges.count) gauges (\(quota.subtitle))")
            claudeCard.apply(Self.liveModel(quota))
            return nil
        }
        AppLogger.session.info("usage: no Claude usage API reachable, estimating from sessions")
        do {
            let result = try await collect(profile: primary, backend: backend, samples: Self.claudeSamples)
            claudeCard.apply(Self.claudeEstimateModel(result.samples))
            return nil
        } catch {
            claudeCard.renderError()
            return error
        }
    }

    private func fillOpencode(profile: ConnectionProfile?, controller: ConnectionController) async -> Error? {
        guard let profile, let backend = controller.makeBackend(for: profile) else { return nil }
        do {
            let result = try await collect(profile: profile, backend: backend, samples: Self.opencodeSamples)
            opencodeCard.apply(Self.opencodeModel(result.samples))
            return nil
        } catch {
            opencodeCard.renderError()
            return error
        }
    }

    private func collect(
        profile: ConnectionProfile,
        backend: any CodingAgentBackend,
        samples: @escaping @Sendable (any CodingAgentBackend, AgentSession) async throws -> [UsageSample]
    ) async throws -> ScanResult {
        let sessions = try await backend.listSessions()
        let scanned = Array(sessions.prefix(Self.sessionLimit))
        AppLogger.session.info(
            "usage: scanning \(scanned.count)/\(sessions.count) \(profile.backend.rawValue) sessions from \(profile.name)")
        let result = await scan(backend: backend, sessions: scanned, samples: samples)
        AppLogger.session.info(
            "usage: \(profile.backend.rawValue) → \(result.samples.count) priced entries, \(result.timedOut) timed out")
        return result
    }

    private func scan(
        backend: any CodingAgentBackend,
        sessions: [AgentSession],
        samples: @escaping @Sendable (any CodingAgentBackend, AgentSession) async throws -> [UsageSample]
    ) async -> ScanResult {
        let timeout = Self.perRequestTimeout
        return await withTaskGroup(of: [UsageSample]?.self) { group in
            var pending = sessions.makeIterator()

            func schedule() {
                guard let session = pending.next() else { return }
                group.addTask {
                    await Self.withTimeout(timeout) {
                        (try? await samples(backend, session)) ?? []
                    }
                }
            }

            for _ in 0..<Self.concurrency { schedule() }
            var result = ScanResult(samples: [], timedOut: 0)
            for await batch in group {
                if let batch {
                    result.samples.append(contentsOf: batch)
                } else {
                    result.timedOut += 1
                }
                schedule()
            }
            return result
        }
    }

    private static func liveModel(_ quota: UsageQuota) -> CardModel {
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
            accent: Theme.Color.claude,
            gauges: Array(gauges),
            details: quota.details.map { ($0.key, $0.value) },
            note: "Live rolling rate limits straight from \(quota.source). Percentages are your "
                + "actual plan consumption, not an estimate.")
    }

    private static func claudeEstimateModel(_ samples: [UsageSample]) -> CardModel {
        let windows = [
            UsageWindow(name: "5-hour", seconds: 5 * 3600, cap: claudePlanUSD * 5 / (30 * 24)),
            UsageWindow(name: "Weekly", seconds: 7 * 24 * 3600, cap: claudePlanUSD * 7 / 30),
            UsageWindow(name: "Monthly", seconds: 30 * 24 * 3600, cap: claudePlanUSD),
        ]
        let totalSpend = samples.reduce(0) { $0 + $1.cost }
        let totalTokens = samples.reduce(0) { $0 + $1.tokens }
        return CardModel(
            subtitle: "$100/mo plan · API-equivalent estimate",
            pill: "EST",
            accent: Theme.Color.claude,
            gauges: gaugeVMs(samples: samples, windows: windows),
            details: [
                ("All-time spend", currency(totalSpend)),
                ("Sessions", "\(samples.count)"),
                ("Tokens (in + out)", tokenCount(totalTokens)),
            ],
            note: "Live usage API unavailable on this server — estimated from per-session cost against "
                + "your plan price, pro-rated per window. Update the bridge for real rate-limit gauges.")
    }

    private static func opencodeModel(_ samples: [UsageSample]) -> CardModel {
        let windows = [
            UsageWindow(name: "5-hour", seconds: 5 * 3600, cap: 12),
            UsageWindow(name: "Weekly", seconds: 7 * 24 * 3600, cap: 30),
            UsageWindow(name: "Monthly", seconds: 30 * 24 * 3600, cap: 60),
        ]
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
            note: "No usage API — estimated from this server's opencode.db against Go's rolling dollar "
                + "caps. May miss usage on other machines and server-side accounting.")
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

    private static func opencodeSamples(
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> [UsageSample] {
        let messages = try await backend.messages(for: session.id)
        return messages.compactMap { message in
            guard message.providerID == opencodeProviderID, let cost = message.costUSD else { return nil }
            return UsageSample(cost: cost, createdAt: message.createdAt, tokens: message.totalTokens ?? 0)
        }
    }

    private static func claudeSamples(
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> [UsageSample] {
        guard let usage = try await backend.sessionUsage(session.id), let cost = usage.costUSD else {
            return []
        }
        return [UsageSample(cost: cost, createdAt: session.updatedAt, tokens: usage.tokens ?? 0)]
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
        activityIndicator.stopAnimating()
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

    private func color(for fraction: Double, accent: UIColor) -> UIColor {
        if fraction > 0.85 { return Theme.Color.danger }
        if fraction >= 0.6 { return Theme.Color.warning }
        return accent
    }
}
