import TailscodeCore
import UIKit

/// One capability's checklist on one machine, as a sheet sized to its words with a large detent
/// behind it for the type sizes and the long lists that outgrow it. It draws Core's `SetupChecklist`
/// and nothing else: a headline with its state, a card per row, and the one primary button pinned at
/// the foot so it can never scroll out of reach.
///
/// The desk polls only while the sheet is on screen: the lifetime that holds the watch ends when it
/// disappears, and a closed checklist asks its machine for nothing.
@MainActor
final class SetupChecklistViewController: UIViewController {
    private static let detent = UISheetPresentationController.Detent.Identifier("setup.checklist")
    private static let copiedFor: Duration = .milliseconds(1500)

    private let target: SetupTarget
    private let focus: SetupFocus?
    private let reportLines: () -> [String]
    private let onFinish: (() -> Void)?
    private let onChange: ((SetupChecklistViewController) -> Void)?
    private let placeLabel = UILabel()
    private let placeButton = UIButton(type: .system)
    private let placeLine = UIStackView()
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let footer = UIView()
    private let primary = UIButton(type: .system)
    private let lifetime = PaneLifetime()
    private let icon = ActivityBadgeView(pointSize: 22)
    private let nameLabel = UILabel()
    private let headline = UILabel()
    private let titleLine = UIStackView()
    private var badge: BetaBadge?
    private var badgeFeature: BetaFeature?
    private var rowViews: [String: SetupRowView] = [:]
    private var order: [String] = []
    private var checklist: SetupChecklist?
    private var copiedTicket = 0
    private var copied = false

    static func present(
        target: SetupTarget, focus: SetupFocus?, from presenter: UIViewController,
        reportLines: @escaping () -> [String], onFinish: (() -> Void)?,
        onChange: ((SetupChecklistViewController) -> Void)?
    ) {
        let controller = SetupChecklistViewController(
            target: target, focus: focus, reportLines: reportLines, onFinish: onFinish, onChange: onChange)
        controller.loadViewIfNeeded()
        let fallbackWidth = presenter.view.bounds.width
        let bottom = presenter.view.safeAreaInsets.bottom
        if let sheet = controller.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [
                .custom(identifier: detent) { [weak controller] context in
                    guard let controller else { return context.maximumDetentValue }
                    let width = controller.view.bounds.width > 0 ? controller.view.bounds.width : fallbackWidth
                    return min(context.maximumDetentValue, controller.fittingHeight(width: width, bottomInset: bottom))
                },
                .large(),
            ]
        }
        presenter.present(controller, animated: true)
    }

    private init(
        target: SetupTarget, focus: SetupFocus?, reportLines: @escaping () -> [String], onFinish: (() -> Void)?,
        onChange: ((SetupChecklistViewController) -> Void)?
    ) {
        self.target = target
        self.focus = focus
        self.reportLines = reportLines
        self.onFinish = onFinish
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { lifetime.cancelAll() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        buildHeader()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.backgroundColor = Theme.Color.groupedBackground
        view.addSubview(footer)
        configurePrimary()
        primary.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(primary)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            primary.topAnchor.constraint(equalTo: footer.topAnchor, constant: Theme.Spacing.s),
            primary.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Theme.Spacing.l),
            primary.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Theme.Spacing.l),
            primary.bottomAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
        ])
        apply(SetupChecklist(snapshot: SetupSnapshot(target: target), focus: focus))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SetupGate.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.apply(SetupChecklist(snapshot: snapshot, focus: self.focus))
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifetime.cancelAll()
    }

    func fittingHeight(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let inner = max(width - 2 * Theme.Spacing.l, 200)
        let content = column.systemLayoutSizeFitting(
            CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let foot = primary.isHidden ? 0 : 44 + 2 * Theme.Spacing.s
        return ceil(content.height + Theme.Spacing.xl + Theme.Spacing.m + foot + bottomInset)
    }

    private func buildHeader() {
        nameLabel.font = Theme.Ramp.font(.panelLabel)
        nameLabel.textColor = Theme.Color.secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true
        titleLine.axis = .horizontal
        titleLine.alignment = .center
        titleLine.spacing = Theme.Spacing.s
        titleLine.addArrangedSubview(nameLabel)
        headline.font = Theme.Ramp.font(.panelTitle)
        headline.textColor = Theme.Color.label
        headline.adjustsFontForContentSizeCategory = true
        headline.numberOfLines = 0
        headline.accessibilityTraits = .header
    }

    private func headerView() -> UIView {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let titles = UIStackView(arrangedSubviews: [titleLine, headline])
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = Theme.Spacing.xs
        let stack = UIStackView(arrangedSubviews: [icon, titles])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = Theme.Spacing.m
        return stack
    }

    private func placeView() -> UIView {
        placeLabel.font = Theme.Ramp.font(.panelFootnote)
        placeLabel.textColor = Theme.Color.secondaryLabel
        placeLabel.adjustsFontForContentSizeCategory = true
        placeLabel.numberOfLines = 0
        placeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeButton.addAction(UIAction { [weak self] _ in self?.pressChange() }, for: .touchUpInside)
        placeButton.setContentHuggingPriority(.required, for: .horizontal)
        placeLine.axis = .horizontal
        placeLine.alignment = .center
        placeLine.spacing = Theme.Spacing.s
        placeLine.addArrangedSubview(placeLabel)
        placeLine.addArrangedSubview(placeButton)
        placeLine.isHidden = true
        return placeLine
    }

    private func renderPlace(_ place: SetupPlace?) {
        guard let place else {
            placeLine.isHidden = true
            return
        }
        placeLabel.text = place.line
        var config = UIButton.Configuration.plain()
        config.title = place.changeLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        placeButton.configuration = config
        placeButton.isHidden = onChange == nil
        placeLine.isHidden = false
    }

    private func pressChange() {
        Theme.Haptics.tap()
        onChange?(self)
    }

    private func configurePrimary() {
        primary.isHidden = true
        primary.addAction(UIAction { [weak self] _ in self?.pressPrimary() }, for: .touchUpInside)
        primary.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func apply(_ next: SetupChecklist) {
        let before = (order, checklist?.headline, checklist?.primary == nil)
        checklist = next
        if column.arrangedSubviews.isEmpty {
            column.addArrangedSubview(headerView())
            column.addArrangedSubview(placeView())
        }
        nameLabel.text = next.name
        renderPlace(next.place)
        placeBadge(for: next)
        icon.show(next.icon, spoken: next.headline)
        headline.text = next.headline
        renderRows(next.rows)
        renderPrimary(next.primary)
        if before.0 != order || before.1 != next.headline || before.2 != (next.primary == nil) {
            sheetPresentationController?.invalidateDetents()
        }
    }

    private func placeBadge(for next: SetupChecklist) {
        guard next.beta != badgeFeature else { return }
        badge?.removeFromSuperview()
        badge = nil
        badgeFeature = next.beta
        guard let feature = next.beta else { return }
        let made = BetaBadge(feature: feature, reportLines: reportLines)
        titleLine.addArrangedSubview(made)
        badge = made
    }

    private func renderRows(_ rows: [SetupRow]) {
        let ids = rows.map(\.id)
        for stale in Set(rowViews.keys).subtracting(ids) {
            rowViews[stale]?.removeFromSuperview()
            rowViews[stale] = nil
        }
        for row in rows {
            if let existing = rowViews[row.id] {
                existing.apply(row)
            } else {
                let made = SetupRowView(row: row)
                made.onFix = { [weak self] fix in self?.start(fix) }
                made.onCancel = { [weak self] in self?.cancel() }
                made.onCopied = { Theme.Haptics.success() }
                rowViews[row.id] = made
            }
        }
        guard ids != order else { return }
        for view in rowViews.values { column.removeArrangedSubview(view) }
        for id in ids {
            if let view = rowViews[id] { column.addArrangedSubview(view) }
        }
        order = ids
    }

    private func renderPrimary(_ action: SetupAction?) {
        guard let action else {
            primary.isHidden = true
            return
        }
        primary.isHidden = false
        var config = UIButton.Configuration.filled()
        config.title = copied && action.isCopy ? DelegateSetup.copied : action.label
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Ramp.font(ChatChrome.chipRole)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        primary.configuration = config
        primary.accessibilityLabel = action.label
    }

    private func pressPrimary() {
        guard let action = checklist?.primary else { return }
        Theme.Haptics.tap()
        switch action {
        case .setUp:
            let target = target
            Task { await SetupGate.desk.runAll(target) }
        case .copy(let command, _):
            UIPasteboard.general.string = command
            Theme.Haptics.success()
            flashCopied()
        case .finish:
            finish()
        case .askPassword:
            askPassword()
        }
    }

    private func flashCopied() {
        copied = true
        renderPrimary(checklist?.primary)
        copiedTicket += 1
        let ticket = copiedTicket
        Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFor)
            guard let self, self.copiedTicket == ticket else { return }
            self.copied = false
            self.renderPrimary(self.checklist?.primary)
        }
    }

    private func start(_ fix: SetupRowFix) {
        Theme.Haptics.tap()
        let target = target
        Task { await SetupGate.desk.start(fix: fix.id, for: target) }
    }

    private func cancel() {
        Theme.Haptics.tap()
        let target = target
        Task { await SetupGate.desk.cancel(target) }
    }

    private func finish() {
        let next = onFinish
        dismiss(animated: true) { next?() }
    }

    private func askPassword() {
        let alert = UIAlertController(title: checklist?.name, message: VoiceReach.wantsPassword.line, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = Localized.text("Password")
        }
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        let target = target
        alert.addAction(
            UIAlertAction(title: Localized.text("Save"), style: .default) { [weak alert] _ in
                guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
                Task { await SetupGate.desk.remember(password: text, for: target) }
            })
        present(alert, animated: true)
    }
}

extension SetupAction {
    fileprivate var isCopy: Bool {
        if case .copy = self { return true }
        return false
    }
}

/// One row of the checklist as a card: its state on the glyph, the title, one line of facts, and the
/// row's fix. A row is redrawn only when its value changed, and a bar that moved is written in place.
@MainActor
private final class SetupRowView: UIView {
    var onFix: ((SetupRowFix) -> Void)?
    var onCancel: (() -> Void)?
    var onCopied: (() -> Void)?

    private var row: SetupRow
    private let badge = ActivityBadgeView(pointSize: 20)
    private let body = UIStackView()
    private var bar: UIProgressView?
    private var jobLabel: UILabel?

    init(row: SetupRow) {
        self.row = row
        super.init(frame: .zero)
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: SetupRowView, _) in
            view.paintBorder()
        }
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        body.axis = .vertical
        body.spacing = Theme.Spacing.xs
        let line = UIStackView(arrangedSubviews: [badge, body])
        line.axis = .horizontal
        line.alignment = .top
        line.spacing = Theme.Spacing.m
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            line.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        rebuild()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ next: SetupRow) {
        guard next != row else { return }
        let shape = Self.shape(row) == Self.shape(next)
        row = next
        if shape, let bar, let jobLabel, let job = next.job {
            if let fraction = job.fraction { bar.setProgress(Float(min(1, max(0, fraction))), animated: true) }
            jobLabel.text = job.waiting ? Localized.text("Waiting for its turn") : (job.line ?? job.step)
            return
        }
        rebuild()
    }

    private static func shape(_ row: SetupRow) -> String {
        "\(row.state)|\(row.fix?.id ?? "")|\(row.fix?.enabled ?? true)|\(row.fix?.command ?? "")|\(row.job != nil)|\(row.job?.fraction != nil)|\(row.failure ?? "")|\(row.line ?? "")|\(row.title)"
    }

    private func paintBorder() {
        let color: UIColor =
            switch row.state {
            case .needsYou: Theme.Color.warning
            case .failed: Theme.Color.danger
            default: Theme.Color.separator
            }
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
        alpha = 1
    }

    private func rebuild() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bar = nil
        jobLabel = nil
        paintBorder()
        badge.show(row.icon, spoken: row.word)
        body.addArrangedSubview(label(row.title, role: .rowTitleStrong, color: Theme.Color.label))
        if let line = row.line, !line.isEmpty {
            body.addArrangedSubview(label(line, role: .rowDetail, color: Theme.Color.secondaryLabel))
        }
        if let failure = row.failure {
            body.addArrangedSubview(label(failure, role: .rowDetail, color: Theme.Color.danger))
        }
        if let job = row.job {
            addJob(job)
        } else if let fix = row.fix {
            addFix(fix)
        }
    }

    private func label(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(role)
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func addJob(_ job: SetupRowJob) {
        if let fraction = job.fraction {
            let made = UIProgressView(progressViewStyle: .bar)
            made.progress = Float(min(1, max(0, fraction)))
            made.progressTintColor = Theme.Color.accent
            made.trackTintColor = Theme.Color.separator
            made.layer.cornerRadius = 2
            made.clipsToBounds = true
            bar = made
            body.addArrangedSubview(made)
            body.setCustomSpacing(Theme.Spacing.s, after: body.arrangedSubviews[body.arrangedSubviews.count - 2])
        }
        let measure = label(
            job.waiting ? Localized.text("Waiting for its turn") : (job.line ?? job.step ?? ""), role: .rowDetail,
            color: Theme.Color.secondaryLabel)
        jobLabel = measure
        var cancel = UIButton.Configuration.plain()
        cancel.title = Localized.text("Cancel")
        cancel.baseForegroundColor = Theme.Color.accent
        cancel.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        let button = UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel?() })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [measure, button])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Theme.Spacing.m
        body.addArrangedSubview(line)
    }

    private func addFix(_ fix: SetupRowFix) {
        switch fix.kind {
        case .job:
            var config = UIButton.Configuration.tinted()
            config.title = row.state == .failed ? Localized.text("Try again") : fix.label
            config.cornerStyle = .capsule
            config.baseForegroundColor = Theme.Color.accent
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onFix?(fix) })
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.contentHorizontalAlignment = .leading
            button.isEnabled = fix.enabled
            body.addArrangedSubview(button)
            if let cost = fix.cost {
                body.addArrangedSubview(label(cost, role: .rowDetail, color: Theme.Color.secondaryLabel))
            }
        case .command:
            guard let command = fix.command else { return }
            body.addArrangedSubview(commandBlock(command))
            if let reason = fix.reason {
                body.addArrangedSubview(label(reason, role: .rowDetail, color: Theme.Color.secondaryLabel))
            }
        }
    }

    private func commandBlock(_ command: String) -> UIView {
        let text = UILabel()
        text.text = command
        text.font = Theme.Ramp.font(.code)
        text.textColor = Theme.Color.label
        text.numberOfLines = 0
        text.lineBreakMode = .byCharWrapping
        text.adjustsFontForContentSizeCategory = true
        var copy = UIButton.Configuration.plain()
        copy.title = Localized.text("Copy")
        copy.baseForegroundColor = Theme.Color.accent
        let button = UIButton(configuration: copy)
        button.addAction(
            UIAction { [weak self, weak button] _ in
                UIPasteboard.general.string = command
                self?.onCopied?()
                button?.configuration?.title = DelegateSetup.copied
                Task { @MainActor [weak button] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    button?.configuration?.title = Localized.text("Copy")
                }
            }, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [text, button])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = Theme.Spacing.s
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: Theme.Spacing.s, left: Theme.Spacing.m, bottom: Theme.Spacing.s, right: Theme.Spacing.xs)
        stack.backgroundColor = Theme.Color.groupedBackground
        stack.layer.cornerRadius = Theme.Radius.control
        stack.layer.cornerCurve = .continuous
        return stack
    }
}
