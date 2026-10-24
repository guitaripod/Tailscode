import MidgarCore
import TailscodeCore
import UIKit

extension HomeViewController {
    func renderSnapshot() {
        deferredSnapshot = false
        savedChats = SavedChatStore.all()
        let today = showsToday
        let limits: HomeBandLimits = today ? .column : .phone
        let servers = viewModel.servers
        let down = hasLoadedOnce ? servers.filter { viewModel.unreachable.contains($0.id) } : []
        let archived = ArchivedChatStore.all()
        let isUnread = SessionSeenStore.unreadEvaluator()
        let pins = Set(SessionPinStore.all())
        let rows = viewModel.entries
            .filter { !archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id)) }
            .map { entry in
                SessionRowModel(
                    entry: entry, unreachable: viewModel.unreachable.contains(entry.profileID),
                    unread: isUnread(entry.session.id, entry.session.updatedAt), saved: false,
                    pinned: pins.contains(SessionPinStore.key(entry.profileID, entry.session.id)),
                    presence: SessionActivity.shared.presence(for: entry.session.id),
                    observedAt: viewModel.observedAt[entry.profileID])
            }
        let vocabulary = ChatListVocabulary(rows: rows)
        let missed = Dictionary(
            ActivityInbox.all().map { ($0.sessionID, $0.reason) }, uniquingKeysWith: { first, _ in first })

        func key(_ profileID: String, _ sessionID: String) -> String { "\(profileID)\u{1}\(sessionID)" }
        let serverIDs = Set(servers.map(\.id))
        let listed =
            savedChats.isEmpty ? Set<String>() : Set(viewModel.entries.map { key($0.profileID, $0.session.id) })
        let kept = Set(
            rows.filter { $0.state.isInFlight || $0.pinned }.map { key($0.entry.profileID, $0.entry.session.id) })
        let savedCards = Array(
            savedChats.lazy
                .filter { self.isOpenable($0, servers: serverIDs, listed: listed) }
                .filter { !kept.contains(key($0.profileID, $0.sessionID)) }
                .prefix(limits.saved)
                .map { SavedCard(chat: $0, unread: isUnread($0.sessionID, $0.updatedAt)) })
        let savedKeys = Set(savedCards.map { key($0.chat.profileID, $0.chat.sessionID) })
        let board = HomeBoard.make(
            rows: rows.filter { !savedKeys.contains(key($0.entry.profileID, $0.entry.session.id)) },
            limits: limits, offline: down.map(\.name))

        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        if hasLoadedOnce, !servers.isEmpty {
            let status = HomeStatus.reading(
                rows: rows, offline: down.map(\.name),
                range: RangeHome.line(
                    quotas: quotas, board: QuotaBoardStore.current, trail: RangeStore.trail))
            snapshot.appendSections([.status])
            snapshot.appendItems([.status(HomeStatusCard(status: status))], toSection: .status)
        }
        if !showsQuotaCards, !quotas.isEmpty {
            let glance = QuotaGlance.make(
                from: quotas.map { ("", $0) }, answeredAt: quotasAnsweredAt,
                board: QuotaBoardStore.current, trail: RangeStore.trail)
            if !glance.isEmpty {
                snapshot.appendSections([.glance])
                snapshot.appendItems([.glance(QuotaGlanceCard(glance: glance))], toSection: .glance)
            }
        }
        if !down.isEmpty {
            snapshot.appendSections([.alerts])
            snapshot.appendItems(
                [.alert(ServerAlertCard(names: down.map(\.name)))], toSection: .alerts)
        }
        if showsDemoNudge {
            snapshot.appendSections([.demoNudge])
            snapshot.appendItems([.demoNudge(DemoNudgeCard())], toSection: .demoNudge)
        }
        if SupporterInvitation.isDue(isPro: ProAccess.shared.isPro) {
            snapshot.appendSections([.supporter])
            snapshot.appendItems([.supporter(SupporterCard(price: proPrice))], toSection: .supporter)
        }

        func cards(_ band: HomeBoard.Band) -> [HomeItem] {
            band.rows.map { row in
                let id = row.entry.session.id
                return .chat(
                    ChatRowCard(
                        row: row,
                        facts: ChatRowFacts(
                            row: row, vocabulary: vocabulary,
                            ask: SessionActivity.shared.approvalAsk(for: id), missed: missed[id]),
                        band: band.section))
            }
        }
        let bands = Dictionary(uniqueKeysWithValues: board.bands.map { ($0.section, $0) })
        if today {
            let asks = (bands[.needsYou]?.rows ?? []).map { row -> HomeItem in
                let id = row.entry.session.id
                return .ask(
                    AskCard(
                        row: row,
                        facts: ChatRowFacts(
                            row: row, vocabulary: vocabulary,
                            ask: SessionActivity.shared.approvalAsk(for: id), missed: missed[id])))
            }
            if !asks.isEmpty {
                snapshot.appendSections([.asks])
                snapshot.appendItems(uniqued(asks, in: .asks), toSection: .asks)
            }
            if showsQuotaCards {
                let quotaBoard = QuotaBoardStore.current
                let shown = quotas.filter {
                    !quotaBoard.isHidden(QuotaBoard.key(providerName: $0.providerName))
                }
                if !shown.isEmpty {
                    snapshot.appendSections([.usage])
                    snapshot.appendItems(
                        shown.map { HomeItem.quota(QuotaCard(quota: $0)) }, toSection: .usage)
                }
            }
        }
        for section in today ? [] : [SessionSection.needsYou, .working, .pinned] {
            guard let band = bands[section] else { continue }
            let id = HomeSection(section)
            snapshot.appendSections([id])
            snapshot.appendItems(uniqued(cards(band), in: id), toSection: id)
        }
        if !today, !savedCards.isEmpty {
            snapshot.appendSections([.saved])
            snapshot.appendItems(
                uniqued(savedCards.map(HomeItem.saved), in: .saved), toSection: .saved)
        }
        if !today, let band = bands[.recent] {
            snapshot.appendSections([.recent])
            snapshot.appendItems(uniqued(cards(band), in: .recent), toSection: .recent)
            snapshot.appendItems(
                [.more(HomeMoreCard(band: .recent, count: rows.count))], toSection: .recent)
        } else if !today, rows.isEmpty, !hasLoadedOnce, !servers.isEmpty, workspace == nil {
            snapshot.appendSections([.recent])
            snapshot.appendItems((0..<3).map(HomeItem.placeholder), toSection: .recent)
        }

        let previous = dataSource.snapshot()
        let existing = Set(previous.itemIdentifiers)
        var content: [HomeItem: Int] = [:]
        var stale: [HomeItem] = []
        for item in snapshot.itemIdentifiers {
            let signature = item.contentSignature
            content[item] = signature
            if existing.contains(item), appliedContent[item] != signature { stale.append(item) }
        }
        appliedContent = content
        if !stale.isEmpty { snapshot.reconfigureItems(stale) }
        let rowItems = snapshot.itemIdentifiers.filter {
            switch $0 {
            case .chat, .ask, .saved, .placeholder: return true
            case .status, .glance, .quota, .alert, .demoNudge, .supporter, .more: return false
            }
        }.count
        if stale.isEmpty, previous.sectionIdentifiers == snapshot.sectionIdentifiers,
            previous.itemIdentifiers == snapshot.itemIdentifiers
        {
            refreshVisibleHeaders()
            updateEmptyState(itemCount: rowItems)
            applyOrbState()
            consumePendingDeepLink()
            return
        }
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate(from: previous, to: snapshot))
        refreshVisibleHeaders()
        updateEmptyState(itemCount: rowItems)
        applyOrbState()
        consumePendingDeepLink()
    }

    var hasUnreadRecents: Bool {
        guard dataSource.snapshot().sectionIdentifiers.contains(.recent) else { return false }
        return dataSource.snapshot().itemIdentifiers(inSection: .recent).contains {
            if case .chat(let card) = $0 { return card.facts.unread }
            return false
        }
    }

    func markRecentsRead() {
        Theme.Haptics.tap()
        for item in dataSource.snapshot().itemIdentifiers(inSection: .recent) {
            if case .chat(let card) = item, card.facts.unread {
                SessionSeenStore.markSeen(card.entry.session.id)
            }
        }
        NotificationManager.clearAllNotices()
        applySnapshot()
    }

    /// Home lists a saved chat only while it is something you can actually open.
    /// A bookmark whose conversation was deleted, or whose server was
    /// disconnected, is a tidying-up job for the Saved screen, not a launch pad.
    private func isOpenable(_ chat: SavedChat, servers: Set<String>, listed: Set<String>) -> Bool {
        guard servers.contains(chat.profileID) else { return false }
        if listed.contains("\(chat.profileID)\u{1}\(chat.sessionID)") { return true }
        return !hasLoadedOnce || viewModel.unreachable.contains(chat.profileID)
    }

    /// Only structural changes animate, and only once something is on screen to
    /// animate from: a card arriving should slide the list open rather than snap
    /// it, but the per-second content churn of a running agent must not.
    ///
    /// A reorder is not a structural change to a reader — the same cards are there — so a poll that
    /// moves the most recent chat up settles rather than animating, and nothing animates at all
    /// under a finger: a batch update landing mid-scroll fights the scroll it lands on.
    private func shouldAnimate(
        from previous: NSDiffableDataSourceSnapshot<HomeSection, HomeItem>,
        to next: NSDiffableDataSourceSnapshot<HomeSection, HomeItem>
    ) -> Bool {
        guard view.window != nil, !previous.itemIdentifiers.isEmpty,
            !collectionView.isDragging, !collectionView.isDecelerating
        else { return false }
        return previous.sectionIdentifiers != next.sectionIdentifiers
            || Set(previous.itemIdentifiers) != Set(next.itemIdentifiers)
    }

    /// What a section may be handed. A diffable snapshot given the same identifier twice does not
    /// draw the row twice — it raises, and the app is gone before the row it was drawing appears.
    /// Every list on this screen is derived from something a server said, so a duplicate is a
    /// server's account of itself changing under a poll rather than a mistake anybody can see
    /// coming; the row is dropped, and the drop is written down with the section that produced it
    /// so the next one names its own cause instead of arriving as a stack trace.
    private func uniqued(_ items: [HomeItem], in section: HomeSection) -> [HomeItem] {
        var seen = Set<HomeItem>()
        var kept: [HomeItem] = []
        for item in items where seen.insert(item).inserted { kept.append(item) }
        if kept.count != items.count {
            MidgarLog.error(
                "home: \(items.count - kept.count) duplicate row(s) dropped from \(String(describing: section))",
                category: .ui
            )
        }
        return kept
    }

    private func updateEmptyState(itemCount: Int) {
        let working = itemCount == 0 && !viewModel.isEmptyOfServers && !hasLoadedOnce
        collectionView.backgroundView = nil
        collectionView.showsWork(working)
        if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = String(localized: "No servers connected")
            config.secondaryText = String(
                localized: "Add a connection in Settings to start chatting with your agents.")
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }
}
