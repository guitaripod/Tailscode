import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// A question owes no form: the sheet is one composer aimed by memory, and sending is the whole
/// ceremony. The aim is one chip and one menu — which machine answers and which model it answers
/// on — and both halves are the quick ask's own: `QuickAskDefaults` keeps them per server, beside
/// the composer's memory rather than inside it, so asking a throwaway question on a cheap model
/// never re-aims the project chats and never has to be set up twice. The conversation minted
/// carries no project directory and is stamped with the aim, and afterwards it is any other chat.
/// The mint happens here so the sheet can keep the words through a failed create, but where the
/// conversation opens stays the host's: `onOpen` receives the entry with the text still unsent.
@MainActor
final class QuickAskViewController: UIViewController, UITextViewDelegate {
    var onOpen: ((SessionEntry, String, ModelChoice) -> Void)?

    private let viewModel: SessionListViewModel
    private var targetProfileID: String?
    private var aim = ModelChoice()
    private var resolvedAimFor: String?
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

    /// The chip states the whole aim as a fact — the machine and the model it answers on — and
    /// the menu behind it is the one action that changes either. A fleet of one still shows the
    /// chip: the surface names its target rather than assuming the person remembers which
    /// machine answers, and the model half is the reason a question can be pointed at something
    /// cheap and stay there.
    private func refreshTarget() {
        guard let profile = targetProfile else {
            targetButton.configuration?.title = String(localized: "No servers")
            targetButton.menu = nil
            refreshSendButton()
            return
        }
        targetButton.configuration?.title = aimLabel(for: profile)
        targetButton.configuration?.image = UIImage(
            systemName: profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
        targetButton.menu = aimMenu(for: profile)
        resolveAimIfNeeded(for: profile)
        refreshSendButton()
    }

    /// One line for two facts, and the model half is dropped rather than faked on a backend that
    /// has neither a model nor an effort to name.
    private func aimLabel(for profile: ConnectionProfile) -> String {
        guard aimIsSelectable(on: profile) else { return profile.name }
        return "\(profile.name) · \(ModelBadge.label(model: aim.model, effort: aim.effort))"
    }

    private func aimIsSelectable(on profile: ConnectionProfile) -> Bool {
        guard let backend = viewModel.backend(forProfileID: profile.id) else { return false }
        return backend.capabilities.supportsModelSelection
            || backend.capabilities.supportsReasoningEffort
    }

    /// Servers first, then the model — one menu rather than two chips, because a lookup is aimed
    /// once and the aim is a single thought. The model rows resolve when the menu opens, so a
    /// catalog still in flight when the sheet was drawn is not what the person is offered.
    private func aimMenu(for profile: ConnectionProfile) -> UIMenu {
        var sections: [UIMenuElement] = []
        if viewModel.servers.count > 1 {
            sections.append(
                UIMenu(
                    title: String(localized: "Ask on"), options: .displayInline,
                    children: viewModel.servers.map { server in
                        UIAction(
                            title: server.name, subtitle: server.backend.displayName,
                            state: server.id == targetProfileID ? .on : .off
                        ) { [weak self] _ in self?.aimServer(server.id) }
                    }))
        }
        guard let backend = viewModel.backend(forProfileID: profile.id),
            aimIsSelectable(on: profile)
        else { return UIMenu(children: sections) }
        sections.append(
            UIMenu(
                title: String(localized: "Model"), options: .displayInline,
                children: [modelElement(for: profile, backend: backend)]))
        if QuickAskDefaults.hasOwnAim(forProfileID: profile.id) {
            sections.append(
                UIMenu(
                    options: .displayInline,
                    children: [
                        UIAction(
                            title: String(localized: "Follow this server"),
                            subtitle: String(localized: "Use what a new chat here would"),
                            image: UIImage(systemName: "arrow.uturn.backward")
                        ) { [weak self] _ in
                            QuickAskDefaults.clearOwnAim(forProfileID: profile.id)
                            self?.reresolveAim()
                        }
                    ]))
        }
        return UIMenu(children: sections)
    }

    private func modelElement(for profile: ConnectionProfile, backend: any CodingAgentBackend)
        -> UIMenuElement
    {
        UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self else { return completion([]) }
                let models =
                    backend.capabilities.supportsModelSelection
                    ? await ModelCatalog.models(for: profile.id, backend: backend) : []
                completion(
                    ModelMenu.elements(
                        models: models, choice: self.aim,
                        efforts: backend.reasoningEffortOptions,
                        allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                        quotas: QuotaSurface.relevantQuotas(
                            for: backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                        actions: ModelMenu.Actions(
                            selectModel: { [weak self] selection in
                                QuickAskDefaults.recordModel(selection, forProfileID: profile.id)
                                self?.aim.model = selection
                                self?.pickedAim(for: profile)
                            },
                            selectEffort: { [weak self] level in
                                QuickAskDefaults.recordEffort(level, forProfileID: profile.id)
                                self?.aim.effort = level
                                self?.pickedAim(for: profile)
                            },
                            browseAll: { [weak self] in
                                self?.presentModelPicker(profile: profile, models: models)
                            })))
            }
        }
    }

    private func aimServer(_ profileID: String) {
        targetProfileID = profileID
        Theme.Haptics.selection()
        reresolveAim()
    }

    private func pickedAim(for profile: ConnectionProfile) {
        resolvedAimFor = profile.id
        Theme.Haptics.selection()
        refreshTarget()
    }

    private func reresolveAim() {
        resolvedAimFor = nil
        aim = ModelChoice()
        refreshTarget()
    }

    /// The chip names what the question will actually run on, so the aim is resolved the way a
    /// chat resolves it — through the quick ask's own memory when it has one, the server's until
    /// then — rather than left blank until something is picked by hand.
    private func resolveAimIfNeeded(for profile: ConnectionProfile) {
        guard resolvedAimFor != profile.id, aimIsSelectable(on: profile),
            let backend = viewModel.backend(forProfileID: profile.id)
        else { return }
        resolvedAimFor = profile.id
        Task { @MainActor in
            let resolved = await ChatModelResolver.choice(
                profileID: profile.id, backend: backend,
                contextID: QuickAskDefaults.aimContext(forProfileID: profile.id))
            guard targetProfileID == profile.id else { return }
            aim = resolved
            refreshTarget()
        }
    }

    private func presentModelPicker(profile: ConnectionProfile, models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(
            sources: ModelFleet.sources(
                profiles: viewModel.servers, current: profile.id,
                currentModels: models,
                allowsServerDefault: profile.backend == .claudeCode),
            selected: aim.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas())
        ) { [weak self] pick in
            guard let self else { return }
            guard !pick.isElsewhere else {
                QuickAskDefaults.adopt(pick)
                self.aimServer(pick.profileID)
                return
            }
            QuickAskDefaults.recordModel(pick.selection, forProfileID: profile.id)
            self.aim.model = pick.selection
            self.pickedAim(for: profile)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
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
            QuickAskDefaults.stamp(profileID: profile.id, sessionID: entry.session.id)
            Theme.Haptics.success()
            let onOpen = onOpen
            let aim = aim
            if let presenter = presentingViewController {
                presenter.dismiss(animated: true) { onOpen?(entry, text, aim) }
            } else {
                onOpen?(entry, text, aim)
            }
        }
    }
}
