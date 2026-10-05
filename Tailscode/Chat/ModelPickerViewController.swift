import CodingAgentKit
import TailscodeCore
import UIKit

/// Every model the server offers, from every provider, as one list.
///
/// A catalog is not a menu. Two hundred rows, each repeating the same provider key under a name,
/// is a thing to scroll past rather than choose from — so the sections are model families, the
/// provider is a fact on the row beside the id, and the same model reached through two gateways is
/// one row that says so and opens onto both. None of that is decided here: `ModelChooser` in the
/// Kit folds, ranks and walks the catalog, and this draws its answer.
@MainActor
final class ModelPickerViewController: UIViewController {
    private let onSelect: (ModelPick) -> Void
    private var chooser: ModelChooser
    private let quotas: [UsageQuota]
    private let recents: [ModelSelection]
    /// Runs when the picker leaves the screen by any road — a pick, the close button, a swipe-down —
    /// so the caller stops watching a catalog nobody is looking at.
    var onClose: (() -> Void)?

    /// What the picker needs to speak for the chat that opened it: the model's name and levels for
    /// the effort strip, the level in force for the pairs a swipe pins, and how big the
    /// conversation is for the cost of switching.
    struct Dial {
        let modelName: String
        var chip: ModelChip? = nil
        let options: [String]
        let agentOptions: [String]
        var effort: String?
        let contextTokens: Int?
        let onEffort: (String?) -> Void
    }

    /// Where the picker was opened from, which decides what a pick means and what the sheet says
    /// about it: a pick in a chat changes that chat, one from Home aims the message being written,
    /// and one from a server's own screen sets what that server runs by default.
    enum Context {
        case chat, composer, serverDefault

        var chooser: ChooserContext {
            switch self {
            case .chat: return .chat
            case .composer: return .composer
            case .serverDefault: return .serverDefault
            }
        }
    }

    private let context: Context
    private var dial: Dial?
    private let effortStrip = EffortStripView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private let search = UISearchController(searchResultsController: nil)
    private let machineStrip = ChipStripView()
    private let doorStrip = ChipStripView()
    private let consequence = UILabel()
    private let above = BandView()
    private let aboveClip = ClippingBand()
    private var didScrollToSelected = false
    private var sectionIDs: [String] = []
    private var rowsByID: [String: ModelChooserRow] = [:]

    init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(), dial: Dial? = nil,
        context: Context = .chat, onSelect: @escaping (ModelPick) -> Void
    ) {
        self.context = context
        self.dial = dial
        self.chooser = Self.makeChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas, dial: dial,
            context: context)
        self.onSelect = onSelect
        self.quotas = quotas
        self.recents = recents
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The list is told what the chat is doing — its level, and what each model can take — so a
    /// row can say what a pick would run at, and pinned pairs lead the list when there is a level
    /// to pair a model with. A server's own screen has neither: it sets a default, not a send.
    private static func makeChooser(
        sources: [ModelSource], selected: ModelSelection?, recents: [ModelSelection],
        quotas: [UsageQuota], dial: Dial?, context: Context
    ) -> ModelChooser {
        ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas,
            showsPairs: dial != nil && context != .serverDefault,
            aim: dial.map { ChooserAim(effort: $0.effort, agentOptions: $0.agentOptions) })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        configureSearch()
        configureCollectionView()
        configureMachines()
        applySnapshot()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (picker: ModelPickerViewController, _) in
            picker.syncMachines()
            picker.applySnapshot(keepingScroll: true)
            picker.scrollBand()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        scrollToSelected()
    }

    private func scrollToSelected() {
        guard !didScrollToSelected, let focused = chooser.focused, focused.isAuto == false else {
            return
        }
        didScrollToSelected = true
        guard let indexPath = dataSource.indexPath(for: focused.id) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search models, providers, ids")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
    }

    /// The machine first, as a strip of tabs under the search field, and under the strip the one
    /// sentence a tab that is not this chat's server owes: that a pick there is a new chat. The
    /// strip is a row of capsules that scrolls sideways rather than a segmented control, because
    /// a server's name is a word somebody chose and a segment truncates it to nothing.
    private func configureMachines() {
        above.axis = .vertical
        above.backgroundColor = Theme.Color.groupedBackground
        above.spacing = Theme.Spacing.xs
        above.translatesAutoresizingMaskIntoConstraints = false
        above.onResize = { [weak self] in self?.fitBand() }
        machineStrip.onPick = { [weak self] index in self?.pickMachine(index) }
        doorStrip.onPick = { [weak self] index in self?.pickDoor(index) }
        machineStrip.onInfo = { [weak self] index in self?.briefMachine(index) }
        doorStrip.onInfo = { [weak self] index in self?.briefDoor(index) }
        consequence.numberOfLines = 0
        consequence.adjustsFontForContentSizeCategory = true
        consequence.isAccessibilityElement = true
        let line = UIView()
        line.addSubview(consequence)
        consequence.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            consequence.topAnchor.constraint(equalTo: line.topAnchor),
            consequence.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            consequence.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: Theme.Spacing.l),
            consequence.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        if let dial {
            effortStrip.render(
                modelName: dial.modelName, chip: dial.chip,
                context: context == .composer ? String(localized: "Next chat") : String(localized: "This chat"),
                options: dial.options, effort: dial.effort)
            effortStrip.onSet = { [weak self] level in
                guard let self else { return }
                self.dial?.effort = level
                self.dial?.onEffort(level)
                self.chooser.setAim(
                    self.dial.map { ChooserAim(effort: $0.effort, agentOptions: $0.agentOptions) })
                self.applySnapshot(keepingScroll: true)
            }
            above.addArrangedSubview(effortStrip)
        }
        above.addArrangedSubview(machineStrip)
        above.addArrangedSubview(doorStrip)
        above.addArrangedSubview(line)
        aboveClip.clipsToBounds = true
        aboveClip.translatesAutoresizingMaskIntoConstraints = false
        aboveClip.addSubview(above)
        view.addSubview(aboveClip)
        NSLayoutConstraint.activate([
            aboveClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            aboveClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            aboveClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            aboveClip.bottomAnchor.constraint(equalTo: above.bottomAnchor),
            above.topAnchor.constraint(equalTo: aboveClip.topAnchor),
            above.leadingAnchor.constraint(equalTo: aboveClip.leadingAnchor),
            above.trailingAnchor.constraint(equalTo: aboveClip.trailingAnchor),
        ])
        syncMachines()
    }

    private func syncMachines() {
        let shown = chooser.showsMachines
        machineStrip.isHidden = !shown
        machineStrip.render(chooser.machines.map(ChipStripView.Chip.init), selected: chooser.machineIndex)
        syncDoors()
        let line = chooser.shownMachine?.consequence(for: context.chooser)
        consequence.superview?.isHidden = !shown || line == nil
        consequence.attributedText = line.map {
            NSAttributedString(
                string: $0, attributes: Theme.Ramp.attributes(.rowNote, color: Theme.Color.warning))
        }
        consequence.accessibilityLabel = line
        view.setNeedsLayout()
        view.layoutIfNeeded()
        fitBand()
    }

    /// The doors under the machine: every door first, then each provider the machine reaches its
    /// models through, biggest first. Drawn only past one door.
    private func syncDoors() {
        let shown = chooser.showsDoors
        doorStrip.isHidden = !shown
        guard shown else { return }
        let every = ChipStripView.Chip(
            title: String(localized: "All"), count: chooser.doors.reduce(0) { $0 + $1.count },
            detail: String(localized: "Every provider this server reaches"), dot: nil)
        doorStrip.render(
            [every] + chooser.doors.map(ChipStripView.Chip.init), selected: chooser.doorIndex)
    }

    private func briefMachine(_ index: Int) {
        guard chooser.machines.indices.contains(index),
            let card = chooser.briefing(machine: chooser.machines[index].profileID)
        else { return }
        ChooserBriefingViewController.present(card, from: self)
    }

    private func briefDoor(_ index: Int) {
        guard index > 0, let door = chooser.doors[safe: index - 1],
            let card = chooser.briefing(door: door.providerID)
        else { return }
        ChooserBriefingViewController.present(card, from: self)
    }

    private func pickMachine(_ index: Int) {
        guard chooser.machines.indices.contains(index),
            chooser.setMachine(chooser.machines[index].profileID)
        else { return }
        Theme.Haptics.selection()
        syncMachines()
        applySnapshot()
        scrollToFocused()
    }

    private func pickDoor(_ index: Int) {
        let door = index == 0 ? nil : chooser.doors[safe: index - 1]?.providerID
        guard index == 0 || door != nil, chooser.setDoor(door) else { return }
        Theme.Haptics.selection()
        syncDoors()
        applySnapshot()
        scrollToFocused()
    }

    private func scrollToFocused() {
        guard let focused = chooser.focused, let indexPath = dataSource.indexPath(for: focused.id)
        else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        if chooser.showsMachines {
            commands += (1...min(9, chooser.machines.count)).map { digit in
                let command = UIKeyCommand(
                    title: chooser.machines[digit - 1].title, action: #selector(machineKey(_:)),
                    input: "\(digit)", modifierFlags: .control)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        if chooser.showsDoors {
            commands += (0...min(9, chooser.doors.count)).map { digit in
                let title = digit == 0 ? String(localized: "All providers") : chooser.doors[digit - 1].title
                let command = UIKeyCommand(
                    title: title, action: #selector(doorKey(_:)),
                    input: "\(digit)", modifierFlags: .alternate)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        return commands.isEmpty ? nil : commands
    }

    @objc private func doorKey(_ command: UIKeyCommand) {
        guard let input = command.input, let digit = Int(input),
            let chord = KeyChord.canonical(keyval: UInt32(0x30 + digit), state: KeyChord.altMask),
            case .door(let index) = ModelChooser.command(for: chord)
        else { return }
        pickDoor(index.map { $0 + 1 } ?? 0)
    }

    @objc private func machineKey(_ command: UIKeyCommand) {
        guard let input = command.input, let digit = Int(input),
            let chord = KeyChord.canonical(
                keyval: UInt32(0x30 + digit), state: KeyChord.controlMask),
            case .machine(let index) = ModelChooser.command(for: chord)
        else { return }
        pickMachine(index)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitBand()
    }

    /// The band above the list is real chrome of a height nobody here knows ahead — the effort card,
    /// two strips of chips and a sentence that wraps — so the list leaves room for what it measured
    /// *now*, and again whenever the band changes size: a tab that turns a line on used to leave
    /// the list one line short, with the sentence drawn over the first heading.
    private func fitBand() {
        guard isViewLoaded else { return }
        let height =
            above.isHidden
            ? 0
            : above.systemLayoutSizeFitting(
                CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        let inset =
            machineStrip.isHidden && doorStrip.isHidden && effortStrip.isHidden
            ? 0 : height + Theme.Spacing.xs
        let was = collectionView.contentInset.top
        defer { scrollBand() }
        guard abs(was - inset) > 0.5 else { return }
        let atTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
        collectionView.contentInset.top = inset
        collectionView.verticalScrollIndicatorInsets.top = inset
        if atTop { collectionView.contentOffset.y = -collectionView.adjustedContentInset.top }
    }

    /// At the accessibility text sizes the band alone would fill the screen, so it stops being
    /// chrome and becomes the head of the list: it scrolls away with it.
    private func scrollBand() {
        guard isViewLoaded, traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        else {
            above.transform = .identity
            return
        }
        let lift = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        above.transform = CGAffineTransform(translationX: 0, y: -lift)
    }

    private func row(for id: String) -> ModelChooserRow? { rowsByID[id] }

    /// One list configuration lays out every section the same way, so a footer asked for once — the
    /// sentence under the last group that explains the grouping — is asked for under all of them,
    /// and a section that answers with nothing takes the collection view down with it. The layout is
    /// built a section at a time instead: a heading where a section has one, the footer only at the
    /// end, and the data source then always has a view to hand back.
    private func listSection(
        at index: Int, environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = sectionTitle(at: index).isEmpty ? .none : .supplementary
        config.footerMode = index == sectionIDs.count - 1 ? .supplementary : .none
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.pinActions(at: indexPath)
        }
        return .list(using: config, layoutEnvironment: environment)
    }

    private func sectionTitle(at index: Int) -> String {
        guard sectionIDs.indices.contains(index) else { return "" }
        let id = sectionIDs[index]
        return chooser.sections.first { $0.id == id }?.title ?? ""
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section =
                self?.listSection(at: index, environment: environment)
                ?? .list(
                    using: UICollectionLayoutListConfiguration(appearance: .insetGrouped),
                    layoutEnvironment: environment)
            if environment.traitCollection.horizontalSizeClass == .regular {
                section.contentInsetsReference = .readableContent
            }
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = self.row(for: id) else { return }
            var content = cell.defaultContentConfiguration()
            content.attributedText = Self.title(row)
            content.textProperties.font = Theme.Ramp.font(row.isSelected ? .rowTitleStrong : .rowTitle)
            content.image = Self.face(row)
            content.imageProperties.reservedLayoutSize = CGSize(width: 14, height: 14)
            content.imageToTextPadding = Theme.Spacing.m
            content.secondaryAttributedText = Self.subtitle(row, shown: self.chooser.machine)
            content.secondaryTextProperties.numberOfLines = 0
            content.textProperties.numberOfLines = 0
            if row.wall != nil, !row.isSelected {
                content.textProperties.color = Theme.Color.tertiaryLabel
            }
            cell.accessibilityLabel = Self.spoken(row)
            cell.contentConfiguration = content
            cell.indentationLevel = row.isNested ? 1 : 0
            cell.accessories = [
                self.marks(row, room: self.view.bounds.width * 0.42)
            ]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let id = self.dataSource.sectionIdentifier(for: indexPath.section),
                let section = self.chooser.sections.first(where: { $0.id == id })
            else { return }
            self.configureHeader(view, section: section)
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText()
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else {
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: footer, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// A heading's face: the chevron says whether it is open. A supplementary view is not an item,
    /// so a diffable snapshot never reconfigures it — a fold that changed the rows under a heading
    /// left the chevron pointing the old way until the heading scrolled off and back. The face is
    /// therefore written from one place, and a fold rewrites every heading on screen through it.
    private func configureHeader(_ view: UICollectionViewListCell, section: ModelChooserSection) {
            var content = UIListContentConfiguration.header()
            content.text = section.title.isEmpty ? nil : section.title.uppercased()
            content.textProperties.font = Theme.Ramp.font(.sectionLabel)
            content.secondaryText = section.title.isEmpty ? nil : section.detail
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowMeta)
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            if section.canCollapse {
                content.image = UIImage(
                    systemName: section.isCollapsed ? "chevron.right" : "chevron.down",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
                content.imageProperties.tintColor = Theme.Color.secondaryLabel
            }
            view.contentConfiguration = content
            view.accessibilityTraits = section.canCollapse ? .button : []
            view.accessibilityHint =
                section.canCollapse
                ? String(localized: "Opens or folds this family") : nil
            view.accessibilityValue =
                section.canCollapse
                ? (section.isCollapsed ? String(localized: "Folded") : String(localized: "Open")) : nil
            view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
            guard section.canCollapse else { return }
            view.addGestureRecognizer(
                SectionTapRecognizer(section: section.id) { [weak self] id in
                    guard let self, self.chooser.toggleSection(id) else { return }
                    Theme.Haptics.selection()
                    self.applySnapshot(keepingScroll: true)
                })
    }

    private func refreshVisibleHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader)
        {
            guard
                let view = collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath)
                    as? UICollectionViewListCell,
                let id = dataSource.sectionIdentifier(for: indexPath.section),
                let section = chooser.sections.first(where: { $0.id == id })
            else { continue }
            configureHeader(view, section: section)
        }
    }

    /// The name, with the letters the query landed on weighted inside it — the row says why the
    /// ranking put it here.
    private static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let text = NSMutableAttributedString(string: row.title)
        guard !row.highlight.isEmpty else { return text }
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: Theme.Color.accent,
                    .font: Theme.Ramp.font(.rowTitleStrong),
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    /// The row's face: the family's dot, who answers, exactly as the pill and the quick menu wear
    /// it; a hollow circle where nobody has been chosen yet.
    private static func face(_ row: ModelChooserRow) -> UIImage {
        if let chip = row.chip { return EffortMeterView.dotImage(Theme.Color.modelIdentity(chip)) }
        return UIImage(
            systemName: "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))?
            .withTintColor(Theme.Color.tertiaryLabel, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    /// One line under the name, said the same way on every row: what settles which model it is,
    /// where it runs when that is news, and what a pick would do to the level when it would move it.
    private static func subtitle(_ row: ModelChooserRow, shown: String) -> NSAttributedString? {
        let font = Theme.Ramp.font(.rowDetail)
        let text = NSMutableAttributedString()
        func add(_ part: String, _ color: UIColor) {
            if text.length > 0 {
                text.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: Theme.Color.tertiaryLabel]))
            }
            text.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: color]))
        }
        if let wall = row.wall { add(QuotaSurface.rowNote(wall), Theme.Color.danger) }
        if !row.detail.isEmpty {
            add(row.detail, row.isAuto ? Theme.Color.secondaryLabel : Theme.Color.tertiaryLabel)
        }
        if let place = row.place, row.profileID != shown || !row.isElsewhere {
            add(place, Theme.Color.info)
        }
        if let hint = row.reading?.hint { add(hint, Theme.Color.secondaryLabel) }
        return text.length > 0 ? text : nil
    }

    /// Under the last group: what the catalog amounts to, and — only when a row has other
    /// providers to open — the one sentence about the chevron.
    private func footerText() -> String? {
        if let reading = chooser.serverReading { return reading }
        if chooser.isNarrowed { return chooser.summary }
        guard chooser.canExpandAny else { return chooser.catalogSummary }
        return chooser.catalogSummary + "\n"
            + String(localized: "The chevron opens the other providers that run it.")
    }

    /// The whole row in words. A narrow screen has room for two marks and drops the rest, which is
    /// the right trade for the eye and the wrong one for a reader who cannot see the row at all —
    /// so everything the row knows is spoken whether or not it fitted.
    private static func spoken(_ row: ModelChooserRow) -> String {
        var parts = [row.title]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if let wall = row.wall { parts.append(QuotaSurface.bannerBody(wall)) }
        parts += row.facts.map(\.label)
        if let word = row.reading?.word { parts.append(word) }
        if let hint = row.reading?.hint { parts.append(hint) }
        if row.pinning.isPinned { parts.append(String(localized: "Pinned")) }
        if row.isSelected { parts.append(String(localized: "Currently chosen")) }
        return parts.joined(separator: ". ")
    }

    /// The pin: one decision about the pair a row would run — the model at the level it would be
    /// worked at — muted until it is made. A swipe, the menu and this star are the same action,
    /// and every listing of the same model wears the same state.
    private func star(_ row: ModelChooserRow) -> UIView? {
        guard !row.isAuto, !row.isLiteral, row.pinning.preset != nil else { return nil }
        let pinned = row.pinning.isPinned
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: pinned ? "star.fill" : "star",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        button.tintColor = pinned ? Theme.Color.accent : Theme.Color.tertiaryLabel
        button.frame = CGRect(x: 0, y: 0, width: 30, height: 28)
        button.accessibilityLabel =
            pinned ? String(localized: "Unpin") : String(localized: "Pin pair")
        button.addAction(UIAction { [weak self] _ in self?.togglePin(row) }, for: .touchUpInside)
        return button
    }

    private func pinActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id),
            row.pinning.preset != nil
        else { return nil }
        let pinned = row.pinning.isPinned
        let action = UIContextualAction(
            style: .normal,
            title: pinned ? String(localized: "Unpin") : String(localized: "Pin pair")
        ) { [weak self] _, _, done in
            self?.togglePin(row)
            done(true)
        }
        action.backgroundColor = Theme.Color.accent
        action.image = UIImage(systemName: pinned ? "star.slash" : "star.fill")
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func togglePin(_ row: ModelChooserRow) {
        guard let preset = row.pinning.preset else { return }
        let pinned = chooser.togglePin(row: row)
        Theme.Haptics.success()
        applySnapshot(keepingScroll: true)
        let said = ModelPresetCycle.said(preset, modelName: row.title)
        ToastView(
            message: pinned ? String(localized: "Pinned: \(said)") : String(localized: "Unpinned: \(said)")
        ).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor, duration: 1.8)
    }

    private func peekReading(for row: ModelChooserRow) -> ModelPeekReading? {
        guard !row.isAuto, let selection = row.selection,
            let candidate = chooser.candidates.first(where: { $0.carries(selection) })
        else { return nil }
        return ModelPeekReading.of(
            candidate, selected: chooser.selected, effort: dial?.effort,
            agentOptions: dial?.agentOptions ?? [], contextTokens: dial?.contextTokens,
            quotas: quotas)
    }

    private func contextMenu(for row: ModelChooserRow) -> UIContextMenuConfiguration? {
        guard let reading = peekReading(for: row) else { return nil }
        let hue = ModelBadge.chip(selection: row.selection, effort: nil)
            .map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
        return UIContextMenuConfiguration(
            identifier: row.id as NSString,
            previewProvider: { ModelPeekViewController(reading: reading, hue: hue) },
            actionProvider: { [weak self] _ in
                guard let self else { return nil }
                var actions: [UIMenuElement] = [
                    UIAction(
                        title: self.pickTitle(for: row),
                        image: UIImage(systemName: "checkmark.circle")
                    ) { [weak self] _ in
                        self?.onSelect(row.pick)
                        self?.dismiss(animated: true)
                    }
                ]
                if row.pinning.preset != nil {
                    let pinned = row.pinning.isPinned
                    actions.append(
                        UIAction(
                            title: pinned
                                ? String(localized: "Unpin") : String(localized: "Pin this pair"),
                            image: UIImage(systemName: pinned ? "star.slash" : "star")
                        ) { [weak self] _ in self?.togglePin(row) })
                }
                return UIMenu(children: actions)
            })
    }

    /// What the press on a row's menu says it does, by where the picker was opened from.
    private func pickTitle(for row: ModelChooserRow) -> String {
        switch context {
        case .serverDefault: return String(localized: "Use as the default")
        case .composer:
            return row.isElsewhere
                ? String(localized: "Start a new chat there") : String(localized: "Use for this message")
        case .chat:
            return row.isElsewhere
                ? String(localized: "Start a new chat there") : String(localized: "Use for this chat")
        }
    }

    /// Everything the row wears, in one accessory.
    ///
    /// Two custom accessories on one row are two views UIKit sizes from their own frames and never
    /// compresses, so a row with a wall, a machine, its levels, its doors, a chevron and a tick put
    /// six of them into space for two and drew them on top of each other. One view is one frame:
    /// the tick and the chevron take their places first because they are what a press is aimed at,
    /// and the marks fill what is left, dropped from the least decisive end — what ran out, then
    /// where it runs, then what it can do.
    private func marks(_ row: ModelChooserRow, room: CGFloat) -> UICellAccessory {
        let strip = RowMarksView(
            row: row, slots: chooser.policy.capabilitySlots, room: max(60, room), star: star(row)
        ) { [weak self] in
            guard let self, let index = self.chooser.rows.firstIndex(where: { $0.id == row.id })
            else { return }
            self.chooser.focus(index)
            _ = self.chooser.setExpanded(!row.isExpanded, at: index)
            Theme.Haptics.selection()
            self.applySnapshot(keepingScroll: true)
        }
        return .customView(
            configuration: .init(
                customView: strip, placement: .trailing(), isHidden: false,
                reservedLayoutWidth: .actual, maintainsFixedSize: true))
    }

    /// Opening a family, or a row's other providers, adds rows *below* the row that was pressed, so
    /// the honest answer is to move nothing — but the sections' layout is rebuilt to hold them and
    /// the list can land somewhere else entirely, which for a press that asked to see one more row
    /// reads as the catalog throwing itself. A fold keeps the reader where they were; a new
    /// question — a query, a filter, a fresh catalog — is a different list and starts at the top.
    private func applySnapshot(keepingScroll: Bool = false) {
        let held = keepingScroll ? collectionView.contentOffset : nil
        applyRows()
        guard let held else { return }
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let ceiling = max(
            -inset.top,
            collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.setContentOffset(
            CGPoint(x: held.x, y: min(held.y, ceiling)), animated: false)
    }

    /// A row's identity is its place in the list, not its face: opening a row's other doors, or
    /// picking one of them, changes what the row wears without changing which row it is, and a
    /// snapshot that finds the same ids draws nothing new. Every row whose reading changed is
    /// reloaded by name rather than reconfigured — a reconfigured cell keeps the height it was
    /// measured at, so a longer subtitle was cut off at the old row's one line — and the headings
    /// on screen are rewritten, so a chevron always points the way the list is actually folded.
    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        let before = rowsByID
        rowsByID.removeAll(keepingCapacity: true)
        for section in chooser.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            for row in section.rows { rowsByID[row.id] = row }
        }
        let changed = rowsByID.compactMap { id, row -> String? in
            guard let old = before[id], old != row else { return nil }
            return id
        }
        if !changed.isEmpty { snapshot.reloadItems(changed) }
        sectionIDs = chooser.sections.map(\.id)
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshVisibleHeaders()
        syncFoldItem()
        guard let empty = chooser.emptyResult else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.search()
        config.text = empty
        contentUnavailableConfiguration = config
    }

    /// The one press over the whole list: open everything the folding is holding back, or shut it
    /// all again. It names the number, because "show more" over a catalog is a promise of unknown
    /// size and a person deciding whether to scroll is deciding on that number.
    private func syncFoldItem() {
        guard let action = chooser.foldAction else {
            navigationItem.leftBarButtonItem = nil
            return
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: action.title, image: nil,
            primaryAction: UIAction { [weak self] _ in
                guard let self, self.chooser.setAllCollapsed(action.collapses) else { return }
                Theme.Haptics.selection()
                self.applySnapshot(keepingScroll: true)
            })
    }

    @objc private func close() { dismiss(animated: true) }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }

    /// A catalog that arrived while the picker is up — a server that came back from a restart —
    /// re-answers the list in place. The query and the tab survive the answer, and a server that
    /// is still down reads as down rather than as a machine with no models.
    func update(sources: [ModelSource]) {
        let query = chooser.query
        let machine = chooser.machine
        let door = chooser.door
        chooser = Self.makeChooser(
            sources: sources, selected: chooser.selected, recents: recents, quotas: quotas,
            dial: dial, context: context)
        chooser.search(query)
        chooser.setMachine(machine)
        chooser.setDoor(door)
        guard isViewLoaded else { return }
        syncMachines()
        applySnapshot()
    }

    #if DEBUG
        func tourMachine(_ index: Int) { pickMachine(index) }

        func tourDoor(_ index: Int) { pickDoor(index) }

        func tourExpand() {
            guard let index = chooser.rows.firstIndex(where: { $0.canExpand && !$0.isExpanded })
            else { return }
            chooser.focus(index)
            _ = chooser.setExpanded(true, at: index)
            applySnapshot(keepingScroll: true)
        }

        func tourSearch(_ text: String) {
            search.isActive = true
            search.searchBar.text = text
            updateSearchResults(for: search)
        }

        func tourPeek(matching modelID: String) {
            guard
                let row = chooser.rows.first(where: { row in
                    if case .candidate(let candidate) = row.kind {
                        return candidate.offers.contains { $0.model.id == modelID }
                    }
                    return false
                }),
                let reading = peekReading(for: row)
            else { return }
            let hue = ModelBadge.chip(selection: row.selection, effort: nil)
                .map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
            let card = ModelPeekViewController(reading: reading, hue: hue)
            card.loadViewIfNeeded()
            let scrim = UIView(frame: view.bounds)
            scrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scrim)
            addChild(card)
            let size = card.preferredContentSize
            card.view.frame = CGRect(
                x: (view.bounds.width - size.width) / 2, y: view.bounds.height * 0.34,
                width: size.width, height: size.height)
            card.view.layer.cornerRadius = 26
            card.view.layer.cornerCurve = .continuous
            card.view.clipsToBounds = true
            view.addSubview(card.view)
            card.didMove(toParent: self)
        }

        func tourSelect(matching modelID: String) {
            guard
                let row = chooser.rows.first(where: { row in
                    if case .candidate(let candidate) = row.kind {
                        return candidate.offers.contains { $0.model.id == modelID }
                    }
                    return false
                })
            else { return }
            onSelect(row.pick)
            dismiss(animated: true)
        }
    #endif
}

/// A press on a family heading, carrying which heading it was. A supplementary view is recycled, so
/// the gesture has to know its own section rather than the one the view held last time.
private final class SectionTapRecognizer: UITapGestureRecognizer {
    private let section: String
    private let handler: (String) -> Void

    init(section: String, handler: @escaping (String) -> Void) {
        self.section = section
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() {
        guard state == .ended else { return }
        handler(section)
    }
}

/// What a pick would run at, as the pill draws it: the same five bars, and the level's word in the
/// model's own spelling beside them when there is room.
private final class LevelMark: UIView {
    init(reading: ModelRowLevel, withWord: Bool) {
        let meter = EffortMeterView(
            reading: EffortMeterView.Reading(
                heat: reading.heat, level: reading.level, isPower: reading.isPower,
                isServer: reading.isServer, isEmber: reading.isEmber))
        let size = EffortMeterView.size
        meter.frame = CGRect(x: 0, y: (28 - size.height) / 2, width: size.width, height: size.height)
        var width = size.width
        var label: UILabel?
        if withWord, let word = reading.word {
            let text = UILabel()
            text.attributedText = ModelDialPill.effortWord(
                word, isPower: reading.isPower, font: Theme.Ramp.font(.rowMeta))
            if !reading.isPower {
                text.textColor = Theme.Color.secondaryLabel
            }
            let fitted = text.intrinsicContentSize
            text.frame = CGRect(
                x: size.width + 5, y: (28 - fitted.height) / 2, width: fitted.width, height: fitted.height)
            width += 5 + fitted.width
            label = text
        }
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 28))
        addSubview(meter)
        if let label { addSubview(label) }
        isAccessibilityElement = false
        translatesAutoresizingMaskIntoConstraints = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The right-hand end of a row: what ran out or what it reads, where it runs, the star, and the
/// chevron —
/// laid out once, inside a width it was told about, so nothing is ever drawn on top of anything.
/// Marks are dropped from the least decisive end rather than shrunk, and the row's own name keeps
/// whatever is left; a screen reader still hears all of them from the cell's label.
private final class RowMarksView: UIView {
    private static let gap: CGFloat = 5
    private static let slotWidth: CGFloat = 15

    init(
        row: ModelChooserRow, slots: [ModelFact], room: CGFloat, star: UIView?,
        onExpand: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        var tail: [UIView] = []
        if let star { tail.append(star) }
        if row.isSelected {
            let tick = UIImageView(
                image: UIImage(
                    systemName: "checkmark",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 13, weight: .semibold)))
            tick.tintColor = Theme.Color.accent
            tick.accessibilityLabel = String(localized: "Currently chosen")
            tick.frame = CGRect(x: 0, y: 0, width: 20, height: 28)
            tick.contentMode = .center
            tail.append(tick)
        }
        if row.canExpand {
            let chevron = UIButton(type: .system)
            chevron.setImage(
                UIImage(
                    systemName: row.isExpanded ? "chevron.down" : "chevron.right",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 11, weight: .semibold)), for: .normal)
            chevron.tintColor = Theme.Color.secondaryLabel
            chevron.accessibilityLabel = String(localized: "The other providers that run it")
            chevron.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            chevron.addAction(UIAction { _ in onExpand() }, for: .touchUpInside)
            tail.append(chevron)
        }
        let spoken = max(0, room - tail.reduce(0) { $0 + $1.frame.width + Self.gap })

        var pieces: [UIView] = []
        if let reading = row.reading, reading.takesLevels {
            pieces.append(LevelMark(reading: reading, withWord: spoken >= 150))
        }
        if let capabilities = Self.capabilities(row: row, slots: slots) {
            pieces.append(capabilities)
        }

        var width: CGFloat = 0
        var kept: [UIView] = []
        for piece in pieces {
            let size = piece.frame.width > 0 ? piece.frame.width : piece.intrinsicContentSize.width
            let next = width + size + (kept.isEmpty ? 0 : Self.gap)
            guard next <= spoken else { continue }
            width = next
            kept.append(piece)
        }

        let height: CGFloat = 28
        var x: CGFloat = 0
        for piece in kept + tail {
            let size =
                piece.frame.width > 0
                ? piece.frame.size
                : piece.intrinsicContentSize
            piece.frame = CGRect(
                x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            addSubview(piece)
            x += size.width + Self.gap
        }
        let total = max(0, x - Self.gap)
        isAccessibilityElement = false
        frame = CGRect(x: 0, y: 0, width: total, height: height)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: total),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// One slot per capability the catalog can tell models apart by, empty where a model lacks it,
    /// so the symbols read down the list as a column rather than a huddle that shifts per row.
    private static func capabilities(row: ModelChooserRow, slots: [ModelFact]) -> UIView? {
        guard !slots.isEmpty, case .candidate = row.kind else { return nil }
        let worn = Set(row.facts.filter(\.isCapability))
        let strip = FixedWidthView(
            width: CGFloat(slots.count) * slotWidth + CGFloat(slots.count - 1) * gap, height: 18)
        var x: CGFloat = 0
        for slot in slots {
            defer { x += slotWidth + gap }
            guard worn.contains(slot) else { continue }
            let icon = UIImageView(
                image: UIImage(
                    systemName: slot.symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)))
            icon.tintColor = Theme.Color.tertiaryLabel
            icon.contentMode = .center
            icon.frame = CGRect(x: x, y: 0, width: slotWidth, height: 18)
            strip.addSubview(icon)
        }
        return strip
    }
}

/// A view that answers with the size it was built for, so a hand-laid strip can be measured like
/// anything else in the row.
private final class FixedWidthView: UIView {
    private let size: CGSize

    init(width: CGFloat, height: CGFloat) {
        size = CGSize(width: width, height: height)
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { size }
}

extension ModelPickerViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollBand() }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return nil
        }
        return contextMenu(for: row)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return
        }
        onSelect(row.pick)
        dismiss(animated: true)
    }
}

extension ModelPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        chooser.search(searchController.searchBar.text ?? "")
        applySnapshot()
    }
}

/// Holds the band so that, lifted by a scroll, it is cut off at the edge of the bars rather than
/// drawn through them, and lets every touch it does not cover reach the list underneath.
private final class ClippingBand: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The stack above the list, which tells its owner when it changes size.
private final class BandView: UIStackView {
    var onResize: (() -> Void)?
    private var measured: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.height - measured) > 0.5 else { return }
        measured = bounds.height
        onResize?()
    }
}

/// One capsule per machine, scrolling sideways. The name, a dot for a machine that is not
/// answering, and the count in the quieter register; the selected one wears the accent. The same
/// row of capsules serves the doors under the machines — one press each, the one in force wearing
/// the accent.
private final class ChipStripView: UIScrollView {
    struct Chip {
        let title: String
        let count: Int
        let detail: String
        /// A dot before the name, in the colour of what it says; nil for nothing to say.
        let dot: UIColor?

        init(title: String, count: Int, detail: String, dot: UIColor?) {
            self.title = title
            self.count = count
            self.detail = detail
            self.dot = dot
        }

        init(_ machine: ModelMachine) {
            self.init(
                title: machine.title, count: machine.count, detail: machine.detail,
                dot: machine.state.wearsDot
                    ? ChooserBriefingViewController.colour(machine.state.tone) : nil)
        }

        init(_ door: ModelDoor) {
            self.init(
                title: door.title, count: door.count, detail: door.detail,
                dot: door.kind == .local ? Theme.Color.info : nil)
        }
    }

    var onPick: ((Int) -> Void)?
    /// A long press, or the context menu, on a chip: the card that explains it.
    var onInfo: ((Int) -> Void)?
    private let row = UIStackView()

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = false
        contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.l, bottom: 0, right: Theme.Spacing.l)
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(
                equalTo: contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor, constant: 2 * Theme.Spacing.xs),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(_ chips: [Chip], selected: Int) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        for (index, chip) in chips.enumerated() {
            let button = Self.button(chip, selected: index == selected)
            button.addAction(UIAction { [weak self] _ in self?.onPick?(index) }, for: .touchUpInside)
            button.menu = UIMenu(children: [
                UIAction(
                    title: String(localized: "About \(chip.title)"),
                    image: UIImage(systemName: "info.circle")
                ) { [weak self] _ in self?.onInfo?(index) }
            ])
            button.showsMenuAsPrimaryAction = false
            button.accessibilityHint = String(localized: "Hold for what is behind it")
            row.addArrangedSubview(button)
        }
        layoutIfNeeded()
        guard row.arrangedSubviews.indices.contains(selected) else { return }
        scrollRectToVisible(row.arrangedSubviews[selected].frame.insetBy(dx: -Theme.Spacing.l, dy: 0), animated: false)
    }

    private static func button(_ chip: Chip, selected: Bool) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        configuration.baseBackgroundColor =
            selected ? Theme.Color.accent : Theme.Color.secondaryBackground
        let ink = selected ? Theme.Color.onAccent : Theme.Color.label
        let quiet = selected ? Theme.Color.onAccent.withAlphaComponent(0.7) : Theme.Color.tertiaryLabel
        let title = NSMutableAttributedString(
            string: chip.title, attributes: Theme.Ramp.attributes(.chip, color: ink))
        title.append(
            NSAttributedString(
                string: "  \(chip.count)", attributes: Theme.Ramp.attributes(.rowMeta, color: quiet)))
        configuration.attributedTitle = AttributedString(title)
        if let dot = chip.dot {
            configuration.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 6, weight: .bold))
            configuration.imagePadding = Theme.Spacing.xs
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in dot }
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "\(chip.title). \(chip.detail)"
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        return button
    }
}
