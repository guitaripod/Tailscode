import CodingAgentKit
import TailscodeCore
import UIKit

/// The checklist a Mac server's missing grants render as, shared by the server detail screen
/// (`ServerDetailViewController`) and the extra first-run step (`MachinePermissionsStepViewController`)
/// — both are the same list of rows at a different moment, and every word on either one comes from
/// `MachinePermissionReading`.
@MainActor
final class MachinePermissionsView: UIStackView {
    var onRequest: ((MachinePermissions.Grant.Kind) -> Void)?

    private var rows: [String: MachinePermissionRowView] = [:]

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Spacing.m
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func apply(
        _ permissions: MachinePermissions, local: Bool,
        requesting: MachinePermissions.Grant.Kind? = nil
    ) {
        let known = permissions.known
        let ids = Set(known.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            removeArrangedSubview(row)
            row.removeFromSuperview()
            rows[id] = nil
        }
        for grant in known {
            let row: MachinePermissionRowView
            if let existing = rows[grant.id] {
                row = existing
            } else {
                let created = MachinePermissionRowView()
                created.onRequest = { [weak self] kind in self?.onRequest?(kind) }
                rows[grant.id] = created
                addArrangedSubview(created)
                row = created
            }
            row.apply(
                grant, permissions: permissions, local: local,
                isRequesting: grant.kind == requesting)
        }
    }
}

/// One grant: what it is for, on or off, and — while it is off — the one press that opens it and
/// the steps for after.
@MainActor
private final class MachinePermissionRowView: UIView {
    var onRequest: ((MachinePermissions.Grant.Kind) -> Void)?

    private var kind: MachinePermissions.Grant.Kind?
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let purposeLabel = UILabel()
    private let stateLabel = UILabel()
    private let actionButton = UIButton(configuration: .gray())
    private let actionSpinner = ActivityBadgeView(pointSize: 14)
    private let stepsStack = UIStackView()
    private let doneLabel = UILabel()
    private let bottomStack = UIStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        symbol.contentMode = .center
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        purposeLabel.font = Theme.Ramp.font(.panelDetail)
        purposeLabel.adjustsFontForContentSizeCategory = true
        purposeLabel.textColor = Theme.Color.secondaryLabel
        purposeLabel.numberOfLines = 0

        stateLabel.font = Theme.Ramp.font(.panelFootnote)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, purposeLabel])
        text.axis = .vertical
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = AdaptiveRow([symbol, text, stateLabel], alignment: .top)

        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        actionButton.configuration = config
        actionButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let kind = self.kind else { return }
                self.onRequest?(kind)
            }, for: .touchUpInside)

        let actionRow = UIStackView(arrangedSubviews: [actionButton, actionSpinner])
        actionRow.axis = .horizontal
        actionRow.spacing = Theme.Spacing.s
        actionRow.alignment = .center

        stepsStack.axis = .vertical
        stepsStack.spacing = Theme.Spacing.xs
        stepsStack.isHidden = true

        doneLabel.font = Theme.Ramp.font(.panelDetail)
        doneLabel.adjustsFontForContentSizeCategory = true
        doneLabel.textColor = Theme.Color.success
        doneLabel.numberOfLines = 0
        doneLabel.isHidden = true

        bottomStack.axis = .vertical
        bottomStack.spacing = Theme.Spacing.s
        [actionRow, stepsStack, doneLabel].forEach(bottomStack.addArrangedSubview)

        let column = UIStackView(arrangedSubviews: [header, bottomStack])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(
        _ grant: MachinePermissions.Grant, permissions: MachinePermissions, local: Bool,
        isRequesting: Bool
    ) {
        guard let kind = grant.kind else { return }
        self.kind = kind
        let granted = grant.state == .granted

        symbol.image = UIImage(
            systemName: MachinePermissionReading.symbol(grant),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        symbol.tintColor = granted ? Theme.Color.success : Theme.Color.warning

        titleLabel.text = MachinePermissionReading.title(kind)
        purposeLabel.text = MachinePermissionReading.purpose(kind)
        stateLabel.text = MachinePermissionReading.state(grant)
        stateLabel.textColor = granted ? Theme.Color.success : Theme.Color.warning
        accessibilityLabel = MachinePermissionReading.accessibility(grant)

        let waiting = MachinePermissionReading.isWaiting(permissions)
        let justCompleted = MachinePermissionReading.showsDone(permissions)

        if granted {
            bottomStack.isHidden = !justCompleted
            actionButton.isHidden = true
            actionSpinner.working(false)
            stepsStack.isHidden = true
            doneLabel.isHidden = !justCompleted
            if justCompleted { doneLabel.text = MachinePermissionReading.done(permissions) }
        } else {
            bottomStack.isHidden = false
            actionButton.isHidden = false
            actionButton.configuration?.title = MachinePermissionReading.action(
                permissions, local: local)
            actionButton.isEnabled = !isRequesting
            actionSpinner.working(isRequesting)
            doneLabel.isHidden = true
            stepsStack.isHidden = !waiting
            if waiting { setSteps(MachinePermissionReading.steps(permissions, local: local)) }
        }
    }

    private func setSteps(_ steps: [String]) {
        stepsStack.arrangedSubviews.forEach {
            stepsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, step) in steps.enumerated() {
            let number = UILabel()
            number.text = "\(index + 1)."
            number.font = Theme.Ramp.font(.panelFootnote)
            number.adjustsFontForContentSizeCategory = true
            number.textColor = Theme.Color.tertiaryLabel
            number.setContentHuggingPriority(.required, for: .horizontal)
            number.setContentCompressionResistancePriority(.required, for: .horizontal)

            let text = UILabel()
            text.text = step
            text.font = Theme.Ramp.font(.panelFootnote)
            text.adjustsFontForContentSizeCategory = true
            text.textColor = Theme.Color.secondaryLabel
            text.numberOfLines = 0

            let row = UIStackView(arrangedSubviews: [number, text])
            row.axis = .horizontal
            row.spacing = Theme.Spacing.xs
            row.alignment = .firstBaseline
            stepsStack.addArrangedSubview(row)
        }
    }
}

/// The card for the server detail screen's Permissions section — same shape as
/// `UpdateCardCell`, a self-sizing row that hosts a rich view instead of `UIListContentConfiguration`.
final class MachinePermissionsCardCell: UICollectionViewListCell {
    let permissionsView = MachinePermissionsView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        permissionsView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(permissionsView)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            permissionsView.topAnchor.constraint(equalTo: margins.topAnchor, constant: Theme.Spacing.xs),
            permissionsView.bottomAnchor.constraint(
                equalTo: margins.bottomAnchor, constant: -Theme.Spacing.xs),
            permissionsView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            permissionsView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The extra step first run and add-server inject after a Claude Code server is reached and turns
/// out to be a Mac missing a grant — the same checklist, before the app calls setup finished.
@MainActor
final class MachinePermissionsStepViewController: UIViewController {
    var onFinished: (() -> Void)?

    private let backend: any PermissionReportingBackend
    private let profileName: String
    private var permissions: MachinePermissions
    private var requesting: MachinePermissions.Grant.Kind?
    private var pollTask: Task<Void, Never>?
    private var finished = false

    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let badge = UIImageView()
    private let headline = UILabel()
    private let detail = UILabel()
    private let permissionsView = MachinePermissionsView()
    private let footer = OnboardingFooterBar()

    init(backend: any PermissionReportingBackend, profileName: String, permissions: MachinePermissions) {
        self.backend = backend
        self.profileName = profileName
        self.permissions = permissions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MachinePermissionReading.setupTitle
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.hidesBackButton = true
        buildUI()
        render()
        AppLogger.connection.info("permissions step shown for \(profileName)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTask?.cancel()
        pollTask = nil
    }

    private func buildUI() {
        badge.image = UIImage(
            systemName: "lock.shield",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        badge.tintColor = Theme.Color.accent
        badge.contentMode = .scaleAspectFit
        badge.setContentHuggingPriority(.required, for: .vertical)

        headline.text = MachinePermissionReading.setupTitle
        headline.font = Theme.Font.display(.title2)
        headline.adjustsFontForContentSizeCategory = true
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 0

        detail.text = MachinePermissionReading.setupDetail(permissions)
        detail.font = Theme.Ramp.font(.panelLabel)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0

        permissionsView.onRequest = { [weak self] kind in self?.request(kind) }

        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        [badge, headline, detail, permissionsView].forEach(column.addArrangedSubview)
        column.setCustomSpacing(Theme.Spacing.s, after: headline)
        column.setCustomSpacing(Theme.Spacing.xl, after: detail)
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(column)
        view.addSubview(scroll)

        footer.primary.setTitle(String(localized: "Continue"))
        footer.primary.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        footer.setSecondary(title: MachinePermissionReading.skip) { [weak self] in self?.finish() }
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            column.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    /// Continue appears only once the grant is on; until then the way past is "Not now", which
    /// says what it is rather than a Continue that quietly means the same thing.
    private func render() {
        permissionsView.apply(permissions, local: false, requesting: requesting)
        footer.primary.isHidden = !permissions.isComplete
    }

    private func request(_ kind: MachinePermissions.Grant.Kind) {
        requesting = kind
        render()
        Theme.Haptics.tap()
        AppLogger.connection.info("requesting \(kind.rawValue) on \(profileName) during setup")
        Task { [weak self] in
            guard let self else { return }
            do {
                if let updated = try await self.backend.requestMachinePermission(kind) {
                    self.permissions = updated
                }
                self.requesting = nil
                self.render()
                self.startPollingIfNeeded()
            } catch {
                self.requesting = nil
                self.render()
                AppLogger.connection.error(
                    "permission request failed on \(self.profileName): \(error)")
                ToastView(message: MachinePermissionReading.requestFailed)
                    .flash(in: self.view, above: self.footer.topAnchor)
            }
        }
    }

    private func startPollingIfNeeded() {
        guard MachinePermissionReading.isWaiting(permissions), pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MachinePermissionReading.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard let updated = try? await backend.machinePermissions() else { return }
        let wasWaiting = MachinePermissionReading.isWaiting(permissions)
        permissions = updated
        render()
        if wasWaiting, updated.isComplete {
            Theme.Haptics.success()
            AppLogger.connection.info("permission granted on \(profileName) during setup")
            scheduleAutoFinish()
        }
        if !MachinePermissionReading.isWaiting(updated) {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Once the switch lands, the step moves on by itself after `doneLinger` — long enough to see
    /// the checkmark, short enough that nobody has to press Continue on their own good news.
    private func scheduleAutoFinish() {
        Task { [weak self] in
            try? await Task.sleep(for: MachinePermissionReading.doneLinger)
            guard let self, !Task.isCancelled else { return }
            self.finish(haptic: false)
        }
    }

    private func finish(haptic: Bool = true) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        pollTask = nil
        if haptic { Theme.Haptics.tap() }
        onFinished?()
    }
}
