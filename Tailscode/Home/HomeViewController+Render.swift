import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

extension HomeViewController {
    /// Rebuilds the board now, on the main thread: what a press, a fold or a page of RECENT needs,
    /// because the person is looking at the very row that moves.
    func renderSnapshot() {
        #if DEBUG
            let passBegan = BoardBench.cpuTime()
            var bench = BoardBench.Stages()
            defer {
                bench.mark("rest")
                BoardBench.note(pass: BoardBench.cpuTime() - passBegan, stages: bench)
            }
        #endif
        boardGeneration += 1
        let plan = boardPlan()
        #if DEBUG
            bench.mark("plan")
        #endif
        let walk = HomeBoardWalk.make(plan.input)
        #if DEBUG
            bench.mark("walk")
            present(walk, plan: plan, bench: &bench)
        #else
            present(walk, plan: plan)
        #endif
    }

    /// Rebuilds the board for something the listing or a store said, which nobody pressed: the
    /// fleet is walked off the main thread (``HomeBoardWalk``) and only the drawing comes back to
    /// it. A rebuild asked for after this one started, or a press drawn in the meantime, makes this
    /// one stale and it is dropped; one that lands under a finger waits for the scroll to end.
    func renderSnapshotAway() {
        boardGeneration += 1
        let generation = boardGeneration
        deferredSnapshot = false
        #if DEBUG
            let planBegan = BoardBench.cpuTime()
        #endif
        let plan = boardPlan()
        #if DEBUG
            let planned = BoardBench.cpuTime() - planBegan
        #endif
        Task { @MainActor [weak self] in
            let (walk, spent) = await HomeBoardWalk.away(plan.input)
            guard let self, self.boardGeneration == generation else { return }
            guard self.viewIfLoaded?.window != nil, !self.isUnderSettings, !self.isLeaving else {
                self.deferredSnapshot = true
                return
            }
            guard !self.isUnderFinger else {
                self.deferredWhileTouching = true
                return
            }
            #if DEBUG
                let passBegan = BoardBench.cpuTime() - planned
                var bench = BoardBench.Stages(spent: planned, as: "plan")
                bench.note(away: spent)
                defer {
                    bench.mark("rest")
                    BoardBench.note(pass: BoardBench.cpuTime() - passBegan, stages: bench)
                }
                self.present(walk, plan: plan, bench: &bench)
            #else
                self.present(walk, plan: plan)
            #endif
        }
    }

    /// Whether a hand, or the bench standing in for one, is moving the board.
    var isUnderFinger: Bool {
        #if DEBUG
            if BoardBench.isDrivingScroll { return true }
        #endif
        return collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    /// What a rebuild reads on the main thread before the fleet is walked: the stores, the activity
    /// this device witnesses, the notices and the shape of the screen.
    struct BoardPlan {
        let input: HomeBoardWalk.Input
        let readings: StoreReadings
        let presence: [String: SessionPresence]
        let missed: [String: MissedActivity.Reason]
        let today: Bool
        let limits: HomeBandLimits
        let folds: Set<SessionSection>
        let servers: [ConnectionProfile]
        let down: [ConnectionProfile]
    }

    private func boardPlan() -> BoardPlan {
        deferredSnapshot = false
        lastRenderAt = Date()
        let readings = storeReadings()
        let today = showsToday
        let limits = (today ? HomeBandLimits.column : .phone).reaching(recentReach)
        let servers = viewModel.servers
        let down = hasLoadedOnce ? servers.filter { viewModel.unreachable.contains($0.id) } : []
        let presence = SessionActivity.shared.presenceSummary()
        let missed = Dictionary(
            ActivityInbox.all().map { ($0.sessionID, $0.reason) }, uniquingKeysWith: { first, _ in first })
        let input = HomeBoardWalk.Input(
            entries: viewModel.entries, unreachable: viewModel.unreachable, archived: readings.archived,
            pins: readings.pins, unread: readings.unread, presence: presence, saved: readings.saved,
            serverIDs: Set(servers.map(\.id)), limits: limits, hasLoadedOnce: hasLoadedOnce,
            notices: missed.count,
            status: hasLoadedOnce && !servers.isEmpty
                ? HomeBoardWalk.StatusInput(
                    offline: down.map(\.name), quotas: quotas, board: readings.quotaBoard,
                    trail: readings.trail)
                : nil)
        return BoardPlan(
            input: input, readings: readings, presence: presence, missed: missed, today: today,
            limits: limits, folds: today ? [] : readings.folds, servers: servers, down: down)
    }

    #if DEBUG
        private func present(_ walk: HomeBoardWalk, plan: BoardPlan, bench: inout BoardBench.Stages) {
            presentBoard(walk, plan: plan) { bench.mark($0) }
        }
    #endif

    private func present(_ walk: HomeBoardWalk, plan: BoardPlan) {
        presentBoard(walk, plan: plan) { _ in }
    }

    /// Draws what a walk found: the cards for the rows that are drawn, the snapshot, and only the
    /// cards whose words moved reconfigured.
    private func presentBoard(_ walk: HomeBoardWalk, plan: BoardPlan, mark: (String) -> Void) {
        let readings = plan.readings
        let today = plan.today
        let folds = plan.folds
        let servers = plan.servers
        let down = plan.down
        let missed = plan.missed
        let vocabulary = walk.vocabulary
        savedChats = readings.saved
        appliedPresence = plan.presence
        appliedVocabulary = vocabulary
        appliedMissed = missed
        let savedCards = walk.saved.map { SavedCard(chat: $0.chat, unread: $0.unread) }
        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        if hasLoadedOnce, !servers.isEmpty, let status = walk.status {
            snapshot.appendSections([.status])
            snapshot.appendItems([.status(HomeStatusCard(status: status))], toSection: .status)
            if let line = scheduleLine {
                snapshot.appendSections([.schedule])
                snapshot.appendItems([.schedule(line)], toSection: .schedule)
            }
            if let news = agentNews {
                snapshot.appendSections([.agentNews])
                snapshot.appendItems([.agentNews(news)], toSection: .agentNews)
            }
        }
        mark("status")
        appendShelf(to: &snapshot, masters: hasLoadedOnce && !servers.isEmpty ? masterShelf : nil)
        mark("shelf")
        if let reach = ReachReading.here(
            silent: down.map(\.name), answering: servers.count - down.count)
        {
            snapshot.appendSections([.alerts])
            snapshot.appendItems([.alert(ServerAlertCard(reading: reach))], toSection: .alerts)
        }
        if showsDemoNudge {
            snapshot.appendSections([.demoNudge])
            snapshot.appendItems([.demoNudge(DemoNudgeCard())], toSection: .demoNudge)
        }
        if ProInvitation.isDue(isPro: ProAccess.shared.hasProAccess) {
            snapshot.appendSections([.proInvitation])
            let gift = ProInvitation.gift(canStartWeek: ProAccess.shared.canStartProWeek)
            let card = ProInvitationCard(
                gift: gift, price: gift == .pro ? proPrice : nil,
                facts: ProPersonalDetails.Facts(turns: ReviewPromptPolicy.successCount))
            snapshot.appendItems([.proInvitation(card)], toSection: .proInvitation)
        }

        func cards(_ band: HomeBoard.Band<HomeRowSeed>) -> [HomeItem] {
            band.rows.map { seed in
                let id = seed.entry.session.id
                let row = SessionRowModel(
                    seed: seed, observedAt: viewModel.observedAt[seed.entry.profileID])
                return .chat(
                    ChatRowCard(
                        row: row,
                        facts: ChatRowFacts(
                            row: row, vocabulary: vocabulary,
                            ask: SessionActivity.shared.approvalAsk(for: id), missed: missed[id],
                            section: band.section),
                        band: band.section))
            }
        }
        let bands = Dictionary(uniqueKeysWithValues: walk.bands.map { ($0.section, $0) })
        if today {
            let asks = (bands[.needsYou]?.rows ?? []).map { seed -> HomeItem in
                let id = seed.entry.session.id
                let row = SessionRowModel(
                    seed: seed, observedAt: viewModel.observedAt[seed.entry.profileID])
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
                        shown.map { HomeItem.quota(QuotaCard(quota: QuotaReset.settled($0))) },
                        toSection: .usage)
                }
            }
        }
        var bandCounts: [HomeSection: (total: Int, fresh: Int)] = [:]
        for section in today ? [] : [SessionSection.needsYou, .working, .pinned] {
            guard let band = bands[section] else { continue }
            let id = HomeSection(section)
            snapshot.appendSections([id])
            bandCounts[id] = (band.total, band.fresh)
            guard !folds.contains(section) else { continue }
            snapshot.appendItems(uniqued(cards(band), in: id), toSection: id)
        }
        if !today, !savedCards.isEmpty {
            snapshot.appendSections([.saved])
            bandCounts[.saved] = (savedCards.count, savedCards.count { $0.facts.unread })
            if !folds.contains(.saved) {
                snapshot.appendItems(
                    uniqued(savedCards.map(HomeItem.saved), in: .saved), toSection: .saved)
            }
        }
        if !today, let band = bands[.recent] {
            snapshot.appendSections([.recent])
            bandCounts[.recent] = (band.total, band.fresh)
            if !folds.contains(.recent) {
                snapshot.appendItems(uniqued(cards(band), in: .recent), toSection: .recent)
                if let foot = recentReach.foot(hidden: band.hidden) {
                    snapshot.appendItems(
                        [.more(HomeMoreCard(band: .recent, foot: foot))], toSection: .recent)
                }
            }
        } else if !today, walk.isEmpty, !hasLoadedOnce, !servers.isEmpty, workspace == nil {
            snapshot.appendSections([.recent])
            snapshot.appendItems((0..<3).map(HomeItem.placeholder), toSection: .recent)
        }
        mark("cards")
        bandReadings = bandCounts
        canReachFurther = !today && !folds.contains(.recent) && (bands[.recent]?.hidden ?? 0) > 0
        hasNews = walk.hasNews
        mark("snapshot")

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
        boardItems = Dictionary(snapshot.itemIdentifiers.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        mark("compare")
        let rowItems = snapshot.itemIdentifiers.filter {
            switch $0 {
            case .chat, .ask, .saved, .placeholder: return true
            case .status, .schedule, .agentNews, .shelfBar, .masters, .glance, .quota, .alert, .demoNudge, .proInvitation,
                .more:
                return false
            }
        }.count
        if previous.sectionIdentifiers == snapshot.sectionIdentifiers,
            previous.itemIdentifiers == snapshot.itemIdentifiers
        {
            if redrawInPlace(stale) {
                mark("redraw")
            } else {
                snapshot.reconfigureItems(stale)
                dataSource.apply(snapshot, animatingDifferences: false)
                mark("fallback")
            }
            refreshVisibleHeaders()
            updateEmptyState(itemCount: rowItems)
            applyOrbState()
            consumePendingDeepLink()
            return
        }
        if !stale.isEmpty { snapshot.reconfigureItems(stale) }
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate(from: previous, to: snapshot))
        mark("apply")
        refreshVisibleHeaders()
        updateEmptyState(itemCount: rowItems)
        applyOrbState()
        consumePendingDeepLink()
    }

    /// Reads everything at once: every unread chat on every server, under any fold and below any
    /// foot, the archived and the saved with them, and every notice still standing. A turn still
    /// running is left to say its ending when it lands (``ReadSweep``).
    func markEverythingRead() {
        EverythingRead.perform(
            EverythingRead.sweep(entries: viewModel.entries, unreachable: viewModel.unreachable))
        forgetStoreReadings()
        renderSnapshot()
    }

    /// RECENT's next page, taken as its foot comes within a screen of the glass while a hand is
    /// scrolling the board, so every chat is on Home without a press. It lands after the scroll
    /// event that asked for it, once, and a board that is no longer cut short ignores it; a press
    /// on Show fewer moves no hand, so the band it shrinks stays shrunk until the board is scrolled.
    func reachFurther(in scrollView: UIScrollView) {
        guard canReachFurther, !reachRequested,
            scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        else { return }
        let below = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height
        guard below < scrollView.bounds.height else { return }
        reachRequested = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reachRequested = false
            guard self.canReachFurther else { return }
            self.recentReach.press(.more(hidden: 0))
            self.renderSnapshot()
        }
    }

    /// Shuts a band or opens it again, the rows leaving and arriving under the heading that stays.
    func toggleFold(_ section: SessionSection) {
        let shut = HomeFolds.toggle(section)
        if shut, section == .recent { recentReach = HomeReach() }
        forgetStoreReadings()
        renderSnapshot()
        UIAccessibility.post(
            notification: .layoutChanged,
            argument: shut ? String(localized: "Collapsed") : String(localized: "Expanded"))
    }

    /// The foot of RECENT: another page of chats arrives under the ones already there, each rising
    /// into its place a beat after the one above it, or the band goes back to the board's height.
    func pressFoot(_ foot: HomeReach.Foot) {
        Theme.Haptics.selection()
        let before = Set(dataSource.snapshot().itemIdentifiers)
        recentReach.press(foot)
        renderSnapshot()
        guard case .more = foot, !UIAccessibility.isReduceMotionEnabled else { return }
        collectionView.layoutIfNeeded()
        let arrivals = dataSource.snapshot().itemIdentifiers(inSection: .recent)
            .filter { !before.contains($0) }
            .compactMap { dataSource.indexPath(for: $0) }
            .compactMap { collectionView.cellForItem(at: $0) }
        for (index, cell) in arrivals.enumerated() {
            let content = cell.contentView
            content.alpha = 0
            content.transform = CGAffineTransform(translationX: 0, y: -12)
            UIView.animate(
                withDuration: 0.42, delay: 0.035 * Double(index), usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0, options: [.allowUserInteraction]
            ) {
                content.alpha = 1
                content.transform = .identity
            }
        }
    }

    /// The card at a place in the list as it was last worded, which can be newer than the
    /// snapshot the list holds (``redrawInPlace(_:)``).
    func boardItem(at indexPath: IndexPath) -> HomeItem? {
        dataSource.itemIdentifier(for: indexPath).map { boardItems[$0] ?? $0 }
    }

    /// Redraws the cards among `items` that are on screen, from their newest values, without
    /// applying a snapshot, and says whether it could. Their identity and order are what the list
    /// already holds, so there is nothing to diff, and applying a snapshot anyway re-measured every
    /// visible card: five to ten milliseconds of an iPhone Air's main thread for a pass that changed
    /// one card's words, once or twice a second while agents work. Each card is dressed by the same
    /// function its registration uses and measured again on its own; one the list has not put on
    /// screen is dressed from ``boardItems`` when it comes (``redrawIfStale(_:at:)``). A set holding
    /// any kind that is not redrawn in place (``HomeItem/redrawsInPlace``) is left to a snapshot.
    /// UIKit's own `reconfigureItems(at:)` is not an option: a list run by a diffable data source
    /// raises on it.
    func redrawInPlace(_ items: [HomeItem]) -> Bool {
        guard items.allSatisfy(\.redrawsInPlace) else { return false }
        for item in items {
            guard let path = dataSource.indexPath(for: item),
                let cell = collectionView.cellForItem(at: path)
            else { continue }
            dress(cell, with: item)
            cell.invalidateIntrinsicContentSize()
        }
        return true
    }

    /// A card coming on screen that the list made before its words last moved — prefetched ahead of
    /// the scroll — is dressed again from its newest value.
    func redrawIfStale(_ cell: UICollectionViewCell, at indexPath: IndexPath) {
        guard let item = boardItem(at: indexPath), let row = cell as? ChatRowCell else { return }
        let facts: ChatRowFacts
        switch item {
        case .chat(let card): facts = card.facts
        case .saved(let card): facts = card.facts
        default: return
        }
        guard (row.contentConfiguration as? ChatRowConfiguration)?.facts != facts else { return }
        dress(cell, with: item)
    }

    private func dress(_ cell: UICollectionViewCell, with item: HomeItem) {
        switch item {
        case .chat(let card):
            (cell as? ChatRowCell).map { Self.dress($0, facts: card.facts, attention: card.band == .needsYou) }
        case .saved(let card):
            (cell as? ChatRowCell).map { Self.dress($0, facts: card.facts, attention: false) }
        case .status(let card):
            (cell as? HomeStatusCell)?.configure(card)
        case .glance(let card):
            (cell as? HomeGlanceCell)?.configure(card)
        case .shelfBar(let card):
            (cell as? HomeShelfBarCell)?.configure(card)
        case .quota(let card):
            (cell as? QuotaCardCell)?.configure(card)
        case .schedule, .agentNews, .masters, .alert, .demoNudge, .proInvitation, .ask, .more, .placeholder:
            return
        }
    }

    /// How a chat card's cell is dressed, by its registration and by a redraw in place alike.
    static func dress(_ cell: ChatRowCell, facts: ChatRowFacts, attention: Bool) {
        cell.wantsAttention = attention
        cell.contentConfiguration = ChatRowConfiguration(facts: facts)
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

    /// The bar that stands for the masters and the quotas, and under it whichever of the two the
    /// person has out. A card whose button is gone (no master yet, a pane tall enough to draw the
    /// quota cards whole) is not out, whatever was remembered.
    private func appendShelf(
        to snapshot: inout NSDiffableDataSourceSnapshot<HomeSection, HomeItem>, masters: MasterShelfCard?
    ) {
        let readings = storeReadings()
        var glance: QuotaGlance?
        let reports = quotas.map { ("", $0) }
        if !showsQuotaCards, !quotas.isEmpty {
            let made = QuotaGlance.make(
                from: reports, answeredAt: quotasAnsweredAt,
                board: readings.quotaBoard, trail: readings.trail)
            if !made.isEmpty { glance = made }
        }
        guard masters != nil || glance != nil else { return }
        var peek = HomeShelfPeek.current
        if peek == .masters, masters == nil { peek = .none }
        if peek == .quota, glance == nil { peek = .none }
        snapshot.appendSections([.shelfBar])
        snapshot.appendItems(
            [.shelfBar(HomeShelfBarCard(masters: masters?.board, glance: glance, peek: peek))],
            toSection: .shelfBar)
        if peek == .masters, let masters {
            snapshot.appendSections([.masters])
            snapshot.appendItems([.masters(masters)], toSection: .masters)
        }
        if peek == .quota, glance != nil {
            let opened = QuotaGlance.make(
                from: reports, answeredAt: quotasAnsweredAt,
                board: readings.quotaBoard, trail: readings.trail, everyWindow: true)
            snapshot.appendSections([.glance])
            snapshot.appendItems(
                [.glance(QuotaGlanceCard(glance: opened.isEmpty ? glance! : opened))],
                toSection: .glance)
        }
    }

    /// The stores as the board last read them, decoded on demand. Something that changes one of
    /// them calls ``forgetStoreReadings()``; a listing push does not, because nothing a push
    /// carries lives in them.
    func storeReadings() -> StoreReadings {
        if let readingsCache { return readingsCache }
        let made = StoreReadings(
            saved: SavedChatStore.all(), archived: ArchivedChatStore.keys(),
            pins: Set(SessionPinStore.all()), unread: SessionSeenStore.unreadEvaluator(),
            folds: HomeFolds.shut(), quotaBoard: QuotaBoardStore.current, trail: RangeStore.trail)
        readingsCache = made
        return made
    }

    func forgetStoreReadings() {
        readingsCache = nil
    }
}
