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

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private let search = UISearchController(searchResultsController: nil)
    private let machineStrip = MachineStripView()
    private let consequence = UILabel()
    private let above = UIStackView()
    private var didScrollToSelected = false
    private var sectionIDs: [String] = []
    private var rowsByID: [String: ModelChooserRow] = [:]

    init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(),
        onSelect: @escaping (ModelPick) -> Void
    ) {
        self.chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
        self.onSelect = onSelect
        self.quotas = quotas
        self.recents = recents
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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
        above.spacing = Theme.Spacing.xs
        above.translatesAutoresizingMaskIntoConstraints = false
        machineStrip.onPick = { [weak self] index in self?.pickMachine(index) }
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
        above.addArrangedSubview(machineStrip)
        above.addArrangedSubview(line)
        view.addSubview(above)
        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            above.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            above.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        syncMachines()
    }

    private func syncMachines() {
        let shown = chooser.showsMachines
        machineStrip.isHidden = !shown
        machineStrip.render(chooser.machines, selected: chooser.machineIndex)
        let line = chooser.shownMachine?.consequence
        consequence.superview?.isHidden = !shown || line == nil
        consequence.attributedText = line.map {
            NSAttributedString(
                string: $0, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.warning))
        }
        consequence.accessibilityLabel = line
        view.setNeedsLayout()
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

    private func scrollToFocused() {
        guard let focused = chooser.focused, let indexPath = dataSource.indexPath(for: focused.id)
        else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard chooser.showsMachines else { return nil }
        return (1...min(9, chooser.machines.count)).map { digit in
            let command = UIKeyCommand(
                title: chooser.machines[digit - 1].title, action: #selector(machineKey(_:)),
                input: "\(digit)", modifierFlags: .control)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
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
        let height = above.isHidden ? 0 : above.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        let inset = machineStrip.isHidden ? 0 : height + Theme.Spacing.xs
        if abs(collectionView.contentInset.top - inset) > 0.5 {
            collectionView.contentInset.top = inset
            collectionView.verticalScrollIndicatorInsets.top = inset
        }
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
            content.textProperties.font = Theme.Ramp.font(row.isSelected ? .rowTitleStrong : .answer)
            if row.isAuto {
                content.secondaryText = row.detail
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                content.image = UIImage(systemName: "wand.and.stars")
                content.imageProperties.tintColor = Theme.Color.accent
            } else {
                content.secondaryText = row.detail
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
                content.secondaryTextProperties.font = Theme.Ramp.font(.toolOutput)
                content.secondaryTextProperties.numberOfLines = 1
                content.secondaryTextProperties.lineBreakMode = .byTruncatingTail
            }
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            if row.wall != nil, !row.isSelected {
                content.textProperties.color = Theme.Color.tertiaryLabel
            }
            cell.accessibilityLabel = Self.spoken(row)
            cell.contentConfiguration = content
            cell.indentationLevel = row.isNested ? 1 : 0
            cell.accessories = [
                self.marks(row, room: self.view.bounds.width * (row.wall == nil ? 0.42 : 0.56))
            ]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let id = self.dataSource.sectionIdentifier(for: indexPath.section),
                let section = self.chooser.sections.first(where: { $0.id == id })
            else { return }
            var content = UIListContentConfiguration.header()
            content.text = section.title.isEmpty ? nil : section.title.uppercased()
            content.secondaryText = section.title.isEmpty ? nil : section.detail
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
            view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
            guard section.canCollapse else { return }
            view.addGestureRecognizer(
                SectionTapRecognizer(section: section.id) { [weak self] id in
                    guard let self, self.chooser.toggleSection(id) else { return }
                    Theme.Haptics.selection()
                    self.applySnapshot(keepingScroll: true)
                })
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text =
                self?.chooser.serverReading
                ?? (self?.chooser.isNarrowed == true
                    ? self?.chooser.summary
                    : String(
                        localized:
                            "One row per model, grouped by family. The chevron opens the other providers that run it."
                    ))
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
                    .font: Theme.Ramp.font(.headline),
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    /// The whole row in words. A narrow screen has room for two marks and drops the rest, which is
    /// the right trade for the eye and the wrong one for a reader who cannot see the row at all —
    /// so everything the row knows is spoken whether or not it fitted.
    private static func spoken(_ row: ModelChooserRow) -> String {
        var parts = [row.title]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if let wall = row.wall { parts.append(QuotaSurface.bannerBody(wall)) }
        parts += row.facts.map(\.label)
        if row.isSelected { parts.append(String(localized: "Currently chosen")) }
        return parts.joined(separator: ". ")
    }

    /// The star: a decision about the model rather than a fact about it, muted until it is made.
    /// Every listing of the same model wears the same state, because `isPinned` follows the
    /// selection through every section it appears in.
    private func star(_ row: ModelChooserRow) -> UIView? {
        guard !row.isAuto, !row.isLiteral, let selection = row.selection else { return nil }
        let pinned = row.isPinned
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: pinned ? "star.fill" : "star",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        button.tintColor = pinned ? Theme.Color.accent : Theme.Color.tertiaryLabel
        button.frame = CGRect(x: 0, y: 0, width: 30, height: 28)
        button.accessibilityLabel =
            pinned ? String(localized: "Unpin") : String(localized: "Pin")
        button.addAction(UIAction { [weak self] _ in self?.togglePin(selection) }, for: .touchUpInside)
        return button
    }

    private func togglePin(_ selection: ModelSelection) {
        Theme.Haptics.selection()
        chooser.togglePin(selection)
        applySnapshot(keepingScroll: true)
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

    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        rowsByID.removeAll(keepingCapacity: true)
        for section in chooser.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            for row in section.rows { rowsByID[row.id] = row }
        }
        sectionIDs = chooser.sections.map(\.id)
        dataSource.apply(snapshot, animatingDifferences: false)
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
        chooser = ModelChooser(
            sources: sources, selected: chooser.selected, recents: recents, quotas: quotas)
        chooser.search(query)
        chooser.setMachine(machine)
        guard isViewLoaded else { return }
        syncMachines()
        applySnapshot()
    }

    #if DEBUG
        func tourMachine(_ index: Int) { pickMachine(index) }

        func tourSearch(_ text: String) {
            search.isActive = true
            search.searchBar.text = text
            updateSearchResults(for: search)
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

/// A pill that measures itself. An accessory laid out from a hand-set frame has no size for the
/// cell to lay out *around*, so two of them on one row were drawn in the same place — which is how
/// a row ended up wearing "used up" and "3 levels" on top of each other. A label with an honest
/// `intrinsicContentSize` is the whole fix.
private final class PillLabel: UILabel {
    var minimumWidth: CGFloat = 0
    private let inset = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: max(minimumWidth, size.width + inset.left + inset.right),
            height: size.height + inset.top + inset.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    /// An accessory is laid out from whichever of the two a cell asks for, and which one it asks
    /// for is not ours to know — so the size is stated both ways.
    func fixSize() {
        let size = intrinsicContentSize
        frame = CGRect(origin: .zero, size: size)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    static func make(text: String, tint: UIColor, spoken: String, minimum: CGFloat) -> PillLabel {
        let pill = PillLabel()
        pill.text = text
        pill.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        pill.textColor = tint
        pill.textAlignment = .center
        pill.accessibilityLabel = spoken
        pill.minimumWidth = minimum
        pill.backgroundColor = tint.withAlphaComponent(0.12)
        pill.layer.cornerRadius = 5
        pill.layer.cornerCurve = .continuous
        return pill
    }
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
        if let wall = row.wall {
            let note = UILabel()
            note.attributedText = NSAttributedString(
                string: QuotaSurface.rowNote(wall),
                attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.danger))
            note.accessibilityLabel = QuotaSurface.bannerBody(wall)
            note.lineBreakMode = .byTruncatingTail
            let fitted = min(note.intrinsicContentSize.width, spoken)
            note.frame = CGRect(x: 0, y: 0, width: fitted, height: 28)
            pieces.append(note)
        } else if let capabilities = Self.capabilities(row: row, slots: slots) {
            pieces.append(capabilities)
        }
        for fact in row.facts where !fact.isCapability {
            pieces.append(
                PillLabel.make(
                    text: fact.tag.uppercased(), tint: Self.tint(fact), spoken: fact.label,
                    minimum: 0))
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

    private static func tint(_ fact: ModelFact) -> UIColor {
        switch fact {
        case .local: return Theme.Color.accent
        case .server: return Theme.Color.warning
        default: return Theme.Color.secondaryLabel
        }
    }

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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return
        }
        Theme.Haptics.success()
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

/// One capsule per machine, scrolling sideways. The name, a dot for a machine that is not
/// answering, and the count in the quieter register; the selected one wears the accent.
private final class MachineStripView: UIScrollView {
    var onPick: ((Int) -> Void)?
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
            row.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor, constant: -2 * Theme.Spacing.xs),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(_ machines: [ModelMachine], selected: Int) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        for (index, machine) in machines.enumerated() {
            let chip = Self.chip(machine, selected: index == selected)
            chip.addAction(UIAction { [weak self] _ in self?.onPick?(index) }, for: .touchUpInside)
            row.addArrangedSubview(chip)
        }
        layoutIfNeeded()
        guard row.arrangedSubviews.indices.contains(selected) else { return }
        scrollRectToVisible(row.arrangedSubviews[selected].frame.insetBy(dx: -Theme.Spacing.l, dy: 0), animated: false)
    }

    private static func chip(_ machine: ModelMachine, selected: Bool) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        configuration.baseBackgroundColor =
            selected ? Theme.Color.accent : Theme.Color.secondaryBackground
        let ink = selected ? Theme.Color.onAccent : Theme.Color.label
        let quiet = selected ? Theme.Color.onAccent.withAlphaComponent(0.7) : Theme.Color.tertiaryLabel
        let title = NSMutableAttributedString(
            string: machine.title, attributes: Theme.Ramp.attributes(.rowTitleStrong, color: ink))
        title.append(
            NSAttributedString(
                string: "  \(machine.count)", attributes: Theme.Ramp.attributes(.rowMeta, color: quiet)))
        configuration.attributedTitle = AttributedString(title)
        if machine.isReachable != true {
            configuration.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 6, weight: .bold))
            configuration.imagePadding = Theme.Spacing.xs
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in
                machine.isReachable == false ? Theme.Color.danger : Theme.Color.tertiaryLabel
            }
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "\(machine.title). \(machine.detail)"
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        return button
    }
}
