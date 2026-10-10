import CodingAgentKit
import TailscodeCore
import UIKit

/// Asking for a picture, and everything that happens to it afterwards.
///
/// The stage is the room and it owns the screen: the picture, or the machine's own sketch of it
/// while it is painted, at the size the render will land in, with the verbs that get it out — into
/// Photos, to another app, onto the pasteboard, rolled again, used as the reference the next
/// render starts from, or animated into a clip — directly under it. Under the verbs is the shelf:
/// every picture the machine keeps, whoever made it, newest first, the render in flight leading
/// it, with the one on the stage ringed. At the foot is the brief, written like a sentence: what
/// to start from, the words, how, go.
///
/// The render itself is `ImageStudio`'s, not this screen's: backing out closes a screen, and
/// coming back finds the same picture exactly where it was.
@MainActor
final class ImageStudioViewController: UIViewController {
    private enum StripItem: Hashable {
        case job
        case tile(String)
        case note
    }

    private let studio = ImageStudio.shared
    private let stage = StudioStageView()
    private let verbs = StudioVerbsBar()
    private var strip: UICollectionView!
    private var stripSource: UICollectionViewDiffableDataSource<Int, StripItem>!
    private let pill = StudioMachinePill()
    private lazy var menuItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu())

    private let dock = Theme.Glass.view()
    private let chipFlow = StudioChipFlow()
    private let promptView = StudioPromptView()
    private let placeholder = UILabel()
    private let clearButton = UIButton(type: .system)
    private let startFrom = UIButton(type: .system)
    private let startFromRing = CAShapeLayer()
    private let enhanceControl = StudioEnhanceControl()
    private let renderButton = UIButton(type: .system)
    private var promptHeight: NSLayoutConstraint!
    private var growing = false
    private var appliedChips: String?
    private var beforeEnhance: String?
    private let enhancement = PromptEnhancementController()
    private weak var enhanceOverlay: PromptEnhanceOverlay?
    private var intake: ImageReferenceIntake!
    private var wasPainting = false
    private var loadingOriginal: String?
    private var shownExhibitID: String?
    private var clock: Task<Void, Never>?
    private var referenceRatios: [String: CGFloat] = [:]

    private var slot: ImageGenSlot { studio.slot }
    private var library: ImageLibrary { studio.library }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ImageGenSurface.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ImageGenSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = menuItem
        navigationItem.titleView = pill
        menuItem.accessibilityLabel = ImageGenWords.moreTitle
        pill.addAction(UIAction { [weak self] _ in self?.presentMachine() }, for: .touchUpInside)
        intake = ImageReferenceIntake(presenter: self, studio: studio) { [weak self] in
            self?.presentLibraryPicker()
        }
        configureStage()
        configureStrip()
        configureDock()
        configureStripSource()
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
        render(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grow()
        layoutStartFrom()
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
            if environment["TAILSCODE_IMAGE_FOCUS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.promptView.becomeFirstResponder()
                }
            }
            if environment["TAILSCODE_IMAGE_SCROLL"] == "library" {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, let last = self.library.items.last,
                        let path = self.stripSource.indexPath(for: .tile(last.id))
                    else { return }
                    self.strip.scrollToItem(at: path, at: .right, animated: true)
                }
            }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        studio.rememberDraft(promptView.text ?? "")
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            appliedChips = nil
            updateChips()
            updateVerbs()
            updateRenderButton()
        }
    }

    private func configureStage() {
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.onOpen = { [weak self] in self?.openStage() }
        stage.onStarter = { [weak self] index in self?.useStarter(index) }
        stage.onRemedy = { [weak self] in self?.remedyTapped() }
        verbs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)
        view.addSubview(verbs)
    }

    private func configureStrip() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: Self.tile, height: Self.tile)
        layout.minimumLineSpacing = Theme.Spacing.s
        layout.sectionInset = UIEdgeInsets(
            top: 1, left: Theme.Spacing.m, bottom: 1, right: Theme.Spacing.m)
        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = .clear
        strip.showsHorizontalScrollIndicator = false
        strip.delegate = self
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.accessibilityLabel = ImageGenLibraryWords.title
        view.addSubview(strip)
    }

    private static let tile: CGFloat = 64

    /// The brief, in the order it is read: what to start from, the words, how, go. The dock is the
    /// floor of the screen — its glass runs to the bottom edge and under the home indicator, and
    /// only its contents ride the keyboard — and the stage and the shelf above it never move
    /// under a finger, they only give way.
    private func configureDock() {
        dock.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, *) {
            dock.cornerConfiguration = .uniformEdges(
                topRadius: .fixed(Theme.Radius.card), bottomRadius: .fixed(0))
        }
        chipFlow.translatesAutoresizingMaskIntoConstraints = false

        promptView.backgroundColor = Theme.Color.codeBackground
        promptView.layer.cornerRadius = Theme.Radius.control
        promptView.layer.cornerCurve = .continuous
        promptView.font = Theme.Ramp.font(.composer)
        promptView.textColor = Theme.Color.label
        promptView.delegate = self
        promptView.onWidth = { [weak self] in self?.grow() }
        promptView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 38)
        promptView.translatesAutoresizingMaskIntoConstraints = false
        promptView.accessibilityLabel = ImageGenStudioWords.wordsTitle
        placeholder.numberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        promptView.addSubview(placeholder)

        configureClearButton()
        configureStartFrom()

        renderButton.translatesAutoresizingMaskIntoConstraints = false
        renderButton.addAction(
            UIAction { [weak self] _ in self?.renderTapped() }, for: .touchUpInside)
        renderButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(renderHeld)))
        enhancement.mode = .image
        enhancement.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.enhanceOverlay?.render(status, original: self.enhancement.latestInput)
        }
        enhanceControl.translatesAutoresizingMaskIntoConstraints = false
        enhanceControl.onEnhance = { [weak self] in self?.enhancePressed() }

        view.addSubview(dock)
        dock.contentView.addSubview(chipFlow)
        dock.contentView.addSubview(startFrom)
        dock.contentView.addSubview(promptView)
        dock.contentView.addSubview(clearButton)
        dock.contentView.addSubview(enhanceControl)
        dock.contentView.addSubview(renderButton)
        promptHeight = promptView.heightAnchor.constraint(equalToConstant: Self.promptMinimum)
        let margin = Theme.Spacing.m
        let stageFloor = stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        stageFloor.priority = UILayoutPriority(750)
        let verbsWidth = verbs.widthAnchor.constraint(equalTo: stage.widthAnchor)
        verbsWidth.priority = UILayoutPriority(750)
        let verbsFit = verbs.heightAnchor.constraint(equalToConstant: StudioVerbsBar.height)
        verbsFit.priority = UILayoutPriority(760)
        let stripFit = strip.heightAnchor.constraint(equalToConstant: Self.tile + 2)
        stripFit.priority = UILayoutPriority(770)
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            stage.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: margin),
            stage.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -margin),
            stageFloor,
            verbs.topAnchor.constraint(equalTo: stage.bottomAnchor),
            verbs.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            verbs.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor),
            verbs.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor),
            verbs.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            verbsWidth,
            verbsFit,
            strip.topAnchor.constraint(equalTo: verbs.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripFit,
            dock.topAnchor.constraint(equalTo: strip.bottomAnchor),
            dock.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chipFlow.topAnchor.constraint(equalTo: dock.contentView.topAnchor, constant: 4),
            chipFlow.leadingAnchor.constraint(equalTo: dock.contentView.leadingAnchor, constant: margin),
            chipFlow.trailingAnchor.constraint(equalTo: dock.contentView.trailingAnchor, constant: -margin),
            startFrom.leadingAnchor.constraint(equalTo: dock.contentView.leadingAnchor, constant: margin),
            startFrom.widthAnchor.constraint(equalToConstant: Self.slotSide),
            startFrom.heightAnchor.constraint(equalToConstant: Self.slotSide),
            startFrom.bottomAnchor.constraint(equalTo: promptView.bottomAnchor),
            promptView.topAnchor.constraint(equalTo: chipFlow.bottomAnchor, constant: 6),
            promptView.leadingAnchor.constraint(equalTo: startFrom.trailingAnchor, constant: Theme.Spacing.s),
            promptView.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.xs),
            promptHeight,
            clearButton.topAnchor.constraint(equalTo: promptView.topAnchor, constant: 2),
            clearButton.trailingAnchor.constraint(equalTo: promptView.trailingAnchor, constant: -2),
            clearButton.widthAnchor.constraint(equalToConstant: 40),
            clearButton.heightAnchor.constraint(equalToConstant: 40),
            enhanceControl.trailingAnchor.constraint(
                equalTo: promptView.trailingAnchor, constant: -Self.enhanceMargin),
            enhanceControl.bottomAnchor.constraint(
                equalTo: promptView.bottomAnchor, constant: -Self.enhanceMargin),
            renderButton.leadingAnchor.constraint(equalTo: promptView.trailingAnchor, constant: Theme.Spacing.s),
            renderButton.trailingAnchor.constraint(equalTo: dock.contentView.trailingAnchor, constant: -margin),
            renderButton.bottomAnchor.constraint(equalTo: promptView.bottomAnchor),
            renderButton.widthAnchor.constraint(equalToConstant: 64),
            renderButton.heightAnchor.constraint(equalToConstant: 56),
            placeholder.leadingAnchor.constraint(equalTo: promptView.leadingAnchor, constant: 13),
            placeholder.trailingAnchor.constraint(equalTo: promptView.trailingAnchor, constant: -40),
            placeholder.topAnchor.constraint(equalTo: promptView.topAnchor, constant: 12),
        ])
        updateChips()
        updateRenderButton()
        updatePlaceholder()
        updateEnhance()
    }

    private static let slotSide: CGFloat = 52

    private static var promptMinimum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 2) + 24
    }

    private static var promptMaximum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 6) + 24
    }

    private func configureStripSource() {
        let job = UICollectionView.CellRegistration<ImageJobTileCell, StripItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(
                sketch: self.studio.sketch, progress: self.studio.progress,
                words: self.slot.waitingLine(since: self.studio.startedAt, progress: self.studio.progress))
        }
        let tile = UICollectionView.CellRegistration<ImageTileCell, StripItem> {
            [weak self] cell, _, item in
            guard let self, case .tile(let id) = item, let kept = self.library.item(named: id) else {
                return
            }
            cell.ringWidth = 2
            cell.apply(kept, library: self.library, onStage: self.studio.exhibit?.libraryID == id)
        }
        let note = UICollectionView.CellRegistration<ImageStripNoteCell, StripItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(self.library.state, machine: self.library.machine)
        }
        stripSource = UICollectionViewDiffableDataSource<Int, StripItem>(collectionView: strip) {
            view, indexPath, item in
            switch item {
            case .job: return view.dequeueConfiguredReusableCell(using: job, for: indexPath, item: item)
            case .tile: return view.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: item)
            case .note: return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            }
        }
    }

    /// The whole stage as one value. A kept picture whose original is not here yet shows its tile
    /// while the bytes come, and asks for them once.
    private func stageState() -> StudioStageState {
        var state = StudioStageState()
        let exhibit = studio.exhibit
        var image: UIImage?
        var thumbnail: UIImage?
        var ratio: CGFloat?
        switch exhibit {
        case .made(let picture):
            image = studio.image(of: picture)
        case .kept(let item):
            image = studio.image(of: item)
            thumbnail = library.cachedThumbnail(of: item)
            if let facts = library.facts(of: item), let width = facts.width, let height = facts.height,
                width > 0
            {
                ratio = CGFloat(height) / CGFloat(width)
            }
            if image == nil { fetchOriginal(of: item) }
            library.describe(item)
        case nil:
            break
        }
        let held = image ?? thumbnail
        if let shown = held, shown.size.width > 0 {
            ratio = ratio ?? shown.size.height / shown.size.width
            if let image, image.size.width > 0 { ratio = image.size.height / image.size.width }
        }
        let paint = expectedRatio()
        switch slot.phase {
        case .painting:
            state.picture = held
            state.sketch = studio.sketch
            state.ratio = paint
            state.face = studio.sketch == nil ? .waiting : .painting
            state.sentence = slot.waitingLine(since: studio.startedAt, progress: studio.progress)
            state.activity = .working
            state.tone = .live
            if state.face == .painting {
                state.sketchCaption = ImageGenPreviewWords.caption(studio.progress)
                if let stage = studio.progress?.stage, stage == .decoding || stage == .saving {
                    state.dim = 0.25
                }
            } else {
                state.dim = held == nil ? 0 : 0.6
            }
            state.bar = studio.progress?.bar.map { [$0] } ?? []
            state.spoken = state.sentence
        case .failed(let prompt, let reason):
            let stopped = reason == ImageGenWords.stoppedNotice
            state.ratio = ratio ?? paint
            state.sentence = reason
            if stopped {
                state.face = .stopped
                state.picture = held
                state.tone = .attention
                state.dim = 0.45
                state.spoken = reason
            } else {
                state.face = .failed
                state.tone = .danger
                state.caption = prompt
                state.remedy = failureRemedy()
                state.spoken = [reason, prompt].filter { !$0.isEmpty }.joined(separator: ", ")
            }
        case .asking, .composing:
            if let exhibit, held != nil {
                state.face = .finished
                state.picture = held
                state.ratio = ratio ?? paint
                state.isOpenable = image != nil
                switch exhibit {
                case .made(let picture):
                    state.caption = ImageGenFacts.caption(for: picture)
                    state.facts = ImageGenFacts.line(for: picture)
                    state.spoken = [state.caption, state.facts].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                case .kept(let item):
                    let facts = library.facts(of: item)
                    state.caption = facts.map { ImageGenFacts.caption(for: $0) }
                    state.facts = facts.map { ImageGenFacts.line(for: $0) }
                    state.spoken = [
                        state.caption, state.facts, facts == nil ? nil : ImageGenWords.keptNote,
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                }
            } else {
                state.face = .empty
                state.ratio = 0.7
                state.emptyTitle = ImageGenWords.emptyTitle
                state.emptyBody = library.isEmpty ? ImageGenWords.emptyBody : ImageGenWords.stageEmptyKept
                state.starters = ImageGenBrief.examples.prefix(4).map { StudioStarter(title: $0.title) }
                state.behind = library.items.first.flatMap { library.cachedThumbnail(of: $0) }
                state.spoken = [state.emptyTitle, state.emptyBody].compactMap { $0 }.joined(separator: ", ")
                if !studio.door.isOpen {
                    state.emptyTitle = ImageGenEntryPoint.tooltip(configured: false)
                    state.emptyBody = ImageGenWords.emptyBody
                    state.starters = []
                    state.behind = nil
                    state.remedy = ForgeSetup.title
                    state.spoken = [state.emptyTitle, state.emptyBody].compactMap { $0 }.joined(separator: ", ")
                }
            }
        }
        return state
    }

    /// The rectangle the render will land in, decided before it starts: the shape asked for, or —
    /// when a reference is held and both editors take their size from it — the reference's own.
    private func expectedRatio() -> CGFloat {
        if !slot.aspectApplies, let reference = slot.references.first {
            if let known = referenceRatios[reference.path] { return known }
            let source = reference.kept.flatMap { library.cachedThumbnail(of: $0) }
                ?? UIImage(contentsOfFile: reference.path)
            if let source, source.size.width > 0 {
                let ratio = source.size.height / source.size.width
                referenceRatios[reference.path] = ratio
                return ratio
            }
        }
        let pixels = slot.aspect.pixels
        return CGFloat(pixels.height) / CGFloat(max(pixels.width, 1))
    }

    private func failureRemedy() -> String {
        if let reading = StudioMachineReading.image(studio.door), reading.cannotPaint {
            return ImageGenMachineWords.title
        }
        return String(localized: "Try again")
    }

    private func remedyTapped() {
        guard studio.door.isOpen else {
            presentSetup()
            return
        }
        if let reading = StudioMachineReading.image(studio.door), reading.cannotPaint {
            presentMachine()
            return
        }
        guard let words = slot.activePrompt, !words.isEmpty else { return }
        Theme.Haptics.send()
        studio.submit(prompt: words)
    }

    private func useStarter(_ index: Int) {
        let examples = ImageGenBrief.examples
        guard examples.indices.contains(index) else { return }
        let example = examples[index]
        Theme.Haptics.tap()
        studio.choose(aspect: example.aspect)
        setPrompt(example.prompt)
        studio.rememberDraft(example.prompt)
        updateChips()
        promptView.becomeFirstResponder()
    }

    private func fetchOriginal(of item: ImageGenLibraryItem) {
        guard loadingOriginal != item.id else { return }
        loadingOriginal = item.id
        Task { [weak self] in
            _ = await self?.studio.payload(of: item)
            guard let self else { return }
            if self.loadingOriginal == item.id { self.loadingOriginal = nil }
            self.renderStage()
            self.updateVerbs()
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
        render(animated: true)
        if landed { announceLanding() }
    }

    @objc private func progressDidChange() {
        renderStage()
        var snapshot = stripSource.snapshot()
        if snapshot.indexOfItem(.job) != nil {
            snapshot.reconfigureItems([.job])
            stripSource.apply(snapshot, animatingDifferences: false)
        }
    }

    @objc private func libraryDidChange() {
        render(animated: true)
    }

    @objc private func itemDidChange(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String else { return }
        var snapshot = stripSource.snapshot()
        if snapshot.indexOfItem(.tile(id)) != nil {
            snapshot.reconfigureItems([.tile(id)])
            stripSource.apply(snapshot, animatingDifferences: false)
        }
        if studio.exhibit?.libraryID == id {
            renderStage()
            updateVerbs()
        }
    }

    private func render(animated: Bool) {
        renderStage()
        updateVerbs()
        applyStrip(animated: animated)
        updateChips()
        updateRenderButton()
        updatePlaceholder()
        updateEnhance()
        updateChrome()
        runClock()
    }

    private func renderStage() {
        stage.apply(stageState())
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a screen that keeps a timer alive over a settled state spends frames on
    /// nothing.
    private func runClock() {
        guard studio.isPainting else {
            clock?.cancel()
            clock = nil
            return
        }
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.renderStage()
            }
        }
    }

    private func updateVerbs() {
        let painting = studio.isPainting
        guard let exhibit = studio.exhibit, !painting, slot.failure == nil else {
            verbs.apply(
                verbs: [], more: [], holding: true,
                waiting: ImageGenSurface.dismissNote(painting: painting))
            return
        }
        let held = studio.isReference(exhibit)
        let offered = actions(for: exhibit).map { action in
            StudioVerb(
                title: action.phoneTitle, hint: action.hint,
                symbol: action == .reference && held ? "checkmark.circle.fill" : action.symbol,
                value: action == .reference && held ? String(localized: "Already the reference") : nil
            ) { [weak self] in self?.perform(action, on: exhibit) }
        }
        var more: [UIMenuElement] = [
            UIAction(
                title: ForgeWords.animateTitle, subtitle: ForgeWords.animateHint,
                image: UIImage(systemName: "film")
            ) { [weak self] _ in self?.animate(exhibit) },
            UIAction(
                title: ImageGenAction.open.title, image: UIImage(systemName: ImageGenAction.open.symbol)
            ) { [weak self] _ in self?.perform(.open, on: exhibit) },
        ]
        if case .made = exhibit {
            more.append(
                UIAction(
                    title: ImageGenAction.discard.title,
                    image: UIImage(systemName: ImageGenAction.discard.symbol),
                    attributes: .destructive
                ) { [weak self] _ in self?.perform(.discard, on: exhibit) })
        }
        verbs.apply(verbs: offered, more: more, holding: false, waiting: nil)
    }

    private func applyStrip(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, StripItem>()
        snapshot.appendSections([0])
        if studio.isPainting { snapshot.appendItems([.job]) }
        if library.items.isEmpty {
            snapshot.appendItems([.note])
        } else {
            snapshot.appendItems(library.items.map { .tile($0.id) })
        }
        var refresh: [StripItem] = [.note]
        let shown = studio.exhibit?.libraryID
        if shown != shownExhibitID {
            for id in [shown, shownExhibitID].compactMap({ $0 }) { refresh.append(.tile(id)) }
            shownExhibitID = shown
        }
        snapshot.reconfigureItems(refresh.filter { snapshot.indexOfItem($0) != nil })
        stripSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
        strip.accessibilityValue = library.line
    }

    /// The machine in the bar, and the menu behind the circle beside it: start over, ask the shelf
    /// again, and the machine's own sheet. Starting over says beforehand what else goes with the
    /// stage — the words — and every picture stays on the shelf.
    private func updateChrome() {
        pill.apply(StudioMachineReading.image(studio.door), working: studio.isPainting)
        var items: [UIMenuElement] = []
        let promptWords = (promptView.text ?? "").trimmed()
        if studio.canStartOver || !promptWords.isEmpty {
            items.append(
                UIAction(
                    title: ImageGenWords.startOver, subtitle: ImageGenWords.startOverHint,
                    image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive
                ) { [weak self] _ in self?.startOver() })
        }
        items.append(
            UIAction(
                title: ImageGenLibraryWords.refresh, subtitle: library.line,
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                Theme.Haptics.tap()
                self?.library.refresh()
            })
        items.append(
            UIAction(
                title: ImageGenMachineWords.title, image: UIImage(systemName: "desktopcomputer")
            ) { [weak self] _ in self?.presentMachine() })
        menuItem.menu = UIMenu(
            title: ImageGenLibraryWords.heading(machine: library.machine), children: items)
    }

    /// Back to blank. The words in the box go with it, so a person who only wanted the stage gone
    /// is told beforehand what else goes — and every picture stays on the shelf.
    private func startOver() {
        Theme.Haptics.tap()
        view.endEditing(true)
        studio.startOver()
        setPrompt("")
    }

    private func announceLanding() {
        guard let exhibit = studio.exhibit else { return }
        var words: String?
        if case .made(let picture) = exhibit { words = ImageGenFacts.caption(for: picture) }
        let spoken = NSAttributedString(
            string: StudioStageWords.landed(words: words),
            attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    private func updateChips() {
        let sighting = studio.sighting
        let identity = ImageGenField.allCases.map { "\($0.rawValue)=\(slot.value(of: $0))" }
            .joined(separator: "|")
            + "|\(slot.references.map(\.chip).joined(separator: ","))|\(slot.isBusy)"
            + "|\(slot.aspectApplies)|\(sighting?.readyEngines.map(\.rawValue).joined() ?? "?")"
            + "|\(intake.available.count)|\(slot.cutout)|\(slot.seed.chip)|\(slot.negative)"
            + "|\(briefIsThin)|\(traitCollection.preferredContentSizeCategory.rawValue)"
            + "|\(slot.cutoutApplies)|\(slot.negativeApplies)"
        updateStartFrom()
        guard identity != appliedChips else { return }
        appliedChips = identity
        var chips: [UIView] = [engineChip(sighting: sighting), aspectChip()]
        if slot.applies(.size) { chips.append(sizeChip()) }
        if slot.applies(.detail) { chips.append(detailChip()) }
        chips.append(moreChip())
        chipFlow.set(chips)
    }

    /// Whether the words in the box are thin enough that the model would invent most of the
    /// frame. The More chip wears the answer rather than a banner taking the composer's room.
    private var briefIsThin: Bool {
        ImageGenBrief.isThin(promptView.text ?? "")
    }

    private func chip(
        _ field: ImageGenField, value: String, accessibility: String? = nil, tint: UIColor? = nil
    ) -> UIButton {
        let button = StudioChip.button(label: field.label, value: value, tint: tint)
        button.isEnabled = !slot.isBusy
        if let accessibility { button.accessibilityLabel = accessibility }
        return button
    }

    private func engineChip(sighting: ImageGenSighting?) -> UIButton {
        let unavailable = slot.engineAvailable(given: sighting) == false
        let button = chip(
            .engine, value: slot.value(of: .engine), tint: unavailable ? Theme.Color.warning : nil)
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
            let button = chip(.aspect, value: ImageGenWords.aspectFollowsReference)
            button.isEnabled = false
            button.accessibilityLabel = ImageGenWords.aspectFollowsReference
            return button
        }
        let button = chip(.aspect, value: slot.value(of: .aspect))
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

    private func sizeChip() -> UIButton {
        let button = chip(
            .size, value: slot.value(of: .size),
            accessibility: "\(ImageGenField.size.label), \(slot.aspect.label(slot.size))")
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.size)
            }, for: .touchUpInside)
        button.menu = ImageChip.sizeMenu(slot: slot) { [weak self] size in
            Theme.Haptics.selection()
            self?.studio.choose(size: size)
        }
        return button
    }

    private func detailChip() -> UIButton {
        let button = chip(
            .detail, value: slot.value(of: .detail),
            accessibility: "\(ImageGenField.detail.label), \(slot.detail.detail)")
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.detail)
            }, for: .touchUpInside)
        button.menu = ImageChip.detailMenu(slot: slot) { [weak self] detail in
            Theme.Haptics.selection()
            self?.studio.choose(detail: detail)
        }
        return button
    }

    /// Everything the four decisions do not cover — the seed, painting on transparency, what to
    /// keep out, and the craft — in one chip that says which of them are in force, so a decision
    /// that is made is never hidden and a value is never cut to make room for it.
    private func moreChip() -> UIButton {
        var active: [String] = []
        if slot.seed.isHeld { active.append(slot.seed.chip) }
        if slot.cutout { active.append(ImageGenWords.cutoutTitle) }
        if !slot.negative.trimmed().isEmpty { active.append(ImageGenWords.avoidTitle) }
        let value = active.isEmpty ? slot.seed.chip : active.joined(separator: ", ")
        let button = StudioChip.button(
            label: ImageGenWords.moreTitle, value: value,
            tint: briefIsThin ? Theme.Color.warning : (active.isEmpty ? nil : Theme.Color.accent))
        var children: [UIMenuElement] = []
        if slot.cutoutApplies {
            children.append(
                UIAction(
                    title: ImageGenWords.cutoutTitle, subtitle: ImageGenWords.cutoutHint,
                    image: UIImage(systemName: "square.on.square.dashed"),
                    attributes: slot.isBusy ? .disabled : [], state: slot.cutout ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    Theme.Haptics.selection()
                    self.studio.setCutout(!self.slot.cutout)
                })
        }
        let seedCanHold = slot.seed.isHeld || slot.seed.last != nil
        children.append(
            UIAction(
                title: ImageGenStudioWords.holdSeedTitle,
                subtitle: ImageGenStudioWords.holdSeedDetail(seed: slot.seed),
                image: UIImage(systemName: slot.seed.isHeld ? "lock.fill" : "die.face.5"),
                attributes: slot.isBusy || !seedCanHold ? .disabled : [],
                state: slot.seed.isHeld ? .on : .off
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.toggleSeedHold()
            })
        if slot.negativeApplies {
            let holding = !slot.negative.trimmed().isEmpty
            children.append(
                UIAction(
                    title: ImageGenWords.avoidTitle,
                    subtitle: holding ? slot.negative.ellipsized(to: 40) : ImageGenWords.avoidHint,
                    image: UIImage(systemName: "nosign"),
                    attributes: slot.isBusy ? .disabled : [], state: holding ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    self?.presentAvoid()
                })
        }
        children.append(
            ImageChip.craftMenu { [weak self] example in
                guard let self else { return }
                Theme.Haptics.tap()
                self.studio.choose(aspect: example.aspect)
                self.setPrompt(example.prompt)
                self.studio.rememberDraft(example.prompt)
                self.updateChips()
            })
        button.menu = UIMenu(children: children)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "\(ImageGenWords.moreTitle), \(value)"
        button.accessibilityHint = briefIsThin ? ImageGenBrief.thinBody : nil
        return button
    }

    /// Attaching a picture is the whole of asking for an edit, so this control is never a switch:
    /// it holds one or it does not, wears the picture it holds, and opens the sources — or replace
    /// and remove — as a menu, because the doors are five and a phone has no tooltip to name them.
    private func configureStartFrom() {
        startFrom.translatesAutoresizingMaskIntoConstraints = false
        startFrom.clipsToBounds = false
        startFromRing.fillColor = nil
        startFromRing.lineWidth = 1.5
        startFromRing.lineDashPattern = [4, 3]
        startFrom.layer.addSublayer(startFromRing)
        startFrom.showsMenuAsPrimaryAction = true
        updateStartFrom()
    }

    private func layoutStartFrom() {
        startFromRing.frame = startFrom.bounds
        startFromRing.path = UIBezierPath(
            roundedRect: startFrom.bounds.insetBy(dx: 1, dy: 1), cornerRadius: Theme.Radius.control
        ).cgPath
        startFromRing.strokeColor = Theme.Color.separator.cgColor
    }

    private func updateStartFrom() {
        let holding = slot.references.last
        let count = slot.references.count
        let thumb = holding.flatMap { reference -> UIImage? in
            if let kept = reference.kept, let tile = library.cachedThumbnail(of: kept) { return tile }
            guard let data = FileManager.default.contents(atPath: reference.path),
                let image = UIImage(data: data)
            else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        }
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .fixed
        config.background.cornerRadius = Theme.Radius.control
        config.background.backgroundColor = Theme.Color.codeBackground
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        if let thumb {
            config.background.image = thumb
            config.background.imageContentMode = .scaleAspectFill
            config.image = nil
            config.title = nil
            if count > 1 {
                var badge = AttributedString("\(count)")
                badge.font = Theme.Ramp.font(.badge)
                badge.foregroundColor = Theme.Color.onAccent
                config.attributedTitle = badge
                config.background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.3)
            }
        } else {
            config.image = UIImage(
                systemName: "photo.badge.plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            var caption = AttributedString(ForgeField.frame.label)
            caption.font = Theme.Font.capped(.caption2, maximum: 11)
            config.attributedTitle = caption
            config.baseForegroundColor = Theme.Color.secondaryLabel
        }
        startFrom.configuration = config
        startFromRing.isHidden = thumb != nil
        startFrom.isEnabled = !slot.isBusy
        startFrom.titleLabel?.adjustsFontSizeToFitWidth = true
        startFrom.titleLabel?.minimumScaleFactor = 0.6
        startFrom.menu = intake.menu(references: slot.references)
        startFrom.accessibilityLabel = holding.map(ImageGenWords.referenceHint) ?? ImageGenWords.attachTitle
        startFrom.accessibilityHint = count == 0 ? nil : ImageGenWords.attachMoreHint
    }

    private func updateEnhance() {
        enhanceControl.apply(
            busy: studio.enhancing, undoing: beforeEnhance != nil,
            enabled: !slot.isBusy, helper: studio.helper)
    }

    /// Press once to have the brief written out, press again to get your own sentence back.
    private func enhancePressed() {
        Theme.Haptics.tap()
        if let original = beforeEnhance {
            setPrompt(original)
            studio.rememberDraft(original)
            beforeEnhance = nil
            updateEnhance()
            return
        }
        let brief = (promptView.text ?? "").trimmed()
        guard !brief.isEmpty, !studio.enhancing else { return }
        studio.enhance(brief) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let written):
                self.beforeEnhance = brief
                self.studio.followWriter(aspect: written.1)
                self.setPrompt(written.0)
                self.studio.rememberDraft(written.0)
                if let helper = self.studio.helper {
                    self.notice(ImageGenWords.enhancedNotice(helper))
                }
                Theme.Haptics.success()
            case .failure(let failure):
                self.notice(
                    self.studio.helper == nil ? ImageGenWords.enhanceMissing : failure.reason)
                Theme.Haptics.warning()
            }
            self.updateEnhance()
            self.updateChips()
        }
        updateEnhance()
    }

    /// A small box for the avoid list, because a phone has nowhere to keep a second field open
    /// under the composer without taking the picture's room.
    private func presentAvoid() {
        let alert = UIAlertController(
            title: ImageGenWords.avoidTitle, message: ImageGenWords.avoidHint,
            preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.slot.negative
            field.placeholder = ImageGenWords.avoidPlaceholder
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: ImageGenWords.cancelTitle, style: .cancel))
        alert.addAction(
            UIAlertAction(title: ImageGenWords.applyTitle, style: .default) { [weak self] _ in
                let words = alert.textFields?.first?.text ?? ""
                self?.studio.setNegative(words)
                self?.updateChips()
            })
        present(alert, animated: true)
    }

    /// One control, two meanings, and it says which it is: a render out is stopped from the same
    /// place it was started, because a person who wants it to end should not have to find another
    /// button to end it with.
    private func updateRenderButton() {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.cornerStyle = .large
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        config.image = UIImage(
            systemName: studio.isPainting ? "stop.fill" : ImageGenEntryPoint.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        var title = AttributedString(
            studio.isPainting ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode))
        title.font = Theme.Font.capped(.caption1, maximum: 14)
        if !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            config.attributedTitle = title
        }
        renderButton.configuration = config
        renderButton.titleLabel?.adjustsFontSizeToFitWidth = true
        renderButton.titleLabel?.minimumScaleFactor = 0.6
        renderButton.isEnabled =
            studio.isPainting || !(promptView.text ?? "").trimmed().isEmpty
        renderButton.accessibilityLabel = studio.isPainting
            ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode)
    }

    /// A long brief is minutes of typing or a whole rewrite, and emptying it by selecting and
    /// deleting is a fight with a loupe. The mark sits inside the box where the words are, is
    /// there only while there is something to clear, and leaves the keyboard up so the next
    /// brief starts at once.
    private func configureClearButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        config.baseForegroundColor = Theme.Color.tertiaryLabel
        clearButton.configuration = config
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.accessibilityLabel = String(localized: "Clear")
        clearButton.alpha = 0
        clearButton.isUserInteractionEnabled = false
        clearButton.addAction(UIAction { [weak self] _ in self?.clearPrompt() }, for: .touchUpInside)
    }

    private func clearPrompt() {
        Theme.Haptics.tap()
        enhanceOverlay?.requestDismiss()
        beforeEnhance = nil
        setPrompt("")
        studio.rememberDraft("")
        updateChips()
        updateEnhance()
        promptView.becomeFirstResponder()
    }

    private func updateClearButton() {
        let visible = !(promptView.text ?? "").isEmpty
        clearButton.isUserInteractionEnabled = visible
        guard clearButton.alpha != (visible ? 1 : 0) else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
            self.clearButton.alpha = visible ? 1 : 0
        }
    }

    private func updatePlaceholder() {
        updateClearButton()
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

    /// The box is as tall as what is in it, from two lines to six, after which it scrolls — a
    /// prompt worth two sentences must not be typed into a slot that shows one line of it. The
    /// Enhance control sits over its trailing foot, and the words flow around it rather than under.
    private func grow() {
        guard promptView.bounds.width > 0, !growing else { return }
        growing = true
        defer { growing = false }
        let width = promptView.bounds.width
        var height = promptHeight.constant
        for _ in 0..<3 {
            flow(around: height)
            let fitted = promptView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            let next = min(max(Self.promptMinimum, fitted.height), Self.promptMaximum)
            guard abs(next - height) > 0.5 else { break }
            height = next
        }
        flow(around: height)
        guard abs(height - promptHeight.constant) > 0.5 else { return }
        promptHeight.constant = height
        view.setNeedsLayout()
    }

    /// Keeps the words out of the rectangle the Enhance control covers at a given box height.
    private func flow(around height: CGFloat) {
        let control = enhanceControl.size
        let inset = promptView.textContainerInset
        let width = promptView.bounds.width
        let rect = CGRect(
            x: width - Self.enhanceMargin - control.width - 4 - inset.left,
            y: height - Self.enhanceMargin - control.height - 1 - inset.top,
            width: control.width + 40, height: control.height + 200)
        promptView.textContainer.exclusionPaths = [UIBezierPath(rect: rect)]
    }

    private static let enhanceMargin: CGFloat = 5

    /// Holding the button that makes the picture offers the brief written out first — the chat's
    /// hold-Send, answered by the machine that paints rather than by a coding model. Nothing is
    /// replaced until the card is taken, and taking it leaves the undo behind.
    @objc private func renderHeld(_ gesture: UILongPressGestureRecognizer) {
        let words = (promptView.text ?? "").trimmed()
        guard gesture.state == .began, !studio.isPainting, !words.isEmpty else { return }
        Theme.Haptics.tap()
        enhancement.requestNow(for: words)
        presentEnhanceOverlay(original: words)
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
            overlay.bottomAnchor.constraint(equalTo: dock.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let origin = renderButton.convert(
            CGPoint(x: renderButton.bounds.midX, y: renderButton.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
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
        beforeEnhance = nil
        studio.submit(prompt: words)
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

    private func putOnStage(_ exhibit: ImageExhibit) {
        switch exhibit {
        case .made(let picture): studio.show(picture.path)
        case .kept(let item): studio.show(kept: item)
        }
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
            if exhibit != studio.exhibit { putOnStage(exhibit) }
            studio.again()
        case .stage:
            Theme.Haptics.selection()
            putOnStage(exhibit)
        case .reference:
            Theme.Haptics.selection()
            switch exhibit {
            case .made(let picture):
                studio.hold(ImageGenReference(path: picture.path, kept: picture.kept))
            case .kept(let item):
                studio.hold(kept: item)
            }
            if exhibit != studio.exhibit { putOnStage(exhibit) }
            promptView.becomeFirstResponder()
        case .discard:
            guard case .made(let picture) = exhibit else { return }
            Theme.Haptics.tap()
            studio.discard(picture.path)
            notice(ImageGenWords.discardNotice)
        }
    }

    /// The bridge to the other thing this app makes: the video forge opened over the work, holding
    /// this picture as the clip's first frame. A picture on the machine that renders the clip is
    /// named where it is so no byte travels; anywhere else the picture goes with the render.
    private func animate(_ exhibit: ImageExhibit) {
        Theme.Haptics.tap()
        Task { [weak self] in
            guard let self, let start = await self.firstFrame(of: exhibit) else { return }
            ForgeRunner.shared.start(from: start.frame, width: start.width, height: start.height)
            let nav = UINavigationController(rootViewController: VideoForgeViewController())
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
    }

    private func firstFrame(of exhibit: ImageExhibit) async -> (frame: ForgeFrame, width: Int?, height: Int?)? {
        let sameMachine = ForgeRunner.shared.endpoint.map {
            ImageGenEndpoint(sharing: $0).displayHost == studio.endpoint.displayHost
        } ?? false
        switch exhibit {
        case .made(let picture):
            let size = studio.image(of: picture).map(Self.pixels(of:))
            if sameMachine, let remote = picture.remoteName {
                return (.kept(ImageGenLibraryItem(filename: remote).annotatedName), size?.0, size?.1)
            }
            return (.file(picture.path), size?.0, size?.1)
        case .kept(let item):
            let facts = library.facts(of: item)
            if sameMachine {
                return (.kept(item.annotatedName), facts?.width, facts?.height)
            }
            guard let payload = await studio.payload(of: item),
                let data = payload.data,
                let path = ImageGenFiles.stage(data, named: payload.filename)
            else {
                notice(ForgeFailure.unconfigured.description)
                return nil
            }
            let size = Self.pixels(of: payload.image)
            return (.file(path), size.0, size.1)
        }
    }

    private static func pixels(of image: UIImage) -> (Int, Int) {
        (Int((image.size.width * image.scale).rounded()), Int((image.size.height * image.scale).rounded()))
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

extension ImageStudioViewController: UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    /// A tile is a picture made this session when the session made it, else the kept file.
    private func exhibitFor(_ kept: ImageGenLibraryItem) -> ImageExhibit {
        if let made = slot.pictures.first(where: { $0.remoteName == kept.id }) { return .made(made) }
        return .kept(kept)
    }

    /// Pressing a tile puts that picture on the stage, because the stage is directly above it and
    /// the answer is the stage changing — tapping the stage opens it full size, and nothing about
    /// choosing a picture decides what the next render is about: that is the reference verb's,
    /// pressed on purpose.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return }
        Theme.Haptics.selection()
        view.endEditing(true)
        putOnStage(exhibitFor(kept))
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
        -> Bool
    {
        if case .tile = stripSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(
        _ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        if case .tile = stripSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if case .note = stripSource.itemIdentifier(for: indexPath) {
            return CGSize(
                width: max(120, collectionView.bounds.width - 2 * Theme.Spacing.m), height: Self.tile)
        }
        return CGSize(width: Self.tile, height: Self.tile)
    }

    /// A tile that comes into view learns its own words, so a screen reader and a press-and-hold
    /// name the picture rather than the file. One ranged read each, kept on disk afterwards.
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return }
        library.describe(kept)
    }

    /// Press and hold a tile for its verbs: the caption names it, the first verb puts it on the
    /// stage, and the rest are the ones the stage offers.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return nil }
        library.describe(kept)
        let exhibit = exhibitFor(kept)
        let facts = library.facts(of: kept)
        let words: String
        switch exhibit {
        case .made(let made): words = ImageGenFacts.caption(for: made)
        case .kept: words = ImageGenFacts.caption(for: facts)
        }
        let offered = [ImageGenAction.stage, .open] + ImageGenAction.offered(
            kept: true, hasWords: exhibit.isKept ? facts?.recipe?.prompt?.isEmpty == false : true,
            sharing: true, tapOpens: true)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var children: [UIMenuElement] = offered.map { action in
                UIAction(
                    title: action.phoneTitle, image: UIImage(systemName: action.symbol),
                    attributes: action.isDestructive ? .destructive : []
                ) { _ in self?.perform(action, on: exhibit) }
            }
            children.append(
                UIAction(
                    title: ForgeWords.animateTitle, image: UIImage(systemName: "film")
                ) { _ in self?.animate(exhibit) })
            return UIMenu(title: words.ellipsized(to: 80), children: children)
        }
    }
}

extension ImageStudioViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        enhanceOverlay?.requestDismiss()
        updatePlaceholder()
        updateRenderButton()
        updateChrome()
        updateChips()
        grow()
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ImageStudioViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        let before = (promptView.text ?? "").trimmed()
        Theme.Haptics.success()
        overlay.requestDismiss()
        studio.followWriter(aspect: prompt.aspect)
        setPrompt(prompt.text)
        studio.rememberDraft(prompt.text)
        beforeEnhance = before
        if let helper = studio.helper { notice(ImageGenWords.enhancedNotice(helper)) }
        updateChips()
        updateEnhance()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
    }
}
