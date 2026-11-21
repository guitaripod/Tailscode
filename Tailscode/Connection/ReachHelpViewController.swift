import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

extension ReachReading.Device {
    @MainActor static var here: ReachReading.Device { DeviceWord.isPad ? .iPad : .iPhone }
}

extension ReachReading {
    /// A reading from what a screen already knows, before anything has been asked again: the
    /// machines it saw fall silent and how many it heard from.
    @MainActor
    static func here(silent: [String], answering: Int) -> ReachReading? {
        read(
            silent: silent, answering: answering, onTailnet: TailnetStatus.isConnected,
            device: .here)
    }
}

/// Every saved machine asked the cheapest question there is, at once, with a short deadline: the
/// evidence a reading is made of. A machine counts as answering only when it says it is healthy.
@MainActor
enum ReachProbe {
    private nonisolated static let deadline: Duration = .seconds(4)

    static func read() async -> ReachReading? {
        let sources = ConnectionController.shared.allBackends()
        guard !sources.isEmpty else { return nil }
        let answers = await withTaskGroup(of: (String, Bool).self) { group in
            for source in sources {
                let backend = source.backend
                let name = source.profile.name
                group.addTask { (name, await healthy(backend)) }
            }
            var answers: [(String, Bool)] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        let order = sources.map(\.profile.name)
        let silent = order.filter { name in answers.contains { $0.0 == name && !$0.1 } }
        let answering = answers.count { $0.1 }
        MidgarLog.info(
            "reach probe: \(answering) answering, silent \(silent), tailnet \(TailnetStatus.isConnected)",
            category: .connection)
        return ReachReading.here(silent: silent, answering: answering)
    }

    private nonisolated static func healthy(_ backend: any CodingAgentBackend) async -> Bool {
        do {
            return try await withThrowingTaskGroup(of: Bool.self) { probe in
                probe.addTask { try await backend.health().healthy }
                probe.addTask {
                    try await Task.sleep(for: deadline)
                    throw CancellationError()
                }
                let first = try await probe.next() ?? false
                probe.cancelAll()
                return first
            }
        } catch {
            return false
        }
    }
}

/// Where a reading's actions go on a phone. Tailscale is another app, so its switch is one press
/// away and never closer; the store page is where an update for it is.
@MainActor
enum ReachDoors {
    static let tailscaleStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    static func title(for action: ReachReading.Action) -> String {
        switch action {
        case .openTailscale: return String(localized: "Open Tailscale")
        case .updateTailscale: return String(localized: "Open App Store")
        case .retry: return String(localized: "Try again")
        }
    }

    static func symbol(for action: ReachReading.Action) -> String {
        switch action {
        case .openTailscale: return "arrow.up.forward.app"
        case .updateTailscale: return "arrow.down.app"
        case .retry: return "arrow.clockwise"
        }
    }

    /// Opens what the action names. A retry is the caller's, because only the screen asking knows
    /// what asking again means there.
    static func open(_ action: ReachReading.Action) {
        switch action {
        case .openTailscale: TailnetStatus.openTailscaleApp()
        case .updateTailscale: UIApplication.shared.open(tailscaleStore)
        case .retry: break
        }
    }
}

/// The ladder for machines that stopped answering: which side is the likelier cause and what to
/// try, cheapest first. It asks every machine again when it opens, when the person comes back
/// from Tailscale or Settings, and on Try again, and it closes itself once they answer.
@MainActor
final class ReachHelpViewController: UIViewController {
    private var reading: ReachReading
    private let onRecovered: () -> Void
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let statusLabel = UILabel()
    private let retryButton = PrimaryButton(title: String(localized: "Try again"))
    private var checking: Task<Void, Never>?
    private var recovered = false

    init(reading: ReachReading, onRecovered: @escaping () -> Void) {
        self.reading = reading
        self.onRecovered = onRecovered
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(
        from host: UIViewController, reading: ReachReading, onRecovered: @escaping () -> Void
    ) {
        guard host.presentedViewController == nil else { return }
        let nav = UINavigationController(
            rootViewController: ReachHelpViewController(reading: reading, onRecovered: onRecovered))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large(), .medium()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        host.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        layOut()
        fill()
        retryButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.check()
            }, for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        MidgarLog.info("reach help opened: \(reading.suspect)", category: .connection)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        check()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        checking?.cancel()
        checking = nil
    }

    @objc private func cameBack() {
        check()
    }

    private func layOut() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        content.axis = .vertical
        content.spacing = Theme.Spacing.l
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        view.addSubview(retryButton)

        let guide = scroll.contentLayoutGuide
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: retryButton.topAnchor, constant: -Theme.Spacing.m),

            retryButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Theme.Spacing.l),
            retryButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Theme.Spacing.l),
            retryButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Theme.Spacing.m),

            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Spacing.s),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Theme.Spacing.l),
            content.leadingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func fill() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.addArrangedSubview(hero())
        let steps = UIStackView(
            arrangedSubviews: reading.steps.enumerated().map { step(number: $0.offset + 1, $0.element) })
        steps.axis = .vertical
        steps.spacing = Theme.Spacing.m
        content.addArrangedSubview(steps)
        content.addArrangedSubview(
            label(
                String(localized: "Tailscode asks your machines again by itself when you come back."),
                role: .panelFootnote, color: Theme.Color.tertiaryLabel))
    }

    private func hero() -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: reading.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
        let tint = reading.suspect == .machines ? Theme.Color.warning : Theme.Color.danger
        icon.tintColor = tint
        icon.contentMode = .center
        icon.backgroundColor = tint.withAlphaComponent(0.12)
        icon.layer.cornerRadius = 26
        icon.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
        ])

        let headline = label(reading.title, role: .headline, color: Theme.Color.label)
        headline.accessibilityTraits = .header
        let lead = label(reading.lead, role: .panelLabel, color: Theme.Color.secondaryLabel)

        statusLabel.font = Theme.Ramp.font(.panelFootnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Theme.Color.tertiaryLabel
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, headline, lead, statusLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.s
        stack.setCustomSpacing(Theme.Spacing.m, after: icon)
        return stack
    }

    private func step(number: Int, _ step: ReachReading.Step) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = Theme.Ramp.font(.badge)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = Theme.Color.accent
        badge.textAlignment = .center
        badge.backgroundColor = Theme.Color.accent.withAlphaComponent(0.14)
        badge.layer.cornerRadius = 13
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        badge.isAccessibilityElement = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])

        let title = label(step.title, role: .rowTitleStrong, color: Theme.Color.label)
        let detail = label(step.detail, role: .panelDetail, color: Theme.Color.secondaryLabel)
        let words = UIStackView(arrangedSubviews: [title, detail])
        words.axis = .vertical
        words.spacing = 2
        words.isAccessibilityElement = true
        words.accessibilityLabel = "\(number). \(step.title). \(step.detail)"

        let column = UIStackView(arrangedSubviews: [words])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = Theme.Spacing.s
        if let action = step.action, action != .retry {
            column.addArrangedSubview(actionButton(action))
        }

        let row = UIStackView(arrangedSubviews: [badge, column])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Spacing.m
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        row.backgroundColor = Theme.Color.groupedSurface
        row.layer.cornerRadius = Theme.Radius.card
        row.layer.cornerCurve = .continuous
        return row
    }

    private func actionButton(_ action: ReachReading.Action) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = ReachDoors.title(for: action)
        config.image = UIImage(
            systemName: ReachDoors.symbol(for: action),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        config.imagePadding = Theme.Spacing.xs
        config.baseForegroundColor = Theme.Color.accent
        config.baseBackgroundColor = Theme.Color.accent
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.chip)
            return out
        }
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { _ in
                Theme.Haptics.tap()
                MidgarLog.info("reach help: \(action)", category: .connection)
                ReachDoors.open(action)
            }, for: .touchUpInside)
        return button
    }

    private func label(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(role)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func check() {
        guard checking == nil, !recovered else { return }
        retryButton.setLoading(true)
        statusLabel.text = String(localized: "Checking…")
        checking = Task { [weak self] in
            let next = await ReachProbe.read()
            guard let self, !Task.isCancelled else { return }
            self.checking = nil
            self.retryButton.setLoading(false)
            guard let next else {
                self.cameBackOnline()
                return
            }
            if next != self.reading {
                self.reading = next
                self.fill()
            }
            self.statusLabel.text = String(
                localized: "Still no answer at \(Date().formatted(date: .omitted, time: .shortened))")
        }
    }

    private func cameBackOnline() {
        recovered = true
        MidgarLog.info("reach help: machines answer again", category: .connection)
        Theme.Haptics.success()
        statusLabel.text = String(localized: "Everything answers again")
        statusLabel.textColor = Theme.Color.success
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
        onRecovered()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.dismiss(animated: true)
        }
    }
}
