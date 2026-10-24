import TailscodeCore
import UIKit

extension AgentsBoardViewController {
    func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            self?.section(at: index, environment: environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func section(
        at index: Int, environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection? {
        guard let identifier = dataSource.sectionIdentifier(for: index) else { return nil }
        let estimate: CGFloat = identifier == .needsYou ? 200 : 84
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimate))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        let side = AgentsLayout.side(for: environment.container.effectiveContentSize.width)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: identifier == .header ? Theme.Spacing.s : 0, leading: side,
            bottom: Theme.Spacing.s, trailing: side)
        section.interGroupSpacing = identifier == .needsYou ? Theme.Spacing.m : 0
        if identifier != .header {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
        }
        return section
    }

    func configureDataSource() {
        let header = UICollectionView.CellRegistration<AgentsHeaderCell, AgentsItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(self.board)
        }
        let empty = UICollectionView.CellRegistration<AgentsEmptyCell, AgentsItem> { _, _, _ in }
        let ask = UICollectionView.CellRegistration<AgentsAskCell, String> {
            [weak self] cell, _, id in
            guard let self, let card = self.board.ask(id) else { return }
            cell.configure(
                card, state: self.actionStates[card.ask.id], showsMachines: self.board.showsMachines,
                heard: self.hub.lastHeard(card.profileID), now: Date())
            cell.onDecide = { [weak self] allow in self?.decide(card, allow: allow) }
            cell.onOption = { [weak self] option in self?.choose(card, option: option) }
            cell.onOpenChat = { [weak self] in
                self?.openChat(profileID: card.profileID, sessionID: card.sessionID)
            }
        }
        let row = UICollectionView.CellRegistration<AgentsRowCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = self.board.row(id) else { return }
            cell.configure(
                row, background: self.board.background.contains { $0.id == id },
                showsMachines: self.board.showsMachines, expanded: self.expanded.contains(id),
                heard: self.hub.lastHeard(row.profileID), now: Date())
            cell.onOpenChat = { [weak self] in
                self?.openChat(profileID: row.profileID, sessionID: row.sessionID)
            }
            cell.onToggleChildren = { [weak self] in self?.toggleChildren(id) }
        }
        let finish = UICollectionView.CellRegistration<AgentsFinishCell, String> {
            [weak self] cell, _, id in
            guard let self, let finish = self.board.finish(id) else { return }
            cell.configure(finish, showsMachines: self.board.showsMachines, now: Date())
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(
                    using: header, for: indexPath, item: item)
            case .empty:
                return collectionView.dequeueConfiguredReusableCell(
                    using: empty, for: indexPath, item: item)
            case .ask(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: ask, for: indexPath, item: id)
            case .row(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: row, for: indexPath, item: id)
            case .finish(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: finish, for: indexPath, item: id)
            }
        }
        let sectionHeader = UICollectionView.SupplementaryRegistration<AgentsSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureSectionHeader(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeader, for: indexPath)
        }
    }

    private func configureSectionHeader(_ view: AgentsSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section),
            let title = section.title
        else { return }
        let count = dataSource.snapshot().numberOfItems(inSection: section)
        let unread = section == .finished ? board.headline.unread : 0
        view.configure(
            title: title, count: count,
            detail: unread > 0 ? String(localized: "\(unread) unread") : nil,
            urgent: section == .needsYou)
    }

    func refreshSectionHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? AgentsSectionHeaderView
            else { continue }
            configureSectionHeader(view, at: indexPath)
        }
    }
}

extension AgentsBoardViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath)?.key != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.tap()
        switch item {
        case .ask(let id):
            if let card = board.ask(id) { presentPeek(AgentsPeekTarget(ask: card)) }
        case .row(let id):
            if let row = board.row(id) { presentPeek(AgentsPeekTarget(row: row)) }
        case .finish(let id):
            if let finish = board.finish(id) {
                openChat(profileID: finish.profileID, sessionID: finish.sessionID)
            }
        case .header, .empty:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        var target: AgentsPeekTarget?
        var identity: (profileID: String, sessionID: String)?
        switch item {
        case .ask(let id):
            guard let card = board.ask(id) else { return nil }
            target = AgentsPeekTarget(ask: card)
            identity = (card.profileID, card.sessionID)
        case .row(let id):
            guard let row = board.row(id) else { return nil }
            target = AgentsPeekTarget(row: row)
            identity = (row.profileID, row.sessionID)
        case .finish(let id):
            guard let finish = board.finish(id) else { return nil }
            identity = (finish.profileID, finish.sessionID)
        case .header, .empty:
            return nil
        }
        guard let identity else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if let target {
                actions.append(
                    UIAction(title: String(localized: "Peek"), image: UIImage(systemName: "eye")) {
                        _ in self?.presentPeek(target)
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Open chat"), image: UIImage(systemName: "bubble.left")
                ) { _ in self?.openChat(profileID: identity.profileID, sessionID: identity.sessionID) })
            return UIMenu(children: actions)
        }
    }
}
