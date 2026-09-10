import CodingAgentKit
import PhotosUI
import TailscodeCore
import UIKit
import UniformTypeIdentifiers

/// Asking for a picture, and everything that happens to it afterwards.
///
/// This is an app inside the app rather than a button that makes a file appear somewhere: the
/// picture is the room, what it cost is stated under it, and the verbs that get it out — into
/// Photos, onto the pasteboard, full size, rolled again, or used as the reference the next render
/// starts from — sit where the hand already is. Every picture made this session stays, because a
/// render is a thing you compare against the words that made it.
///
/// The render itself is `ImageStudio`'s, not this screen's: backing out closes a screen, and
/// coming back finds the same picture exactly where it was.
@MainActor
final class ImageStudioViewController: UIViewController {
    private enum Item: Hashable {
        case stage
        case facts
        case actions
        case dismissNote
        case machineNote
        case history
    }

    private let studio = ImageStudio.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>!

    private let dock = Theme.Glass.view()
    private let chipRow = UIStackView()
    private let promptView = UITextView()
    private let placeholder = UILabel()
    private let renderButton = UIButton(type: .system)
    private var promptHeight: NSLayoutConstraint!
    private var appliedChips: String?

    private var slot: ImageGenSlot { studio.slot }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ImageGenSurface.title
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ImageGenSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        configureCollectionView()
        configureDock()
        configureDataSource()
        NotificationCenter.default.addObserver(
            self, selector: #selector(studioDidChange), name: ImageStudio.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(studioDidChange), name: ImageGenStore.didChange, object: nil)
        setPrompt(slot.promptDraft)
        apply(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        studio.adoptDoor()
        studio.checkMachine()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        studio.rememberDraft(promptView.text ?? "")
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.headerMode = .none
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.readableList(
                using: configuration))
        collectionView.backgroundColor = .clear
        collectionView.contentInset.bottom = Theme.Spacing.m
        collectionView.keyboardDismissMode = .interactive
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
    }

    /// The prompt, the two decisions the picture is made from, and the one control that starts or
    /// stops the render — all on the keyboard's own edge, because composing a picture is typing
    /// with two settings beside it rather than filling in a form.
    private func configureDock() {
        dock.translatesAutoresizingMaskIntoConstraints = false
        chipRow.axis = .horizontal
        chipRow.spacing = Theme.Spacing.xs
        chipRow.alignment = .center
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        promptView.backgroundColor = Theme.Color.codeBackground
        promptView.layer.cornerRadius = Theme.Radius.control
        promptView.layer.cornerCurve = .continuous
        promptView.font = Theme.Ramp.font(.composer)
        promptView.textColor = Theme.Color.label
        promptView.delegate = self
        promptView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        promptView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.numberOfLines = 1
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        promptView.addSubview(placeholder)

        renderButton.translatesAutoresizingMaskIntoConstraints = false
        renderButton.addAction(
            UIAction { [weak self] _ in self?.renderTapped() }, for: .touchUpInside)

        view.addSubview(dock)
        dock.contentView.addSubview(chipRow)
        dock.contentView.addSubview(promptView)
        dock.contentView.addSubview(renderButton)
        promptHeight = promptView.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: dock.topAnchor),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            chipRow.topAnchor.constraint(
                equalTo: dock.contentView.topAnchor, constant: Theme.Spacing.s),
            chipRow.leadingAnchor.constraint(
                equalTo: dock.contentView.leadingAnchor, constant: Theme.Spacing.l),
            chipRow.trailingAnchor.constraint(
                lessThanOrEqualTo: dock.contentView.trailingAnchor, constant: -Theme.Spacing.l),
            promptView.topAnchor.constraint(
                equalTo: chipRow.bottomAnchor, constant: Theme.Spacing.s),
            promptView.leadingAnchor.constraint(
                equalTo: dock.contentView.leadingAnchor, constant: Theme.Spacing.l),
            promptView.bottomAnchor.constraint(
                equalTo: dock.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            promptHeight,
            renderButton.leadingAnchor.constraint(
                equalTo: promptView.trailingAnchor, constant: Theme.Spacing.s),
            renderButton.trailingAnchor.constraint(
                equalTo: dock.contentView.trailingAnchor, constant: -Theme.Spacing.l),
            renderButton.bottomAnchor.constraint(equalTo: promptView.bottomAnchor),
            placeholder.leadingAnchor.constraint(
                equalTo: promptView.leadingAnchor, constant: 13),
            placeholder.topAnchor.constraint(equalTo: promptView.topAnchor, constant: 10),
        ])
        updateChips()
        updateRenderButton()
        updatePlaceholder()
    }

    private func configureDataSource() {
        let stage = UICollectionView.CellRegistration<ImageStageCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let picture = self.slot.onStage
            cell.apply(
                ImageStageReading(
                    slot: self.slot, picture: picture,
                    image: picture.flatMap { self.studio.image(of: $0) },
                    startedAt: self.studio.startedAt))
            cell.onOpen = { [weak self] in self?.openStage() }
        }
        let facts = UICollectionView.CellRegistration<ImageFactsCell, Item> {
            [weak self] cell, _, _ in
            guard let picture = self?.slot.onStage else { return }
            cell.apply(picture)
        }
        let actions = UICollectionView.CellRegistration<ImageActionsCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(holding: self.slot.reference != nil)
            cell.onAction = { [weak self] action in self?.perform(action) }
        }
        let note = UICollectionView.CellRegistration<ForgeNoteCell, Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .dismissNote:
                guard let words = ImageGenSurface.dismissNote(painting: self.studio.isPainting)
                else { return }
                cell.apply(words, tone: .quiet)
            default:
                cell.apply(self.machineWords(), tone: self.studio.door.tone ?? .quiet)
            }
        }
        let history = UICollectionView.CellRegistration<ImageHistoryCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let thumbnails = self.slot.pictures.reduce(into: [String: UIImage]()) { seen, picture in
                seen[picture.path] = self.studio.image(of: picture)
            }
            cell.apply(
                pictures: self.slot.pictures, current: self.slot.onStage?.path,
                thumbnails: thumbnails)
            cell.onPick = { [weak self] path in
                Theme.Haptics.selection()
                self?.studio.show(path)
            }
        }
        dataSource = UICollectionViewDiffableDataSource<String, Item>(
            collectionView: collectionView
        ) { view, indexPath, item in
            switch item {
            case .stage:
                return view.dequeueConfiguredReusableCell(using: stage, for: indexPath, item: item)
            case .facts:
                return view.dequeueConfiguredReusableCell(using: facts, for: indexPath, item: item)
            case .actions:
                return view.dequeueConfiguredReusableCell(
                    using: actions, for: indexPath, item: item)
            case .dismissNote, .machineNote:
                return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            case .history:
                return view.dequeueConfiguredReusableCell(
                    using: history, for: indexPath, item: item)
            }
        }
    }

    @objc private func studioDidChange() {
        apply(animated: true)
        updateChips()
        updateRenderButton()
        updatePlaceholder()
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections(["studio"])
        var items: [Item] = [.stage]
        if slot.onStage != nil, !studio.isPainting {
            items.append(.facts)
            items.append(.actions)
        }
        if studio.isPainting { items.append(.dismissNote) }
        if slot.pictures.count > 1 { items.append(.history) }
        items.append(.machineNote)
        snapshot.appendItems(items)
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// Where the work happens, and anything the machine last said that a reader would want to know
    /// before pressing render. Nothing at all about a machine nobody has looked at yet.
    private func machineWords() -> String {
        [studio.door.line, ImageGenSurface.subtitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func updateChips() {
        let identity = ImageGenField.allCases.map { "\($0.rawValue)=\(slot.value(of: $0))" }
            .joined(separator: "|") + "|\(slot.reference?.chip ?? "-")|\(slot.isBusy)"
        guard identity != appliedChips else { return }
        appliedChips = identity
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for field in ImageGenField.allCases {
            chipRow.addArrangedSubview(chip(for: field))
        }
        chipRow.addArrangedSubview(referenceChip())
    }

    private func chip(for field: ImageGenField) -> UIButton {
        let button = ImageChip.button(symbol: field.symbol, title: slot.value(of: field))
        button.isEnabled = !slot.isBusy
        button.accessibilityLabel = "\(field.label), \(slot.value(of: field))"
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(field)
            }, for: .touchUpInside)
        button.menu = ImageChip.menu(
            for: field, slot: slot,
            onEngine: { [weak self] engine in self?.studio.choose(engine: engine) },
            onAspect: { [weak self] aspect in self?.studio.choose(aspect: aspect) })
        return button
    }

    /// Attaching a picture is the whole of asking for an edit, so this control is never a switch:
    /// it holds one or it does not, and what it says is which.
    private func referenceChip() -> UIButton {
        let holding = slot.reference
        let button = ImageChip.button(
            symbol: holding == nil ? "photo.badge.plus" : "photo.fill",
            title: holding?.chip ?? ImageGenWords.attachTitle)
        button.isEnabled = !slot.isBusy
        button.accessibilityLabel = holding.map(ImageGenWords.referenceHint) ?? ImageGenWords
            .attachTitle
        button.accessibilityHint = holding == nil ? nil : ImageGenWords.detachHint
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                if self.slot.reference == nil {
                    self.presentReferencePicker()
                } else {
                    self.studio.hold(nil)
                }
            }, for: .touchUpInside)
        return button
    }

    /// One control, two meanings, and it says which it is: a render out is stopped from the same
    /// place it was started, because a person who wants it to end should not have to find another
    /// button to end it with.
    private func updateRenderButton() {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.cornerStyle = .capsule
        config.image = UIImage(
            systemName: studio.isPainting ? "stop.fill" : ImageGenEntryPoint.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = Theme.Spacing.xs
        var title = AttributedString(
            studio.isPainting ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode))
        title.font = Theme.Ramp.font(.control)
        config.attributedTitle = title
        renderButton.configuration = config
        renderButton.isEnabled =
            studio.isPainting || !(promptView.text ?? "").trimmed().isEmpty
        renderButton.accessibilityLabel = studio.isPainting
            ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode)
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !(promptView.text ?? "").isEmpty
        placeholder.attributedText = NSAttributedString(
            string: slot.hint,
            attributes: Theme.Ramp.attributes(.composer, color: Theme.Color.tertiaryLabel))
    }

    /// Words put in the box by anything other than a keystroke still owe the box its own three
    /// answers: whether the hint is still showing, whether the render control is live, and how
    /// tall the box has to be to hold them.
    private func setPrompt(_ words: String) {
        promptView.text = words
        updatePlaceholder()
        updateRenderButton()
        grow()
    }

    /// The box is as tall as what is in it, up to four lines, after which it scrolls — a prompt
    /// worth two sentences must not be typed into a slot that shows one line of it.
    private func grow() {
        guard promptView.bounds.width > 0 else { return }
        let fitted = promptView.sizeThatFits(
            CGSize(width: promptView.bounds.width, height: .greatestFiniteMagnitude))
        let height = min(max(44, fitted.height), 132)
        guard abs(height - promptHeight.constant) > 0.5 else { return }
        promptHeight.constant = height
        view.layoutIfNeeded()
    }

    private func renderTapped() {
        guard !studio.isPainting else {
            Theme.Haptics.tap()
            studio.stop()
            return
        }
        let words = (promptView.text ?? "").trimmed()
        guard !words.isEmpty else { return }
        Theme.Haptics.send()
        view.endEditing(true)
        studio.submit(prompt: words)
    }

    private func openStage() {
        guard let picture = slot.onStage, let payload = studio.payload(of: picture) else { return }
        Theme.Haptics.tap()
        present(viewer(for: picture, payload: payload), animated: true)
    }

    /// Full size is the chat's own gallery, because a picture this app made deserves the same zoom,
    /// the same Live Text and the same ways out as one the agent handed over. There is no server
    /// behind these: the bytes are already on this device.
    private func viewer(for picture: ImageGenPicture, payload: ImagePayload)
        -> ImageViewerViewController
    {
        let items = slot.pictures.map { made in
            GalleryImage(
                id: made.path,
                file: FileReference(
                    path: made.path, mime: "image/png", url: "file://" + made.path,
                    filename: ImageGenFacts.fileName(for: made)),
                localData: FileManager.default.contents(atPath: made.path))
        }
        let start = slot.pictures.firstIndex(where: { $0.path == picture.path }) ?? 0
        return ImageViewerViewController(
            items: items, startIndex: start, backend: nil, from: nil)
    }

    private func perform(_ action: ImageGenAction) {
        guard let picture = slot.onStage else { return }
        switch action {
        case .save:
            save(picture)
        case .copy:
            guard let payload = studio.payload(of: picture) else { return }
            ImageExport.copy(payload)
            Theme.Haptics.success()
            notice(ImageGenWords.copiedNotice)
        case .open:
            openStage()
        case .again:
            Theme.Haptics.send()
            studio.again()
        case .reference:
            Theme.Haptics.selection()
            studio.hold(ImageGenReference(path: picture.path))
        case .discard:
            Theme.Haptics.tap()
            studio.discard(picture.path)
            notice(ImageGenWords.discardNotice)
        }
    }

    /// Saving on a phone means the photo library, which is where a picture a person made goes —
    /// and it hands over the bytes the machine wrote rather than a re-encode of what is on screen.
    private func save(_ picture: ImageGenPicture) {
        guard let payload = studio.payload(of: picture) else { return }
        Task { [weak self] in
            switch await ImageExport.saveToPhotos(payload) {
            case .saved:
                Theme.Haptics.success()
                self?.notice(String(localized: "Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self?.notice(
                    String(localized: "Allow photo access in Settings to save pictures."))
            case .failed:
                Theme.Haptics.error()
                self?.notice(String(localized: "Couldn't save to Photos"))
            }
        }
    }

    private func presentReferencePicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func notice(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor)
    }
}

extension ImageStudioViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        updateRenderButton()
        grow()
    }
}

extension ImageStudioViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let name = provider.suggestedName
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
            [weak self] data, _ in
            guard let data else { return }
            let kind = ImageBytes.kind(of: data)
            Task { @MainActor in
                self?.studio.hold(
                    data: data, named: "\(name ?? "reference").\(kind.ext)")
            }
        }
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
