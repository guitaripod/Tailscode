import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// A question owes no form: the sheet is one composer aimed by memory, and sending is the whole
/// ceremony. The aim is `QuickAskDefaults.target` — the server the last quick ask used while it
/// is still connected — worn as a chip one tap changes; the conversation minted carries no
/// project directory, and afterwards it is any other chat. The mint happens here so the sheet
/// can keep the words through a failed create, but where the conversation opens stays the
/// host's: `onOpen` receives the entry with the text still unsent.
@MainActor
final class QuickAskViewController: UIViewController, UITextViewDelegate {
    var onOpen: ((SessionEntry, String) -> Void)?

    private let viewModel: SessionListViewModel
    private var targetProfileID: String?
    private let targetButton = UIButton(type: .system)
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private var isSending = false

    init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        targetProfileID = QuickAskDefaults.target(
            among: viewModel.servers.map(\.id),
            fallback: AppPreferences.lastComposeTarget?.profileID)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(from host: UIViewController, viewModel: SessionListViewModel)
        -> QuickAskViewController
    {
        let ask = QuickAskViewController(viewModel: viewModel)
        ask.modalPresentationStyle = .pageSheet
        if let sheet = ask.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(ask, animated: true)
        return ask
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground

        let title = UILabel()
        title.text = String(localized: "Quick ask")
        title.font = UIFont.preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        var chip = Theme.Glass.buttonConfiguration()
        chip.cornerStyle = .capsule
        chip.buttonSize = .small
        chip.imagePadding = Theme.Spacing.xs
        targetButton.configuration = chip
        targetButton.showsMenuAsPrimaryAction = true
        targetButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(targetButton)

        textView.font = Theme.Font.body()
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        placeholder.text = String(localized: "Ask anything — no project, no setup")
        placeholder.font = Theme.Font.body()
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        send.baseBackgroundColor = Theme.Color.accent
        send.baseForegroundColor = .white
        sendButton.configuration = send
        sendButton.accessibilityLabel = String(localized: "Send")
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            title.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            targetButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            targetButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            targetButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: title.trailingAnchor, constant: Theme.Spacing.s),
            textView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Theme.Spacing.l),
            textView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            textView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor, constant: 5),
            sendButton.topAnchor.constraint(
                equalTo: textView.bottomAnchor, constant: Theme.Spacing.s),
            sendButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            sendButton.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.s),
            sendButton.widthAnchor.constraint(equalToConstant: 44),
            sendButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        refreshTarget()
        refreshSendButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshSendButton()
    }

    private var targetProfile: ConnectionProfile? {
        viewModel.servers.first { $0.id == targetProfileID }
    }

    /// The chip states the aim as a fact; the menu is the one action that changes it. A fleet of
    /// one still shows the chip — the surface names its target rather than assuming the person
    /// remembers which machine answers.
    private func refreshTarget() {
        guard let profile = targetProfile else {
            targetButton.configuration?.title = String(localized: "No servers")
            targetButton.menu = nil
            refreshSendButton()
            return
        }
        targetButton.configuration?.title = profile.name
        targetButton.configuration?.image = UIImage(
            systemName: profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
        targetButton.menu = UIMenu(
            title: String(localized: "Ask on…"),
            children: viewModel.servers.map { server in
                UIAction(
                    title: server.name, subtitle: server.backend.displayName,
                    state: server.id == targetProfileID ? .on : .off
                ) { [weak self] _ in
                    self?.targetProfileID = server.id
                    self?.refreshTarget()
                }
            })
        refreshSendButton()
    }

    private var draft: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSendButton() {
        placeholder.isHidden = !(textView.text ?? "").isEmpty
        sendButton.isEnabled = !isSending && !draft.isEmpty && targetProfile != nil
    }

    /// The words survive a dead server: the sheet stays up with the text intact and the failure
    /// named, never a dismissal that swallows the question. While the mint is in flight the
    /// sheet pins itself open — a pull-down mid-create would strand a minted session empty and
    /// lose the words with it.
    private func send() {
        guard let profile = targetProfile, !draft.isEmpty else { return }
        let text = draft
        isSending = true
        isModalInPresentation = true
        textView.isEditable = false
        refreshSendButton()
        Theme.Haptics.send()
        Task {
            guard let entry = await viewModel.newSession(on: profile, directory: nil) else {
                isSending = false
                isModalInPresentation = false
                textView.isEditable = true
                refreshSendButton()
                Theme.Haptics.error()
                let alert = UIAlertController(
                    title: String(localized: "Couldn't ask"),
                    message: String(
                        localized:
                            "\(profile.name) didn't respond. Check the connection and try again."),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
                return
            }
            QuickAskDefaults.record(profileID: profile.id)
            Theme.Haptics.success()
            let onOpen = onOpen
            if let presenter = presentingViewController {
                presenter.dismiss(animated: true) { onOpen?(entry, text) }
            } else {
                onOpen?(entry, text)
            }
        }
    }
}
