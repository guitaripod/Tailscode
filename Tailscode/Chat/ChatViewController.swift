import CodingAgentKit
import PhotosUI
import UIKit

@MainActor
final class ChatViewController: UIViewController {
    private enum Section { case main }
    private let typingID = "typing"

    private let viewModel: ChatViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private let composer = ComposerView()
    private let banner = BannerView()
    private let emptyState = EmptyStateView(
        symbol: "sparkles",
        title: "Start the conversation",
        message: "Ask your agent to build, fix, or explain something.")

    private var rowsByID: [String: ChatRow] = [:]
    private var orderedIDs: [String] = []
    private var pendingAttachments: [PromptAttachment] = []
    private var pendingPermission: PermissionRequest?
    private var availableModels: [ModelInfo] = []
    private var expandedReasoning: Set<String> = []
    private var seenReasoning: Set<String> = []
    private var wasRunning = false
    private var lastNotifiedPermissionID: String?

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.background
        configureLayout()
        configureDataSource()
        composer.delegate = self
        composer.showsAttach = viewModel.supportsAttachments
        NotificationManager.requestAuthorizationIfNeeded()
        bind()
        viewModel.start()
        if viewModel.supportsModelSelection || viewModel.supportsReasoningEffort {
            Task { await loadModels() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            viewModel.stop()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = max(0, view.bounds.height - composer.frame.minY)
        if abs(collectionView.contentInset.bottom - inset) > 0.5 {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    private func configureLayout() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.Color.background
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        collectionView.register(TextBubbleCell.self, forCellWithReuseIdentifier: TextBubbleCell.reuseID)
        collectionView.register(CodeBlockCell.self, forCellWithReuseIdentifier: CodeBlockCell.reuseID)
        collectionView.register(PermissionCell.self, forCellWithReuseIdentifier: PermissionCell.reuseID)
        collectionView.register(
            ActivityGroupCell.self, forCellWithReuseIdentifier: ActivityGroupCell.reuseID)

        [banner, collectionView, composer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            collectionView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.isUserInteractionEnabled = false
        view.insertSubview(emptyState, belowSubview: composer)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self else { return UICollectionViewCell() }
            if id == self.typingID {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
                cell.configure(text: "…", role: .assistant, reasoning: true)
                return cell
            }
            if id.hasPrefix("permission:"), let request = self.pendingPermission {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PermissionCell.reuseID, for: indexPath) as! PermissionCell
                cell.configure(
                    title: request.toolName.map { "Allow \($0)?" } ?? "Permission requested",
                    detail: request.title ?? "The agent needs your approval to continue."
                ) { [weak self] decision in
                    self?.viewModel.respond(to: request, decision: decision)
                }
                return cell
            }
            guard let row = self.rowsByID[id] else { return UICollectionViewCell() }
            switch row.content {
            case .text(let text):
                return self.bubble(collectionView, indexPath, text, row.role, reasoning: false)
            case .code(let block):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CodeBlockCell.reuseID, for: indexPath) as! CodeBlockCell
                cell.configure(block, expanded: self.expandedReasoning.contains(id)) {
                    [weak self] in self?.toggleReasoning(id)
                }
                return cell
            case .activity(let steps):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ActivityGroupCell.reuseID, for: indexPath)
                    as! ActivityGroupCell
                let streaming = self.viewModel.isBusy && id == self.orderedIDs.last
                cell.configure(
                    steps: steps, expanded: self.expandedReasoning.contains(id), streaming: streaming
                ) { [weak self] in self?.toggleReasoning(id) }
                return cell
            case .file(let file):
                let label = "📎 \(file.filename ?? file.mime ?? "attachment")"
                return self.bubble(collectionView, indexPath, label, row.role, reasoning: false)
            }
        }
    }

    private func bubble(
        _ collectionView: UICollectionView, _ indexPath: IndexPath, _ text: String,
        _ role: MessageRole, reasoning: Bool
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
        cell.configure(text: text, role: role, reasoning: reasoning)
        return cell
    }

    private func bind() {
        viewModel.onState = { [weak self] state in self?.render(state) }
        viewModel.onModelChange = { [weak self] in self?.updateNavControls() }
        viewModel.onError = { [weak self] message in self?.presentError(message) }
    }

    private func render(_ state: ConversationState) {
        let rows = Self.makeRows(from: state.messages)
        let previous = rowsByID
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedIDs = rows.map(\.id)

        if AppPreferences.autoExpandThinking {
            for row in rows where isActivity(row) && !seenReasoning.contains(row.id) {
                seenReasoning.insert(row.id)
                expandedReasoning.insert(row.id)
            }
        }

        pendingPermission = state.pendingPermissions.first
        let showTyping =
            state.status == .running && (rows.last?.role != .assistant) && pendingPermission == nil
        var ids = orderedIDs
        if showTyping { ids.append(typingID) }
        if let pendingPermission { ids.append("permission:\(pendingPermission.id)") }
        emptyState.isHidden = !(orderedIDs.isEmpty && !showTyping)

        let nearBottom = isNearBottom()
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids, toSection: .main)

        let changed = orderedIDs.filter { previous[$0] != nil && previous[$0] != rowsByID[$0] }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if !changed.isEmpty {
                var reconfigure = self.dataSource.snapshot()
                reconfigure.reconfigureItems(changed)
                self.dataSource.apply(reconfigure, animatingDifferences: false)
            }
            if nearBottom { self.scrollToBottom(animated: false) }
        }

        composer.setBusy(state.status == .running)
        if wasRunning && state.status != .running {
            Theme.Haptics.received()
            NotificationManager.notify(
                title: viewModel.title, body: "Your agent finished.",
                identifier: "done:\(viewModel.session.id)")
        }
        wasRunning = state.status == .running
        if let permission = pendingPermission, permission.id != lastNotifiedPermissionID {
            lastNotifiedPermissionID = permission.id
            NotificationManager.notify(
                title: viewModel.title,
                body: permission.toolName.map { "Approval needed: \($0)" } ?? "Approval needed.",
                identifier: "perm:\(permission.id)")
        }
        updateBanner(for: state)
    }

    private func updateBanner(for state: ConversationState) {
        switch state.connection {
        case .reconnecting:
            banner.show("Reconnecting…", color: Theme.Color.warning)
        case .offline:
            banner.show("Offline", color: Theme.Color.danger)
        case .connecting, .live:
            if let failure = state.lastFailure, state.status != .running {
                banner.show(failure.message, color: Theme.Color.danger)
            } else {
                banner.hide()
            }
        }
    }

    private func isActivity(_ row: ChatRow) -> Bool {
        if case .activity = row.content { return true }
        return false
    }

    private func toggleReasoning(_ id: String) {
        if expandedReasoning.contains(id) {
            expandedReasoning.remove(id)
        } else {
            expandedReasoning.insert(id)
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func loadModels() async {
        availableModels = await viewModel.availableModels()
        updateNavControls()
    }

    private func updateNavControls() {
        var items: [UIBarButtonItem] = [overflowBarButton()]
        if viewModel.supportsModelSelection {
            items.append(modelBarButton())
        }
        if viewModel.supportsReasoningEffort {
            items.append(effortBarButton())
        }
        navigationItem.rightBarButtonItems = items
    }

    private func overflowBarButton() -> UIBarButtonItem {
        let jump = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let prompts = self.orderedIDs.compactMap { id -> UIAction? in
                guard let row = self.rowsByID[id], row.role == .user,
                    case .text(let text) = row.content
                else { return nil }
                return UIAction(title: String(text.prefix(50))) { [weak self] _ in
                    self?.scrollTo(id: id)
                }
            }
            guard !prompts.isEmpty else { return completion([]) }
            completion([
                UIMenu(
                    title: "Jump to message", image: UIImage(systemName: "list.bullet"),
                    children: Array(prompts.suffix(20)))
            ])
        }
        let usage = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, let usage = await self.viewModel.usage() else { return completion([]) }
                var parts: [String] = []
                if let tokens = usage.tokens {
                    parts.append("\(tokens.formatted(.number.notation(.compactName))) tokens")
                }
                if let cost = usage.costUSD {
                    parts.append(String(format: "$%.3f", cost))
                }
                guard !parts.isEmpty else { return completion([]) }
                let item = UIAction(
                    title: parts.joined(separator: " · "),
                    image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent"),
                    attributes: .disabled
                ) { _ in }
                completion([item])
            }
        }
        var children: [UIMenuElement] = [jump, usage]
        if viewModel.canClear {
            children.append(
                UIAction(
                    title: "Clear conversation", image: UIImage(systemName: "eraser"),
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmClear() })
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: children))
    }

    private func scrollTo(id: String) {
        guard let index = dataSource.snapshot().indexOfItem(id) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .top, animated: true)
        Theme.Haptics.selection()
    }

    private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear conversation?",
            message: "This starts a fresh conversation on the agent.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            self?.viewModel.clearConversation()
        })
        present(alert, animated: true)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    private func modelBarButton() -> UIBarButtonItem {
        let icon = UIImage(systemName: "cpu")
        let item: UIBarButtonItem
        if availableModels.count <= 12 {
            let current = viewModel.selectedModel
            let actions = availableModels.map { model in
                UIAction(
                    title: model.name,
                    state: current?.modelID == model.id && current?.providerID == model.providerID
                        ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.viewModel.selectModel(model.selection)
                    self?.updateNavControls()
                }
            }
            item = UIBarButtonItem(image: icon, menu: UIMenu(title: "Model", children: actions))
        } else {
            item = UIBarButtonItem(
                image: icon, style: .plain, target: self, action: #selector(presentModelPicker))
        }
        item.isEnabled = !availableModels.isEmpty
        return item
    }

    private func effortBarButton() -> UIBarButtonItem {
        let current = viewModel.currentEffort
        let actions = viewModel.reasoningEffortOptions.map { level in
            UIAction(
                title: level.capitalized,
                state: current == level ? .on : .off
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.viewModel.setEffort(level)
                self?.updateNavControls()
            }
        }
        let menu = UIMenu(title: "Reasoning effort", children: actions)
        return UIBarButtonItem(
            image: UIImage(systemName: "gauge.with.dots.needle.50percent"), menu: menu)
    }

    @objc private func presentModelPicker() {
        guard !availableModels.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(
            models: availableModels, selected: viewModel.selectedModel
        ) { [weak self] selection in
            self?.viewModel.selectModel(selection)
            self?.updateNavControls()
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Folds consecutive agent actions (thinking + tools) into one `.activity` row; text and files
    /// break the group and render on their own.
    private static func makeRows(from messages: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        for message in messages {
            var steps: [ActivityStep] = []
            var groupID: String?

            func flushActivity() {
                guard !steps.isEmpty, let groupID else { return }
                rows.append(
                    ChatRow(
                        id: "\(message.id):activity:\(groupID)", messageID: message.id,
                        role: message.role, content: .activity(steps)))
                steps = []
            }

            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                switch part.kind {
                case .reasoning(let text):
                    if text.isEmpty { continue }
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.reasoning(text))
                case .tool(let call):
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.tool(call))
                case .text(let text):
                    flushActivity()
                    if text.isEmpty { continue }
                    if message.role == .user {
                        rows.append(
                            ChatRow(id: id, messageID: message.id, role: message.role, content: .text(text)))
                    } else {
                        let segments = MessageSegment.split(text)
                        for (index, segment) in segments.enumerated() {
                            let segID = segments.count == 1 ? id : "\(id):seg\(index)"
                            let content: ChatRow.Content
                            switch segment {
                            case .text(let value): content = .text(value)
                            case .code(let block): content = .code(block)
                            }
                            rows.append(
                                ChatRow(id: segID, messageID: message.id, role: message.role, content: content))
                        }
                    }
                case .file(let file):
                    flushActivity()
                    rows.append(
                        ChatRow(id: id, messageID: message.id, role: message.role, content: .file(file)))
                case .unknown:
                    continue
                }
            }
            flushActivity()
        }
        return fuseActivity(rows)
    }

    /// Merges any adjacent activity rows into one, so a run of thinking/tool steps (even across
    /// message boundaries) reads as a single collapsible group.
    private static func fuseActivity(_ rows: [ChatRow]) -> [ChatRow] {
        var merged: [ChatRow] = []
        for row in rows {
            if case .activity(let steps) = row.content, let last = merged.last,
                case .activity(let prior) = last.content
            {
                merged[merged.count - 1] = ChatRow(
                    id: last.id, messageID: last.messageID, role: last.role,
                    content: .activity(prior + steps))
            } else {
                merged.append(row)
            }
        }
        return merged
    }

    private func isNearBottom() -> Bool {
        let offsetY = collectionView.contentOffset.y
        let height = collectionView.contentSize.height
        let visible = collectionView.bounds.height
        return height <= visible || offsetY > height - visible - 120
    }

    private func scrollToBottom(animated: Bool) {
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        let indexPath = IndexPath(item: count - 1, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension ChatViewController: ComposerViewDelegate {
    func composerDidSend(_ text: String) {
        let attachments = pendingAttachments
        pendingAttachments = []
        composer.showsAttach = viewModel.supportsAttachments
        viewModel.send(text, attachments: attachments)
    }

    func composerDidRequestSendOptions(from view: UIView) {
        let text = composer.currentText
        guard !text.isEmpty else { return }
        let sheet = UIAlertController(
            title: "Send this message with…", message: nil, preferredStyle: .actionSheet)
        for model in availableModels.prefix(8) {
            sheet.addAction(
                UIAlertAction(title: model.name, style: .default) { [weak self] _ in
                    Theme.Haptics.send()
                    self?.viewModel.send(text, model: model.selection)
                    self?.composer.clear()
                })
        }
        for level in viewModel.reasoningEffortOptions {
            sheet.addAction(
                UIAlertAction(title: "\(level.capitalized) effort", style: .default) { [weak self] _ in
                    Theme.Haptics.send()
                    self?.viewModel.send(text, effort: level)
                    self?.composer.clear()
                })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    func composerDidTapStop() {
        Theme.Haptics.tap()
        viewModel.abort()
    }

    func composerDidBeginEditing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scrollToBottom(animated: true)
        }
    }

    func composerDidTapAttach() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension ChatViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
            provider.canLoadObject(ofClass: UIImage.self)
        else { return }
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.pendingAttachments.append(
                    PromptAttachment(mime: "image/jpeg", filename: "image.jpg", data: data))
                self?.presentAttachmentToast()
            }
        }
    }

    private func presentAttachmentToast() {
        Theme.Haptics.success()
        let toast = UIAlertController(
            title: nil, message: "Image attached — it'll be sent with your next message.",
            preferredStyle: .actionSheet)
        toast.addAction(UIAlertAction(title: "OK", style: .default))
        toast.popoverPresentationController?.sourceView = composer
        present(toast, animated: true)
    }
}

extension ChatViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let id = dataSource.itemIdentifier(for: indexPath), id != typingID,
            let text = messageText(for: id), !text.isEmpty
        else { return nil }

        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var actions: [UIAction] = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                    Theme.Haptics.success()
                }
            ]
            if let code = Self.firstCodeBlock(in: text) {
                actions.append(
                    UIAction(title: "Copy code", image: UIImage(systemName: "curlybraces")) { _ in
                        UIPasteboard.general.string = code
                        Theme.Haptics.success()
                    })
            }
            actions.append(
                UIAction(title: "Quote", image: UIImage(systemName: "quote.opening")) { _ in
                    self?.composer.insertQuote(text)
                })
            actions.append(
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self?.shareText(text)
                })
            return UIMenu(children: actions)
        }
    }

    private func messageText(for id: String) -> String? {
        guard let row = rowsByID[id] else { return nil }
        switch row.content {
        case .text(let text):
            return text
        case .code(let block):
            return block.source
        case .activity(let steps):
            return steps.map { step in
                switch step {
                case .reasoning(let text): return text
                case .tool(let call): return call.output ?? call.title ?? call.name
                }
            }.joined(separator: "\n\n")
        case .file(let file):
            return file.filename ?? file.mime
        }
    }

    private func shareText(_ text: String) {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private static func firstCodeBlock(in text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        var block = parts[1]
        if let newline = block.firstIndex(of: "\n") {
            block = String(block[block.index(after: newline)...])
        }
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
