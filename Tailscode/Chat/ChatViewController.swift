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
    private var isPresentingPermission = false
    private var availableModels: [ModelInfo] = []
    private var expandedReasoning: Set<String> = []

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
        bind()
        viewModel.start()
        if viewModel.supportsModelSelection { Task { await loadModels() } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            viewModel.stop()
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
        collectionView.register(TextBubbleCell.self, forCellWithReuseIdentifier: TextBubbleCell.reuseID)
        collectionView.register(ToolCallCell.self, forCellWithReuseIdentifier: ToolCallCell.reuseID)
        collectionView.register(ReasoningCell.self, forCellWithReuseIdentifier: ReasoningCell.reuseID)

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
            collectionView.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
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
            guard let row = self.rowsByID[id] else { return UICollectionViewCell() }
            switch row.content {
            case .tool(let call):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ToolCallCell.reuseID, for: indexPath) as! ToolCallCell
                cell.configure(tool: call)
                return cell
            case .text(let text):
                return self.bubble(collectionView, indexPath, text, row.role, reasoning: false)
            case .reasoning(let text):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ReasoningCell.reuseID, for: indexPath) as! ReasoningCell
                let streaming = self.viewModel.isBusy && id == self.orderedIDs.last
                cell.configure(
                    text: text, expanded: self.expandedReasoning.contains(id), streaming: streaming
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
        viewModel.onError = { [weak self] message in self?.presentError(message) }
    }

    private func render(_ state: ConversationState) {
        let rows = Self.makeRows(from: state.messages)
        let previous = rowsByID
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedIDs = rows.map(\.id)

        let showTyping =
            state.status == .running && (rows.last?.role != .assistant)
        var ids = orderedIDs
        if showTyping { ids.append(typingID) }
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
        updateBanner(for: state)
        handlePermissions(state)
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

    private func handlePermissions(_ state: ConversationState) {
        guard !isPresentingPermission, let permission = state.pendingPermissions.first else { return }
        isPresentingPermission = true
        Theme.Haptics.warning()
        let title = permission.toolName.map { "Allow \($0)?" } ?? "Permission requested"
        let alert = UIAlertController(
            title: title, message: permission.title, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Allow once", style: .default) { [weak self] _ in
            self?.viewModel.respond(to: permission, decision: .once)
            self?.isPresentingPermission = false
        })
        alert.addAction(UIAlertAction(title: "Always allow", style: .default) { [weak self] _ in
            self?.viewModel.respond(to: permission, decision: .always)
            self?.isPresentingPermission = false
        })
        alert.addAction(UIAlertAction(title: "Deny", style: .destructive) { [weak self] _ in
            self?.viewModel.respond(to: permission, decision: .reject)
            self?.isPresentingPermission = false
        })
        present(alert, animated: true)
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
        updateModelButton()
    }

    private func updateModelButton() {
        let current = viewModel.selectedModel?.modelID ?? "Model"
        let actions = availableModels.prefix(40).map { model in
            UIAction(
                title: model.id,
                state: viewModel.selectedModel?.modelID == model.id ? .on : .off
            ) { [weak self] _ in
                self?.viewModel.selectedModel = model.selection
                self?.updateModelButton()
            }
        }
        let menu = UIMenu(title: "Model", children: Array(actions))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: current, menu: menu)
    }

    private static func makeRows(from messages: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        for message in messages {
            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                let content: ChatRow.Content
                switch part.kind {
                case .text(let text):
                    if text.isEmpty { continue }
                    content = .text(text)
                case .reasoning(let text):
                    if text.isEmpty { continue }
                    content = .reasoning(text)
                case .tool(let call):
                    content = .tool(call)
                case .file(let file):
                    content = .file(file)
                case .unknown:
                    continue
                }
                rows.append(
                    ChatRow(id: id, messageID: message.id, role: message.role, content: content))
            }
        }
        return rows
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
