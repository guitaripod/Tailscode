import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import SafariServices
import UIKit

/// Setup as a checklist the app verifies for you, instead of a form plus a
/// document. Every step reports whether it is actually true — this phone's
/// tailnet address, which agent answers at the address you typed — and the one
/// screen carries the commands, the address, and the connect action, so nothing
/// has to be remembered across a push.
@MainActor
final class ServerSetupViewController: UIViewController {
    enum Mode {
        case firstRun
        case addServer
    }

    var onConnected: (() -> Void)?
    var onTryDemo: (() -> Void)?
    var startOnConnectStep = false

    private enum Verification: Equatable {
        case idle
        case checking
        case verified(agent: AgentType, version: String?, url: URL)
        case failed(ConnectDiagnosis)
    }

    private let mode: Mode
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let footer = OnboardingFooterBar()

    private let tailnetCard: SetupStepCard
    private let agentCard: SetupStepCard
    private let connectCard: SetupStepCard

    private let openTailscaleButton = UIButton(type: .system)
    private let tailscaleLink = UIButton(type: .system)
    private let commandHost = UIStackView()
    private let agentLink = UIButton(type: .system)
    private let addressField = FormField(
        title: String(localized: "Address"), placeholder: "100.101.102.103",
        keyboard: .URL, contentType: .URL, returnKey: .go)
    private let addressHint = UILabel()
    private let passwordField = FormField(
        title: String(localized: "Password"), placeholder: String(localized: "From your server"),
        secure: true, contentType: .password, returnKey: .go)
    private let passwordDisclosure = UIButton(type: .system)
    private let passwordNote = UILabel()
    private let diagnosisCard = DiagnosisCardView()
    private let checkingRow = UIStackView()
    private let checkingLabel = UILabel()
    private let checkingSpinner = ActivityBadgeView(pointSize: 16)
    private var choiceCards: [AgentType: AgentChoiceCard] = [:]

    private var backend: AgentType = .openCode
    private var tailnetAddress: String?
    private var verification: Verification = .idle
    private var authTarget: URL?
    private let generatedPassword = BridgeInstall.makePassword()
    private var probeTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var tailnetTicker: Task<Void, Never>?
    private var didRenderTailnet = false

    init(mode: Mode) {
        self.mode = mode
        tailnetCard = SetupStepCard(
            index: 1, total: 3, title: String(localized: "Tailscale on this iPhone"),
            detail: String(
                localized:
                    "Install Tailscale here and on the computer that will run the agent, then sign both into the same account. Free for personal use."
            ))
        agentCard = SetupStepCard(
            index: 2, total: 3, title: String(localized: "Run an agent on that computer"),
            detail: String(localized: "Type this on the computer, not on this phone."))
        connectCard = SetupStepCard(
            index: 3, total: 3, title: String(localized: "Connect this iPhone"),
            detail: String(
                localized:
                    "Enter that machine's tailnet address. Run tailscale ip -4 on it, or read it off the machine list in the Tailscale app."
            ))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .firstRun ? String(localized: "Set up") : String(localized: "Add a server")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"), menu: helpMenu())
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: ["public.url", "public.plain-text", "public.text"])
        buildUI()
        selectBackend(.openCode, animated: false)
        refreshTailnet()
        applyVerification()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        AppLogger.lifecycle.info("server setup shown (\(mode == .firstRun ? "first run" : "add server"))")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTailnetTicker()
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            switch environment["TAILSCODE_SETUP_AGENT"] {
            case "claude": selectBackend(.claudeCode, animated: false)
            case "omp": selectBackend(.omp, animated: false)
            default: break
            }
            if let password = environment["TAILSCODE_SETUP_PASSWORD"] {
                showPasswordField(focus: false)
                passwordField.setText(password)
            }
            if let seeded = environment["TAILSCODE_SETUP_ADDRESS"], addressField.text.isEmpty {
                prefill(address: seeded)
            }
        #endif
        if startOnConnectStep {
            startOnConnectStep = false
            revealConnectStep()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tailnetTicker?.cancel()
        tailnetTicker = nil
    }

    /// The system paste button hands over exactly what the user chose to give,
    /// with no pasteboard sniffing and no "pasted from" banner.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in self?.apply(pasted: text) }
        }
    }

    /// A paste is whatever was on the clipboard: an address, a URL, or the whole
    /// `BRIDGE_PASSWORD=… claude-bridge` line off the other machine's terminal.
    /// The line carries the password too, so take it.
    private func apply(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let password = BridgeInstall.password(in: trimmed) {
            showPasswordField(focus: false)
            passwordField.setText(password)
            passwordNote.text = String(localized: "Password taken from what you pasted.")
            passwordNote.isHidden = false
        }
        let reading = HostAddress.read(trimmed, defaultPort: HostAddress.port(for: backend))
        if case .address(let address) = reading, trimmed.contains(where: { $0.isWhitespace }) {
            addressField.setText(address.url.absoluteString)
        } else {
            addressField.setText(trimmed)
        }
        Theme.Haptics.tap()
        addressChanged()
    }

    func prefill(address: String) {
        addressField.setText(address)
        addressChanged()
        startOnConnectStep = true
    }


    private func buildUI() {
        buildTailnetStep()
        buildAgentStep()
        buildConnectStep()

        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        [tailnetCard, agentCard, connectCard].forEach(column.addArrangedSubview)
        column.translatesAutoresizingMaskIntoConstraints = false

        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(box)
        view.addSubview(scroll)

        footer.primary.addAction(UIAction { [weak self] _ in self?.footerTapped() }, for: .touchUpInside)
        if mode == .firstRun {
            footer.setSecondary(title: String(localized: "Try the demo instead")) { [weak self] in
                Theme.Haptics.tap()
                self?.onTryDemo?()
            }
        }
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

    private func buildTailnetStep() {
        var openConfig = Theme.Glass.buttonConfiguration()
        openConfig.title = String(localized: "Open Tailscale")
        openConfig.image = UIImage(
            systemName: "arrow.up.forward.app",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        openConfig.imagePadding = Theme.Spacing.xs
        openConfig.baseForegroundColor = Theme.Color.label
        openConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        openTailscaleButton.configuration = openConfig
        openTailscaleButton.addAction(
            UIAction { _ in
                Theme.Haptics.tap()
                TailnetStatus.openTailscaleApp()
            }, for: .touchUpInside)

        configureLink(tailscaleLink, title: String(localized: "What is Tailscale?"))
        tailscaleLink.addAction(
            UIAction { [weak self] _ in self?.open("https://tailscale.com/download") },
            for: .touchUpInside)

        tailnetCard.content.addArrangedSubview(AdaptiveRow([openTailscaleButton, tailscaleLink]))
    }

    private func buildAgentStep() {
        let opencodeChoice = AgentChoiceCard(
            backend: .openCode, title: String(localized: "opencode"),
            detail: String(localized: "Any provider you have configured. One command, no build."))
        let claudeChoice = AgentChoiceCard(
            backend: .claudeCode, title: String(localized: "Claude Code"),
            detail: String(localized: "Your own Claude subscription, through claude-bridge."))
        let ompChoice = AgentChoiceCard(
            backend: .omp, title: String(localized: "Oh My Pi"),
            detail: String(localized: "Your own oh-my-pi agent, through omp-bridge."))
        choiceCards = [.openCode: opencodeChoice, .claudeCode: claudeChoice, .omp: ompChoice]
        for (type, card) in choiceCards {
            card.addAction(
                UIAction { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.selectBackend(type, animated: true)
                }, for: .touchUpInside)
        }
        let choices = UIStackView(arrangedSubviews: [opencodeChoice, claudeChoice, ompChoice])
        choices.axis = .vertical
        choices.spacing = Theme.Spacing.s

        commandHost.axis = .vertical
        commandHost.spacing = Theme.Spacing.s

        configureLink(agentLink, title: String(localized: "Install opencode"))
        agentLink.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.open(self.agentLinkURL(for: self.backend))
            }, for: .touchUpInside)

        agentCard.content.addArrangedSubview(choices)
        agentCard.content.addArrangedSubview(commandHost)
        agentCard.content.addArrangedSubview(agentLink)
    }

    private func agentLinkURL(for backend: AgentType) -> String {
        switch backend {
        case .openCode: return "https://opencode.ai"
        case .claudeCode: return "https://github.com/guitaripod/claude-bridge"
        case .omp: return "https://github.com/guitaripod/omp-bridge"
        }
    }

    private func buildConnectStep() {
        addressField.textField.addAction(
            UIAction { [weak self] _ in self?.addressChanged() }, for: .editingChanged)
        addressField.onSubmit = { [weak self] in self?.footerTapped() }

        let pasteConfig = UIPasteControl.Configuration()
        pasteConfig.displayMode = .iconAndLabel
        pasteConfig.cornerStyle = .capsule
        pasteConfig.baseBackgroundColor = Theme.Color.groupedBackground
        let paste = UIPasteControl(configuration: pasteConfig)
        paste.target = self
        paste.translatesAutoresizingMaskIntoConstraints = false

        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paste.setContentHuggingPriority(.required, for: .horizontal)
        paste.setContentCompressionResistancePriority(.required, for: .horizontal)
        let addressRow = AdaptiveRow([addressField, paste], alignment: .bottom)
        addressRow.distribution = .fill

        addressHint.font = Theme.Font.scaledMono(.caption1)
        addressHint.adjustsFontForContentSizeCategory = true
        addressHint.textColor = Theme.Color.tertiaryLabel
        addressHint.numberOfLines = 0

        checkingLabel.font = Theme.Ramp.font(.panelDetail)
        checkingLabel.adjustsFontForContentSizeCategory = true
        checkingLabel.textColor = Theme.Color.secondaryLabel
        checkingLabel.numberOfLines = 0
        checkingRow.axis = .horizontal
        checkingRow.spacing = Theme.Spacing.s
        checkingRow.alignment = .center
        checkingRow.addArrangedSubview(checkingSpinner)
        checkingRow.addArrangedSubview(checkingLabel)
        checkingRow.isHidden = true

        configureLink(passwordDisclosure, title: String(localized: "The server needs a password"))
        passwordDisclosure.addAction(
            UIAction { [weak self] _ in self?.showPasswordField(focus: true) }, for: .touchUpInside)

        passwordField.isHidden = true
        passwordField.textField.addAction(
            UIAction { [weak self] _ in self?.passwordChanged() }, for: .editingChanged)
        passwordField.onSubmit = { [weak self] in self?.footerTapped() }

        passwordNote.font = Theme.Ramp.font(.panelFootnote)
        passwordNote.adjustsFontForContentSizeCategory = true
        passwordNote.textColor = Theme.Color.tertiaryLabel
        passwordNote.numberOfLines = 0
        passwordNote.isHidden = true

        diagnosisCard.onAction = { [weak self] in self?.diagnosisActionTapped() }

        let scanRow = UIStackView()
        scanRow.axis = .vertical
        scanRow.spacing = 2
        let scanButton = UIButton(type: .system)
        configureLink(scanButton, title: String(localized: "Scan my tailnet instead"))
        scanButton.addAction(UIAction { [weak self] _ in self?.scanTapped() }, for: .touchUpInside)
        let scanCaption = UILabel()
        scanCaption.text = String(
            localized: "Optional. Needs a Tailscale API token with Devices read access.")
        scanCaption.font = Theme.Ramp.font(.panelFootnote)
        scanCaption.adjustsFontForContentSizeCategory = true
        scanCaption.textColor = Theme.Color.tertiaryLabel
        scanCaption.numberOfLines = 0
        scanRow.addArrangedSubview(scanButton)
        scanRow.addArrangedSubview(scanCaption)

        let separator = UIView()
        separator.backgroundColor = Theme.Color.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        [addressRow, addressHint, checkingRow, diagnosisCard, passwordDisclosure, passwordField,
            passwordNote, separator, scanRow,
        ].forEach(connectCard.content.addArrangedSubview)
        connectCard.content.setCustomSpacing(Theme.Spacing.xs, after: addressRow)
        connectCard.content.setCustomSpacing(Theme.Spacing.l, after: separator)
    }

    private func configureLink(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(
            systemName: "arrow.up.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = Theme.Spacing.xs
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.panelDetail)
            return out
        }
        button.configuration = config
        button.contentHorizontalAlignment = .leading
    }

    private func helpMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: String(localized: "View logs"), image: UIImage(systemName: "doc.text.magnifyingglass")
            ) { [weak self] _ in
                self?.navigationController?.pushViewController(LogViewerViewController(), animated: true)
            },
            UIAction(
                title: String(localized: "Copy diagnostics"), image: UIImage(systemName: "stethoscope")
            ) { [weak self] _ in
                Task { @MainActor in
                    UIPasteboard.general.string = await DiagnosticsReport.build()
                    Theme.Haptics.success()
                    guard let self else { return }
                    ToastView(message: String(localized: "Diagnostics copied"))
                        .flash(in: self.view, above: self.footer.topAnchor)
                }
            },
        ])
    }


    private func selectBackend(_ backend: AgentType, animated: Bool) {
        self.backend = backend
        for (type, card) in choiceCards { card.isSelected = type == backend }
        agentLink.configuration?.title = agentLinkTitle(for: backend)
        rebuildCommand(animated: animated)
        agentCard.setDetail(agentDetail(for: backend))
        switch backend {
        case .openCode:
            if passwordField.text.isEmpty, authTarget == nil {
                passwordField.isHidden = true
                passwordDisclosure.isHidden = false
                passwordNote.isHidden = true
            }
        case .claudeCode:
            showPasswordField(focus: false)
            passwordNote.text = String(
                localized: "claude-bridge always needs a password — the one in the command above.")
            passwordNote.isHidden = false
        case .omp:
            showPasswordField(focus: false)
            passwordNote.text = String(
                localized: "omp-bridge always needs a password — the one in the command above.")
            passwordNote.isHidden = false
        }
        if !addressField.text.isEmpty { addressChanged() }
        guard animated else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: agentCard)
    }

    private func agentLinkTitle(for backend: AgentType) -> String {
        switch backend {
        case .openCode: return String(localized: "Install opencode")
        case .claudeCode: return String(localized: "claude-bridge on GitHub")
        case .omp: return String(localized: "omp-bridge on GitHub")
        }
    }

    private func agentDetail(for backend: AgentType) -> String {
        switch backend {
        case .openCode:
            return String(localized: "Type this on the computer, not on this phone.")
        case .claudeCode:
            return String(
                localized:
                    "Type this on the computer, not on this phone. It builds from source (git and a Swift toolchain, a few minutes the first time) and installs a service that survives reboots."
            )
        case .omp:
            return String(
                localized:
                    "Type this on the computer, not on this phone. omp-bridge serves your oh-my-pi agent on port 4099 and installs a service that survives reboots."
            )
        }
    }

    private func rebuildCommand(animated: Bool) {
        let block = CommandBlockView(command: command(for: backend))
        block.onShare = { [weak self] text, source in self?.share(text, from: source) }
        block.onCopy = { [weak self] in self?.adoptGeneratedPasswordIfNeeded() }
        let apply = { [weak self] in
            guard let self else { return }
            self.commandHost.arrangedSubviews.forEach {
                self.commandHost.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            self.commandHost.addArrangedSubview(block)
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: commandHost, duration: 0.22, options: .transitionCrossDissolve, animations: apply)
    }

    private func command(for backend: AgentType) -> String {
        BridgeInstall.command(for: backend, password: generatedPassword)
    }

    /// A password only works if both sides carry the same one, so the app mints it,
    /// puts it in the command the user is about to run, and fills its own field
    /// the moment they take the command away.
    private func share(_ text: String, from source: UIView) {
        adoptGeneratedPasswordIfNeeded()
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source
        activity.popoverPresentationController?.sourceRect = source.bounds
        present(activity, animated: true)
    }

    private func adoptGeneratedPasswordIfNeeded() {
        guard passwordField.text.isEmpty else { return }
        showPasswordField(focus: false)
        passwordField.setText(generatedPassword)
        passwordNote.text = String(
            localized: "Filled in below, so this phone and the server carry the same password.")
        passwordNote.isHidden = false
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
    /// afford to keep asking — which is what makes it advance itself while the
    /// user is off in the Tailscale app.
    private func refreshTailnet() {
        let address = TailnetStatus.localAddress()
        guard address != tailnetAddress || !didRenderTailnet else { return }
        let cameUp = didRenderTailnet && tailnetAddress == nil && address != nil
        didRenderTailnet = true
        tailnetAddress = address
        if let address {
            tailnetCard.setStatus(.done)
            tailnetCard.setPill(address, symbol: "checkmark.circle.fill", tint: Theme.Color.success)
            tailnetCard.setDetail(
                String(
                    localized:
                        "This iPhone is on your tailnet. The computer that runs the agent has to be signed into the same account."
                ))
            openTailscaleButton.isHidden = true
            tailscaleLink.isHidden = true
        } else {
            tailnetCard.setStatus(.active)
            tailnetCard.setPill(
                String(localized: "Not connected"), symbol: "exclamationmark.circle.fill",
                tint: Theme.Color.warning)
            openTailscaleButton.isHidden = false
            tailscaleLink.isHidden = false
        }
        if cameUp {
            Theme.Haptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "This iPhone is on your tailnet."))
            if case .failed = verification { probeNow(userInitiated: false) }
        }
        applyVerification()
    }


    private func addressChanged() {
        authTarget = nil
        probeTask?.cancel()
        verification = .idle
        let reading = HostAddress.read(addressField.text, defaultPort: HostAddress.port(for: backend))
        switch reading {
        case .empty:
            addressHint.text = nil
        case .address(let address):
            addressHint.textColor = Theme.Color.tertiaryLabel
            addressHint.text = address.portWasInferred
                ? "→ \(address.url.absoluteString)  " + String(localized: "(port added)")
                : "→ \(address.url.absoluteString)"
            scheduleProbe()
        case .bindAll:
            addressHint.textColor = Theme.Color.warning
            addressHint.text = String(
                localized: "0.0.0.0 is what the server binds to. Use that machine's own address.")
        case .unsupportedScheme(let scheme):
            addressHint.textColor = Theme.Color.warning
            addressHint.text = String(localized: "\(scheme):// isn't supported — use http.")
        case .invalid:
            addressHint.textColor = Theme.Color.tertiaryLabel
            addressHint.text = String(localized: "An address like 100.101.102.103 or studio:4098.")
        }
        applyVerification()
    }

    /// A password edit keeps whatever answered — re-guessing ports after a
    /// rejected password would just lose the server that is already talking.
    private func passwordChanged() {
        diagnosisCard.hide()
        guard case .address = HostAddress.read(
            addressField.text, defaultPort: HostAddress.port(for: backend))
        else { return }
        setVerification(.idle)
        scheduleProbe()
    }

    private func scheduleProbe() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.probeNow(userInitiated: false)
        }
    }

    private func probeNow(userInitiated: Bool) {
        guard case .address(let address) = HostAddress.read(
            addressField.text, defaultPort: HostAddress.port(for: backend))
        else { return }
        probeTask?.cancel()
        debounceTask?.cancel()
        setVerification(.checking)
        let password = passwordField.text.isEmpty ? nil : passwordField.text
        let candidates = authTarget.map { [$0] } ?? address.probeCandidates()
        let preferred = backend
        let policy = userInitiated ? ProbeSweep.interactivePolicy : ProbeSweep.typingPolicy
        probeTask = Task { @MainActor [weak self] in
            var best: (url: URL, outcome: ConnectionProbe.Outcome)?
            for candidate in candidates {
                let outcome = await ProbeSweep.probe(
                    baseURL: candidate, password: password, preferring: preferred,
                    policy: policy, retryUnreachable: userInitiated)
                guard !Task.isCancelled else { return }
                if Self.rank(outcome) > Self.rank(best?.outcome) { best = (candidate, outcome) }
                if case .ok = outcome { break }
                if case .authFailed = outcome { break }
            }
            guard let best else { return }
            var reachability: PortReachability.Verdict?
            if case .unreachable = best.outcome, let host = best.url.host, let port = best.url.port,
                let narrow = UInt16(exactly: port)
            {
                reachability = await PortReachability.check(host: host, port: narrow)
            }
            guard let self, !Task.isCancelled else { return }
            self.consume(
                outcome: best.outcome, url: best.url, address: address, reachability: reachability)
        }
    }

    private static func rank(_ outcome: ConnectionProbe.Outcome?) -> Int {
        switch outcome {
        case .none: return -1
        case .unreachable: return 0
        case .notAnAgentServer: return 1
        case .authFailed: return 2
        case .ok: return 3
        }
    }

    private func consume(
        outcome: ConnectionProbe.Outcome, url: URL, address: HostAddress,
        reachability: PortReachability.Verdict?
    ) {
        switch outcome {
        case .ok(let agent, let version):
            AppLogger.connection.info("setup verified \(agent.displayName) at \(url.absoluteString)")
            setVerification(.verified(agent: agent, version: version, url: url))
            Theme.Haptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "\(agent.displayName) answered. Ready to connect."))
            #if DEBUG
                if ProcessInfo.processInfo.environment["TAILSCODE_SETUP_CONNECT"] != nil {
                    footerTapped()
                }
            #endif
        case .authFailed:
            authTarget = url
            showPasswordField(focus: passwordField.text.isEmpty)
            fail(outcome: outcome, url: url, address: address, reachability: reachability)
        default:
            fail(outcome: outcome, url: url, address: address, reachability: reachability)
        }
    }

    private func fail(
        outcome: ConnectionProbe.Outcome, url: URL, address: HostAddress,
        reachability: PortReachability.Verdict?
    ) {
        let alternate = address.probeCandidates().first { $0 != url }
        guard
            let diagnosis = ConnectDiagnosis.make(
                outcome: outcome, address: address, tailnetAddress: tailnetAddress,
                alternatePort: alternate, sentPassword: !passwordField.text.isEmpty,
                reachability: reachability, deviceName: String(localized: "This iPhone"),
                offersLocalNetworkSettings: true)
        else { return }
        setVerification(.failed(diagnosis))
    }

    private func setVerification(_ next: Verification) {
        guard next != verification else { return }
        verification = next
        applyVerification()
    }

    private func applyVerification() {
        switch verification {
        case .idle:
            checkingRow.isHidden = true
            checkingSpinner.working(false)
            diagnosisCard.hide()
            connectCard.setPill(nil)
        case .checking:
            checkingSpinner.working(true)
            checkingLabel.text = String(localized: "Looking for an agent…")
            checkingRow.isHidden = false
            diagnosisCard.hide()
            connectCard.setPill(nil)
        case .verified(let agent, let version, _):
            checkingRow.isHidden = true
            checkingSpinner.working(false)
            diagnosisCard.hide()
            agentCard.setPill(
                String(localized: "Answering"), symbol: "checkmark.circle.fill", tint: Theme.Color.success)
            connectCard.setPill(
                version.map { "\(agent.displayName) \($0)" } ?? agent.displayName,
                symbol: "checkmark.circle.fill", tint: Theme.Color.success)
        case .failed(let diagnosis):
            checkingRow.isHidden = true
            checkingSpinner.working(false)
            diagnosisCard.show(
                diagnosis,
                tint: diagnosis.fix == .revealPassword ? Theme.Color.warning : Theme.Color.danger)
            connectCard.setPill(nil)
            scrollIntoView(diagnosisCard)
        }
        applySteps()
        applyFooter()
    }

    /// One step is current at a time, and the tailnet gate outranks the others:
    /// with the VPN down, nothing further can be true, so nothing further claims
    /// to be in progress.
    private func applySteps() {
        if case .verified = verification {
            agentCard.setStatus(.done)
            connectCard.setStatus(.done)
            return
        }
        guard tailnetAddress != nil else {
            agentCard.setStatus(.pending)
            connectCard.setStatus(.pending)
            agentCard.setPill(nil)
            return
        }
        agentCard.setStatus(.active)
        connectCard.setStatus(addressField.text.isEmpty ? .pending : .active)
    }

    private func applyFooter() {
        switch verification {
        case .checking:
            footer.primary.setTitle(String(localized: "Checking…"))
            footer.primary.setLoading(true)
        case .verified(_, _, let url):
            footer.primary.setLoading(false)
            footer.primary.isEnabled = true
            footer.primary.setTitle(String(localized: "Connect to \(url.host ?? "server")"))
        case .idle, .failed:
            footer.primary.setLoading(false)
            if tailnetAddress == nil, addressField.text.isEmpty {
                footer.primary.isEnabled = true
                footer.primary.setTitle(String(localized: "Open Tailscale"))
                return
            }
            let reading = HostAddress.read(addressField.text, defaultPort: HostAddress.port(for: backend))
            if case .address = reading {
                footer.primary.isEnabled = true
            } else {
                footer.primary.isEnabled = false
            }
            footer.primary.setTitle(String(localized: "Connect"))
        }
    }

    private func showPasswordField(focus: Bool) {
        passwordDisclosure.isHidden = true
        guard passwordField.isHidden else {
            if focus { passwordField.textField.becomeFirstResponder() }
            return
        }
        passwordField.isHidden = false
        if focus { passwordField.textField.becomeFirstResponder() }
        UIAccessibility.post(notification: .layoutChanged, argument: passwordField.textField)
    }

    /// A diagnosis the keyboard is covering is the same as no diagnosis, which is
    /// what the old status label at the foot of the scroll amounted to.
    private func scrollIntoView(_ target: UIView) {
        view.layoutIfNeeded()
        let frame = target.convert(target.bounds, to: scroll)
        scroll.scrollRectToVisible(frame.insetBy(dx: 0, dy: -Theme.Spacing.m), animated: true)
    }

    private func revealConnectStep() {
        view.layoutIfNeeded()
        let target = connectCard.convert(connectCard.bounds, to: scroll)
        scroll.setContentOffset(
            CGPoint(x: 0, y: max(0, min(target.minY - Theme.Spacing.l, scroll.contentSize.height - scroll.bounds.height))),
            animated: true)
        addressField.textField.becomeFirstResponder()
    }


    private func footerTapped() {
        view.endEditing(true)
        switch verification {
        case .verified(let agent, _, let url):
            connect(agent: agent, url: url)
        case .checking:
            return
        case .idle, .failed:
            if tailnetAddress == nil, addressField.text.isEmpty {
                Theme.Haptics.tap()
                TailnetStatus.openTailscaleApp()
                return
            }
            Theme.Haptics.tap()
            probeNow(userInitiated: true)
        }
    }

    private func diagnosisActionTapped() {
        guard case .failed(let diagnosis) = verification else { return }
        Theme.Haptics.tap()
        switch diagnosis.fix {
        case .openTailscale:
            TailnetStatus.openTailscaleApp()
        case .openAppSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .retry:
            probeNow(userInitiated: true)
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            addressField.setText(url.absoluteString)
            addressChanged()
            probeNow(userInitiated: true)
        case .revealPassword:
            showPasswordField(focus: true)
        case .copyCommand(let command):
            copy(command)
        case .seePro:
            ProUpgradeViewController.present(from: self)
        case .none:
            break
        }
    }

    /// A fix that lives on the other machine is handed over as a line to run there rather than as
    /// an instruction to go and read something, so the clipboard is the whole of the action and the
    /// command itself is the confirmation.
    private func copy(_ command: String) {
        UIPasteboard.general.string = command
        Theme.Haptics.success()
        ToastView(message: command).flash(in: view, above: footer.topAnchor, duration: 3)
    }

    private func connect(agent: AgentType, url: URL) {
        let password = passwordField.text.isEmpty ? nil : passwordField.text
        let name = Self.name(for: url)
        let profile = ConnectionProfile(id: UUID().uuidString, name: name, backend: agent, baseURL: url)
        do {
            try ConnectionController.shared.save(profile, password: password)
            AppLogger.connection.info("connected to \(agent.displayName) as \(name)")
            Theme.Haptics.success()
            celebrate { [weak self] in self?.onConnected?() }
        } catch is ConnectionController.ProRequired {
            Theme.Haptics.warning()
            setVerification(
                .failed(
                    ConnectDiagnosis(
                        symbol: "star.circle",
                        title: String(localized: "A second server needs Pro"),
                        detail: String(
                            localized:
                                "Tailscode Pro is a one-time purchase that lifts the one-server limit. Your first server keeps working either way."
                        ),
                        fix: .seePro, actionTitle: String(localized: "See Pro"))))
        } catch {
            Theme.Haptics.error()
            setVerification(
                .failed(
                    ConnectDiagnosis(
                        symbol: "exclamationmark.triangle",
                        title: String(localized: "Couldn't save that server"),
                        detail: error.localizedDescription, fix: .none, actionTitle: nil)))
        }
    }

    /// A held beat on the checkmark before the root swaps, so the payoff of the
    /// whole flow is a confirmation rather than a flash.
    private func celebrate(_ completion: @escaping () -> Void) {
        footer.primary.setTitle(String(localized: "Connected"))
        footer.primary.isEnabled = false
        connectCard.setStatus(.done)
        guard !UIAccessibility.isReduceMotionEnabled else {
            completion()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            completion()
        }
    }

    private static func name(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return String(localized: "Server") }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        if Int(label) != nil { return host }
        return label
    }

    private func scanTapped() {
        Theme.Haptics.tap()
        let discovery = DiscoveryViewController()
        discovery.onConnected = onConnected
        present(UINavigationController(rootViewController: discovery), animated: true)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Theme.Haptics.tap()
        present(SFSafariViewController(url: url), animated: true)
    }
}
