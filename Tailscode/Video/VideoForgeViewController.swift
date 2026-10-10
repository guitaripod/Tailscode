import AVFoundation
import TailscodeCore
import UIKit

/// Asking for a video, and watching it be made.
///
/// The screen has the same anatomy as the image studio's, because it is the same machine making
/// the other thing: the stage owns the screen — the machine's own sketch of the clip while it
/// renders, the clip playing in the rectangle the sketch used when it lands — with the verbs that
/// get a clip out under it, the shelf of clips already made under those, and at the foot the brief
/// written like a sentence: what to start from, the words, how, go.
///
/// Everything on it is `ForgeBoard`'s and `ForgeJob`'s: every word, which settings walk, what the
/// button says it would do, how far each pass is. The controller draws them and does the things a
/// board cannot — open a text box, put a clip on screen, hand a picture to the render.
///
/// The render itself is `ForgeRunner`'s, not this screen's: a clip is minutes of another machine's
/// card, and a phone goes in a pocket halfway through. Backing out and coming back finds the same
/// render exactly where it was.
@MainActor
final class VideoForgeViewController: UIViewController {
    private enum StripItem: Hashable {
        case job
        case clip(String)
        case note
    }

    private let runner = ForgeRunner.shared
    private let stage = StudioStageView()
    private let player = ClipPlayerView()
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

    private var stageEntry: ForgeEntry?
    private var stageClip: (asset: ForgeAsset, url: URL)?
    private var stageFailure: String?
    private var locating: Task<Void, Never>?
    private var locatingAsset: ForgeAsset?
    private var lastDelivered: ForgeAsset?
    private var muted = true
    private var sketchFrame: ImageGenPreviewFrame?
    private var sketchImage: UIImage?
    private var decoding: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var wasRendering = false

    private var board: ForgeBoard { runner.board }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ForgeSurface.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ForgeSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = menuItem
        navigationItem.titleView = pill
        menuItem.accessibilityLabel = ImageGenWords.moreTitle
        pill.addAction(UIAction { [weak self] _ in self?.openRenderer() }, for: .touchUpInside)
        intake = ImageReferenceIntake(
            presenter: self,
            deliver: { [weak self] data, name in self?.startFromPicture(data, named: name) },
            hasGallery: { [weak self] in self?.galleryIsHere ?? false },
            onLibrary: { [weak self] in self?.presentLibraryPicker() })
        configureStage()
        configureStrip()
        configureDock()
        configureStripSource()
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange), name: ForgeRunner.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange), name: ImageStudio.didChange, object: nil)
        wasRendering = runner.isRendering
        setPrompt(board.recipe.prompt)
        render(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grow()
        layoutStartFrom()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !runner.isRendering else { return }
        runner.probe()
        ImageStudio.shared.library.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            scrollForVerification()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runner.rememberRecipe()
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
        player.translatesAutoresizingMaskIntoConstraints = false
        stage.overlay.addSubview(player)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: stage.overlay.topAnchor),
            player.bottomAnchor.constraint(equalTo: stage.overlay.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: stage.overlay.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: stage.overlay.trailingAnchor),
        ])
        stage.onOpen = { [weak self] in self?.openStageClip() }
        stage.onRemedy = { [weak self] in self?.remedyTapped() }
        verbs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)
        view.addSubview(verbs)
    }

    private static let tile: CGFloat = 64
    private static let slotSide: CGFloat = 52
    private static let enhanceMargin: CGFloat = 5

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
        strip.accessibilityLabel = ForgeWords.recentTitle
        view.addSubview(strip)
    }

    private static var promptMinimum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 2) + 24
    }

    private static var promptMaximum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 6) + 24
    }

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
        promptView.accessibilityLabel = ForgeField.prompt.label
        placeholder.numberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        promptView.addSubview(placeholder)

        var clear = UIButton.Configuration.plain()
        clear.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        clear.baseForegroundColor = Theme.Color.tertiaryLabel
        clearButton.configuration = clear
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.accessibilityLabel = String(localized: "Clear")
        clearButton.alpha = 0
        clearButton.isUserInteractionEnabled = false
        clearButton.addAction(UIAction { [weak self] _ in self?.clearPrompt() }, for: .touchUpInside)

        startFrom.translatesAutoresizingMaskIntoConstraints = false
        startFromRing.fillColor = nil
        startFromRing.lineWidth = 1.5
        startFromRing.lineDashPattern = [4, 3]
        startFrom.layer.addSublayer(startFromRing)
        startFrom.showsMenuAsPrimaryAction = true

        renderButton.translatesAutoresizingMaskIntoConstraints = false
        renderButton.addAction(
            UIAction { [weak self] _ in self?.renderTapped() }, for: .touchUpInside)
        renderButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(renderHeld)))
        enhancement.mode = .video
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
    }

    private func configureStripSource() {
        let job = UICollectionView.CellRegistration<ImageJobTileCell, StripItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let job = self.board.job
            var step: String?
            if job.samplerSteps > 0 {
                step = "\(min(job.samplerStep, job.samplerSteps))/\(job.samplerSteps)"
            }
            cell.apply(
                sketch: self.sketchImage, step: step, fraction: self.lineFractions().last,
                words: job.subtitle)
        }
        let clip = UICollectionView.CellRegistration<ForgeClipTileCell, StripItem> {
            [weak self] cell, _, item in
            guard let self, case .clip(let id) = item,
                let entry = self.board.history.first(where: { $0.id == id })
            else { return }
            cell.apply(
                entry, endpoint: self.runner.endpoint, onStage: self.stageEntry?.id == id,
                gone: self.runner.isMissing(entry))
        }
        let note = UICollectionView.CellRegistration<ImageStripNoteCell, StripItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.apply(words: self.historyNote ?? "", machine: ForgeWords.recentTitle)
        }
        stripSource = UICollectionViewDiffableDataSource<Int, StripItem>(collectionView: strip) {
            view, indexPath, item in
            switch item {
            case .job: return view.dequeueConfiguredReusableCell(using: job, for: indexPath, item: item)
            case .clip: return view.dequeueConfiguredReusableCell(using: clip, for: indexPath, item: item)
            case .note: return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            }
        }
    }

    private var historyNote: String? {
        board.sections.first(where: { $0.id == ForgeBoard.historyID })?.rows
            .first(where: { $0.kind == .note })?.title
    }

    /// The line along the stage's edge: one fraction per pass while the graph says which pass it
    /// is in, one fraction for the whole render otherwise, and none until there is a count — never
    /// a line sitting at zero.
    private func lineFractions() -> [Double] {
        let job = board.job
        guard job.isBusy else { return [] }
        if let segments = job.passSegments { return segments.map(\.fraction) }
        if let fraction = job.fraction, fraction >= 0.005 { return [fraction] }
        return []
    }

    private func stageState() -> StudioStageState {
        let job = board.job
        var state = StudioStageState()
        state.glyph = "film"
        let size = job.isBusy ? job.recipe.size : board.recipe.size
        state.ratio = CGFloat(size.height) / CGFloat(max(size.width, 1))
        if job.isBusy {
            let working = job.phase.activity
            state.activity = working
            state.tone = job.phase.tone
            state.sketch = sketchImage
            state.face = sketchImage == nil ? .waiting : .painting
            var parts: [String] = []
            if case .running = job.phase, !job.isCollecting {
                parts.append(job.detail)
            } else {
                parts.append(job.subtitle)
            }
            if let spent = job.spent() { parts.append(spent) }
            state.sentence = parts.joined(separator: " · ")
            if state.face == .painting {
                state.sketchCaption = ForgeWords.sketchCaption(job)
                if job.isCollecting { state.dim = 0.25 }
            }
            state.bar = lineFractions()
            state.spoken = state.sentence
            return state
        }
        if let entry = stageEntry {
            state.ratio = CGFloat(entry.recipe.size.height) / CGFloat(max(entry.recipe.size.width, 1))
            guard entry.isPlayable else {
                state.face = .failed
                state.tone = .danger
                state.sentence = entry.failure
                state.caption = entry.title
                state.spoken = [entry.failure, entry.title].compactMap { $0 }.joined(separator: ", ")
                return state
            }
            if stageClip != nil {
                state.face = .finished
                state.overlayVisible = true
                state.isOpenable = true
                state.caption = entry.title
                state.facts = entry.recipe.summary
                state.spoken = [entry.title, entry.recipe.summary].joined(separator: ", ")
                state.sketch = nil
            } else if let failure = stageFailure {
                state.face = .failed
                state.tone = .danger
                state.sentence = failure
                state.caption = entry.title
                state.spoken = [failure, entry.title].joined(separator: ", ")
            } else {
                state.face = .waiting
                state.sentence = Localized.text("Checking…")
                state.activity = .connecting
                state.sketch = sketchImage
                state.dim = 0.25
                state.spoken = state.sentence
            }
            return state
        }
        switch job.phase {
        case .failed(let reason):
            state.face = .failed
            state.tone = .danger
            state.sentence = reason
            state.caption = job.recipe.prompt
            state.remedy = failureRemedy()
            state.spoken = [reason, job.recipe.prompt].filter { !$0.isEmpty }.joined(separator: ", ")
        case .cancelled:
            state.face = .stopped
            state.tone = .attention
            state.sentence = job.subtitle
            state.spoken = job.subtitle
        case .drafting, .submitting, .queued, .running, .done:
            state.face = .empty
            state.emptyTitle = board.prompt
            state.emptyBody = ForgeBoard.notice
            state.spoken = [board.prompt, ForgeBoard.notice].joined(separator: ", ")
            if runner.endpoint == nil {
                state.emptyTitle = ForgeEntryPoint.tooltip(configured: false)
                state.remedy = ForgeSetup.title
                state.spoken = state.emptyTitle
            }
            state.behind = nil
        }
        return state
    }

    private func failureRemedy() -> String {
        if let reading = StudioMachineReading.forge(board), reading.cannotPaint {
            return ForgeField.endpoint.label
        }
        return String(localized: "Try again")
    }

    private func remedyTapped() {
        guard runner.endpoint != nil else { return openRenderer() }
        if let reading = StudioMachineReading.forge(board), reading.cannotPaint {
            return openRenderer()
        }
        renderTapped()
    }

    @objc private func boardDidChange() {
        render(animated: true)
    }

    private func render(animated: Bool) {
        let rendering = runner.isRendering
        let landed = wasRendering && !rendering
        wasRendering = rendering
        adoptSketch()
        syncStage()
        renderStage()
        updateVerbs()
        applyStrip(animated: animated)
        updateChips()
        updateRenderButton()
        syncPrompt()
        updateEnhance()
        updateChrome()
        runClock()
        if landed, case .done = board.job.phase { announceLanding() }
    }

    private func renderStage() {
        stage.apply(stageState())
        if stageClip == nil { player.clear() }
    }

    /// The machine's sketch, decoded away from the main thread and only if it is still the newest
    /// when it is ready. A render that sends none leaves the stage on the phase's own face.
    private func adoptSketch() {
        let job = board.job
        guard job.isBusy else {
            if stageClip != nil || job.isFinished { decoding?.cancel() }
            return
        }
        guard let frame = job.sketch, frame != sketchFrame else { return }
        sketchFrame = frame
        decoding?.cancel()
        decoding = Task { [weak self] in
            let image = await Task.detached { StudioSketch.decode(frame) }.value
            guard let self, !Task.isCancelled, self.sketchFrame == frame, let image else { return }
            self.sketchImage = image
            self.renderStage()
            var snapshot = self.stripSource.snapshot()
            if snapshot.indexOfItem(.job) != nil {
                snapshot.reconfigureItems([.job])
                self.stripSource.apply(snapshot, animatingDifferences: false, completion: nil)
            }
        }
    }

    /// Which clip is on the stage: the one a render just delivered, until somebody puts another
    /// there; nothing while a render is out, because the render is what the stage is for.
    private func syncStage() {
        let job = board.job
        if job.isBusy {
            if stageEntry != nil || stageClip != nil {
                stageEntry = nil
                stageClip = nil
                stageFailure = nil
                locating?.cancel()
                locatingAsset = nil
                lastDelivered = nil
            }
            if case .submitting = job.phase, sketchImage != nil, sketchFrame == nil || job.sketch == nil {
                sketchImage = nil
                sketchFrame = nil
            }
        } else if let asset = job.asset, asset != lastDelivered {
            lastDelivered = asset
            stageEntry = board.history.first(where: { $0.asset == asset }) ?? ForgeEntry(job: job)
            stageClip = nil
            stageFailure = nil
        }
        guard !job.isBusy, let entry = stageEntry, let asset = entry.asset else {
            if stageEntry == nil { stageClip = nil }
            return
        }
        guard stageClip?.asset != asset, locatingAsset != asset else {
            if let clip = stageClip {
                player.show(clip.url)
                player.setMuted(muted)
            }
            return
        }
        locating?.cancel()
        locatingAsset = asset
        stageFailure = nil
        locating = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(asset, entryID: entry.id)
                guard !Task.isCancelled else { return }
                self.stageClip = (asset, url)
                self.player.show(url)
                self.player.setMuted(self.muted)
            } catch {
                guard !Task.isCancelled else { return }
                self.stageFailure = ForgeClient.reason(error, host: self.runner.endpoint?.host ?? "")
            }
            self.locating = nil
            self.locatingAsset = nil
            self.renderStage()
            self.updateVerbs()
            self.applyStrip(animated: false)
        }
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does.
    private func runClock() {
        guard runner.isRendering else {
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
        let rendering = runner.isRendering
        guard !rendering, let entry = stageEntry, entry.isPlayable, stageClip != nil else {
            verbs.apply(
                verbs: [], more: [], holding: true,
                waiting: ForgeSurface.dismissNote(rendering: rendering))
            return
        }
        var offered: [StudioVerb] = [
            StudioVerb(
                title: String(localized: "Play"), hint: nil, symbol: "play.fill"
            ) { [weak self] in self?.openStageClip() }
        ]
        if let asset = entry.asset {
            offered.append(
                StudioVerb(
                    title: String(localized: "Share"), hint: nil, symbol: "square.and.arrow.up"
                ) { [weak self] in self?.share(asset) })
        }
        offered.append(
            StudioVerb(
                title: ForgeWords.extendTitle, hint: ForgeWords.extendHint, symbol: "forward.end.fill"
            ) { [weak self] in self?.continueIt(entry) })
        offered.append(
            StudioVerb(
                title: muted ? String(localized: "Play sound") : String(localized: "Mute"), hint: nil,
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            ) { [weak self] in self?.toggleSound() })
        let more: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Use these settings"),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in self?.reuse(entry) },
            UIAction(
                title: String(localized: "Remove"), image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.forget(entry) },
        ]
        verbs.apply(verbs: offered, more: more, holding: false, waiting: nil)
    }

    private func applyStrip(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, StripItem>()
        snapshot.appendSections([0])
        if runner.isRendering { snapshot.appendItems([.job]) }
        if board.history.isEmpty {
            snapshot.appendItems([.note])
        } else {
            snapshot.appendItems(board.history.map { .clip($0.id) })
        }
        let refresh: [StripItem] = [.note] + board.history.map { .clip($0.id) }
        snapshot.reconfigureItems(refresh.filter { snapshot.indexOfItem($0) != nil })
        stripSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
    }

    /// The renderer in the bar, and the menu behind the circle beside it: the renderer's own
    /// screen and where its address is changed.
    private func updateChrome() {
        pill.apply(StudioMachineReading.forge(board), working: runner.isRendering)
        menuItem.menu = UIMenu(
            children: [
                UIAction(
                    title: ForgeField.endpoint.label, image: UIImage(systemName: "desktopcomputer")
                ) { [weak self] _ in self?.openRenderer() }
            ])
        if runner.endpoint == nil { pill.apply(nil, working: false) }
    }

    private func announceLanding() {
        let spoken = NSAttributedString(
            string: StudioStageWords.clipLanded(words: board.job.recipe.prompt),
            attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    private func updateChips() {
        let identity = ForgeStudio.chips.map { "\($0.rawValue)=\(board.value(of: $0))" }
            .joined(separator: "|")
            + "|\(board.isBusy)|\(board.recipe.negative)|\(board.recipe.sound)"
            + "|\(traitCollection.preferredContentSizeCategory.rawValue)"
        updateStartFrom()
        guard identity != appliedChips else { return }
        appliedChips = identity
        var chips: [UIView] = []
        for field in ForgeStudio.chips where field != .seed {
            chips.append(chip(for: field))
        }
        chips.append(moreChip())
        chipFlow.set(chips)
    }

    private func chip(for field: ForgeField) -> UIButton {
        let value = board.value(of: field)
        let button = StudioChip.button(label: field.label, value: value)
        button.isEnabled = !board.isBusy
        button.accessibilityLabel = "\(field.label), \(value)"
        if let row = board.rows.first(where: { $0.kind == .field(field) }) {
            button.addAction(
                UIAction { [weak self] _ in
                    Theme.Haptics.selection()
                    _ = self?.runner.activate(row)
                }, for: .touchUpInside)
        }
        button.menu = UIMenu(
            title: field.label,
            children: board.choices(of: field).map { choice in
                UIAction(
                    title: choice.title, subtitle: choice.detail.isEmpty ? nil : choice.detail,
                    state: choice.selected ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.runner.pick(field, id: choice.id)
                }
            })
        return button
    }

    /// The seed, what to keep out and what is heard, in one chip that says which of them are in
    /// force, so a decision that is made is never hidden and a value is never cut to make room.
    private func moreChip() -> UIButton {
        var active: [String] = []
        if !board.recipe.negative.trimmed().isEmpty { active.append(ForgeField.negative.label) }
        if !board.recipe.sound.trimmed().isEmpty { active.append(ForgeField.sound.label) }
        let value = active.isEmpty ? board.value(of: .seed) : active.joined(separator: ", ")
        let button = StudioChip.button(
            label: ImageGenWords.moreTitle, value: value,
            tint: active.isEmpty ? nil : Theme.Color.accent)
        let busy = board.isBusy
        var children: [UIMenuElement] = []
        children.append(
            UIAction(
                title: ForgeField.sound.label, subtitle: soundSubtitle,
                image: UIImage(systemName: ForgeField.sound.symbol),
                attributes: busy ? .disabled : [],
                state: board.recipe.sound.trimmed().isEmpty ? .off : .on
            ) { [weak self] _ in self?.presentWords(for: .sound) })
        children.append(
            UIAction(
                title: ForgeField.negative.label, subtitle: avoidSubtitle,
                image: UIImage(systemName: ForgeField.negative.symbol),
                attributes: busy ? .disabled : [],
                state: board.recipe.negative.trimmed().isEmpty ? .off : .on
            ) { [weak self] _ in self?.presentWords(for: .negative) })
        children.append(
            UIAction(
                title: ForgeField.seed.label, subtitle: board.value(of: .seed),
                image: UIImage(systemName: "die.face.5"), attributes: busy ? .disabled : []
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.runner.pick(.seed, id: "reroll")
            })
        button.menu = UIMenu(children: children)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "\(ImageGenWords.moreTitle), \(value)"
        return button
    }

    private var soundSubtitle: String {
        let heard = board.recipe.sound.trimmed()
        return heard.isEmpty ? ForgeWords.soundUnset : heard.ellipsized(to: 40)
    }

    private var avoidSubtitle: String {
        let avoid = board.recipe.negative.trimmed()
        return avoid.isEmpty ? ForgeWords.negativeIgnoredHint : avoid.ellipsized(to: 40)
    }

    /// A small box for the two lines that are not the clip's words — what is heard and what to
    /// keep out — because a phone has nowhere to keep a second field open under the composer
    /// without taking the stage's room.
    private func presentWords(for field: ForgeField) {
        let sound = field == .sound
        let alert = UIAlertController(
            title: field.label, message: sound ? ForgeWords.soundHint : ForgeWords.negativeIgnoredHint,
            preferredStyle: .alert)
        alert.addTextField { text in
            text.text = sound ? self.board.recipe.sound : self.board.recipe.negative
            text.placeholder = sound ? ForgeWords.soundPlaceholder : ImageGenWords.avoidPlaceholder
            text.autocapitalizationType = .none
            text.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: ImageGenWords.cancelTitle, style: .cancel))
        alert.addAction(
            UIAlertAction(title: ImageGenWords.applyTitle, style: .default) { [weak self] _ in
                let words = alert.textFields?.first?.text ?? ""
                if sound { self?.runner.hear(words) } else { self?.runner.avoid(words) }
            })
        present(alert, animated: true)
    }

    private var galleryIsHere: Bool {
        guard let endpoint = runner.endpoint else { return false }
        let library = ImageStudio.shared.library
        return !library.isEmpty
            && ImageGenEndpoint(sharing: endpoint).displayHost == library.endpoint.displayHost
    }

    private func layoutStartFrom() {
        startFromRing.frame = startFrom.bounds
        startFromRing.path = UIBezierPath(
            roundedRect: startFrom.bounds.insetBy(dx: 1, dy: 1), cornerRadius: Theme.Radius.control
        ).cgPath
        startFromRing.strokeColor = Theme.Color.separator.cgColor
    }

    /// What the slot wears: the picture the clip opens on, the poster of the clip it continues, or
    /// the invitation to choose one. One decision, three sources, and it says which.
    private func startFromThumbnail(_ frame: ForgeFrame) -> UIImage? {
        switch frame {
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path), let image = UIImage(data: data)
            else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        case .kept(let name):
            let library = ImageStudio.shared.library
            return library.items.first(where: { $0.annotatedName == name })
                .flatMap { library.cachedThumbnail(of: $0) }
        case .clipEnd(let asset):
            guard let endpoint = runner.endpoint else { return nil }
            return ClipPosters.cached("\(endpoint.host)/\(asset.annotatedName)")
        }
    }

    private func updateStartFrom() {
        let frame = board.recipe.frame
        let thumb = frame.flatMap(startFromThumbnail)
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
        } else {
            let symbol = frame == nil ? "photo.badge.plus" : (frame?.isClipEnd == true ? "film" : "photo")
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            var caption = AttributedString(ForgeField.frame.label)
            caption.font = Theme.Font.capped(.caption2, maximum: 11)
            config.attributedTitle = caption
            config.baseForegroundColor = frame == nil
                ? Theme.Color.secondaryLabel : Theme.Color.accent
        }
        startFrom.configuration = config
        startFromRing.isHidden = frame != nil
        startFrom.isEnabled = !board.isBusy
        startFrom.titleLabel?.adjustsFontSizeToFitWidth = true
        startFrom.titleLabel?.minimumScaleFactor = 0.6
        startFrom.menu = startFromMenu()
        startFrom.accessibilityLabel = ForgeField.frame.label
        startFrom.accessibilityValue = frame.map { "\($0.label), \($0.detail)" } ?? ForgeWords.frameUnset
        startFrom.accessibilityHint = ForgeWords.frameHint
    }

    /// The doors a first frame can come through: the pictures on this device, the camera, a file,
    /// the clipboard, the machine's own gallery — and the end of a clip already made, which
    /// continues it. Letting go of the frame is one row.
    private func startFromMenu() -> UIMenu {
        var children: [UIMenuElement] = ImageChip.sourceActions(available: intake.available) {
            [weak self] source in self?.intake.present(source)
        }
        let clips = board.history.filter(\.isPlayable).prefix(3).map { entry in
            UIAction(
                title: ForgeWords.continueTitle(entry), subtitle: ForgeWords.continueHint,
                image: UIImage(systemName: "film")
            ) { [weak self] _ in
                guard let asset = entry.asset else { return }
                Theme.Haptics.selection()
                self?.runner.start(from: .clipEnd(asset))
            }
        }
        if !clips.isEmpty {
            children.append(UIMenu(title: "", options: .displayInline, children: clips))
        }
        if board.recipe.frame != nil {
            children.append(
                UIAction(
                    title: ForgeWords.noFrameTitle, image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    self?.runner.start(from: nil)
                })
        }
        return UIMenu(title: ForgeField.frame.label, children: children)
    }

    /// A picture handed in from the photo library, the camera, a file or the clipboard has no path
    /// of its own, so it is given one — the render puts it on the machine first.
    private func startFromPicture(_ data: Data, named name: String) {
        guard let path = ImageGenFiles.stage(data, named: name) else { return }
        Theme.Haptics.selection()
        runner.start(from: .file(path))
    }

    private func presentLibraryPicker() {
        let picker = ImageLibraryPickerViewController(library: ImageStudio.shared.library) {
            [weak self] item in
            Theme.Haptics.selection()
            let facts = ImageStudio.shared.library.facts(of: item)
            self?.runner.start(
                from: .kept(item.annotatedName), width: facts?.width, height: facts?.height)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func syncPrompt() {
        let words = board.recipe.prompt
        if !promptView.isFirstResponder, promptView.text != words {
            beforeEnhance = nil
            setPrompt(words)
        } else {
            updatePlaceholder()
        }
    }

    private func setPrompt(_ words: String) {
        promptView.text = words
        updatePlaceholder()
        updateRenderButton()
        grow()
    }

    private func updatePlaceholder() {
        let visible = !(promptView.text ?? "").isEmpty
        clearButton.isUserInteractionEnabled = visible
        if clearButton.alpha != (visible ? 1 : 0) {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
                self.clearButton.alpha = visible ? 1 : 0
            }
        }
        placeholder.isHidden = visible
        placeholder.attributedText = NSAttributedString(
            string: board.prompt,
            attributes: Theme.Ramp.attributes(.composer, color: Theme.Color.tertiaryLabel))
        promptView.isEditable = !board.isBusy
        promptView.alpha = board.isBusy ? 0.6 : 1
    }

    private func clearPrompt() {
        Theme.Haptics.tap()
        enhanceOverlay?.requestDismiss()
        beforeEnhance = nil
        setPrompt("")
        runner.describe("")
        promptView.becomeFirstResponder()
    }

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

    private func updateEnhance() {
        enhanceControl.apply(
            busy: runner.enhancing, undoing: beforeEnhance != nil, enabled: !board.isBusy,
            helper: runner.helper)
    }

    /// Press once to have the words written out as the caption of the clip, press again to get your
    /// own sentence back. Nothing is rendered on the person's behalf.
    private func enhancePressed() {
        Theme.Haptics.tap()
        if let original = beforeEnhance {
            setPrompt(original)
            runner.describe(original)
            beforeEnhance = nil
            updateEnhance()
            return
        }
        let brief = (promptView.text ?? "").trimmed()
        guard !brief.isEmpty, !runner.enhancing else { return }
        runner.enhance(brief) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let written):
                self.beforeEnhance = brief
                self.runner.followWriter(aspect: written.1)
                self.setPrompt(written.0)
                self.runner.describe(written.0)
                if let helper = self.runner.helper {
                    self.notice(ImageGenWords.enhancedNotice(helper))
                }
                Theme.Haptics.success()
            case .failure(let failure):
                self.notice(self.runner.helper == nil ? ImageGenWords.enhanceMissing : failure.reason)
                Theme.Haptics.warning()
            }
            self.updateEnhance()
        }
        updateEnhance()
    }

    /// Holding the button that renders offers the words written out first — the same card the
    /// image studio and the chat's hold-Send use, answered by the helper on the machine with the
    /// card. Nothing is replaced until the card is taken, and taking it leaves the undo behind.
    @objc private func renderHeld(_ gesture: UILongPressGestureRecognizer) {
        let words = (promptView.text ?? "").trimmed()
        guard gesture.state == .began, !runner.isRendering, !words.isEmpty else { return }
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

    /// One control, two meanings, and it says which it is: a render out is stopped from the same
    /// place it was started. A renderer that was never set up gets the setup instead of a render.
    private func updateRenderButton() {
        let rendering = runner.isRendering
        let words = rendering
            ? ImageGenWords.stopTitle
            : (runner.endpoint == nil ? ForgeSetup.title : Localized.text("Render"))
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.cornerStyle = .large
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        config.image = UIImage(
            systemName: rendering ? "stop.fill" : ForgeEntryPoint.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        var title = AttributedString(words)
        title.font = Theme.Font.capped(.caption1, maximum: 14)
        if !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            config.attributedTitle = title
        }
        renderButton.configuration = config
        renderButton.titleLabel?.adjustsFontSizeToFitWidth = true
        renderButton.titleLabel?.minimumScaleFactor = 0.6
        renderButton.isEnabled =
            rendering || runner.endpoint == nil || !(promptView.text ?? "").trimmed().isEmpty
        renderButton.accessibilityLabel = words
    }

    private func renderTapped() {
        guard !runner.isRendering else {
            runner.stop()
            return
        }
        guard runner.endpoint != nil else { return openRenderer() }
        guard board.recipe.isRenderable else {
            promptView.becomeFirstResponder()
            return
        }
        if board.job.asset != nil || stageEntry?.isPlayable == true { runner.pick(.seed, id: "reroll") }
        startRender(board.recipe)
    }

    private func startRender(_ recipe: ForgeRecipe) {
        view.endEditing(true)
        Theme.Haptics.send()
        sketchImage = nil
        sketchFrame = nil
        beforeEnhance = nil
        stageEntry = nil
        stageClip = nil
        stageFailure = nil
        locatingAsset = nil
        lastDelivered = nil
        player.clear()
        runner.render(recipe)
    }

    private func openRenderer() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    private func toggleSound() {
        muted.toggle()
        Theme.Haptics.selection()
        player.setMuted(muted)
        updateVerbs()
    }

    private func openStageClip() {
        guard let clip = stageClip else { return }
        Theme.Haptics.tap()
        ClipTheatre.present(clip.url, from: self)
    }

    private func share(_ asset: ForgeAsset) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.runner.fetch(asset)
                guard let url = ClipExport.stage(data, as: asset) else { return }
                ClipExport.share(url, from: self, source: self.verbs)
            } catch {
                self.notice(ForgeClient.reason(error, host: self.runner.endpoint?.host ?? ""))
                Theme.Haptics.error()
            }
        }
    }

    /// Starts the next clip where this one ended: the same shape, the same words to edit into what
    /// happens next, a fresh seed — and the keyboard, because the words are what changes.
    private func continueIt(_ entry: ForgeEntry) {
        Theme.Haptics.selection()
        runner.extend(entry)
        promptView.becomeFirstResponder()
    }

    private func reuse(_ entry: ForgeEntry) {
        Theme.Haptics.selection()
        runner.reuse(entry)
    }

    private func forget(_ entry: ForgeEntry) {
        Theme.Haptics.warning()
        if stageEntry?.id == entry.id {
            stageEntry = nil
            stageClip = nil
            lastDelivered = nil
            player.clear()
        }
        runner.forget(entry)
    }

    private func notice(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor, duration: 3)
    }

    #if DEBUG
        /// Opens the renderer's own screen when asked, and sets a first frame or raises the rewrite
        /// card, so every part of this surface can be photographed without a finger driving it.
        private func scrollForVerification() {
            let environment = ProcessInfo.processInfo.environment
            let opening = environment["TAILSCODE_VIDEO_OPEN"]
            if opening == "renderer" || opening == "sweep" || opening == "check" {
                openRenderer()
            }
            if environment["TAILSCODE_VIDEO_FRAME"] != nil {
                runner.start(from: ForgeRunner.stagedPicture())
            }
            if environment["TAILSCODE_VIDEO_CARD"] != nil {
                let words = (promptView.text ?? "").trimmed()
                presentEnhanceOverlay(original: words)
                enhanceOverlay?.render(
                    .ready([
                        EnhancedPrompt(
                            id: 0, label: "qwen3-8b",
                            text:
                                "A slow push-in on a ginger cat asleep on warm terracotta roof tiles in late afternoon light, its flank rising and falling as a soft breeze stirs the fur at its ears. Dust motes drift through the golden air above a skyline of chimneys. Distant rooftop doves coo and a faint church bell rings once.",
                            aspect: nil)
                    ]), original: words)
            }
        }
    #endif
}

extension VideoForgeViewController: UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    /// Pressing a clip puts it on the stage, where it plays, and decides nothing about the next
    /// render: continuing it or using its settings is the verb's, pressed on purpose. A render that
    /// made no clip says why instead.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .clip(let id) = stripSource.itemIdentifier(for: indexPath),
            let entry = board.history.first(where: { $0.id == id })
        else { return }
        Theme.Haptics.selection()
        view.endEditing(true)
        guard !runner.isRendering else { return }
        stageEntry = entry
        stageClip = nil
        stageFailure = nil
        locatingAsset = nil
        lastDelivered = board.job.asset
        player.clear()
        syncStage()
        renderStage()
        updateVerbs()
        applyStrip(animated: false)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        if case .clip = stripSource.itemIdentifier(for: indexPath) { return true }
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

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .clip(let id) = stripSource.itemIdentifier(for: indexPath),
            let entry = board.history.first(where: { $0.id == id })
        else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var actions: [UIAction] = []
            if let asset = entry.asset {
                actions.append(
                    UIAction(
                        title: String(localized: "Share"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in self?.share(asset) })
                actions.append(
                    UIAction(
                        title: ForgeWords.extendTitle, subtitle: ForgeWords.extendHint,
                        image: UIImage(systemName: "forward.end.fill")
                    ) { _ in self?.continueIt(entry) })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Use these settings"),
                    image: UIImage(systemName: "arrow.uturn.backward")
                ) { _ in self?.reuse(entry) })
            actions.append(
                UIAction(
                    title: String(localized: "Remove"), image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in self?.forget(entry) })
            return UIMenu(title: entry.title, children: actions)
        }
    }
}

extension VideoForgeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        enhanceOverlay?.requestDismiss()
        runner.describe(textView.text ?? "")
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

extension VideoForgeViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        let before = (promptView.text ?? "").trimmed()
        Theme.Haptics.success()
        overlay.requestDismiss()
        runner.followWriter(aspect: prompt.aspect)
        setPrompt(prompt.text)
        runner.describe(prompt.text)
        beforeEnhance = before
        if let helper = runner.helper { notice(ImageGenWords.enhancedNotice(helper)) }
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
