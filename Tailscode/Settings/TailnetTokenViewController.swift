import CodingAgentKit
import TailscodeCore
import UIKit

/// The one editor for the Tailscale API token, reached from Settings and from
/// Discovery. Pushed, not presented, so it sits inside whichever navigation
/// stack asked for it.
@MainActor
final class TailnetTokenViewController: UIViewController {
    var onChange: (() -> Void)?

    private let tokenField = FormField(
        title: String(localized: "API access token"), placeholder: "tskey-api-...", secure: true)
    private let saveButton = PrimaryButton(title: String(localized: "Save"))
    private let clearButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var checkTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Tailscale Token")
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
    }

    private func buildUI() {
        let header = UILabel()
        header.text = String(
            localized:
                "Generate an API access token with Devices read access on the Tailscale keys page. One paste is all you need."
        )
        header.font = Theme.Ramp.font(.panelLabel)
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        tokenField.setText(TailnetCredentials.token ?? "")

        let openButton = UIButton(type: .system)
        openButton.setTitle(String(localized: "Open Keys page to generate token"), for: .normal)
        openButton.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
        openButton.addAction(
            UIAction { _ in
                guard let url = URL(string: "https://login.tailscale.com/admin/settings/keys")
                else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)

        let note = UILabel()
        note.text = TailnetTokenReading.note
        note.font = Theme.Ramp.font(.panelFootnote)
        note.textColor = Theme.Color.tertiaryLabel
        note.numberOfLines = 0

        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)

        clearButton.setTitle(String(localized: "Clear token"), for: .normal)
        clearButton.setTitleColor(Theme.Color.danger, for: .normal)
        clearButton.isHidden = !TailnetCredentials.hasToken
        clearButton.addAction(UIAction { [weak self] _ in self?.clear() }, for: .touchUpInside)

        statusLabel.font = Theme.Ramp.font(.panelFootnote)
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            header, openButton, tokenField, statusLabel, note, saveButton, clearButton,
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
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    private func save() {
        let token = tokenField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            clear()
            return
        }
        guard checkTask == nil else { return }
        view.endEditing(true)
        show(TailnetTokenReading.checking, color: Theme.Color.secondaryLabel)
        saveButton.setLoading(true)
        checkTask = Task { [weak self] in
            do {
                let devices = try await TailscaleClient().fetchDevices(with: token)
                guard !Task.isCancelled, let self else { return }
                try TailnetCredentials.setToken(token)
                TailnetCredentials.remember(devices)
                Theme.Haptics.success()
                onChange?()
                finish()
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error)
            }
        }
    }

    private func failed(_ error: Error) {
        checkTask = nil
        saveButton.setLoading(false)
        Theme.Haptics.error()
        if TailscaleClient.isRejection(error) {
            show(TailnetTokenReading.rejected, color: Theme.Color.danger)
        } else if error is AgentError {
            show(TailnetTokenReading.unreachable, color: Theme.Color.danger)
        } else {
            show(error.localizedDescription, color: Theme.Color.danger)
        }
    }

    private func show(_ text: String, color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
        statusLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func clear() {
        TailnetCredentials.clearToken()
        Theme.Haptics.warning()
        onChange?()
        finish()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed { checkTask?.cancel() }
    }

    private func finish() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
}
