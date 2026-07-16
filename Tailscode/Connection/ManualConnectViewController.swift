import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ManualConnectViewController: UIViewController {
    var onConnected: (() -> Void)?

    private let device: TailscaleDevice

    private let backendControl = UISegmentedControl(items: ["opencode", "Claude Code"])
    private let nameField = FormField(title: "Name", placeholder: "My server")
    private let hostField = FormField(title: "Host URL", placeholder: "http://100.x.y.z:4096", keyboard: .URL)
    private let passwordField = FormField(title: "Password (optional)", placeholder: "Leave blank on a private tailnet", secure: true)
    private let connectButton = PrimaryButton(title: "Test & Connect")
    private let statusLabel = UILabel()

    private var backend: AgentType { backendControl.selectedSegmentIndex == 0 ? .openCode : .claudeCode }
    private var lastPrefilledHost = ""

    /// Prefers the stable 100.x tailnet IP: the bare hostname only resolves
    /// with MagicDNS search domains enabled, the IP always works.
    private var preferredHost: String {
        device.addresses.first { $0.contains(".") } ?? device.hostname
    }

    init(device: TailscaleDevice) {
        self.device = device
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect to \(device.hostname)"
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
        backendControl.selectedSegmentIndex = 0
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        prefill()
        backendChanged()
    }

    private func prefill() {
        nameField.setText(device.hostname)
        lastPrefilledHost = "http://\(preferredHost):4096"
        hostField.setText(lastPrefilledHost)
    }

    private func buildUI() {
        let infoText = "\(device.hostname)"
            + (device.os.map { " · \($0)" } ?? "")
            + (device.user.map { " · \($0)" } ?? "")
        let header = UILabel()
        header.text = infoText
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

    /// Only rewrites the host field if the user hasn't edited it, so
    /// switching backends can't discard a hand-typed URL.
    @objc private func backendChanged() {
        let port = backend == .openCode ? 4096 : 4098
        let next = "http://\(preferredHost):\(port)"
        if hostField.text.isEmpty || hostField.text == lastPrefilledHost {
            hostField.setText(next)
        }
        lastPrefilledHost = next
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

        connectButton.setLoading(true)
        showStatus("Testing connection…", ok: true)
        let outcome = await AgentProbe.probe(baseURL: url, password: password, preferring: backend)
        connectButton.setLoading(false)

        switch outcome {
        case .ok(let detected, let version):
            let name = nameField.text.isEmpty ? (url.host ?? "Server") : nameField.text
            let profile = ConnectionProfile(id: UUID().uuidString, name: name, backend: detected, baseURL: url)
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
