import CodingAgentKit
import TailscodeCore
import UIKit

/// Asking for a picture, and everything that happens to it afterwards.
///
/// This is an app inside the app rather than a button that makes a file appear somewhere: the
/// picture is the room, what it cost is stated under it, the verbs that get it out — into Photos,
/// to another app, onto the pasteboard, rolled again, or used as the reference the next render
/// starts from — sit where the hand already is, and under all of it is the shelf: every picture
/// the machine keeps, whoever made it, newest first, with the one on the stage marked. A render
/// made here is simply the newest thing on that shelf.
///
/// The render itself is `ImageStudio`'s, not this screen's: backing out closes a screen, and
/// coming back finds the same picture exactly where it was.
@MainActor
final class ImageStudioViewController: UIViewController {
    private enum Section: Hashable {
        case stage
        case details
        case library
    }

    private enum Item: Hashable {
        case stage
        case caption
        case actions
        case dismissNote
        case setup
        case libraryState
        case tile(String)
    }

    private let studio = ImageStudio.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let refresher = UIRefreshControl()
    private let machineButton = UIButton(type: .system)

    private let dock = Theme.Glass.view()
    private let chipRow = UIStackView()
    private let promptView = UITextView()
    private let placeholder = UILabel()
    private let renderButton = UIButton(type: .system)
    private var promptHeight: NSLayoutConstraint!
    private var appliedChips: String?
    private var intake: ImageReferenceIntake!
    private var wasPainting = false
    private var loadingOriginal: String?
    private var shownExhibitID: String?

    private var slot: ImageGenSlot { studio.slot }
    private var library: ImageLibrary { studio.library }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ImageGenSurface.title
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ImageGenSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        configureMachineControl()
        intake = ImageReferenceIntake(presenter: self, studio: studio) { [weak self] in
            self?.presentLibraryPicker()
        }
        configureCollectionView()
        configureDock()
        configureDataSource()
        for name in [ImageStudio.didChange, ImageGenStore.didChange, ForgeStore.didChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(studioDidChange), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(progressDidChange), name: ImageStudio.progressDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange), name: ImageLibrary.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidChange(_:)), name: ImageLibrary.itemDidChange,
            object: nil)
        wasPainting = studio.isPainting
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
        library.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["TAILSCODE_IMAGE_MACHINE"] != nil, presentedViewController == nil {
                presentMachine()
            }
            if environment["TAILSCODE_IMAGE_SCROLL"] == "library" {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, let first = self.library.items.first,
                        let path = self.dataSource.indexPath(for: .tile(first.id))
                    else { return }
                    self.collectionView.scrollToItem(at: path, at: .top, animated: true)
                }
            }
        #endif
    }

    /// The machine lives in the bar: one control wearing the door's tone that opens the sheet, and
    /// — where the bar can carry a second line — what the machine last said about itself under
    /// the title, so a reader knows before the first send whether it is ready and for what.
    private func configureMachineControl() {
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        machineButton.configuration = config
        machineButton.addAction(UIAction { [weak self] _ in self?.presentMachine() }, for: .touchUpInside)
        machineButton.accessibilityHint = ImageGenMachineWords.title
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: machineButton)
        updateMachineControl()
    }

    private func updateMachineControl() {
        let door = studio.door
        let sighting = door.currentSighting
        let tone = door.tone
        var config = machineButton.configuration ?? .plain()
        config.image = UIImage(
            systemName: tone == nil
                ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseForegroundColor = tone == .attention ? Theme.Color.warning : Theme.Color.accent
        machineButton.configuration = config
        machineButton.isHidden = !door.isOpen
        let summary = ImageGenMachineWords.summary(sighting)
        let words = [studio.endpoint.shortName, summary, sighting?.version.map { "ComfyUI \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        machineButton.accessibilityLabel = words
        if #available(iOS 26.0, *) {
            navigationItem.subtitle = door.isOpen ? words : nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        studio.rememberDraft(promptView.text ?? "")
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else {
                return ImageStudioLayout.rows(environment: environment)
            }
            switch section {
            case .stage, .details:
                return ImageStudioLayout.rows(environment: environment)
            case .library:
                let items = self.dataSource.snapshot().itemIdentifiers(inSection: .library)
                if items.contains(.libraryState) {
                    return ImageStudioLayout.rows(environment: environment, header: true)
                }
                return ImageStudioLayout.grid(environment: environment, header: true)
            }
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInset.bottom = Theme.Spacing.m
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        refresher.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        collectionView.refreshControl = refresher
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

        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.addSubview(chipRow)

        view.addSubview(dock)
        dock.contentView.addSubview(chipScroll)
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
            chipScroll.topAnchor.constraint(
                equalTo: dock.contentView.topAnchor, constant: Theme.Spacing.s),
            chipScroll.leadingAnchor.constraint(equalTo: dock.contentView.leadingAnchor),
            chipScroll.trailingAnchor.constraint(equalTo: dock.contentView.trailingAnchor),
            chipScroll.heightAnchor.constraint(equalTo: chipRow.heightAnchor),
            chipRow.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipRow.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipRow.leadingAnchor.constraint(
                equalTo: chipScroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            chipRow.trailingAnchor.constraint(
                equalTo: chipScroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            promptView.topAnchor.constraint(
                equalTo: chipScroll.bottomAnchor, constant: Theme.Spacing.s),
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
            cell.apply(self.stageReading(), ceiling: self.view.bounds.height * 0.5)
            cell.onOpen = { [weak self] in self?.openStage() }
        }
        let caption = UICollectionView.CellRegistration<ImageCaptionCell, Item> {
            [weak self] cell, _, _ in
            guard let self, let exhibit = self.studio.exhibit else { return }
            switch exhibit {
            case .made(let picture):
                cell.apply(
                    caption: ImageGenFacts.caption(for: picture),
                    facts: ImageGenFacts.line(for: picture), note: nil, known: true)
            case .kept(let item):
                let facts = self.library.facts(of: item)
                cell.apply(
                    caption: ImageGenFacts.caption(for: facts), facts: ImageGenFacts.line(for: facts),
                    note: facts == nil ? nil : ImageGenWords.keptNote,
                    known: facts?.recipe?.prompt?.isEmpty == false)
            }
        }
        let actions = UICollectionView.CellRegistration<ImageActionsCell, Item> {
            [weak self] cell, _, _ in
            guard let self, let exhibit = self.studio.exhibit else { return }
            cell.apply(
                self.actions(for: exhibit), referenceHeld: self.studio.isReference(exhibit),
                busy: self.studio.isPainting)
            cell.onAction = { [weak self] action in self?.perform(action) }
        }
        let note = UICollectionView.CellRegistration<ForgeNoteCell, Item> { [weak self] cell, _, _ in
            guard let self, let words = ImageGenSurface.dismissNote(painting: self.studio.isPainting)
            else { return }
            cell.apply(words, tone: .quiet)
        }
        let setup = UICollectionView.CellRegistration<ImageSetupCell, Item> { [weak self] cell, _, _ in
            cell.apply()
            cell.onSetup = { [weak self] in self?.presentSetup() }
        }
        let state = UICollectionView.CellRegistration<ImageLibraryStateCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(self.library.state)
        }
        let tile = UICollectionView.CellRegistration<ImageTileCell, Item> { [weak self] cell, _, item in
            guard let self, case .tile(let id) = item, let kept = self.library.item(named: id) else {
                return
            }
            cell.apply(kept, library: self.library, onStage: self.studio.exhibit?.libraryID == id)
        }
        let header = UICollectionView.SupplementaryRegistration<ImageLibraryHeader>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            guard let self else { return }
            view.apply(
                machine: self.library.machine, line: self.library.line,
                loading: self.library.state == .loading)
            view.onRefresh = { [weak self] in
                Theme.Haptics.tap()
                self?.library.refresh()
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { view, indexPath, item in
            switch item {
            case .stage: return view.dequeueConfiguredReusableCell(using: stage, for: indexPath, item: item)
            case .caption:
                return view.dequeueConfiguredReusableCell(using: caption, for: indexPath, item: item)
            case .actions:
                return view.dequeueConfiguredReusableCell(using: actions, for: indexPath, item: item)
            case .dismissNote:
                return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            case .setup: return view.dequeueConfiguredReusableCell(using: setup, for: indexPath, item: item)
            case .libraryState:
                return view.dequeueConfiguredReusableCell(using: state, for: indexPath, item: item)
            case .tile: return view.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// What the stage is told. A kept picture whose original is not here yet shows its tile while
    /// the bytes come, and asks for them once.
    private func stageReading() -> ImageStageReading {
        let exhibit = studio.exhibit
        var image: UIImage?
        var placeholder: UIImage?
        var ratio = CGFloat(slot.aspect.pixels.height) / CGFloat(slot.aspect.pixels.width)
        switch exhibit {
        case .made(let picture):
            image = studio.image(of: picture)
            ratio = CGFloat(picture.aspect.pixels.height) / CGFloat(picture.aspect.pixels.width)
        case .kept(let item):
            image = studio.image(of: item)
            placeholder = library.cachedThumbnail(of: item)
            if let facts = library.facts(of: item), let width = facts.width, let height = facts.height,
                width > 0
            {
                ratio = CGFloat(height) / CGFloat(width)
            } else if let shown = image ?? placeholder, shown.size.width > 0 {
                ratio = shown.size.height / shown.size.width
            }
            if image == nil { fetchOriginal(of: item) }
            library.describe(item)
        case nil:
            break
        }
        if let image, image.size.width > 0 { ratio = image.size.height / image.size.width }
        let caption: String?
        switch exhibit {
        case .made(let picture): caption = ImageGenFacts.caption(for: picture)
        case .kept(let item): caption = library.facts(of: item).map(ImageGenFacts.caption(for:))
        case nil: caption = nil
        }
        return ImageStageReading(
            slot: slot, exhibit: exhibit, image: image, placeholder: placeholder, ratio: ratio,
            caption: caption, startedAt: studio.startedAt, progress: studio.progress)
    }

    private func fetchOriginal(of item: ImageGenLibraryItem) {
        guard loadingOriginal != item.id else { return }
        loadingOriginal = item.id
        Task { [weak self] in
            _ = await self?.studio.payload(of: item)
            guard let self else { return }
            if self.loadingOriginal == item.id { self.loadingOriginal = nil }
            self.reconfigure([.stage, .caption, .actions])
        }
    }

    private func actions(for exhibit: ImageExhibit) -> [ImageGenAction] {
        switch exhibit {
        case .made:
            return ImageGenAction.offered(kept: false, hasWords: true, sharing: true, tapOpens: true)
                .filter { $0 != .discard }
        case .kept(let item):
            let words = library.facts(of: item)?.recipe?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ImageGenAction.offered(
                kept: true, hasWords: !(words ?? "").isEmpty, sharing: true, tapOpens: true)
        }
    }

    @objc private func studioDidChange() {
        let landed = wasPainting && !studio.isPainting && slot.failure == nil
        wasPainting = studio.isPainting
        apply(animated: true)
        updateChips()
        updateRenderButton()
        updatePlaceholder()
        updateMachineControl()
        if landed { scrollToStage() }
    }

    @objc private func progressDidChange() {
        guard let path = dataSource.indexPath(for: .stage),
            let cell = collectionView.cellForItem(at: path) as? ImageStageCell
        else { return }
        cell.applyProgress(studio.progress, startedAt: studio.startedAt)
    }

    @objc private func libraryDidChange() {
        if library.state != .loading { refresher.endRefreshing() }
        apply(animated: true)
    }

    @objc private func itemDidChange(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String else { return }
        var items: [Item] = [.tile(id)]
        if studio.exhibit?.libraryID == id { items += [.stage, .caption, .actions] }
        reconfigure(items)
    }

    /// The stage is reconfigured in place because it holds a clock and a bar; the caption and the
    /// verbs are reloaded, because a reconfigured self-sizing row keeps the height it was first
    /// measured at and a caption that grew two lines was drawn as one.
    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        let resized = present.filter { $0 == .caption || $0 == .actions }
        if !resized.isEmpty { snapshot.reloadItems(resized) }
        snapshot.reconfigureItems(present.filter { !resized.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.stage, .details, .library])
        snapshot.appendItems([.stage], toSection: .stage)
        var details: [Item] = []
        if !studio.door.isOpen {
            details.append(.setup)
        } else if studio.exhibit != nil, !studio.isPainting, slot.failure == nil {
            details.append(.caption)
            details.append(.actions)
        }
        if studio.isPainting { details.append(.dismissNote) }
        snapshot.appendItems(details, toSection: .details)
        if library.items.isEmpty {
            snapshot.appendItems([.libraryState], toSection: .library)
        } else {
            snapshot.appendItems(library.items.map { .tile($0.id) }, toSection: .library)
        }
        var refresh: [Item] = [.stage, .dismissNote, .setup, .libraryState]
        let shown = studio.exhibit?.libraryID
        if shown != shownExhibitID {
            for id in [shown, shownExhibitID].compactMap({ $0 }) { refresh.append(.tile(id)) }
            shownExhibitID = shown
        }
        snapshot.reconfigureItems(refresh.filter { snapshot.indexOfItem($0) != nil })
        snapshot.reloadItems([Item.caption, .actions].filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: animated)
        collectionView.collectionViewLayout.invalidateLayout()
        if let header = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 2)) as? ImageLibraryHeader
        {
            header.apply(
                machine: library.machine, line: library.line, loading: library.state == .loading)
        }
    }

    private func scrollToStage() {
        guard let path = dataSource.indexPath(for: .stage) else { return }
        collectionView.scrollToItem(at: path, at: .top, animated: true)
    }

    private func pulled() {
        library.refresh()
        studio.checkMachine(force: true)
        if library.state != .loading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refresher.endRefreshing()
            }
        }
    }

    private func updateChips() {
        let sighting = studio.sighting
        let identity = ImageGenField.allCases.map { "\($0.rawValue)=\(slot.value(of: $0))" }
            .joined(separator: "|")
            + "|\(slot.reference?.chip ?? "-")|\(slot.isBusy)|\(slot.aspectApplies)|\(sighting?.readyEngines.map(\.rawValue).joined() ?? "?")|\(intake.available.count)"
        guard identity != appliedChips else { return }
        appliedChips = identity
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipRow.addArrangedSubview(engineChip(sighting: sighting))
        chipRow.addArrangedSubview(aspectChip())
        chipRow.addArrangedSubview(referenceChip())
    }

    private func engineChip(sighting: ImageGenSighting?) -> UIButton {
        let unavailable = slot.engineAvailable(given: sighting) == false
        let button = ImageChip.button(
            symbol: unavailable ? "exclamationmark.triangle" : ImageGenField.engine.symbol,
            title: slot.value(of: .engine))
        button.isEnabled = !slot.isBusy
        if unavailable { button.tintColor = Theme.Color.warning }
        button.accessibilityLabel = "\(ImageGenField.engine.label), \(slot.value(of: .engine))"
        if unavailable, let sighting {
            button.accessibilityValue = ImageGenWords.engineUnavailable(
                slot.engine, missing: sighting.missing(for: slot.engine).count)
        }
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.engine)
            }, for: .touchUpInside)
        button.menu = ImageChip.engineMenu(slot: slot, sighting: sighting) { [weak self] engine in
            Theme.Haptics.selection()
            self?.studio.choose(engine: engine)
        }
        return button
    }

    /// The aspect chip stands down while a reference is held: both editors take the size from the
    /// picture they start from, and a chip that changes nothing must not look like one that does.
    private func aspectChip() -> UIButton {
        guard slot.aspectApplies else {
            let button = ImageChip.button(
                symbol: ImageGenField.aspect.symbol, title: ImageGenWords.aspectFollowsReference)
            button.isEnabled = false
            button.accessibilityLabel = ImageGenWords.aspectFollowsReference
            return button
        }
        let button = ImageChip.button(
            symbol: ImageGenField.aspect.symbol, title: slot.value(of: .aspect))
        button.isEnabled = !slot.isBusy
        button.accessibilityLabel = "\(ImageGenField.aspect.label), \(slot.value(of: .aspect))"
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.aspect)
            }, for: .touchUpInside)
        button.menu = ImageChip.aspectMenu(slot: slot) { [weak self] aspect in
            Theme.Haptics.selection()
            self?.studio.choose(aspect: aspect)
        }
        return button
    }

    /// Attaching a picture is the whole of asking for an edit, so this control is never a switch:
    /// it holds one or it does not, wears the picture it holds, and opens the sources — or replace
    /// and remove — as a menu, because the doors are five and a phone has no tooltip to name them.
    private func referenceChip() -> UIButton {
        let holding = slot.reference
        let thumb = holding.flatMap { reference -> UIImage? in
            if let kept = reference.kept, let tile = library.cachedThumbnail(of: kept) { return tile }
            guard let data = FileManager.default.contents(atPath: reference.path),
                let image = UIImage(data: data)
            else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 60, height: 60)) ?? image
        }
        let button = ImageChip.button(
            symbol: holding == nil ? "photo.badge.plus" : "photo.fill",
            title: holding?.chip ?? ImageGenWords.attachTitle, image: thumb)
        button.isEnabled = !slot.isBusy
        button.accessibilityLabel = holding.map(ImageGenWords.referenceHint) ?? ImageGenWords.attachTitle
        button.accessibilityHint = holding == nil ? nil : ImageGenWords.detachHint
        button.menu = intake.menu(holding: holding)
        button.showsMenuAsPrimaryAction = true
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
        scrollToStage()
    }

    /// Full size is the chat's own gallery, because a picture this app made deserves the same zoom,
    /// the same Live Text and the same ways out as one the agent handed over — paged over the
    /// whole shelf, fetched from the machine as each page is reached.
    private func openStage() {
        guard let exhibit = studio.exhibit else { return }
        Theme.Haptics.tap()
        present(viewer(from: exhibit), animated: true)
    }

    private func viewer(from exhibit: ImageExhibit) -> ImageViewerViewController {
        let shelf = library
        let items = shelf.items
        let client = ImageGenClient(endpoint: studio.endpoint)
        if let target = exhibit.libraryID, let start = items.firstIndex(where: { $0.id == target }) {
            let pages = items.map { kept in
                GalleryImage(
                    id: kept.id,
                    file: FileReference(
                        path: kept.id, mime: kept.kind?.mime ?? "image/png",
                        url: client.viewURL(kept)?.absoluteString ?? "", filename: kept.filename),
                    localData: shelf.originalPath(of: kept).flatMap {
                        FileManager.default.contents(atPath: $0)
                    })
            }
            return ImageViewerViewController(
                items: pages, startIndex: start, backend: nil, from: nil
            ) { page in
                guard let kept = await shelf.item(named: page.id) else { return nil }
                return await shelf.original(of: kept)
            }
        }
        let pages = slot.pictures.map { made in
            GalleryImage(
                id: made.path,
                file: FileReference(
                    path: made.path, mime: "image/png", url: "file://" + made.path,
                    filename: ImageGenFacts.fileName(for: made)),
                localData: FileManager.default.contents(atPath: made.path))
        }
        let start = pages.firstIndex(where: { $0.id == exhibit.id }) ?? 0
        return ImageViewerViewController(items: pages, startIndex: start, backend: nil, from: nil)
    }

    private func perform(_ action: ImageGenAction) {
        guard let exhibit = studio.exhibit else { return }
        perform(action, on: exhibit)
    }

    private func perform(_ action: ImageGenAction, on exhibit: ImageExhibit) {
        switch action {
        case .save:
            Task { [weak self] in
                guard let payload = await self?.studio.payload(of: exhibit) else { return }
                await self?.save(payload)
            }
        case .share:
            Task { [weak self] in
                guard let self, let payload = await self.studio.payload(of: exhibit) else { return }
                self.share(payload)
            }
        case .copy:
            Task { [weak self] in
                guard let self, let payload = await self.studio.payload(of: exhibit) else { return }
                ImageExport.copy(payload)
                Theme.Haptics.success()
                self.notice(ImageGenWords.copiedNotice)
            }
        case .open:
            Theme.Haptics.tap()
            present(viewer(from: exhibit), animated: true)
        case .again:
            Theme.Haptics.send()
            if exhibit != studio.exhibit {
                switch exhibit {
                case .made(let picture): studio.show(picture.path)
                case .kept(let item): studio.show(kept: item)
                }
            }
            studio.again()
            scrollToStage()
        case .reference:
            Theme.Haptics.selection()
            switch exhibit {
            case .made(let picture):
                studio.hold(ImageGenReference(path: picture.path, kept: picture.kept))
            case .kept(let item):
                studio.hold(kept: item)
            }
            promptView.becomeFirstResponder()
        case .discard:
            guard case .made(let picture) = exhibit else { return }
            Theme.Haptics.tap()
            studio.discard(picture.path)
            notice(ImageGenWords.discardNotice)
        }
    }

    /// Saving on a phone means the photo library, which is where a picture a person made goes —
    /// and it hands over the bytes the machine wrote rather than a re-encode of what is on screen.
    private func save(_ payload: ImagePayload) async {
        switch await ImageExport.saveToPhotos(payload) {
        case .saved:
            Theme.Haptics.success()
            notice(String(localized: "Saved to Photos"))
        case .denied:
            Theme.Haptics.warning()
            notice(String(localized: "Allow photo access in Settings to save pictures."))
        case .failed:
            Theme.Haptics.error()
            notice(String(localized: "Couldn't save to Photos"))
        }
    }

    private func share(_ payload: ImagePayload) {
        let item: Any = ImageExport.temporaryFile(payload) ?? payload.image
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func presentSetup() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    private func presentMachine() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ImageMachineViewController())
        nav.navigationBar.prefersLargeTitles = true
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentLibraryPicker() {
        let picker = ImageLibraryPickerViewController(library: library) { [weak self] item in
            self?.studio.hold(kept: item)
            self?.promptView.becomeFirstResponder()
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    private func notice(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor)
    }
}

extension ImageStudioViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .tile(let id):
            guard let kept = library.item(named: id) else { return }
            Theme.Haptics.selection()
            studio.show(kept: kept)
            scrollToStage()
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
        -> Bool
    {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .tile: return true
        default: return false
        }
    }

    /// A tile that comes into view learns its own words, so a screen reader and a press-and-hold
    /// name the picture rather than the file. One ranged read each, kept on disk afterwards.
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard case .tile(let id) = dataSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return }
        library.describe(kept)
    }

    /// Press and hold a tile for its verbs without putting it on the stage first: the caption
    /// names it, and every verb is the same one the stage offers.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .tile(let id) = dataSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return nil }
        library.describe(kept)
        let exhibit: ImageExhibit
        if let made = slot.pictures.first(where: { $0.remoteName == kept.id }) {
            exhibit = .made(made)
        } else {
            exhibit = .kept(kept)
        }
        let facts = library.facts(of: kept)
        let words: String
        switch exhibit {
        case .made(let made): words = ImageGenFacts.caption(for: made)
        case .kept: words = ImageGenFacts.caption(for: facts)
        }
        let offered = ImageGenAction.offered(
            kept: true, hasWords: exhibit.isKept ? facts?.recipe?.prompt?.isEmpty == false : true,
            sharing: true, tapOpens: false)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            UIMenu(
                title: words.ellipsized(to: 80),
                children: offered.map { action in
                    UIAction(
                        title: action.phoneTitle, image: UIImage(systemName: action.symbol),
                        attributes: action.isDestructive ? .destructive : []
                    ) { _ in self?.perform(action, on: exhibit) }
                })
        }
    }
}

extension ImageStudioViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        updateRenderButton()
        grow()
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
