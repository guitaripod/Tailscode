import CodingAgentKit
import CodingAgentKitApple
import PhotosUI
import TailscodeCore
import UIKit
import UniformTypeIdentifiers

/// A question owes no form: the sheet is one composer aimed by memory, and sending is the whole
/// ceremony. The aim is one chip and one menu — which machine answers and which model it answers
/// on — and both halves are the quick ask's own: `QuickAskDefaults` keeps them per server, beside
/// the composer's memory rather than inside it, so asking a throwaway question on a cheap model
/// never re-aims the project chats and never has to be set up twice.
///
/// Owing no form is not the same as being able to do nothing. The composer is the chat's own —
/// pictures, files, a paste, a drop, the on-device enhancement behind a held Send — because a
/// lookup and an errand are the same gesture and only the person knows which one they are
/// starting; what the aim cannot take is never offered, and a picture already in hand is dropped
/// out loud when a model switch makes it unreadable rather than failing on the other machine.
/// The empty surface argues for itself with `QuickAskStarters` and hands back the last few
/// questions asked here, so the blank box is a way into everything the agent can do instead of a
/// text field with a placeholder.
///
/// The conversation minted carries no project directory and is stamped with the aim, and
/// afterwards it is any other chat. The mint happens here so the sheet can keep the words —
/// and the attachments — through a failed create, which is named where the asking happened with
/// the one action that fixes it; where the conversation opens stays the host's, so `onOpen`
/// receives the entry with the question still unsent.
///
/// Being the chat's own composer includes what `/` means in it. The catalog is the machine's own —
/// fetched with no project and remembered per server, minus the commands that read a transcript
/// the minted conversation will not have — and the decision about what the words turn out to be is
/// made here, before the mint, because the conversation that would answer it does not exist yet:
/// `onOpen` therefore carries a `QuickAskSend` rather than a string, and a command runs as a
/// command in the chat it opens.
@MainActor
final class QuickAskViewController: UIViewController {
    var onOpen: ((SessionEntry, QuickAskSend, ModelChoice, [PromptAttachment]) -> Void)?
    /// A question already asked here, reopened rather than asked again.
    var onResume: ((SessionEntry) -> Void)?

    private let viewModel: SessionListViewModel
    private var targetProfileID: String?
    private var aim = ModelChoice()
    private var resolvedAimFor: String?
    private var abilities = ModelAbilities.words
    private var attachments: [PendingAttachment] = []
    private var phase: NewChatPhase = .asking
    private var lastAttempt: (profile: ConnectionProfile, send: QuickAskSend)?
    private var pastedImageCount = 0
    /// What this server can be told to do, minus the commands that read a transcript. Seeded from
    /// memory so the first `/` is never answered with a blank list, then corrected by the machine.
    private var commands: [AgentCommand] = []
    private var catalogProfileID: String?

    private let titleLabel = UILabel()
    private let targetButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let body = UIView()
    private let scrollView = UIScrollView()
    private let starterStack = UIStackView()
    private let statusView = NewChatStatusView()
    private let statusActions = UIStackView()
    private let attachmentScroll = UIScrollView()
    private let attachmentStrip = UIStackView()
    private let composer = ComposerView()
    private let commandPalette = SlashCommandPalette()
    private let enhancement = PromptEnhancementController()
    private weak var enhanceOverlay: PromptEnhanceOverlay?

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
        buildHeader()
        buildBody()
        buildComposer()
        view.addInteraction(UIDropInteraction(delegate: self))
        enhancement.onStatusChange = { [weak self] status in
            self?.handleEnhancementStatus(status)
        }
        refreshTarget()
        restoreDraft()
        show(.asking)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            seedForVerification()
        #endif
        guard !phase.isBusy else { return }
        composer.focus()
        enhancement.prewarm()
    }

    #if DEBUG
        /// Puts the surface into a named state so each one can be reviewed without a hand:
        /// `attach` hangs a picture and a file in the strip, `sending` shows the wait, `failed`
        /// shows a diagnosis with its remedy.
        private func seedForVerification() {
            guard let mode = ProcessInfo.processInfo.environment["TAILSCODE_ASK_STATE"]
            else { return }
            switch mode {
            case "attach":
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                let png = renderer.image { context in
                    Theme.Color.accent.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                }.pngData() ?? Data()
                attachments = [
                    PendingAttachment(name: "shelf.png", mime: "image/png", data: png),
                    PendingAttachment(
                        name: "notes.txt", mime: "text/plain", data: Data(repeating: 0x20, count: 2048)),
                ]
                composer.setDraft("What is on this shelf?", focus: false)
                refreshAttachments()
            case "sending":
                show(.starting(server: targetProfile?.name ?? "studio"))
            case "failed":
                composer.setDraft("What is on this shelf?", focus: false)
                show(
                    .failed(
                        NewChatDiagnosis.failure(
                            server: NewChatServer(
                                profileID: "demo", name: targetProfile?.name ?? "studio",
                                backend: .claudeCode, address: "100.64.0.1:4098"),
                            directory: nil, error: "Connection refused", witness: .unknown)))
            default: break
            }
        }
    #endif

    /// A question is only ever lost in the moment nobody thought to save it, and a sheet swiped
    /// away is exactly that moment.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stashDraft()
        DraftStore.flush()
    }

    private func buildHeader() {
        titleLabel.text = String(localized: "Quick ask")
        titleLabel.font = Theme.Ramp.font(.metricLarge)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var chip = Theme.Glass.buttonConfiguration()
        chip.cornerStyle = .capsule
        chip.buttonSize = .small
        chip.imagePadding = Theme.Spacing.xs
        chip.titleLineBreakMode = .byTruncatingTail
        targetButton.configuration = chip
        targetButton.showsMenuAsPrimaryAction = true
        targetButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        var close = Theme.Glass.buttonConfiguration()
        close.cornerStyle = .capsule
        close.buttonSize = .small
        close.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        closeButton.configuration = close
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titleLabel, targetButton, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            header.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            header.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        headerBottom = header.bottomAnchor
    }

    private var headerBottom: NSLayoutYAxisAnchor!

    private func buildBody() {
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        body.addSubview(scrollView)

        starterStack.axis = .vertical
        starterStack.spacing = Theme.Spacing.s
        starterStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(starterStack)

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true
        body.addSubview(statusView)

        statusActions.axis = .vertical
        statusActions.spacing = Theme.Spacing.s
        statusActions.translatesAutoresizingMaskIntoConstraints = false
        statusActions.isHidden = true
        body.addSubview(statusActions)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: headerBottom, constant: Theme.Spacing.m),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),

            starterStack.topAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.topAnchor),
            starterStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.l),
            scrollView.contentLayoutGuide.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            starterStack.leadingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            starterStack.trailingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),

            statusView.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            statusView.leadingAnchor.constraint(
                equalTo: body.leadingAnchor, constant: Theme.Spacing.l),
            statusView.trailingAnchor.constraint(
                equalTo: body.trailingAnchor, constant: -Theme.Spacing.l),

            statusActions.topAnchor.constraint(
                equalTo: statusView.bottomAnchor, constant: Theme.Spacing.l),
            statusActions.leadingAnchor.constraint(
                equalTo: body.leadingAnchor, constant: Theme.Spacing.l),
            statusActions.trailingAnchor.constraint(
                equalTo: body.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private lazy var attachmentHeight = attachmentScroll.heightAnchor.constraint(
        equalToConstant: 0)

    private func buildComposer() {
        attachmentScroll.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.showsHorizontalScrollIndicator = false
        attachmentScroll.isHidden = true
        view.addSubview(attachmentScroll)

        attachmentStrip.axis = .horizontal
        attachmentStrip.spacing = Theme.Spacing.s
        attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.addSubview(attachmentStrip)

        composer.delegate = self
        composer.placeholderText = String(localized: "Ask anything — no project, no setup")
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)

        NSLayoutConstraint.activate([
            attachmentScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            attachmentScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            attachmentScroll.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: -Theme.Spacing.xs),
            attachmentHeight,

            attachmentStrip.topAnchor.constraint(
                equalTo: attachmentScroll.contentLayoutGuide.topAnchor),
            attachmentStrip.bottomAnchor.constraint(
                equalTo: attachmentScroll.contentLayoutGuide.bottomAnchor),
            attachmentStrip.leadingAnchor.constraint(
                equalTo: attachmentScroll.contentLayoutGuide.leadingAnchor,
                constant: Theme.Spacing.l),
            attachmentStrip.trailingAnchor.constraint(
                equalTo: attachmentScroll.contentLayoutGuide.trailingAnchor,
                constant: -Theme.Spacing.l),
            attachmentStrip.heightAnchor.constraint(
                equalTo: attachmentScroll.frameLayoutGuide.heightAnchor),

            body.bottomAnchor.constraint(equalTo: attachmentScroll.topAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        commandPalette.isHidden = true
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            commandPalette.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            commandPalette.bottomAnchor.constraint(
                equalTo: attachmentScroll.topAnchor, constant: -Theme.Spacing.xs),
            commandPalette.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Theme.Spacing.s),
        ])
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
            abilities = .words
            commands = []
            catalogProfileID = nil
            hideCommandPalette()
            refreshComposerAffordances()
            renderStarters()
            return
        }
        targetButton.configuration?.title = aimLabel(for: profile)
        targetButton.configuration?.image = UIImage(
            systemName: profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
        targetButton.menu = aimMenu(for: profile)
        resolveAimIfNeeded(for: profile)
        refreshAbilities(for: profile)
        loadCommandsIfNeeded(for: profile)
        renderStarters()
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
                                self?.presentModelPicker(profile: profile, backend: backend, models: models)
                            })))
            }
        }
    }

    /// Moving the question to another machine takes the draft with it: what is typed belongs to
    /// the question, not to the server it was pointed at a second ago, and the words already
    /// filed under the machine being left stay there for the next time it is aimed at.
    private func aimServer(_ profileID: String) {
        guard profileID != targetProfileID else { return }
        stashDraft()
        targetProfileID = profileID
        Theme.Haptics.selection()
        reresolveAim()
        restoreDraft()
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

    private func presentModelPicker(
        profile: ConnectionProfile, backend: any CodingAgentBackend, models: [ModelInfo]
    ) {
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
        let contextID = profile.id
        let allowsServerDefault = profile.backend == .claudeCode
        let sources = { (models: [ModelInfo]) in
            ModelFleet.sources(
                profiles: self.viewModel.servers, current: contextID,
                currentModels: models, allowsServerDefault: allowsServerDefault)
        }
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: contextID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(sources: sources(fresh))
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    private func refreshAbilities(for profile: ConnectionProfile) {
        let backend = viewModel.backend(forProfileID: profile.id)
        abilities = ModelAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments ?? false,
            model: modelCapabilities(for: profile),
            camera: UIImagePickerController.isSourceTypeAvailable(.camera))
        let kept = attachments.filter { abilities.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        if dropped > 0 {
            attachments = kept
            toast(QuickAskComposition.droppedNotice(count: dropped))
        }
        refreshAttachments()
    }

    private func modelCapabilities(for profile: ConnectionProfile) -> ModelCapabilities? {
        guard let selection = aim.model else { return nil }
        return ModelCatalog.cached(for: profile.id).first {
            $0.providerID == selection.providerID && $0.id == selection.modelID
        }?.capabilities
    }


    /// What the aimed machine can be told to do, read from memory first and corrected by the
    /// machine afterwards — a list that is blank for the first second is a list nobody trusts. It
    /// is fetched with no directory, because a question carries no project, and the commands that
    /// read a transcript are dropped: the conversation this send mints has none.
    private func loadCommandsIfNeeded(for profile: ConnectionProfile) {
        guard catalogProfileID != profile.id else { return }
        catalogProfileID = profile.id
        commands = CommandCatalogStore.forQuickAsk(CommandCatalogStore.cached(profile.id))
        updateCommandPalette(for: composer.currentText)
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else {
            commands = []
            hideCommandPalette()
            return
        }
        Task { [weak self] in
            let fetched = await CommandCatalogStore.refresh(
                profileID: profile.id, backend: backend)
            guard let self, self.targetProfileID == profile.id else { return }
            self.commands = CommandCatalogStore.forQuickAsk(fetched)
            self.updateCommandPalette(for: self.composer.currentText)
        }
    }

    /// The same reading the chat composer answers, drawn in the same list: candidates while the
    /// command is being named, that one command's signature once it is settled, and a word the
    /// catalog lacks said out loud rather than left to vanish under the caret. Only the server's
    /// own commands are offered — the app's palette rows act on a transcript, and this surface
    /// has none.
    private func updateCommandPalette(for text: String) {
        guard case .asking = phase else { return hideCommandPalette() }
        switch SlashPresentation.of(
            text: text, commands: commands, recents: SlashRecents.surviving(in: commands))
        {
        case .hidden:
            hideCommandPalette()
        case .naming(let matches):
            commandPalette.update(
                with: .commands([
                    SlashCommandSection(
                        title: "",
                        commands: matches.map { row(for: $0.command, highlight: $0.highlight) })
                ]))
            showCommandPalette()
        case .arguments(let command, let typed):
            commandPalette.update(with: .arguments(command: row(for: command), typed: typed))
            showCommandPalette()
        case .noMatch(let query):
            commandPalette.update(
                with: .noMatch(
                    wording: SlashPresentation.noMatchWording("/\(query)", hasProject: false),
                    browse: nil))
            showCommandPalette()
        }
    }

    private func row(for command: AgentCommand, highlight: [Int] = []) -> SlashCommand {
        SlashCommand(
            id: "server:\(command.name)",
            keywords: [command.name.lowercased()],
            title: "/\(command.name)",
            subtitle: command.details,
            symbol: CommandSymbol.of(command),
            highlight: highlight.map { $0 + 1 },
            argumentHint: command.argumentHint,
            badge: command.scope,
            runsOnServer: true
        ) { [weak self] in self?.selectCommand(command) }
    }

    /// Picking a command that takes arguments lands it in the composer with the caret after the
    /// space, to be completed rather than fired bare — a tap is a choice, not a submission.
    private func selectCommand(_ command: AgentCommand) {
        Theme.Haptics.selection()
        hideCommandPalette()
        composer.setDraft(
            command.takesArguments ? "/\(command.name) " : "/\(command.name)", focus: true)
        stashDraft()
    }

    private func showCommandPalette() {
        guard commandPalette.isHidden else { return }
        commandPalette.alpha = 0
        commandPalette.isHidden = false
        UIView.animate(withDuration: 0.18) { self.commandPalette.alpha = 1 }
    }

    private func hideCommandPalette() {
        guard !commandPalette.isHidden else { return }
        UIView.animate(
            withDuration: 0.15, animations: { self.commandPalette.alpha = 0 },
            completion: { _ in self.commandPalette.isHidden = true })
    }


    /// The blank box's argument for itself: what this thing can be asked to do, offered against
    /// what the aim can take, and the last few questions asked here so a lookup worth continuing
    /// is one touch away rather than somewhere in the chat list.
    private func renderStarters() {
        starterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard targetProfile != nil else {
            starterStack.addArrangedSubview(
                sectionLabel(String(localized: "Add a server to ask anything")))
            return
        }
        starterStack.addArrangedSubview(sectionLabel(String(localized: "Try")))
        for starter in QuickAskStarters.offered(for: abilities) {
            starterStack.addArrangedSubview(
                QuickAskRowButton(
                    symbol: starter.symbol, title: starter.title, detail: starter.detail
                ) { [weak self] in self?.pick(starter) })
        }
        let recents = targetProfile.map {
            QuickAskRecents.asks(among: viewModel.entries, profileID: $0.id)
        } ?? []
        guard !recents.isEmpty else { return }
        starterStack.addArrangedSubview(sectionLabel(String(localized: "Asked here")))
        for entry in recents {
            starterStack.addArrangedSubview(
                QuickAskRowButton(
                    symbol: "clock.arrow.circlepath", title: askTitle(entry),
                    detail: entry.session.updatedAt.formatted(.relative(presentation: .numeric))
                ) { [weak self] in self?.resume(entry) })
        }
    }

    private func askTitle(_ entry: SessionEntry) -> String {
        AgentSession.isPlaceholderTitle(entry.session.title)
            ? String(localized: "Untitled question") : entry.session.title
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.rowTitleStrong)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.secondaryLabel
        return label
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the composer with the caret at their end, and a row that needs a
    /// picture or a file opens the picker for it in the same touch.
    private func pick(_ starter: QuickAskStarter) {
        Theme.Haptics.tap()
        QuickAskStarterRecents.record(starter.id)
        composer.setDraft(composer.currentText.isEmpty ? starter.prompt : composer.currentText)
        switch starter.opens {
        case .none: break
        case .photos: presentPhotoPicker()
        case .camera: presentCamera()
        case .files: presentDocumentPicker()
        }
    }

    private func resume(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        stashDraft()
        onResume?(entry)
        (presentingViewController ?? self).dismiss(animated: true)
    }


    private var composition: String { composer.currentText }

    private func refreshComposerAffordances() {
        composer.showsAttach = abilities.attachments
        composer.carriesAttachments = !attachments.isEmpty
        updateStarterVisibility()
    }

    /// The starters are the empty state and nothing more: the moment there is a question they get
    /// out of its way, and they come back if it is emptied again.
    private func updateStarterVisibility() {
        guard case .asking = phase else { return }
        let empty = composition.isEmpty && attachments.isEmpty
        let target: CGFloat = empty ? 1 : 0
        guard scrollView.alpha != target else { return }
        UIView.animate(withDuration: 0.2) {
            self.scrollView.alpha = target
        }
        scrollView.isUserInteractionEnabled = empty
    }

    private func restoreDraft() {
        guard let profileID = targetProfileID else { return }
        let draft = DraftStore.text(for: .quickAsk(profileID: profileID))
        composer.setDraft(draft, focus: false)
        refreshComposerAffordances()
        updateCommandPalette(for: draft)
    }

    private func stashDraft() {
        guard let profileID = targetProfileID else { return }
        DraftStore.record(composer.rawText, for: .quickAsk(profileID: profileID))
    }


    private func attach(_ attachment: PendingAttachment) {
        guard abilities.accepts(mime: attachment.mime) else {
            toast(String(localized: "This model can't read \(attachment.name)."))
            return
        }
        attachments.append(attachment)
        Theme.Haptics.success()
        refreshAttachments()
    }

    private func attach(data: Data, name: String, mime: String) {
        guard data.count <= AttachmentIntake.byteCap else {
            toast(
                String(
                    localized:
                        "\(name) is \(AttachmentIntake.sizeText(data.count)) — the cap is 8 MB."))
            return
        }
        attach(PendingAttachment(name: name, mime: mime, data: data))
    }

    private func refreshAttachments() {
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let image =
                attachment.mime.hasPrefix("image/") ? UIImage(data: attachment.data) : nil
            let id = attachment.id
            let chip = AttachmentChip(
                label: "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))",
                image: image
            ) { [weak self] in
                guard let self else { return }
                self.attachments.removeAll { $0.id == id }
                Theme.Haptics.tap()
                self.refreshAttachments()
            }
            attachmentStrip.addArrangedSubview(chip)
        }
        attachmentScroll.isHidden = attachments.isEmpty
        attachmentHeight.constant = attachments.isEmpty ? 0 : 44
        refreshComposerAffordances()
    }

    private func presentPhotoPicker() {
        Theme.Haptics.tap()
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        Theme.Haptics.tap()
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        Theme.Haptics.tap()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    /// The pasteboard, taken for what it is holding: a picture becomes an attachment, words go
    /// into the question where the caret is.
    private func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, abilities.vision {
            guard let image = pasteboard.image, let data = image.pngData() else {
                toast(String(localized: "The clipboard holds no picture."))
                return
            }
            pastedImageCount += 1
            attach(data: data, name: "pasted-\(pastedImageCount).png", mime: "image/png")
            return
        }
        guard let text = pasteboard.string, !text.isEmpty else {
            toast(String(localized: "The clipboard holds nothing to ask about."))
            return
        }
        composer.insertText(text)
    }


    /// A question that fails to find its machine keeps its words, its pictures and its aim: the
    /// sheet stays up, says what went wrong where the asking happened, and offers the one action
    /// that fixes it. While the mint is in flight the sheet pins itself open — a pull-down mid
    /// create would strand a minted session empty and lose the question with it.
    private func send(text: String? = nil) {
        guard case .asking = phase, let profile = targetProfile else { return }
        let words = text ?? composition
        guard QuickAskComposition.canSend(text: words, attachments: attachments.count) else {
            return
        }
        hideCommandPalette()
        mint(on: profile, send: decide(words, on: profile))
    }

    /// What the words turn out to be, asked of the shared grammar before anything is minted: a
    /// command the machine knows runs as a command in the conversation this send creates, and
    /// everything else — including a word on a server that reads its own slashes out of the
    /// prompt — goes as the words that were written.
    private func decide(_ text: String, on profile: ConnectionProfile) -> QuickAskSend {
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else { return QuickAskSend(text: text, kind: .prompt) }
        return QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: backend.resolvesCommandsFromPromptText)
    }

    private func mint(on profile: ConnectionProfile, send: QuickAskSend) {
        lastAttempt = (profile, send)
        show(.starting(server: profile.name))
        Task { [weak self] in
            let result = await self?.viewModel.createSession(on: profile, directory: nil)
            guard let self, let result else { return }
            switch result {
            case .success(let entry):
                QuickAskDefaults.record(profileID: profile.id)
                QuickAskDefaults.stamp(profileID: profile.id, sessionID: entry.session.id)
                DraftStore.clear(.quickAsk(profileID: profile.id))
                Theme.Haptics.success()
                self.hand(entry, send: send)
            case .failure(let failure):
                Theme.Haptics.error()
                self.composer.setDraft(send.text, focus: false)
                self.stashDraft()
                self.show(.failed(failure))
            }
        }
    }

    /// The handover is one movement: the conversation is opened and the question sent while this
    /// sheet still covers the stack, and the sheet then slides away onto a chat that already holds
    /// the words. Dismissing first and opening in the completion made a person watch two
    /// animations take turns — and put the open inside the exact moment a navigation transition is
    /// running, which is where the question used to be dropped.
    private func hand(_ entry: SessionEntry, send: QuickAskSend) {
        let payload = attachments.map(\.prompt)
        attachments = []
        onOpen?(entry, send, aim, payload)
        (presentingViewController ?? self).dismiss(animated: true)
    }

    /// One state change, one redraw: the starters and the status card are never both on screen,
    /// and the composer is only unreachable while the machine is actually being asked.
    private func show(_ next: NewChatPhase) {
        phase = next
        isModalInPresentation = next.isBusy
        targetButton.isHidden = next.isBusy
        switch next {
        case .asking:
            statusView.isHidden = true
            statusActions.isHidden = true
            statusActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            scrollView.isHidden = false
            composer.isUserInteractionEnabled = true
            scrollView.alpha = 1
            updateStarterVisibility()
            updateCommandPalette(for: composition)
        case .starting(let server):
            hideCommandPalette()
            composer.unfocus()
            composer.isUserInteractionEnabled = false
            scrollView.isHidden = true
            statusView.isHidden = false
            statusActions.isHidden = true
            statusView.showWaiting()
            titleLabel.text = QuickAskComposition.waitingTitle(server: server)
        case .failed(let failure):
            hideCommandPalette()
            composer.isUserInteractionEnabled = true
            scrollView.isHidden = true
            statusView.isHidden = false
            statusView.show(failure)
            titleLabel.text = String(localized: "Quick ask")
            statusActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let actionTitle = failure.actionTitle {
                let button = PrimaryButton(title: actionTitle)
                button.addAction(
                    UIAction { [weak self] _ in self?.applyFix(failure.fix) }, for: .touchUpInside)
                statusActions.addArrangedSubview(button)
            }
            let back = SecondaryButton(title: String(localized: "Keep the question"))
            back.addAction(UIAction { [weak self] _ in self?.show(.asking) }, for: .touchUpInside)
            statusActions.addArrangedSubview(back)
            statusActions.isHidden = false
        }
    }

    /// The remedy, applied and the question retried on the spot — somebody who tapped "Use :4098"
    /// asked for an answer, not for a settings screen.
    private func applyFix(_ fix: NewChatFailure.Fix) {
        switch fix {
        case .none:
            show(.asking)
        case .retry:
            guard let attempt = lastAttempt else { return show(.asking) }
            mint(on: attempt.profile, send: attempt.send)
        case .editServer(let profileID):
            guard let profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return show(.asking)
            }
            let editor = ServerEditViewController(profile: profile)
            editor.onSaved = { [weak self] _ in
                guard let self, let attempt = self.lastAttempt else { return }
                self.viewModel.refreshSources()
                let refreshed =
                    self.viewModel.servers.first { $0.id == attempt.profile.id } ?? attempt.profile
                self.dismiss(animated: true) {
                    self.mint(on: refreshed, send: attempt.send)
                }
            }
            present(UINavigationController(rootViewController: editor), animated: true)
        case .repoint(let profileID, let url, _):
            guard var profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return show(.asking)
            }
            let password = ConnectionController.shared.password(for: profile.id)
            profile.baseURL = url
            show(.starting(server: profile.name))
            do {
                try ConnectionController.shared.save(profile, password: password)
                viewModel.refreshSources()
                mint(on: profile, send: lastAttempt?.send ?? decide(composition, on: profile))
            } catch {
                show(
                    .failed(
                        NewChatDiagnosis.failure(
                            server: NewChatServer(
                                profileID: profile.id, name: profile.name,
                                backend: profile.backend,
                                address: ServerLabel.address(profile)),
                            directory: nil, error: AgentErrorText.readable(error),
                            witness: .unknown)))
            }
        }
    }

    private func close() {
        stashDraft()
        DraftStore.flush()
        dismiss(animated: true)
    }

    private func toast(_ message: String) {
        ToastView(message: message).flash(in: view, above: composer.topAnchor)
    }


    override var keyCommands: [UIKeyCommand]? {
        let ask = [
            UIKeyCommand(
                title: String(localized: "Ask"), action: #selector(sendFromKeyboard),
                input: "\r", modifierFlags: .command),
            UIKeyCommand(
                title: String(localized: "Close"), action: #selector(closeFromKeyboard),
                input: UIKeyCommand.inputEscape),
        ]
        return commandPalette.isHidden ? ask : paletteKeyCommands() + ask
    }

    /// Only while the list is up, and only then claiming priority over the system: the arrows have
    /// to keep moving the caret through an ordinary question, Return has to keep writing a line,
    /// and escape has to close the list before it closes the sheet — a question is not thrown away
    /// by dismissing a completion.
    private func paletteKeyCommands() -> [UIKeyCommand] {
        let bindings: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(paletteSelectPrevious)),
            (UIKeyCommand.inputDownArrow, #selector(paletteSelectNext)),
            ("\t", #selector(paletteSelectNext)),
            ("\r", #selector(paletteAccept)),
            (UIKeyCommand.inputEscape, #selector(paletteDismiss)),
        ]
        var commands = bindings.map { input, action -> UIKeyCommand in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let back = UIKeyCommand(
            input: "\t", modifierFlags: .shift, action: #selector(paletteSelectPrevious))
        back.wantsPriorityOverSystemBehavior = true
        commands.append(back)
        return commands
    }

    @objc private func paletteSelectNext() { commandPalette.moveSelection(by: 1) }

    @objc private func paletteSelectPrevious() { commandPalette.moveSelection(by: -1) }

    @objc private func paletteAccept() {
        guard commandPalette.activateSelection() else {
            composer.triggerSend()
            return
        }
    }

    @objc private func paletteDismiss() { hideCommandPalette() }

    @objc private func sendFromKeyboard() { send() }

    @objc private func closeFromKeyboard() { close() }
}

extension QuickAskViewController: ComposerViewDelegate {
    func composerDidSend(_ text: String) {
        send(text: text)
    }

    func composerTextDidChange(_ text: String) {
        stashDraft()
        updateStarterVisibility()
        updateCommandPalette(for: text)
        enhancement.updateInput(text)
        enhanceOverlay?.requestDismiss()
    }

    /// Holding Send raises the on-device enhancement deck for a question worth sharpening — the
    /// same gesture the chat's composer answers, because a lookup is exactly where a vague
    /// sentence costs a whole round trip.
    func composerDidLongPressSend(from view: UIView) {
        let text = composition
        guard !text.isEmpty else { return }
        enhancement.requestNow(for: text)
        presentEnhanceOverlay(original: text)
    }

    /// A paste too large to read as a sentence becomes the file it already is, so the question
    /// stays a question and the wall of text rides beside it.
    func composerDidPasteLargeText(_ text: String) {
        guard abilities.attachments, let data = text.data(using: .utf8) else {
            composer.insertText(text)
            return
        }
        composer.deleteSelection()
        attach(
            data: data, name: "pasted-\(UUID().uuidString.prefix(8)).txt", mime: "text/plain")
        toast(
            String(
                localized: "Attached \(text.count.formatted()) characters — sent with the question."))
    }

    /// A screenshot in hand is the commonest thing a phone has to show an agent, so pasting one
    /// attaches it rather than doing nothing at all.
    func composerDidPasteImage(_ data: Data, mime: String) {
        guard abilities.vision else {
            toast(String(localized: "This model can't read pictures."))
            return
        }
        pastedImageCount += 1
        attach(data: data, name: "pasted-\(pastedImageCount).png", mime: mime)
    }

    /// Photos and files are different errands, and only the ones this aim can carry out are
    /// offered: a model that cannot see is never handed a photo picker.
    func composerAttachOptions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if abilities.vision {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    image: UIImage(systemName: "photo.on.rectangle")
                ) { [weak self] _ in self?.presentPhotoPicker() })
        }
        if abilities.camera {
            actions.append(
                UIAction(
                    title: String(localized: "Take Photo"), image: UIImage(systemName: "camera")
                ) { [weak self] _ in self?.presentCamera() })
        }
        if abilities.attachments {
            actions.append(
                UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")
                ) { [weak self] _ in self?.presentDocumentPicker() })
        }
        if UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
            actions.append(
                UIAction(
                    title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in self?.pasteFromClipboard() })
        }
        return actions
    }

    func composerDidTapStop() {}

    func composerDidBeginEditing() {
        enhancement.prewarm()
    }

    private func presentEnhanceOverlay(original: String) {
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let anchor = composer.sendControlAnchor
        let origin = anchor.convert(
            CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
    }

    private func handleEnhancementStatus(_ status: PromptEnhancementController.Status) {
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
        enhanceOverlay?.render(status, original: enhancement.latestInput)
    }
}

extension QuickAskViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        Theme.Haptics.success()
        composer.setDraft(prompt.text, focus: true)
        stashDraft()
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        toast(String(localized: "Enhanced prompt copied."))
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
    }
}

extension QuickAskViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            let name = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                [weak self] data, _ in
                guard let data else { return }
                let kind = ImageBytes.kind(of: data)
                Task { @MainActor in
                    self?.attach(
                        data: data,
                        name: "\(name ?? "image-\(UUID().uuidString.prefix(8))").\(kind.ext)",
                        mime: kind.mime)
                }
            }
        }
    }
}

extension QuickAskViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        pastedImageCount += 1
        attach(data: data, name: "photo-\(pastedImageCount).jpg", mime: "image/jpeg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension QuickAskViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        for url in urls {
            switch AttachmentIntake.read(path: url.path) {
            case .success(let attachment): attach(attachment)
            case .failure(let refusal): toast(refusal.message)
            }
        }
    }
}

/// A picture dragged onto the surface is a question about that picture: the drop is taken where
/// it lands, on any part of the sheet, because aiming at a 32-point paperclip with something held
/// in the other hand is not a gesture anybody should have to make.
extension QuickAskViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool
    {
        abilities.attachments && !phase.isBusy
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            let provider = item.itemProvider
            let name = provider.suggestedName ?? String(localized: "attachment")
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                    [weak self] data, _ in
                    guard let data else { return }
                    let kind = ImageBytes.kind(of: data)
                    Task { @MainActor in
                        self?.attach(data: data, name: "\(name).\(kind.ext)", mime: kind.mime)
                    }
                }
                continue
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) {
                [weak self] url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let filename = url.lastPathComponent
                let mime = AttachmentIntake.mime(forExtension: url.pathExtension)
                Task { @MainActor in
                    self?.attach(data: data, name: filename, mime: mime)
                }
            }
        }
    }
}

/// One row of the empty surface: a symbol, what it does, and the half-sentence it will leave in
/// the composer. It is a button rather than a list cell because the surface has no list — the
/// rows are the argument, and they disappear the moment there is a question.
@MainActor
final class QuickAskRowButton: UIButton {
    private let onPick: () -> Void

    init(symbol: String, title: String, detail: String, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.imagePadding = Theme.Spacing.m
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.panelLabel)
        name.foregroundColor = Theme.Color.label
        config.attributedTitle = name
        var subtitle = AttributedString(detail)
        subtitle.font = Theme.Ramp.font(.panelDetail)
        subtitle.foregroundColor = Theme.Color.secondaryLabel
        config.attributedSubtitle = subtitle
        config.titleAlignment = .leading
        config.baseForegroundColor = Theme.Color.accent
        config.background.backgroundColor = Theme.Color.secondaryBackground
        config.background.cornerRadius = Theme.Radius.control
        configuration = config
        contentHorizontalAlignment = .leading
        titleLabel?.adjustsFontForContentSizeCategory = true
        translatesAutoresizingMaskIntoConstraints = false
        addAction(UIAction { [weak self] _ in self?.onPick() }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
