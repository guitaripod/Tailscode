import CodingAgentKit
import TailscodeCore
import UIKit

/// The sheet a pairing link opens when servers already exist: the machine the link names, what
/// has been checked about it, and one button that adds it. A `FirstRunFlow` in addition mode does
/// the looking and the saving, so a key the link carries stays held back until the button is
/// pressed, and this sheet only draws the plan.
@MainActor
final class AddMachineViewController: UIViewController {
    var onOpenExisting: ((String) -> Void)?

    private let flow: FirstRunFlow
    private let link: PairingLink
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let statusStack = UIStackView()
    private let blockStack = UIStackView()
    private let primary = PrimaryButton(title: "")
    private let secondary = SecondaryButton(title: "")
    private lazy var renderer = makeRenderer()
    private var plan: FirstRunPlan?
    private var planTask: Task<Void, Never>?
    private var pendingReveal: UIView?
    private var focusPasswordWhenShown = false
    private var didFinish = false

    init(flow: FirstRunFlow, link: PairingLink) {
        self.flow = flow
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
        Task { await flow.tailscale(TailnetStatus.reading) }
        planTask = Task { [weak self] in
            guard let flow = self?.flow else { return }
            let plans = await flow.plans()
            for await plan in plans {
                guard let self, !Task.isCancelled else { return }
                self.render(plan)
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        AppLogger.lifecycle.info("add machine sheet shown")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        planTask?.cancel()
        planTask = nil
    }

    @objc private func didBecomeActive() {
        Task { await flow.tailscale(TailnetStatus.reading) }
    }

    private func makeRenderer() -> SetupBlockRenderer {
        SetupBlockRenderer(
            actions: SetupBlockRenderer.Actions(
                way: { _ in },
                paste: { _ in },
                type: { _ in },
                useClipboard: {},
                selectAgent: { _ in },
                copied: {},
                share: { _, _ in },
                password: { [weak self] text in
                    guard let self else { return }
                    Task { await self.flow.setPassword(text) }
                },
                submit: { [weak self] in
                    guard let self else { return }
                    self.view.endEditing(true)
                    Task { await self.flow.retry() }
                },
                fix: { [weak self] in self?.perform($0) },
                signIn: { [weak self] in self?.presentSignIn() },
                connectAnyway: { [weak self] in
                    guard let self else { return }
                    Task { await self.flow.confirmOffTailnet() }
                },
                openTailscale: { TailnetStatus.openTailscaleApp() },
                openLink: { _ in },
                reveal: { [weak self] in self?.pendingReveal = $0 }))
    }

    private func buildUI() {
        let title = SetupLink.label(
            ConnectLinkReading.addQuestion, role: .cardTitle, color: Theme.Color.label)
        title.accessibilityTraits = .header
        let detail = SetupLink.label(ConnectLinkReading.addDetail(link), role: .panelLabel)

        [statusStack, blockStack].forEach {
            $0.axis = .vertical
            $0.spacing = Theme.Spacing.m
        }
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        [title, detail, statusStack, blockStack].forEach(column.addArrangedSubview)
        column.setCustomSpacing(Theme.Spacing.xs, after: title)
        column.setCustomSpacing(Theme.Spacing.l, after: detail)
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(column)

        primary.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)
        primary.isHidden = true
        secondary.configuration?.title = ConnectLinkReading.notNow
        secondary.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.notNowTapped()
            }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [primary, secondary])
        buttons.axis = .vertical
        buttons.spacing = Theme.Spacing.s
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor),

            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            column.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),

            buttons.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            buttons.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            buttons.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.s),
        ])
    }

    private func render(_ plan: FirstRunPlan) {
        self.plan = plan
        statusStack.arrangedSubviews.forEach {
            statusStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in plan.rows { statusStack.addArrangedSubview(statusLine(for: row)) }
        let blocks = plan.rows.flatMap(\.blocks).filter(isShownHere)
        let views = renderer.views(for: blocks, slot: "add") + linkViews(in: plan)
        arrange(views)
        applyButtons(plan)
        if focusPasswordWhenShown, renderer.passwordBlock.superview != nil {
            focusPasswordWhenShown = false
            renderer.passwordBlock.field.textField.becomeFirstResponder()
        }
        if let target = pendingReveal {
            pendingReveal = nil
            view.layoutIfNeeded()
            let frame = target.convert(target.bounds, to: scroll)
            scroll.scrollRectToVisible(frame.insetBy(dx: 0, dy: -Theme.Spacing.m), animated: true)
        }
        if case .openExisting(let id) = plan.outcome, !didFinish {
            didFinish = true
            dismiss(animated: true) { [onOpenExisting] in onOpenExisting?(id) }
            return
        }
        finishIfDone(plan)
    }

    private func isShownHere(_ block: FirstRunPlan.Block) -> Bool {
        switch block {
        case .waiting, .diagnosis, .password, .signIn: return true
        case .note, .ways, .paste, .agents, .command, .link, .remedy: return false
        }
    }

    private func linkViews(in plan: FirstRunPlan) -> [UIView] {
        for row in plan.rows {
            for case .link(let card) in row.blocks {
                let stack = UIStackView()
                stack.axis = .vertical
                stack.spacing = Theme.Spacing.xs
                card.lines.forEach {
                    stack.addArrangedSubview(
                        SetupLink.label($0, role: .panelFootnote, color: Theme.Color.secondaryLabel))
                }
                if let title = card.connectAnywayTitle {
                    let button = SetupLink.button(title: title, symbol: nil)
                    button.addAction(
                        UIAction { [weak self] _ in
                            guard let self else { return }
                            Theme.Haptics.tap()
                            Task { await self.flow.confirmOffTailnet() }
                        }, for: .touchUpInside)
                    stack.addArrangedSubview(button)
                }
                return [stack]
            }
        }
        return []
    }

    private func arrange(_ views: [UIView]) {
        let current = blockStack.arrangedSubviews
        var index = 0
        while index < min(current.count, views.count), current[index] === views[index] { index += 1 }
        for stale in current[index...] {
            blockStack.removeArrangedSubview(stale)
            stale.removeFromSuperview()
        }
        for view in views[index...] { blockStack.addArrangedSubview(view) }
    }

    private func statusLine(for row: FirstRunPlan.Row) -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: row.glyph.pillSymbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        icon.tintColor = row.glyph.pillTint
        icon.contentMode = .center
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.isAccessibilityElement = false

        let text = UIStackView(arrangedSubviews: [
            SetupLink.label(row.title, role: .panelLabel, color: Theme.Color.label)
        ])
        text.axis = .vertical
        text.spacing = 2
        if let said = row.pill ?? row.detail {
            text.addArrangedSubview(SetupLink.label(said, role: .panelFootnote))
        }
        let line = UIStackView(arrangedSubviews: [icon, text])
        line.axis = .horizontal
        line.spacing = Theme.Spacing.s
        line.alignment = .firstBaseline
        line.isAccessibilityElement = true
        line.accessibilityLabel = [row.title, row.pill ?? row.detail].compactMap { $0 }.joined(
            separator: ". ")
        return line
    }

    private func applyButtons(_ plan: FirstRunPlan) {
        if let action = plan.primary {
            primary.isHidden = false
            primary.setTitle(action.title)
            primary.setLoading(action.isLoading)
            if !action.isLoading { primary.isEnabled = action.isEnabled }
        } else {
            primary.isHidden = true
        }
        secondary.configuration?.title = plan.later ?? ConnectLinkReading.notNow
    }

    private func primaryTapped() {
        view.endEditing(true)
        guard let intent = plan?.primary?.intent else { return }
        Theme.Haptics.tap()
        switch intent {
        case .connect: Task { await flow.connect() }
        case .openTailscale: TailnetStatus.openTailscaleApp()
        case .signIn: presentSignIn()
        }
    }

    private func notNowTapped() {
        guard plan?.later != nil else {
            dismiss(animated: true)
            return
        }
        Task { await flow.skipSignIn() }
    }

    private func perform(_ fix: ConnectDiagnosis.Fix) {
        SetupFixes.perform(
            fix, flow: flow, from: self,
            revealPassword: { [weak self] in self?.focusPasswordWhenShown = true },
            copied: { [weak self] command in
                guard let self else { return }
                ToastView(message: command).flash(
                    in: self.view, above: self.view.safeAreaLayoutGuide.bottomAnchor, duration: 3)
            })
    }

    private func presentSignIn() {
        SetupFixes.presentSignIn(flow: flow, from: self)
    }

    private func finishIfDone(_ plan: FirstRunPlan) {
        guard plan.isFinished, !didFinish else { return }
        didFinish = true
        Task { [weak self] in
            guard let self else { return }
            let saved = await self.flow.saved
            Theme.Haptics.success()
            if self.presentedViewController != nil {
                try? await Task.sleep(for: .seconds(1))
                await withCheckedContinuation { continuation in
                    self.dismiss(animated: true) { continuation.resume() }
                }
            }
            self.primary.isHidden = false
            self.primary.setLoading(false)
            self.primary.setTitle(Localized.text("Connected"))
            self.primary.isEnabled = false
            if !UIAccessibility.isReduceMotionEnabled { try? await Task.sleep(for: .milliseconds(450)) }
            MachineConnectedStep.proceed(profile: saved?.profile, in: self.navigationController) {
                [weak self] in
                self?.navigationController?.dismiss(animated: true)
            }
        }
    }
}
