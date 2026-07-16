import CodingAgentKit
import CodingAgentKitApple
import Foundation
import UIKit

@MainActor
final class OnboardingViewController: UIViewController {
    var onConnected: (() -> Void)?

    private let discoverButton = PrimaryButton(title: "Discover servers on tailnet")
    private let orLabel = UILabel()
    private let backendControl = UISegmentedControl(items: ["opencode", "Claude Code"])
    private let nameField = FormField(title: "Name", placeholder: "My server")
    private let hostField = FormField(title: "Host URL", placeholder: "http://100.x.y.z:4096", keyboard: .URL)
    private let passwordField = FormField(
        title: "Password (optional)", placeholder: "Leave blank on a private tailnet", secure: true)
    private let connectButton = PrimaryButton(title: "Test & Connect")
    private let statusLabel = UILabel()
    private let demoButton = UIButton(type: .system)

    private var backend: AgentType { backendControl.selectedSegmentIndex == 0 ? .openCode : .claudeCode }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect"
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
        backendControl.selectedSegmentIndex = 0
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        discoverButton.addTarget(self, action: #selector(discoverTapped), for: .touchUpInside)
        demoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)
        backendChanged()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_GUIDE"] != nil {
                DispatchQueue.main.async { [weak self] in self?.guideTapped() }
            }
        #endif
    }

    private func buildUI() {
        let header = UILabel()
        header.text = "Discover servers on your tailnet or enter the address manually."
        header.font = Theme.Font.subheadline()
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        let guideButton = UIButton(type: .system)
        var guideConfig = UIButton.Configuration.tinted()
        guideConfig.title = "Set up a server"
        guideConfig.subtitle = "New here? Three steps, about five minutes"
        guideConfig.image = UIImage(
            systemName: "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        guideConfig.imagePadding = Theme.Spacing.m
        guideConfig.baseBackgroundColor = Theme.Color.accent
        guideConfig.baseForegroundColor = Theme.Color.accent
        guideConfig.cornerStyle = .large
        guideConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        guideConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Font.headline()
            return out
        }
        guideButton.configuration = guideConfig
        guideButton.contentHorizontalAlignment = .leading
        guideButton.addTarget(self, action: #selector(guideTapped), for: .touchUpInside)

        statusLabel.font = Theme.Font.caption()
        statusLabel.numberOfLines = 0
        statusLabel.textColor = Theme.Color.secondaryLabel

        var demoConfig = UIButton.Configuration.plain()
        demoConfig.title = "No server yet? Try the demo"
        demoConfig.image = UIImage(systemName: "play.circle")
        demoConfig.imagePadding = 6
        demoConfig.baseForegroundColor = Theme.Color.accent
        demoButton.configuration = demoConfig

        orLabel.text = "or"
        orLabel.font = Theme.Font.caption()
        orLabel.textColor = Theme.Color.secondaryLabel
        orLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [
            header, guideButton, discoverButton, orLabel, backendControl, nameField, hostField, passwordField, connectButton, demoButton, statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.setCustomSpacing(Theme.Spacing.m, after: header)
        stack.setCustomSpacing(Theme.Spacing.xl, after: guideButton)
        stack.setCustomSpacing(Theme.Spacing.s, after: discoverButton)
        stack.setCustomSpacing(Theme.Spacing.s, after: connectButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    @objc private func backendChanged() {
        let isOpenCode = backend == .openCode
        hostField.textField.placeholder =
            isOpenCode ? "http://100.x.y.z:4096" : "http://100.x.y.z:4098"
    }

    @objc private func connectTapped() {
        view.endEditing(true)
        Task { await attemptConnect() }
    }

    @objc private func guideTapped() {
        Theme.Haptics.tap()
        let guide = SetupGuideViewController()
        guide.onReadyToConnect = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
            self?.hostField.textField.becomeFirstResponder()
        }
        guide.onTryDemo = { [weak self] in
            ConnectionController.shared.enterDemoMode()
            Theme.Haptics.success()
            self?.onConnected?()
        }
        navigationController?.pushViewController(guide, animated: true)
    }

    @objc private func discoverTapped() {
        let discovery = DiscoveryViewController()
        discovery.onConnected = onConnected
        present(UINavigationController(rootViewController: discovery), animated: true)
    }

    @objc private func demoTapped() {
        ConnectionController.shared.enterDemoMode()
        Theme.Haptics.success()
        onConnected?()
    }

    private func attemptConnect() async {
        let host = hostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let url = URL(string: host), url.scheme != nil, url.host != nil else {
            showStatus("Enter a valid URL like http://100.x.y.z:4096", ok: false)
            return
        }
        let password = passwordField.text.isEmpty ? nil : passwordField.text

        connectButton.setLoading(true)
        showStatus("Testing connection…", ok: true)
        let outcome = await AgentProbe.probe(baseURL: url, password: password, preferring: backend)
        connectButton.setLoading(false)

        switch outcome {
        case .ok(let detected, let version):
            let name = nameField.text.isEmpty ? (url.host ?? "Server") : nameField.text
            let profile = ConnectionProfile(
                id: UUID().uuidString, name: name, backend: detected, baseURL: url)
            do {
                try ConnectionController.shared.save(profile, password: password)
                AppLogger.connection.info("connected to \(detected.displayName) \(version ?? "")")
                Theme.Haptics.success()
                onConnected?()
            } catch {
                showStatus("Couldn't save profile: \(error.localizedDescription)", ok: false)
            }
        case .authFailed:
            showStatus("Authentication failed — check the password.", ok: false)
            Theme.Haptics.error()
        case .unreachable(let detail):
            showStatus("Unreachable: \(detail)", ok: false)
            Theme.Haptics.error()
        case .notAnAgentServer:
            showStatus("Reachable, but not an opencode or claude-bridge server.", ok: false)
            Theme.Haptics.error()
        }
    }

    private func showStatus(_ text: String, ok: Bool) {
        statusLabel.text = text
        statusLabel.textColor = ok ? Theme.Color.secondaryLabel : Theme.Color.danger
    }
}
