import CodingAgentKit
import CodingAgentKitApple
import Foundation
import UIKit

@MainActor
final class OnboardingViewController: UIViewController {
    var onConnected: (() -> Void)?

    private let backendControl = UISegmentedControl(items: ["opencode", "Claude Code"])
    private let nameField = FormField(title: "Name", placeholder: "My server")
    private let hostField = FormField(title: "Host URL", placeholder: "http://100.x.y.z:4096", keyboard: .URL)
    private let passwordField = FormField(
        title: "Password (optional)", placeholder: "Leave blank on a private tailnet", secure: true)
    private let connectButton = PrimaryButton(title: "Test & Connect")
    private let statusLabel = UILabel()

    private var backend: AgentType { backendControl.selectedSegmentIndex == 0 ? .openCode : .claudeCode }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect"
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
        backendControl.selectedSegmentIndex = 0
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        backendChanged()
    }

    private func buildUI() {
        let header = UILabel()
        header.text = "Point Tailscode at your coding agent over Tailscale."
        header.font = Theme.Font.subheadline()
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        statusLabel.font = Theme.Font.caption()
        statusLabel.numberOfLines = 0
        statusLabel.textColor = Theme.Color.secondaryLabel

        let stack = UIStackView(arrangedSubviews: [
            header, backendControl, nameField, hostField, passwordField, connectButton, statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.setCustomSpacing(Theme.Spacing.xl, after: header)
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

    private func attemptConnect() async {
        let host = hostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let url = URL(string: host), url.scheme != nil, url.host != nil else {
            showStatus("Enter a valid URL like http://100.x.y.z:4096", ok: false)
            return
        }
        let password = passwordField.text.isEmpty ? nil : passwordField.text
        let username = backend == .openCode ? "opencode" : "claude"
        let credentials = password.map { BasicCredentials(username: username, password: $0) }

        connectButton.setLoading(true)
        showStatus("Testing connection…", ok: true)
        let outcome = await ConnectionProbe().probe(baseURL: url, credentials: credentials)
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
        case .unreachable:
            showStatus("Unreachable. Is the server running and on your tailnet?", ok: false)
            Theme.Haptics.error()
        case .notAnAgentServer:
            showStatus("Reachable, but not an opencode or agentapi server.", ok: false)
            Theme.Haptics.error()
        }
    }

    private func showStatus(_ text: String, ok: Bool) {
        statusLabel.text = text
        statusLabel.textColor = ok ? Theme.Color.secondaryLabel : Theme.Color.danger
    }
}
