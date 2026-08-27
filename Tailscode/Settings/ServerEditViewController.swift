import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// Edits a saved server in place — name, address, password. Rotating a bridge
/// password used to mean removing the connection and adding it back, which threw
/// away the profile id every cached model choice and recent directory is keyed
/// by, and forced a fresh push registration.
@MainActor
final class ServerEditViewController: UIViewController {
    var onSaved: ((ConnectionProfile) -> Void)?

    private let profile: ConnectionProfile
    private let nameField = FormField(title: String(localized: "Name"), placeholder: "homelab")
    private let hostField = FormField(
        title: String(localized: "Host URL"), placeholder: "http://100.x.y.z:4096",
        keyboard: .URL)
    private let passwordField = FormField(
        title: String(localized: "Password"),
        placeholder: String(localized: "Leave blank for none"), secure: true)
    private let saveButton = PrimaryButton(title: String(localized: "Save"))
    private let statusLabel = UILabel()
    private var verifyTask: Task<Void, Never>?

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Edit Server")
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
    }

    private func buildUI() {
        nameField.setText(profile.name)
        hostField.setText(profile.baseURL.absoluteString)
        passwordField.setText(ConnectionController.shared.password(for: profile.id) ?? "")

        let header = UILabel()
        header.text = String(
            localized:
                "The address is verified before it is saved, so a typo fails here rather than as errors in every chat."
        )
        header.font = Theme.Ramp.font(.panelLabel)
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        statusLabel.font = Theme.Ramp.font(.panelFootnote)
        statusLabel.textColor = Theme.Color.secondaryLabel
        statusLabel.numberOfLines = 0

        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            header, nameField, hostField, passwordField, saveButton, statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    private func save() {
        guard verifyTask == nil else { return }
        view.endEditing(true)
        let name = nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: host), url.host != nil else {
            showStatus(String(localized: "Enter a valid URL like http://100.x.y.z:4096"), ok: false)
            return
        }
        let password = passwordField.text.isEmpty ? nil : passwordField.text
        var edited = profile
        edited.name = name.isEmpty ? (url.host ?? profile.name) : name
        edited.baseURL = url

        guard needsVerification(url: url, password: password) else {
            commit(edited, password: password)
            return
        }

        saveButton.setLoading(true)
        showStatus(String(localized: "Verifying \(url.host ?? "server")…"), ok: true)
        let backend = profile.backend
        verifyTask = Task { [weak self] in
            defer { self?.verifyTask = nil }
            let outcome = await ProbeSweep.probe(
                baseURL: url, password: password, preferring: backend,
                policy: ProbeSweep.interactivePolicy, retryUnreachable: true)
            guard let self, !Task.isCancelled else { return }
            self.saveButton.setLoading(false)
            switch outcome {
            case .ok(let detected, _):
                var verified = edited
                verified.backend = detected
                verified.username = ProbeSweep.username(for: detected)
                self.commit(verified, password: password)
            case .authFailed:
                Theme.Haptics.error()
                self.showStatus(
                    String(localized: "Wrong password for \(url.host ?? "server")."), ok: false)
            case .notAnAgentServer:
                Theme.Haptics.error()
                self.showStatus(
                    String(localized: "Reachable, but not an opencode, claude-bridge, or omp-bridge server."),
                    ok: false)
            case .unreachable(let detail):
                Theme.Haptics.error()
                self.showStatus(String(localized: "Unreachable: \(detail)"), ok: false)
            }
        }
    }

    /// Only the address or the password can change whether the server answers,
    /// so a pure rename saves instantly instead of waiting on a probe.
    private func needsVerification(url: URL, password: String?) -> Bool {
        url != profile.baseURL
            || password != ConnectionController.shared.password(for: profile.id)
    }

    private func commit(_ edited: ConnectionProfile, password: String?) {
        do {
            try ConnectionController.shared.update(edited, password: .some(password))
            Theme.Haptics.success()
            onSaved?(edited)
            navigationController?.popViewController(animated: true)
        } catch {
            Theme.Haptics.error()
            showStatus(String(localized: "Save failed: \(error.localizedDescription)"), ok: false)
        }
    }

    private func showStatus(_ text: String, ok: Bool) {
        statusLabel.text = text
        statusLabel.textColor = ok ? Theme.Color.secondaryLabel : Theme.Color.danger
    }
}
