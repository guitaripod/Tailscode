import TailscodeCore
import CodingAgentKit
import UIKit

extension HomeViewController {
    func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section: NSCollectionLayoutSection
            if let self, let id = self.dataSource?.sectionIdentifier(for: index) {
                switch id {
                case .status: section = Self.plainSection(top: 0, bottom: Theme.Spacing.xs)
                case .glance:
                    section = Self.plainSection(top: Theme.Spacing.s, bottom: Theme.Spacing.m)
                case .alerts, .demoNudge, .supporter:
                    section = Self.plainSection(top: 0, bottom: Theme.Spacing.m)
                case .asks:
                    section = Self.headedSection(columns: 1, estimatedHeight: 190)
                case .usage:
                    let wide = environment.container.effectiveContentSize.width >= 640
                    section = Self.headedSection(columns: wide ? 2 : 1, estimatedHeight: 150)
                case .needsYou, .working, .pinned, .saved, .recent:
                    section = Self.bandSection(environment) { [weak self] indexPath in
                        guard let self, let item = self.dataSource.itemIdentifier(for: indexPath)
                        else { return false }
                        if case .more = item { return true }
                        return false
                    }
                }
            } else {
                section = Self.plainSection(top: 0, bottom: 0)
            }
            if environment.traitCollection.horizontalSizeClass == .regular {
                section.contentInsetsReference = .readableContent
            }
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        collectionView.keyboardDismissMode = .interactive
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
        collectionBottom = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionBottom,
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    /// Tapping anywhere outside the composer puts the keyboard away; the tap still reaches
    /// whatever it landed on.
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard composerBar.isEditingText else { return }
        view.endEditing(true)
    }

    func configureComposer() {
        composerBar.delegate = self
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)
        composerFloor = composerBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        composerRidesKeyboard = composerBar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([composerFloor])
        rails.append(ReadableRail(composerBar, in: view))
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = collectionView
            edge.edge = .bottom
            composerBar.addInteraction(edge)
            collectionView.bottomEdgeEffect.style = .soft
        }

        configureAccessories()

        commandPalette.isHidden = true
        commandPalette.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.bottomAnchor.constraint(
                equalTo: accessories.topAnchor, constant: -Theme.Spacing.xs),
            commandPalette.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Theme.Spacing.s),
        ])
        rails.append(
            ReadableRail(
                host: view,
                compact: [
                    commandPalette.leadingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
                    commandPalette.trailingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
                ],
                regular: [
                    commandPalette.leadingAnchor.constraint(
                        equalTo: view.readableContentGuide.leadingAnchor, constant: Theme.Spacing.l),
                    commandPalette.trailingAnchor.constraint(
                        equalTo: view.readableContentGuide.trailingAnchor, constant: -Theme.Spacing.l),
                ]))
        configureOrb()
    }

    /// The three things that float in the gap between the board and the box, in one stack so they
    /// can never land on top of each other: what failed, what is offered, what is in hand. Each
    /// hides itself, and a stack with nothing in it takes no room at all — the bar's own floor
    /// never moves.
    private func configureAccessories() {
        accessories.axis = .vertical
        accessories.spacing = Theme.Spacing.xs
        accessories.translatesAutoresizingMaskIntoConstraints = false
        failureCard.isHidden = true
        suggestions.isHidden = true
        attachmentStrip.isHidden = true
        videoChips.isHidden = true
        imageChips.isHidden = true
        [failureCard, suggestions, videoChips, imageChips, attachmentStrip].forEach(
            accessories.addArrangedSubview)
        videoChips.onPick = { [weak self] field, id in
            ForgeRunner.shared.pick(field, id: id)
            Theme.Haptics.selection()
        }
        videoChips.onOpen = { [weak self] in
            Theme.Haptics.tap()
            self?.presentVideo()
        }
        imageChips.onWalk = { field in
            Theme.Haptics.selection()
            ImageStudio.shared.advance(field)
        }
        imageChips.onEngine = { engine in
            Theme.Haptics.selection()
            ImageStudio.shared.choose(engine: engine)
        }
        imageChips.onAspect = { aspect in
            Theme.Haptics.selection()
            ImageStudio.shared.choose(aspect: aspect)
        }
        imageChips.onSize = { size in
            Theme.Haptics.selection()
            ImageStudio.shared.choose(size: size)
        }
        imageChips.onDetail = { detail in
            Theme.Haptics.selection()
            ImageStudio.shared.choose(detail: detail)
        }
        imageChips.onOpen = { [weak self] in
            Theme.Haptics.tap()
            self?.presentImage()
        }
        view.addSubview(accessories)
        NSLayoutConstraint.activate([
            accessories.bottomAnchor.constraint(
                equalTo: composerBar.topAnchor, constant: -Theme.Spacing.xs),
        ])
        rails.append(ReadableRail(accessories, in: view))
        suggestions.onStarter = { [weak self] starter in self?.pickStarter(starter) }
        suggestions.onRecent = { [weak self] entry in
            Theme.Haptics.tap()
            self?.openChat(for: entry)
        }
        attachmentStrip.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            Theme.Haptics.tap()
            self.refreshAttachments()
        }
        attachmentStrip.onClearCarry = { [weak self] in
            guard let self else { return }
            self.composeCarry = nil
            Theme.Haptics.tap()
            self.refreshAttachments()
        }
        failureCard.onFix = { [weak self] in self?.applyFix() }
        failureCard.onDismiss = { [weak self] in
            Theme.Haptics.tap()
            self?.dismissFailure()
        }
        enhancement.onStatusChange = { [weak self] status in
            self?.handleEnhancementStatus(status)
        }
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    /// The composer follows the keyboard only while this screen is the one being typed into.
    ///
    /// `keyboardLayoutGuide` tracks the keyboard whether or not its own view controller is on
    /// screen, so a chat popped with its keyboard still up handed Home a guide sitting halfway up
    /// the display — and the docked bar was drawn there, floating in the middle of the screen, for
    /// as long as the dismissal took. Home has exactly one text field, so the rule is simple: the
    /// bar rests at the bottom edge, and takes the keyboard's word for where it goes only from the
    /// moment its own composer starts being typed into until this screen goes away.
    ///
    /// The floor is the safe area's bottom, which is exactly where the keyboard guide rests with
    /// no keyboard up — `usesBottomSafeArea` is on by default, so the guide is not the view's own
    /// bottom edge. Adopting it is therefore a change of authority rather than a change of
    /// position, and the bar neither hops nor spends the first tap climbing out from under the
    /// home indicator.
    func composerFollowsKeyboard(_ follows: Bool) {
        guard composerRidesKeyboard.isActive != follows else { return }
        if follows {
            composerFloor.isActive = false
            composerRidesKeyboard.isActive = true
        } else {
            composerRidesKeyboard.isActive = false
            composerFloor.isActive = true
        }
    }

    private func configureOrb() {
        orbView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(orbView)
        NSLayoutConstraint.activate([
            orbView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            orbView.bottomAnchor.constraint(equalTo: accessories.topAnchor, constant: -10),
            orbView.widthAnchor.constraint(equalToConstant: 76),
            orbView.heightAnchor.constraint(equalToConstant: 76),
        ])
        orbView.setEnabled(PresenceOrbSetting.isEnabled)
        orbView.onTap = { [weak self] in
            guard let self, let entry = self.orbTarget else { return }
            self.openChat(for: entry)
        }
        composerBar.onAuraChanged = { [weak self] in self?.applyOrbState() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(orbSettingChanged),
            name: PresenceOrbSetting.didChange, object: nil)
    }

    @objc private func orbSettingChanged() {
        orbView.setEnabled(PresenceOrbSetting.isEnabled)
        applyOrbState()
    }

    /// The orb reads the same board the list draws: what this device is streaming first-hand
    /// wins, the listing's own working flag counts, and every unreachable server rests one quiet
    /// weight on the body. The conversation a tap opens is the one that most needs the person.
    func applyOrbState() {
        guard PresenceOrbSetting.isEnabled else { return }
        var kinds: [ActivityKind?] = viewModel.entries.map { entry in
            switch SessionActivity.shared.status(for: entry.session.id) {
            case .awaitingApproval: return .needsApproval
            case .running: return .working
            case .background(let tasks): return .inBackground(tasks: tasks)
            case .stalled(let tasks): return .stalled(tasks: tasks)
            case .idle:
                if isLive(entry) { return .working }
                return entry.session.backgroundWork.map {
                    $0.stalled ? .stalled(tasks: $0.tasks) : .inBackground(tasks: $0.tasks)
                }
            }
        }
        kinds += viewModel.unreachable.map { _ in ActivityKind.offline }
        orbTarget =
            viewModel.entries.first {
                SessionActivity.shared.status(for: $0.session.id) == .awaitingApproval
            } ?? viewModel.entries.first { isLive($0) }
        orbView.update(
            signal: PresenceSignal.aggregate(kinds, ultracode: composerBar.auraIsActive))
    }

    private static func plainSection(top: CGFloat, bottom: CGFloat) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: top, leading: Theme.Spacing.l, bottom: bottom, trailing: Theme.Spacing.l)
        return section
    }

    /// A section of whole cards under a label — the questions waiting on the person, the account's
    /// quota — rather than rows sharing a surface.
    private static func headedSection(columns: Int, estimatedHeight: CGFloat) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                heightDimension: .estimated(estimatedHeight)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight)),
            repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(Theme.Spacing.m)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Spacing.m
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.xs, leading: Theme.Spacing.l, bottom: Theme.Spacing.xl,
            trailing: Theme.Spacing.l)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        ]
        return section
    }

    /// A band is one grouped list: the rows of one kind of attention, sharing a surface, with the
    /// separator starting where the text does so the state tiles read as one column.
    private static func bandSection(
        _ environment: NSCollectionLayoutEnvironment, isFooter: @escaping (IndexPath) -> Bool
    ) -> NSCollectionLayoutSection {
        var configuration = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        configuration.itemSeparatorHandler = { indexPath, separators in
            var out = separators
            out.bottomSeparatorInsets = NSDirectionalEdgeInsets(
                top: 0, leading: isFooter(indexPath) ? 0 : ChatRowContentView.textInset, bottom: 0,
                trailing: 0)
            return out
        }
        let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.l, bottom: Theme.Spacing.xl, trailing: Theme.Spacing.l)
        return section
    }

    func configureDataSource() {
        let statusCell = UICollectionView.CellRegistration<HomeStatusCell, HomeStatusCard> {
            cell, _, card in cell.configure(card)
        }
        let glanceCell = UICollectionView.CellRegistration<HomeGlanceCell, QuotaGlanceCard> {
            cell, _, card in cell.configure(card)
        }
        let alertCell = UICollectionView.CellRegistration<ServerAlertCell, ServerAlertCard> {
            [weak self] cell, _, card in
            cell.configure(card)
            cell.onRetry = { [weak self] in
                Task { await self?.load(.user) }
            }
        }
        let demoNudgeCell = UICollectionView.CellRegistration<DemoNudgeCell, DemoNudgeCard> {
            [weak self] cell, _, _ in
            cell.onSetUp = { [weak self] in self?.presentSetup() }
            cell.onNotNow = { [weak self] in self?.dismissDemoNudge() }
        }
        let supporterCell = UICollectionView.CellRegistration<SupporterCell, SupporterCard> {
            [weak self] cell, _, card in
            cell.configure(card)
            cell.onUnlock = { [weak self] in self?.openSupporterOffer() }
            cell.onNotNow = { [weak self] in self?.declineSupporterOffer() }
        }
        let chatCell = UICollectionView.CellRegistration<ChatRowCell, ChatRowCard> {
            cell, _, card in
            cell.wantsAttention = card.band == .needsYou
            cell.contentConfiguration = ChatRowConfiguration(facts: card.facts)
        }
        let askCell = UICollectionView.CellRegistration<AskCardCell, AskCard> {
            [weak self] cell, _, card in
            cell.configure(card)
            cell.onOpen = { [weak self] in self?.openChat(for: card.entry) }
        }
        let quotaCell = UICollectionView.CellRegistration<QuotaCardCell, QuotaCard> {
            cell, _, card in cell.configure(card)
        }
        let savedCell = UICollectionView.CellRegistration<ChatRowCell, SavedCard> {
            cell, _, card in
            cell.wantsAttention = false
            cell.contentConfiguration = ChatRowConfiguration(facts: card.facts)
        }
        let moreCell = UICollectionView.CellRegistration<ChatRowCell, HomeMoreCard> {
            cell, _, card in
            cell.wantsAttention = false
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "See all \(card.count) chats")
            content.textProperties.font = Theme.Ramp.font(.control)
            content.textProperties.color = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let placeholderCell = UICollectionView.CellRegistration<RecentPlaceholderCell, Int> {
            _, _, _ in
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .status(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: statusCell, for: indexPath, item: card)
            case .glance(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: glanceCell, for: indexPath, item: card)
            case .alert(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: alertCell, for: indexPath, item: card)
            case .demoNudge(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: demoNudgeCell, for: indexPath, item: card)
            case .supporter(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: supporterCell, for: indexPath, item: card)
            case .chat(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: chatCell, for: indexPath, item: card)
            case .ask(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: askCell, for: indexPath, item: card)
            case .quota(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: quotaCell, for: indexPath, item: card)
            case .saved(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: savedCell, for: indexPath, item: card)
            case .more(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: moreCell, for: indexPath, item: card)
            case .placeholder(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: placeholderCell, for: indexPath, item: index)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<HomeHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureHeader(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }
}

extension HomeViewController {
    /// A band's heading says how many it holds and what can be done to all of them, which are
    /// facts about the band rather than about any one row: a supplementary view is not
    /// reconfigured with the items, so every pass that changes the board says it again.
    fileprivate func configureHeader(_ view: HomeHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
        let count = dataSource.snapshot().numberOfItems(inSection: section)
        switch section {
        case .needsYou, .asks:
            view.configure(title: String(localized: "Needs you"), count: count, needsYou: true)
        case .working:
            view.configure(title: String(localized: "Working"), count: count)
        case .pinned:
            view.configure(title: String(localized: "Pinned"), count: count)
        case .saved:
            view.configure(
                title: String(localized: "Saved"), actionTitle: String(localized: "See all")
            ) { [weak self] in
                self?.pushSaved()
            }
        case .recent:
            view.configure(
                title: String(localized: "Recent"),
                actionTitle: hasUnreadRecents ? String(localized: "Mark read") : nil
            ) { [weak self] in
                self?.markRecentsRead()
            }
        case .usage:
            view.configure(
                title: String(localized: "Usage"), actionTitle: String(localized: "Details")
            ) { [weak self] in
                self?.pushUsage()
            }
        case .status, .glance, .alerts, .demoNudge, .supporter:
            break
        }
    }

    func refreshVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? HomeHeaderView
            else { continue }
            configureHeader(view, at: indexPath)
        }
    }
}
