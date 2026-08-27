import UIKit
import TailscodeCore

/// The one editor for the optional Ollama Cloud API key. Purely additive: without a key the
/// usage surfaces stay exactly as they were, and with one the account's session and weekly
/// windows join the meters and the chooser's ollama-cloud rows learn their own wall.
@MainActor
final class OllamaKeyViewController: UIViewController {
    var onChange: (() -> Void)?

    private let keyField = FormField(
        title: String(localized: "API key"), placeholder: "sk-...", secure: true)
    private let saveButton = PrimaryButton(title: String(localized: "Save"))
    private let clearButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Ollama Cloud API Key")
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
    }

    private func buildUI() {
        let header = UILabel()
        header.text = String(
            localized:
                "Ollama models served by ollama.com are metered by your plan — a session window and a weekly one. Paste the account's API key here and Tailscode will show how much of each window you have used. Models on your own ollama server are unlimited and never wear this."
        )
        header.font = Theme.Ramp.font(.panelLabel)
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        keyField.setText(OllamaCredentials.token ?? "")

        let openButton = UIButton(type: .system)
        openButton.setTitle(String(localized: "Open ollama.com/settings/keys to get a key"), for: .normal)
        openButton.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
        openButton.addAction(
            UIAction { _ in
                guard let url = URL(string: "https://ollama.com/settings/keys") else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)

        let note = UILabel()
        note.text = String(
            localized:
                "Stored only in the Keychain, on this device. Read once per refresh to ollama.com — the key never touches your servers."
        )
        note.font = Theme.Ramp.font(.panelFootnote)
        note.textColor = Theme.Color.tertiaryLabel
        note.numberOfLines = 0

        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)

        clearButton.setTitle(String(localized: "Remove key"), for: .normal)
        clearButton.setTitleColor(Theme.Color.danger, for: .normal)
        clearButton.isHidden = !OllamaCredentials.hasToken
        clearButton.addAction(UIAction { [weak self] _ in self?.clear() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            header, openButton, keyField, note, saveButton, clearButton,
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
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -Theme.Spacing.l * 2),
        ])
    }

    private func save() {
        let key = keyField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            clear()
            return
        }
        do {
            try OllamaCredentials.setToken(key)
        } catch {
            Theme.Haptics.error()
            let alert = UIAlertController(
                title: String(localized: "Couldn't save the key"),
                message: error.localizedDescription,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        Theme.Haptics.success()
        onChange?()
        finish()
    }

    private func clear() {
        OllamaCredentials.clearToken()
        UsageWidgetStore.removeProvider(named: OllamaCloud.providerName)
        Theme.Haptics.warning()
        onChange?()
        finish()
    }

    private func finish() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
}