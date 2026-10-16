import CodingAgentKit
import CodingAgentKitApple
import SafariServices
import TailscodeCore
import UIKit

/// First run drawn from a `FirstRunPlan`. The checklist, its words and the order it is walked in
/// belong to `FirstRunFlow`; this screen forwards what the person does, draws what comes back,
/// and keeps no idea of its own about where in the checklist they are.
@MainActor
final class ServerSetupViewController: UIViewController {
    enum Mode {
        case firstRun
        case addServer
    }

    var onConnected: (() -> Void)?
    var onTryDemo: (() -> Void)?
    var startsOnLink = false

    let flow: FirstRunFlow
    private let mode: Mode
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let footer = OnboardingFooterBar()
    private let introLabel = SetupLink.label("")
    private let backButton = SetupLink.button(title: "", symbol: "chevron.left")
    private lazy var renderer = makeRenderer()
    private var cards: [FirstRunPlan.Row.ID: SetupStepCard] = [:]
    private var scrollToFooter: NSLayoutConstraint?
    private var scrollToKeyboard: NSLayoutConstraint?

    private var plan: FirstRunPlan?
    private var planTask: Task<Void, Never>?
    private var tailnetTicker: Task<Void, Never>?
    private var tailnetAddress: String?
    private var didReadTailnet = false
    private var scanTitle: String?
    private var secondaryKey: String?
    private var lastMachineGlyph: FirstRunPlan.Row.Glyph?
    private var pendingReveal: UIView?
    private var focusFieldWhenShown = false
    private var focusPasswordWhenShown = false
    private var handlingOutcome = false
    private var didFinish = false
    private var didSeed = false
    private var didAutoConnect = false

    init(mode: Mode) {
        self.mode = mode
        flow = FirstRunFlow(
            platform: .current, mode: mode == .firstRun ? .firstRun : .addition,
            environment: .app())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func receive(link text: String) {
        Task { await flow.paste(text) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keepToPageBeforeFold(FoldReading.read(in: view))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .firstRun ? Localized.text("Set up") : Localized.text("Add a server")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"), menu: helpMenu())
        buildUI()
        refreshTailnet()
        startPlanTask()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        AppLogger.lifecycle.info("server setup shown (\(mode == .firstRun ? "first run" : "add server"))")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTailnetTicker()
        if startsOnLink {
            startsOnLink = false
            focusFieldWhenShown = true
            Task { await flow.choose(.link) }
        }
        seedFromEnvironment()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tailnetTicker?.cancel()
        tailnetTicker = nil
        guard isMovingFromParent || isBeingDismissed else { return }
        planTask?.cancel()
        planTask = nil
        guard !didFinish else { return }
        Task { [weak self] in
            guard let self, await self.flow.saved != nil, !self.didFinish else { return }
            self.didFinish = true
            self.onConnected?()
        }
    }

    private func makeRenderer() -> SetupBlockRenderer {
        SetupBlockRenderer(
            actions: SetupBlockRenderer.Actions(
                way: { [weak self] in self?.wayTapped($0) },
                paste: { [weak self] text in
                    guard let self else { return }
                    Task { await self.flow.paste(text) }
                },
                type: { [weak self] text in
                    guard let self else { return }
                    Task { await self.flow.typeAddress(text) }
                },
                useClipboard: { [weak self] in
                    guard let self else { return }
                    Task { await self.flow.useClipboardLink() }
                },
                selectAgent: { [weak self] agent in
                    guard let self else { return }
                    Task { await self.flow.selectAgent(agent) }
                },
                copied: { [weak self] in
                    guard let self else { return }
                    Task { await self.flow.handedOver() }
                },
                share: { [weak self] text, source in self?.share(text, from: source) },
                password: { [weak self] text in
                    guard let self else { return }
                    Task { await self.flow.setPassword(text) }
                },
                submit: { [weak self] in self?.submit() },
                fix: { [weak self] in self?.perform($0) },
                signIn: { [weak self] in self?.presentSignIn() },
                connectAnyway: { [weak self] in
                    guard let self else { return }
                    Task { await self.flow.confirmOffTailnet() }
                },
                openTailscale: { TailnetStatus.openTailscaleApp() },
                openLink: { [weak self] in self?.open($0) },
                reveal: { [weak self] in self?.pendingReveal = $0 }))
    }

    private func buildUI() {
        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        column.addArrangedSubview(introLabel)
        column.translatesAutoresizingMaskIntoConstraints = false

        backButton.configuration?.imagePlacement = .leading
        backButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                Task { await self.flow.back() }
            }, for: .touchUpInside)

        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(box)
        view.addSubview(scroll)

        footer.primary.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)
        view.addSubview(footer)
        footer.isHidden = true

        let toFooter = scroll.bottomAnchor.constraint(equalTo: footer.topAnchor)
        let toKeyboard = scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        scrollToFooter = toFooter
        scrollToKeyboard = toKeyboard

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toKeyboard,

            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            box.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            box.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            box.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

            column.topAnchor.constraint(equalTo: box.topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Theme.Spacing.xl),
            column.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualTo: box.widthAnchor, constant: -2 * Theme.Spacing.l),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            column.widthAnchor.constraint(
                equalTo: box.widthAnchor, constant: -2 * Theme.Spacing.l)
                .withPriority(UILayoutPriority(999)),
        ])
    }

    private func helpMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: Localized.text("View logs"),
                image: UIImage(systemName: "doc.text.magnifyingglass")
            ) { [weak self] _ in
                self?.navigationController?.pushViewController(LogViewerViewController(), animated: true)
            },
            UIAction(
                title: Localized.text("Copy diagnostics"), image: UIImage(systemName: "stethoscope")
            ) { [weak self] _ in
                Task { @MainActor in
                    UIPasteboard.general.string = await DiagnosticsReport.build()
                    Theme.Haptics.success()
                    guard let self else { return }
                    ToastView(message: Localized.text("Diagnostics copied"))
                        .flash(in: self.view, above: self.toastAnchor)
                }
            },
        ])
    }

    private var toastAnchor: NSLayoutYAxisAnchor {
        footer.isHidden ? view.safeAreaLayoutGuide.bottomAnchor : footer.topAnchor
    }

    private func startPlanTask() {
        planTask = Task { [weak self] in
            guard let flow = self?.flow else { return }
            let plans = await flow.plans()
            for await plan in plans {
                guard let self, !Task.isCancelled else { return }
                self.render(plan)
            }
        }
    }

    private func render(_ plan: FirstRunPlan) {
        self.plan = plan
        if cards.isEmpty { buildCards(plan) }
        introLabel.text = plan.intro
        backButton.configuration?.title = plan.back
        for row in plan.rows {
            guard let card = cards[row.id] else { continue }
            apply(row, of: plan, to: card)
        }
        rememberScanTitle(plan)
        announceMachine(plan)
        applyFooter(plan)
        focusIfAsked()
        revealIfAsked()
        handleOutcome(plan)
        finishIfDone(plan)
        connectForVerification(plan)
    }

    private func buildCards(_ plan: FirstRunPlan) {
        for row in plan.rows {
            let card = SetupStepCard(
                index: row.number, total: plan.rows.count, title: row.title, detail: row.detail ?? "")
            cards[row.id] = card
            column.addArrangedSubview(card)
        }
    }

    private func apply(_ row: FirstRunPlan.Row, of plan: FirstRunPlan, to card: SetupStepCard) {
        card.setTitle(row.title)
        card.setDetail(row.detail)
        card.setStatus(row.glyph.cardStatus)
        card.setPill(row.pill, symbol: row.glyph.pillSymbol, tint: row.glyph.pillTint)
        var views = renderer.views(for: row.blocks, slot: row.id.rawValue)
        if row.id == .machine, plan.back != nil { views.insert(backButton, at: 0) }
        arrange(views, in: card.content)
    }

    private func arrange(_ views: [UIView], in stack: UIStackView) {
        let current = stack.arrangedSubviews
        var index = 0
        while index < min(current.count, views.count), current[index] === views[index] { index += 1 }
        for stale in current[index...] {
            stack.removeArrangedSubview(stale)
            stale.removeFromSuperview()
        }
        for view in views[index...] { stack.addArrangedSubview(view) }
    }

    private func rememberScanTitle(_ plan: FirstRunPlan) {
        for row in plan.rows {
            for block in row.blocks {
                guard case .ways(let ways) = block,
                    let scan = ways.first(where: { $0.kind == .scan })
                else { continue }
                scanTitle = scan.title
            }
        }
    }

    private func announceMachine(_ plan: FirstRunPlan) {
        let glyph = plan.row(.machine)?.glyph
        defer { lastMachineGlyph = glyph }
        guard glyph == .proven, lastMachineGlyph != .proven, let pill = plan.row(.machine)?.pill
        else { return }
        Theme.Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: pill)
    }

    private func applyFooter(_ plan: FirstRunPlan) {
        if let primary = plan.primary {
            footer.setPrimaryHidden(false)
            footer.primary.setTitle(primary.title)
            footer.primary.setLoading(primary.isLoading)
            if !primary.isLoading { footer.primary.isEnabled = primary.isEnabled }
        } else {
            footer.setPrimaryHidden(true)
        }
        applySecondary(plan)
        let shown = footer.hasContent
        footer.isHidden = !shown
        scrollToFooter?.isActive = shown
        scrollToKeyboard?.isActive = !shown
    }

    private func applySecondary(_ plan: FirstRunPlan) {
        if let later = plan.later {
            let key = "later:\(later)"
            guard secondaryKey != key else { return }
            secondaryKey = key
            footer.setSecondary(title: later) { [weak self] in
                guard let self else { return }
                Theme.Haptics.tap()
                Task { await self.flow.skipSignIn() }
            }
        } else if let demo = plan.demo {
            let key = "demo:\(demo.title)"
            guard secondaryKey != key else { return }
            secondaryKey = key
            footer.setSecondary(title: demo.title, hint: demo.detail) { [weak self] in
                Theme.Haptics.tap()
                self?.onTryDemo?()
            }
        } else {
            secondaryKey = nil
            footer.setSecondary(title: nil)
        }
    }

    private func focusIfAsked() {
        if focusFieldWhenShown, renderer.pasteBlock.superview != nil {
            focusFieldWhenShown = false
            renderer.pasteBlock.field.textField.becomeFirstResponder()
        }
        if focusPasswordWhenShown, renderer.passwordBlock.superview != nil {
            focusPasswordWhenShown = false
            renderer.passwordBlock.field.textField.becomeFirstResponder()
        }
    }

    private func revealIfAsked() {
        guard let target = pendingReveal else { return }
        pendingReveal = nil
        view.layoutIfNeeded()
        let frame = target.convert(target.bounds, to: scroll)
        scroll.scrollRectToVisible(frame.insetBy(dx: 0, dy: -Theme.Spacing.m), animated: true)
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

    private func submit() {
        view.endEditing(true)
        if let primary = plan?.primary, primary.intent == .connect, primary.isEnabled {
            Task { await flow.connect() }
        } else {
            Task { await flow.retry() }
        }
    }

    private func wayTapped(_ kind: FirstRunPlan.Way.Kind) {
        switch kind {
        case .scan:
            presentScanner()
        case .link:
            focusFieldWhenShown = true
            Task { await flow.choose(.link) }
        case .install:
            Task { await flow.choose(.install) }
        case .tailnet:
            presentDiscovery()
        }
    }

    private func perform(_ fix: ConnectDiagnosis.Fix) {
        SetupFixes.perform(
            fix, flow: flow, from: self,
            revealPassword: { [weak self] in self?.focusPasswordWhenShown = true },
            copied: { [weak self] command in
                guard let self else { return }
                ToastView(message: command).flash(in: self.view, above: self.toastAnchor, duration: 3)
            })
    }

    private func share(_ text: String, from source: UIView) {
        Task { await flow.handedOver() }
        AppLogger.lifecycle.info("setup steps shared for another computer")
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source
        activity.popoverPresentationController?.sourceRect = source.bounds
        present(activity, animated: true)
    }

    private func presentScanner() {
        view.endEditing(true)
        let scanner = QRScannerViewController(prompt: scanTitle ?? "")
        scanner.onCode = { [weak self] text in
            guard let self else { return }
            self.dismiss(animated: true) {
                Task { await self.flow.paste(text) }
            }
        }
        scanner.onPasteInstead = { [weak self] in
            guard let self else { return }
            self.focusFieldWhenShown = true
            self.dismiss(animated: true) {
                Task { await self.flow.choose(.link) }
            }
        }
        let nav = UINavigationController(rootViewController: scanner)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func presentDiscovery() {
        let discovery = DiscoveryViewController()
        discovery.onConnected = onConnected
        present(UINavigationController(rootViewController: discovery), animated: true)
    }

    private func presentSignIn() {
        SetupFixes.presentSignIn(flow: flow, from: self)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Theme.Haptics.tap()
        present(SFSafariViewController(url: url), animated: true)
    }

    private func handleOutcome(_ plan: FirstRunPlan) {
        guard case .openExisting(let id) = plan.outcome, !handlingOutcome else { return }
        handlingOutcome = true
        let name = ConnectionController.shared.profiles.first { $0.id == id }?.name ?? ""
        Theme.Haptics.success()
        ToastView(message: ConnectLinkReading.alreadyAdded(name)).flash(
            in: view, above: toastAnchor, duration: 3)
        Task { [weak self] in
            guard let self else { return }
            await self.flow.acknowledgeOutcome()
            self.handlingOutcome = false
            self.didFinish = true
            self.onConnected?()
        }
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
            self.celebrate { [weak self] in
                guard let self else { return }
                MachineConnectedStep.proceed(
                    profile: saved?.profile, in: self.navigationController
                ) { [weak self] in self?.onConnected?() }
            }
        }
    }

    /// A held beat on the checkmark before the root swaps, so the payoff of the
    /// whole flow is a confirmation rather than a flash.
    private func celebrate(_ completion: @escaping () -> Void) {
        footer.setPrimaryHidden(false)
        footer.primary.setLoading(false)
        footer.primary.setTitle(Localized.text("Connected"))
        footer.primary.isEnabled = false
        guard !UIAccessibility.isReduceMotionEnabled else {
            completion()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            completion()
        }
    }

    @objc private func didBecomeActive() {
        refreshTailnet()
    }

    private func startTailnetTicker() {
        guard tailnetTicker == nil else { return }
        tailnetTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.refreshTailnet()
            }
        }
    }

    /// Reading the interface list is a syscall, not a request, so the screen can
    /// afford to keep asking, which is what makes it advance itself while the
    /// user is off in the Tailscale app.
    private func refreshTailnet() {
        let address = TailnetStatus.localAddress()
        let cameUp = didReadTailnet && tailnetAddress == nil && address != nil
        didReadTailnet = true
        tailnetAddress = address
        if cameUp {
            Theme.Haptics.success()
            UIAccessibility.post(
                notification: .announcement, argument: DeviceWord.onTailnetAnnouncement)
        }
        Task { await flow.tailscale(TailnetStatus.reading) }
    }

    private func seedFromEnvironment() {
        #if DEBUG
            guard !didSeed else { return }
            didSeed = true
            let environment = ProcessInfo.processInfo.environment
            Task {
                switch environment["TAILSCODE_SETUP_AGENT"] {
                case "claude": await flow.selectAgent(.claudeCode)
                case "omp": await flow.selectAgent(.omp)
                case "opencode": await flow.selectAgent(.openCode)
                default: break
                }
                if let seeded = environment["TAILSCODE_SETUP_ADDRESS"] { await flow.paste(seeded) }
                if let password = environment["TAILSCODE_SETUP_PASSWORD"] {
                    await flow.revealPassword()
                    await flow.setPassword(password)
                }
            }
        #endif
    }

    private func connectForVerification(_ plan: FirstRunPlan) {
        #if DEBUG
            guard !didAutoConnect, ProcessInfo.processInfo.environment["TAILSCODE_SETUP_CONNECT"] != nil,
                let primary = plan.primary, primary.intent == .connect, primary.isEnabled,
                !primary.isLoading
            else { return }
            didAutoConnect = true
            Task { await flow.connect() }
        #endif
    }
}
