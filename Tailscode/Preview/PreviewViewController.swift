import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// An iOS app running on a Mac's simulator, streamed picture by picture by a preview host and drawn
/// full screen over the conversation that asked for it. The phone has no tiling, so there is no
/// pane: this is a modal viewer, a skin over ``PreviewSlot`` and ``PreviewRunner``. Every word on it
/// is Core's and every fact comes from the runner's two latest-wins mailboxes, which one display-link
/// tick drains.
///
/// The link exists only while there is something to drain. The runner wakes it when a picture or a
/// state lands, it decodes the newest picture and no more than one per tick, and it comes off the
/// display again the moment both mailboxes are clean, so a viewer showing a still screen owns no
/// clock at all, and one that is not on screen owns neither a clock nor a stream.
///
/// The picture, the checklist and the failure card are content on the opaque canvas. The only glass
/// is the floating control layer: close, the identity strip, and the bar of Light, Dark, Rebuild and
/// Copy.
@MainActor
final class PreviewViewController: UIViewController {
    private enum Face {
        case ask, setup, status, live
    }

    private(set) var slot: PreviewSlot
    let fixedHost: String?

    var onAskAgent: ((String) -> Void)?

    private let secrets: any SecretStore
    private let lifetime = PaneLifetime()
    private let clock = PreviewClock()
    private let ticker = PreviewTicker()
    private var runner: PreviewRunner?
    private var runsRunner = true
    private var probeTask: Task<Void, Never>?
    private var lastDecodedAt: CFTimeInterval = 0
    private var isParked = false
    private var isShutDown = false
    private var announcedLight: PreviewLight?
    private var shownFace: Face = .ask
    private var copiedReset: Task<Void, Never>?

    private(set) var lastPictureJPEG: Data?
    private(set) var pictureSize: (width: Int, height: Int)?

    private let stage = UIView()
    private let askFace = UIScrollView()
    private let setupFace = UIScrollView()
    private let statusFace = UIView()
    private let liveFace = PreviewLiveView()

    private let hostField = PreviewField()
    private let folderField = PreviewField()
    private let passwordField = PreviewField()
    private let reasonLabel = UILabel()
    private let hostLabel = UILabel()
    private let openButton = UIButton(type: .system)

    private let setupHeading = UILabel()
    private let checklist = PreviewChecklistView()

    private let statusBadge = ActivityBadgeView(pointSize: 28)
    private let statusLabel = UILabel()
    private let retryPassword = PreviewField()
    private let statusBanner = PreviewBannerView()

    private let closeGlass = Theme.Glass.view(interactive: true)
    private let stripGlass = Theme.Glass.view()
    private let barGlass = Theme.Glass.view(interactive: true)
    private let stripBadge = ActivityBadgeView(pointSize: 14)
    private let stripTitle = UILabel()
    private let stripSubtitle = UILabel()
    private let lightButton = PreviewBarButton(title: Localized.text("Light"))
    private let darkButton = PreviewBarButton(title: Localized.text("Dark"))
    private let rebuildButton = PreviewBarButton(
        symbol: "arrow.clockwise", spoken: Localized.text("Rebuild"))
    private let copyButton = PreviewBarButton(
        symbol: "doc.on.doc", spoken: Localized.text("Copy picture"))

    private static let decodeInterval: CFTimeInterval = 0.015

    init(
        target: PreviewTarget?, fixedHost: String? = nil, runs: Bool = true,
        secrets: (any SecretStore)? = nil
    ) {
        slot = PreviewSlot(target: target)
        self.fixedHost = fixedHost
        self.secrets = secrets ?? KeychainSecretStore()
        runsRunner = runs
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        clock.owner = self
        ticker.onTick = { [weak self] link in self?.step(link) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        lifetime.cancelAll()
        clock.owner = nil
    }

    var target: PreviewTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }
    var hasLink: Bool { ticker.isRunning }
    var isRunning: Bool { runner != nil && !isParked && !isShutDown }

    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        view.accessibilityViewIsModal = true
        buildStage()
        buildAsk()
        buildSetup()
        buildStatus()
        buildLive()
        buildControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appResigned), name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        if let target = slot.target, runsRunner { startRunner(for: target) }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppLogger.ui.info("preview: appeared target=\(slot.target?.address ?? "none")")
        unpark()
        if let runner, runner.pictures.isDirty || runner.states.isDirty { arm() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            AppLogger.ui.info("preview: closed")
            shutdown()
        } else {
            park()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        liveFace.contentInsets = UIEdgeInsets(
            top: stripGlass.frame.maxY + Theme.Spacing.m, left: Theme.Spacing.l,
            bottom: barGlass.isHidden
                ? view.safeAreaInsets.bottom + Theme.Spacing.l
                : view.bounds.height - barGlass.frame.minY + Theme.Spacing.m,
            right: Theme.Spacing.l)
        let top = stripGlass.frame.maxY + Theme.Spacing.m
        for scroll in [askFace, setupFace] { clear(scroll, below: top) }
    }

    private func buildStage() {
        stage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: view.topAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for face in [askFace, setupFace, statusFace, liveFace] as [UIView] {
            face.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(face)
            NSLayoutConstraint.activate([
                face.topAnchor.constraint(equalTo: stage.topAnchor),
                face.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
                face.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                face.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            ])
        }
    }

    private func style(_ label: UILabel, role: TypeRole, color: UIColor, centered: Bool = false) {
        label.font = Theme.Ramp.font(role)
        label.textColor = color
        label.textAlignment = centered ? .center : .natural
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
    }

    /// Lays a column of content inside a scroll view, under the floating strip and inside the
    /// readable width, scrolling when it is taller than the room it has.
    private func hold(_ column: UIView, in scroll: UIScrollView) {
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.keyboardDismissMode = .interactive
        let margin = Theme.Spacing.l
        let width = column.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        let fill = column.widthAnchor.constraint(
            equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -margin * 2)
        fill.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            width, fill,
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: margin),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -margin),
        ])
    }

    private func clear(_ scroll: UIScrollView, below top: CGFloat) {
        guard abs(scroll.contentInset.top - top) > 0.5 else { return }
        let atStart = scroll.contentOffset.y <= -scroll.contentInset.top + 0.5
        scroll.contentInset.top = top
        scroll.verticalScrollIndicatorInsets.top = top
        if atStart { scroll.contentOffset.y = -top }
    }

    private func buildAsk() {
        let heading = UILabel()
        heading.text = Localized.text("Preview")
        style(heading, role: .cardTitle, color: Theme.Color.label)

        style(hostLabel, role: .panelLabel, color: Theme.Color.secondaryLabel)
        style(reasonLabel, role: .panelFootnote, color: Theme.Color.secondaryLabel)
        reasonLabel.isHidden = true

        hostField.placeholder = Localized.text("Address of the Mac")
        hostField.keyboardType = .URL
        folderField.placeholder = slot.prompt
        passwordField.placeholder = Localized.text("Password")
        passwordField.isSecureTextEntry = true
        passwordField.isHidden = true
        for field in [hostField, folderField, passwordField] {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .go
            field.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)
        }
        if let fixedHost {
            hostLabel.text = PreviewAccessStore.access(host: fixedHost)?.label ?? fixedHost
            hostField.isHidden = true
        } else {
            hostLabel.isHidden = true
            let known = PreviewAccessStore.all()
            if known.count == 1, let only = known.first { hostField.text = only.host }
        }

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.title = Localized.text("Open")
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        openButton.configuration = config
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        openButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [
            heading, hostLabel, hostField, folderField, passwordField, reasonLabel, openButton,
        ])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        hold(column, in: askFace)
    }

    private func buildSetup() {
        style(setupHeading, role: .cardTitle, color: Theme.Color.label)
        checklist.onFix = { [weak self] fix in self?.runner?.runFix(fix) }
        let column = UIStackView(arrangedSubviews: [setupHeading, checklist])
        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        hold(column, in: setupFace)
    }

    private func buildStatus() {
        style(statusLabel, role: .rowTitle, color: Theme.Color.secondaryLabel, centered: true)
        retryPassword.placeholder = Localized.text("Password")
        retryPassword.isSecureTextEntry = true
        retryPassword.returnKeyType = .go
        retryPassword.isHidden = true
        retryPassword.addAction(UIAction { [weak self] _ in self?.retryWithPassword() }, for: .editingDidEndOnExit)
        statusBanner.onAsk = { [weak self] in self?.askAgent() }
        let column = UIStackView(arrangedSubviews: [statusBadge, statusLabel, retryPassword, statusBanner])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        statusFace.addSubview(column)
        let margin = Theme.Spacing.l
        let width = column.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        let fill = column.widthAnchor.constraint(equalTo: statusFace.widthAnchor, constant: -margin * 2)
        fill.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: statusFace.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: statusFace.centerYAnchor),
            width, fill,
        ])
    }

    private func buildLive() {
        liveFace.banner.onAsk = { [weak self] in self?.askAgent() }
    }

    private func buildControls() {
        let close = UIButton(type: .system)
        close.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal)
        close.tintColor = Theme.Color.onGlass
        close.accessibilityLabel = Localized.text("Close")
        close.addAction(UIAction { [weak self] _ in self?.closeTapped() }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        closeGlass.translatesAutoresizingMaskIntoConstraints = false
        closeGlass.layer.cornerRadius = 22
        closeGlass.layer.cornerCurve = .continuous
        closeGlass.clipsToBounds = true
        closeGlass.contentView.addSubview(close)
        view.addSubview(closeGlass)

        style(stripTitle, role: .rowTitleStrong, color: Theme.Color.onGlass)
        stripTitle.numberOfLines = 1
        style(stripSubtitle, role: .rowDetail, color: Theme.Color.onGlassSecondary)
        stripSubtitle.numberOfLines = 1
        let words = UIStackView(arrangedSubviews: [stripTitle, stripSubtitle])
        words.axis = .vertical
        let strip = UIStackView(arrangedSubviews: [stripBadge, words])
        strip.alignment = .center
        strip.spacing = Theme.Spacing.s
        strip.translatesAutoresizingMaskIntoConstraints = false
        stripGlass.translatesAutoresizingMaskIntoConstraints = false
        stripGlass.layer.cornerRadius = 22
        stripGlass.layer.cornerCurve = .continuous
        stripGlass.clipsToBounds = true
        stripGlass.contentView.addSubview(strip)
        view.addSubview(stripGlass)
        stripGlass.isAccessibilityElement = true

        lightButton.onTap = { [weak self] in self?.choose(appearance: "light") }
        darkButton.onTap = { [weak self] in self?.choose(appearance: "dark") }
        rebuildButton.onTap = { [weak self] in self?.rebuild() }
        copyButton.onTap = { [weak self] in self?.copyPicture() }
        let appearance = UIStackView(arrangedSubviews: [lightButton, darkButton])
        appearance.spacing = Theme.Spacing.xs
        let bar = UIStackView(arrangedSubviews: [appearance, rebuildButton, copyButton])
        bar.alignment = .center
        bar.spacing = Theme.Spacing.s
        bar.translatesAutoresizingMaskIntoConstraints = false
        barGlass.translatesAutoresizingMaskIntoConstraints = false
        barGlass.layer.cornerRadius = 26
        barGlass.layer.cornerCurve = .continuous
        barGlass.clipsToBounds = true
        barGlass.contentView.addSubview(bar)
        barGlass.isHidden = true
        view.addSubview(barGlass)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeGlass.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Spacing.s),
            closeGlass.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Spacing.l),
            closeGlass.widthAnchor.constraint(equalToConstant: 44),
            closeGlass.heightAnchor.constraint(equalToConstant: 44),
            close.topAnchor.constraint(equalTo: closeGlass.contentView.topAnchor),
            close.bottomAnchor.constraint(equalTo: closeGlass.contentView.bottomAnchor),
            close.leadingAnchor.constraint(equalTo: closeGlass.contentView.leadingAnchor),
            close.trailingAnchor.constraint(equalTo: closeGlass.contentView.trailingAnchor),

            stripGlass.centerYAnchor.constraint(equalTo: closeGlass.centerYAnchor),
            stripGlass.leadingAnchor.constraint(equalTo: closeGlass.trailingAnchor, constant: Theme.Spacing.s),
            stripGlass.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -Theme.Spacing.l),
            stripGlass.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            strip.topAnchor.constraint(equalTo: stripGlass.contentView.topAnchor, constant: Theme.Spacing.xs),
            strip.bottomAnchor.constraint(equalTo: stripGlass.contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            strip.leadingAnchor.constraint(equalTo: stripGlass.contentView.leadingAnchor, constant: Theme.Spacing.l),
            strip.trailingAnchor.constraint(equalTo: stripGlass.contentView.trailingAnchor, constant: -Theme.Spacing.l),

            barGlass.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            barGlass.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Theme.Spacing.s),
            barGlass.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: Theme.Spacing.s),
            barGlass.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -Theme.Spacing.s),
            barGlass.heightAnchor.constraint(equalToConstant: 52),
            bar.topAnchor.constraint(equalTo: barGlass.contentView.topAnchor, constant: Theme.Spacing.xs),
            bar.bottomAnchor.constraint(equalTo: barGlass.contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            bar.leadingAnchor.constraint(equalTo: barGlass.contentView.leadingAnchor, constant: Theme.Spacing.s),
            bar.trailingAnchor.constraint(equalTo: barGlass.contentView.trailingAnchor, constant: -Theme.Spacing.s),
        ])
    }

    private func closeTapped() {
        Theme.Haptics.tap()
        dismiss(animated: true)
    }

    private var face: Face {
        if slot.isAsking { return .ask }
        let state = slot.state
        switch state.phase {
        case .settingUp: return .setup
        case .connecting: return .status
        case .starting, .live, .reconnecting: return pictureSize == nil ? .status : .live
        case .failed: return pictureSize != nil && state.session != nil ? .live : .status
        }
    }

    /// One line for the headless drivers: the phase, then what the viewer shows.
    var summary: String {
        let size = pictureSize.map { " \($0.width)x\($0.height)" } ?? ""
        guard !slot.isAsking else { return "asking" }
        let state = slot.state
        switch face {
        case .ask: return "asking"
        case .setup: return "settingUp rows=\(slot.checklist.count)"
        case .status:
            if state.light == .broken { return "broken banner=\(statusBanner.problem)" }
            return "\(phaseWord(state.phase)) [\(state.line)]"
        case .live:
            if state.light == .broken { return "broken\(size) banner=\(liveFace.banner.problem)" }
            return "\(phaseWord(state.phase))\(size)"
        }
    }

    private func phaseWord(_ phase: PreviewPhase) -> String {
        switch phase {
        case .connecting: return "connecting"
        case .settingUp: return "settingUp"
        case .starting: return "starting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        let showing = face
        shownFace = showing
        askFace.isHidden = showing != .ask
        setupFace.isHidden = showing != .setup
        statusFace.isHidden = showing != .status
        liveFace.isHidden = showing != .live
        barGlass.isHidden = showing != .live
        switch showing {
        case .ask: break
        case .setup: renderSetup()
        case .status: renderStatus()
        case .live: renderLive()
        }
        renderStrip()
        announceIfChanged()
        view.setNeedsLayout()
    }

    private func renderStrip() {
        stripTitle.text = slot.title
        stripSubtitle.text = slot.subtitle
        stripBadge.activity = slot.light.activity
        stripBadge.isHidden = slot.light.activity == nil
        stripGlass.accessibilityLabel = [slot.title, slot.subtitle].joined(separator: ", ")
        stripGlass.accessibilityValue = slot.light.spoken
    }

    private func announceIfChanged() {
        guard slot.light != announcedLight else { return }
        announcedLight = slot.light
        guard let spoken = slot.light.spoken, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    private func renderSetup() {
        setupHeading.text = slot.state.line
        checklist.apply(slot.checklist)
    }

    private func renderStatus() {
        let state = slot.state
        statusLabel.text = state.line
        statusBadge.activity = slot.light.activity
        statusBadge.isHidden = slot.light.activity == nil
        retryPassword.isHidden = !state.needsPassword
        let broken = state.light == .broken
        statusBanner.isHidden = !broken
        if broken { statusBanner.show(headline: headline(of: state), problem: state.firstProblem) }
    }

    private func renderLive() {
        let state = slot.state
        let stale = state.phase == .reconnecting
        let changing = state.phase == .starting
        liveFace.setDimmed(stale || changing, words: stale ? PreviewLight.stale.line : state.line)
        let broken = state.light == .broken
        liveFace.banner.isHidden = !broken
        if broken { liveFace.banner.show(headline: headline(of: state), problem: state.firstProblem) }
        liveFace.setAccessibility(slot.light.spoken ?? slot.title)
        renderAppearance()
    }

    private func renderAppearance() {
        let dark = slot.appearance == "dark"
        lightButton.isAccented = !dark
        darkButton.isAccented = dark
    }

    private func headline(of state: PreviewState) -> String {
        state.lastBuild.map(PreviewReading.headline(of:)) ?? state.line
    }

    func choose(appearance: String) {
        guard appearance != slot.appearance else { return }
        Theme.Haptics.selection()
        slot.appearance = appearance
        runner?.setAppearance(appearance)
        renderAppearance()
    }

    func rebuild() {
        Theme.Haptics.tap()
        AppLogger.ui.info("preview: rebuild asked")
        runner?.rebuild()
    }

    func copyPicture() {
        guard let lastPictureJPEG, let image = UIImage(data: lastPictureJPEG) else { return }
        UIPasteboard.general.image = image
        Theme.Haptics.success()
        copyButton.confirm(symbol: "checkmark", spoken: Localized.text("Copied"))
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copyButton.confirm(symbol: nil, spoken: nil)
        }
    }

    func askAgent() {
        let problem = slot.state.firstProblem ?? slot.state.line
        let words = Localized.text(
            "The preview of %@ would not build. The first problem is: %@. Please fix it.",
            slot.target?.appName ?? slot.title, problem)
        AppLogger.ui.info("preview: asked the agent to fix the build")
        Theme.Haptics.tap()
        let handler = onAskAgent
        dismiss(animated: true) { handler?(words) }
    }

    private func submit() {
        let typedHost = fixedHost ?? (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (folderField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedHost.isEmpty else {
            hostField.becomeFirstResponder()
            return
        }
        guard !folder.isEmpty else {
            folderField.becomeFirstResponder()
            return
        }
        let (host, typedPort) = Self.split(typedHost)
        let remembered = PreviewAccessStore.access(host: host)
        let access = PreviewAccess(
            host: host, port: typedPort ?? remembered?.port ?? PreviewAccess(host: host).port,
            name: remembered?.name)
        let typedPassword = passwordField.text ?? ""
        let stored = (try? secrets.value(for: access.secretKey)) ?? nil
        let password = typedPassword.isEmpty ? stored : typedPassword
        show(reason: PreviewReach.checking.line)
        view.endEditing(true)
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let reach = await PreviewProbe.probe(access, password: password)
            guard !Task.isCancelled else { return }
            self?.probed(reach, access: access, folder: folder, typedPassword: typedPassword)
        }
    }

    nonisolated static func split(_ address: String) -> (host: String, port: Int?) {
        let parts = address.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return (address.trimmingCharacters(in: CharacterSet(charactersIn: ":")), nil)
        }
        return (parts[0], port)
    }

    private func probed(_ reach: PreviewReach, access: PreviewAccess, folder: String, typedPassword: String) {
        guard !isShutDown, slot.isAsking else { return }
        guard reach.isAnswering else {
            show(reason: reach.line)
            if reach.asksForPassword {
                passwordField.isHidden = false
                passwordField.becomeFirstResponder()
            }
            return
        }
        PreviewAccessStore.remember(access)
        if !typedPassword.isEmpty { try? secrets.setValue(typedPassword, for: access.secretKey) }
        show(reason: nil)
        point(at: PreviewTarget(host: access.host, port: access.port, project: folder))
    }

    private func show(reason: String?) {
        reasonLabel.isHidden = reason == nil
        reasonLabel.text = reason
    }

    private func retryWithPassword() {
        guard let target = slot.target else { return }
        let typed = retryPassword.text ?? ""
        guard !typed.isEmpty else { return }
        try? secrets.setValue(typed, for: target.access.secretKey)
        retryPassword.text = ""
        retryPassword.resignFirstResponder()
        point(at: target)
    }

    func point(at target: PreviewTarget) {
        endRun()
        slot.point(at: target)
        resetPicture()
        startRunner(for: target)
        render()
    }

    private func startRunner(for target: PreviewTarget) {
        guard runsRunner else { return }
        let password = (try? secrets.value(for: target.access.secretKey)) ?? nil
        guard let config = target.access.config(password: password) else {
            var failed = PreviewState()
            failed.phase = .failed(PreviewReach.unreachable(target.access.address).line)
            slot.apply(failed)
            return
        }
        AppLogger.connection.info("preview: starting \(target.address)")
        let runner = PreviewRunner(target: target, config: config, clock: clock)
        self.runner = runner
        guard !isParked, !isShutDown else { return }
        begin(runner)
    }

    private func begin(_ runner: PreviewRunner) {
        runner.start()
        lifetime.add { runner.stop() }
        arm()
    }

    private func endRun() {
        lifetime.cancelAll()
        ticker.stop()
        runner = nil
    }

    func park() {
        guard !isParked else { return }
        isParked = true
        lifetime.cancelAll()
        ticker.stop()
        probeTask?.cancel()
    }

    func unpark() {
        guard isParked else { return }
        isParked = false
        guard !isShutDown, let runner else { return }
        begin(runner)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        probeTask?.cancel()
        probeTask = nil
        copiedReset?.cancel()
        lifetime.cancelAll()
        ticker.stop()
        runner = nil
        clock.owner = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appResigned() { park() }

    @objc private func appBecameActive() {
        guard isViewLoaded, view.window != nil else { return }
        unpark()
    }

    fileprivate func wake() {
        guard runner != nil else { return }
        arm()
    }

    private func arm() {
        guard runner != nil, !isParked, !isShutDown, isViewLoaded, view.window != nil else { return }
        ticker.start()
    }

    /// One frame of the viewer's whole work: the newest state, then the newest picture if the last
    /// decode is old enough, then the clock off the display again once nothing is waiting.
    private func step(_ link: CADisplayLink) {
        guard let runner, !isParked, !isShutDown else {
            ticker.stop()
            return
        }
        if let state = runner.states.take() { apply(state) }
        if runner.pictures.isDirty, link.timestamp - lastDecodedAt >= Self.decodeInterval,
            let newest = runner.pictures.take()
        {
            lastDecodedAt = link.timestamp
            adopt(newest.jpeg)
        }
        if !runner.states.isDirty, !runner.pictures.isDirty { ticker.stop() }
    }

    private func apply(_ state: PreviewState) {
        slot.apply(state)
        render()
    }

    /// Decodes a JPEG into the picture the viewer shows. A bad frame keeps the last good one, which
    /// is the whole point of a preview that outlives a broken build.
    @discardableResult
    private func adopt(_ bytes: Data) -> Bool {
        guard let image = PreviewPictureView.decode(bytes) else { return false }
        let reshaped = pictureSize.map { $0.width != image.width || $0.height != image.height } ?? true
        liveFace.show(image)
        lastPictureJPEG = bytes
        pictureSize = (image.width, image.height)
        if reshaped { render() }
        return true
    }

    private func resetPicture() {
        liveFace.clear()
        lastPictureJPEG = nil
        pictureSize = nil
    }

    #if DEBUG
        func applyForTest(_ state: PreviewState, jpeg bytes: Data? = nil) {
            loadViewIfNeeded()
            if let bytes { adopt(bytes) }
            apply(state)
        }

        var shownPictureAlpha: CGFloat { liveFace.pictureAlpha }
        var shownChipWords: String? { liveFace.chipWords }
        var controlsVisible: Bool { !barGlass.isHidden }
    #endif
}

/// The wake-up the runner is given: a drain request from any thread becomes one tick of the
/// display link on the main loop, and nothing else. It holds the viewer weakly, so a runner
/// outliving its viewer for a moment wakes nothing.
private final class PreviewClock: TailscodeCore.HostClock, @unchecked Sendable {
    nonisolated(unsafe) weak var owner: PreviewViewController?

    func now() -> TimeInterval { CACurrentMediaTime() }

    func requestDrain() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.owner?.wake() }
        }
    }
}

/// The viewer's one display link, owned here so that the link never holds the viewer: it calls a
/// closure the viewer gave it weakly, and a viewer that has gone leaves a link that stops itself on
/// its first tick. It runs only between `start` and `stop`.
@MainActor
private final class PreviewTicker: NSObject {
    var onTick: ((CADisplayLink) -> Void)?
    private var link: CADisplayLink?

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let fresh = CADisplayLink(target: self, selector: #selector(fire(_:)))
        fresh.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        fresh.add(to: .main, forMode: .common)
        link = fresh
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        guard let onTick else {
            stop()
            return
        }
        onTick(link)
    }
}

/// A text field in the viewer's own voice: an opaque raised field on the canvas, with the room a
/// finger needs.
@MainActor
private final class PreviewField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = Theme.Ramp.font(.composer)
        textColor = Theme.Color.label
        backgroundColor = Theme.Color.codeBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        adjustsFontForContentSizeCategory = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private let inset = UIEdgeInsets(top: 0, left: Theme.Spacing.m, bottom: 0, right: Theme.Spacing.m)

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
}

/// One control on the floating bar. Plain text on glass in the system's own ink; the one that is
/// chosen wears a quiet capsule, so the state never lives in a tint alone.
@MainActor
private final class PreviewBarButton: UIButton {
    var onTap: (() -> Void)?

    var isAccented = false {
        didSet {
            guard isAccented != oldValue else { return }
            setNeedsUpdateConfiguration()
            accessibilityTraits = isAccented ? [.button, .selected] : .button
        }
    }

    private let title: String?
    private let symbol: String?
    private let spoken: String?
    private var confirmation: (symbol: String, spoken: String)?

    convenience init(title: String) {
        self.init(title: title, symbol: nil, spoken: title)
    }

    convenience init(symbol: String, spoken: String) {
        self.init(title: nil, symbol: symbol, spoken: spoken)
    }

    private init(title: String?, symbol: String?, spoken: String?) {
        self.title = title
        self.symbol = symbol
        self.spoken = spoken
        super.init(frame: .zero)
        configurationUpdateHandler = { [unowned self] _ in self.refresh() }
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows a brief answer in place of the resting symbol, then goes back when told to with nil.
    func confirm(symbol: String?, spoken: String?) {
        confirmation = symbol.flatMap { symbol in spoken.map { (symbol, $0) } }
        setNeedsUpdateConfiguration()
    }

    private func refresh() {
        var config = UIButton.Configuration.plain()
        config.title = title
        if let shown = confirmation?.symbol ?? symbol {
            config.image = UIImage(
                systemName: shown,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        }
        config.baseForegroundColor = Theme.Color.onGlass
        config.cornerStyle = .capsule
        config.titleLineBreakMode = .byClipping
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        config.background.backgroundColor =
            isAccented ? Theme.Color.onGlass.withAlphaComponent(0.16) : .clear
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Ramp.font(.control)
            return outgoing
        }
        configuration = config
        accessibilityLabel = confirmation?.spoken ?? spoken
    }
}
