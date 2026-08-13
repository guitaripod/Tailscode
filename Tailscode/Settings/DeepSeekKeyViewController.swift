import UIKit

/// The one editor for the optional DeepSeek API key. Purely additive: without a key the usage
/// surfaces stay exactly as they were, and with one the DeepSeek balance joins the meters and
/// the chooser's DeepSeek rows learn their own wall.
@MainActor
final class DeepSeekKeyViewController: UIViewController {
    var onChange: (() -> Void)?

    private let keyField = FormField(
        title: String(localized: "API key"), placeholder: "sk-...", secure: true)
    private let saveButton = PrimaryButton(title: String(localized: "Save"))
    private let clearButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "DeepSeek API Key")
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
    }

    private func buildUI() {
        let header = UILabel()
        header.text = String(
            localized:
                "DeepSeek models reached through opencode normally ride your opencode go plan. If you bill them straight to DeepSeek instead, paste the platform's API key here and Tailscode will show the prepaid balance beside the plan quotas."
        )
        header.font = Theme.Ramp.font(.panelLabel)
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        keyField.setText(DeepSeekCredentials.token ?? "")

        let openButton = UIButton(type: .system)
        openButton.setTitle(String(localized: "Open platform.deepseek.com to get a key"), for: .normal)
        openButton.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
        openButton.addAction(
            UIAction { _ in
                guard let url = URL(string: "https://platform.deepseek.com/api_keys")
                else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)

        let note = UILabel()
        note.text = String(
            localized:
                "Stored only in the Keychain, on this device. Read once per refresh to api.deepseek.com — the key never touches your servers."
        )
        note.font = Theme.Ramp.font(.panelFootnote)
        note.textColor = Theme.Color.tertiaryLabel
        note.numberOfLines = 0

        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)

        clearButton.setTitle(String(localized: "Remove key"), for: .normal)
        clearButton.setTitleColor(Theme.Color.danger, for: .normal)
        clearButton.isHidden = !DeepSeekCredentials.hasToken
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
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.widthAnchor.constraint(
                equalTo: view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    private func save() {
        let key = keyField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            clear()
            return
        }
        do {
            try DeepSeekCredentials.setToken(key)
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
        DeepSeekCredentials.clearToken()
        UsageWidgetStore.removeProvider(named: DeepSeekBalance.providerName)
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
