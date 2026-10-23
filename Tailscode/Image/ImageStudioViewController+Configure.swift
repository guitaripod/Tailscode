import TailscodeCore
import UIKit

extension ImageStudioViewController {
    func configureStage() {
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.onOpen = { [weak self] in self?.openStage() }
        stage.onStarter = { [weak self] index in self?.useStarter(index) }
        stage.onRemedy = { [weak self] in self?.remedyTapped() }
        verbs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)
        view.addSubview(verbs)
    }

    func configureStrip() {
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

    static let tile: CGFloat = 64

    /// The brief, in the order it is read: what to start from, the words, how, go. The dock is the
    /// floor of the screen — its glass runs to the bottom edge and under the home indicator, and
    /// only its contents ride the keyboard — and the stage and the shelf above it never move
    /// under a finger, they only give way.
    func configureDock() {
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

    static var promptMinimum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 2) + 24
    }

    static var promptMaximum: CGFloat {
        ceil(Theme.Ramp.font(.composer).lineHeight * 6) + 24
    }

    func configureStripSource() {
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
}
