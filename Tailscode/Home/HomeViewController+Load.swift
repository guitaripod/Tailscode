import TailscodeCore
import UIKit

extension HomeViewController {
    /// The last numbers the app landed anywhere — background refresh, silent
    /// push, widget — shared on disk. Painting them first means the usage
    /// section carries real figures from the first frame instead of waiting on a
    /// live fetch and a multi-server scan that between them can take a minute.
    func seedCachedQuotas() {
        let cached = UsageWidgetStore.cachedQuotas()
        guard !cached.isEmpty else { return }
        quotas = cached
        quotasAnsweredAt = UsageWidgetStore.read()?.date
    }

    /// Home is a status board, so it keeps itself current while it is on screen:
    /// a chat started from a terminal, a turn that finishes, an agent that stops
    /// to ask something — all of it lands without a pull. Quick cadence while
    /// anything is live, slow when the board is quiet, and stopped outright when
    /// the screen is off or the app is inactive so nothing polls in the
    /// background.
    /// The board's durations move on their own clock, not on the data poll.
    ///
    /// A card's age is baked into its diffable content, so without something driving a redraw a
    /// running turn's elapsed sat frozen for the ten seconds between listings and then jumped. This
    /// ticks once a second, costs no network, and — because `contentSignature` gates the
    /// reconfigure — repaints only the cards whose text actually changed. It runs only while a card
    /// is genuinely counting: an unreachable host's frozen age has nothing to say every second, and
    /// a board of idle chats has no reason to wake the CPU at all.
    func startClockTick() {
        guard clockTickTask == nil, viewIfLoaded?.window != nil, isSceneForeground, !isUnderSettings
        else { return }
        clockTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                guard self.hasTickingCard else { continue }
                self.redrawTickedBoardIfNeeded()
            }
        }
    }

    private func stopClockTick() {
        clockTickTask?.cancel()
        clockTickTask = nil
    }

    /// Rebuilds the board when the clock has changed something on it, and does nothing otherwise.
    ///
    /// A tick only moves text that counts itself: an age or a background task's duration, which
    /// reads in seconds under a minute and in whole minutes above it. Building the board to find
    /// out whether that happened cost the phone most of a frame every second — every row on every
    /// server measured and worded again — for a screen whose cards read the same. So the cards that
    /// are actually drawn are re-worded in place, and a full pass runs only when the minute turned
    /// and the minute-granular text (a quota countdown, the status line, a master's age) can have.
    private func redrawTickedBoardIfNeeded() {
        let now = Date()
        defer { lastTickAt = now }
        guard Int(now.timeIntervalSince1970 / 60) == Int(lastTickAt.timeIntervalSince1970 / 60)
        else { return applySnapshot() }
        refreshTickedCards(asOf: now)
    }

    /// Reconfigures only the drawn cards whose own words have moved on, from their newest values
    /// (``redrawInPlace(_:)``): identity is the chat, so nothing moves, no agent is asked, no
    /// snapshot is applied, and the fleet is not walked.
    private func refreshTickedCards(asOf now: Date) {
        #if DEBUG
            let began = BoardBench.cpuTime()
            var retimedCards = 0
        #endif
        defer {
            #if DEBUG
                BoardBench.note(tick: BoardBench.cpuTime() - began, cards: retimedCards)
            #endif
        }
        guard viewIfLoaded?.window != nil, !isUnderSettings, !isLeaving, !isUnderFinger else { return }
        var changed: [HomeItem] = []
        for listed in dataSource.snapshot().itemIdentifiers {
            let item = boardItems[listed] ?? listed
            guard needsRetiming(item, at: now) else { continue }
            let updated = retimed(item, at: now)
            let signature = updated.contentSignature
            guard signature != item.contentSignature else { continue }
            boardItems[updated] = updated
            appliedContent[updated] = signature
            changed.append(updated)
        }
        guard !changed.isEmpty else { return }
        #if DEBUG
            retimedCards = changed.count
        #endif
        lastRenderAt = now
        guard !redrawInPlace(changed) else { return }
        var current = dataSource.snapshot()
        current.reconfigureItems(changed)
        dataSource.apply(current, animatingDifferences: false)
    }

    /// Whether a drawn card's own clock has moved on since it was worded. An age reads in seconds
    /// under a minute and in whole minutes above it, so most cards say the same words for a
    /// minute: asking first costs one string and saves rebuilding the row and its facts.
    private func needsRetiming(_ item: HomeItem, at now: Date) -> Bool {
        switch item {
        case .chat(let card):
            guard card.row.entry.session.backgroundWork == nil else { return true }
            return age(card, at: now)
        case .ask(let card):
            guard card.row.entry.session.backgroundWork == nil else { return true }
            return age(card.row, card.facts.age, at: now)
        case .saved(let card):
            return SessionRowModel.age(of: card.chat.updatedAt, asOf: now) != card.facts.age
        default:
            return false
        }
    }

    private func age(_ card: ChatRowCard, at now: Date) -> Bool {
        age(card.row, card.facts.age, at: now)
    }

    private func age(_ row: SessionRowModel, _ drawn: String, at now: Date) -> Bool {
        let reference: Date
        if row.state == .offline {
            reference = viewModel.observedAt[row.entry.profileID] ?? now
        } else {
            reference = now
        }
        return SessionRowModel.age(of: row.entry.session.updatedAt, asOf: reference) != drawn
    }

    /// The same card, worded against `now`. A row's age and the duration of work it carries are
    /// baked into its facts, so the row itself is rebuilt — one row, not the board.
    private func retimed(_ item: HomeItem, at now: Date) -> HomeItem {
        switch item {
        case .chat(let card):
            let row = retimed(card.row, at: now)
            return .chat(
                ChatRowCard(
                    row: row,
                    facts: ChatRowFacts(
                        row: row, vocabulary: appliedVocabulary,
                        ask: SessionActivity.shared.approvalAsk(for: card.entry.session.id),
                        missed: appliedMissed[card.entry.session.id], section: card.band),
                    band: card.band))
        case .ask(let card):
            let row = retimed(card.row, at: now)
            return .ask(
                AskCard(
                    row: row,
                    facts: ChatRowFacts(
                        row: row, vocabulary: appliedVocabulary,
                        ask: SessionActivity.shared.approvalAsk(for: card.entry.session.id),
                        missed: appliedMissed[card.entry.session.id])))
        case .saved(let card):
            return .saved(SavedCard(chat: card.chat, unread: card.facts.unread))
        default:
            return item
        }
    }

    private func retimed(_ row: SessionRowModel, at now: Date) -> SessionRowModel {
        SessionRowModel(
            entry: row.entry, unreachable: viewModel.unreachable.contains(row.entry.profileID),
            unread: row.unread, saved: row.saved, pinned: row.pinned,
            presence: appliedPresence[row.entry.session.id] ?? .unobserved,
            observedAt: viewModel.observedAt[row.entry.profileID], now: now)
    }

    /// Whether any card on the board is measuring against `now` rather than against a host that
    /// stopped answering. Only these move, so only these are worth a repaint.
    private var hasTickingCard: Bool {
        viewModel.entries.contains {
            isLive($0) && !viewModel.unreachable.contains($0.profileID)
        }
    }

    func startLiveRefresh() {
        startClockTick()
        guard liveRefreshTask == nil, viewIfLoaded?.window != nil, isSceneForeground, !isUnderSettings
        else { return }
        liveRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.liveRefreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                await self.load(.poll)
            }
        }
    }

    func stopLiveRefresh() {
        stopClockTick()
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    /// Paced against what a listing actually costs: a bridge with hundreds of
    /// sessions spends seconds folding transcripts for one, so a tighter loop
    /// would keep every server permanently busy for a board the user only
    /// glances at. Turns this device drives repaint from their own stream in
    /// between, not from this.
    private var liveRefreshInterval: Double {
        viewModel.entries.contains(where: isLive) ? 10 : 30
    }
    /// Why the list is being refreshed, which decides how eagerly the expensive
    /// parts run: a load the user asked for re-runs the quota and scan work,
    /// while the background cadence rides on throttled enrichment. Reachability
    /// is not on this dial — a server is judged the same way whoever asked.
    enum LoadReason {
        case user, appear, poll
    }

    /// The session fan-out alone decides when the pull-to-refresh spinner stops:
    /// quota and scan work is best-effort enrichment, and an unreachable server
    /// makes each of those calls sit on the 30s request timeout. Blocking the
    /// spinner behind them made a single dead tailnet peer look like a broken
    /// refresh for two minutes.
    /// `viewWillAppear`, scene activation, pull-to-refresh and post-action
    /// reloads can all fire within the same second; against an unreachable
    /// server every one of them parks on the request timeout, so they share a
    /// single in-flight load rather than queueing up behind each other.
    func load(_ reason: LoadReason = .appear) async {
        if let inFlight = loadTask {
            await inFlight.value
            if reason == .user { startEnrichment(force: true) }
            refreshControl.endRefreshing()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(reason)
        }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    private func performLoad(_ reason: LoadReason) async {
        await viewModel.load()
        refreshControl.endRefreshing()
        hasLoadedOnce = true
        MachineDesk.shared.refresh(force: reason == .user)
        MasterDesk.shared.refresh(force: reason == .user)
        HomeQuickActions.refresh(entries: viewModel.entries)
        updateComposer()
        applySnapshot()
        await adoptDeliveredNotices()
        startEnrichment(force: reason == .user)
    }

    /// A notice the bridge pushed while the app was not running was never written down here, so
    /// the listing that just landed is the first moment its session can be placed on a server.
    private func adoptDeliveredNotices() async {
        let owners = Dictionary(
            viewModel.entries.map { ($0.session.id, $0.profileID) }, uniquingKeysWith: { first, _ in
                first
            })
        let live = Set(
            viewModel.entries.filter { $0.session.isWorking }.map(\.session.id)
        ).union(
            SessionActivity.shared.statuses.filter { $0.value != .idle }.map(\.key))
        NoticeOwners.remember(owners)
        await NotificationManager.adoptDelivered(
            profileForSession: { owners[$0] }, liveSessionIDs: live)
    }

    /// Deliberately not awaited by `performLoad`: quota and scan work is
    /// enrichment layered onto an already-painted list, so it must never hold
    /// the refresh spinner — nor a caller that coalesced onto this load, which
    /// is how pull-to-refresh ended up waiting on an unreachable server twice
    /// over.
    /// Unforced callers (returning to Home, the live-refresh cadence) are rate
    /// limited: quotas move on the scale of minutes, and re-running the whole
    /// fan-out every few seconds would burn a request per server per tick for
    /// numbers that cannot have changed.
    /// Never restarts work that is already running: launch starts the fetch and `didBecomeActive`
    /// lands a moment later, and cancelling a half-second-old fetch to start the same one again
    /// only makes the board wait longer for the numbers it is already getting.
    private func startEnrichment(force: Bool) {
        guard !isEnriching else { return }
        if !force, let last = lastEnrichment, Date().timeIntervalSince(last) < 90 { return }
        lastEnrichment = Date()
        isEnriching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadEnrichment()
            self.isEnriching = false
        }
    }

    private func loadEnrichment() async {
        await loadQuotas()
        applySnapshot()
    }

    /// A bridge answers for every provider its host machine is signed into,
    /// but not every bridge host has live quota data — take the first Claude
    /// profile whose bridge does.
    /// Delegates to the same deadline-bounded fetcher the widget and the
    /// background refresh use — it already queries every bridge concurrently,
    /// keeps the partial haul when the deadline fires, and resolves the
    /// first-bridge-wins-per-provider ordering. Home previously carried a
    /// third, unbounded copy of that logic. An empty result means nothing
    /// answered in time, which must not blank a good card.
    private func loadQuotas() async {
        let fetched = await LiveQuotaFetcher.fetch(deadline: 10)
        quotas = QuotaKeeping.carry(
            fetched.map { ("", $0) }, held: UsageWidgetStore.heldReadings(), now: Date()
        ).map(\.1)
        if let deepseek = UsageWidgetStore.cachedQuotas()
            .first(where: { $0.providerName == DeepSeekBalance.providerName })
        {
            quotas = quotas.filter { $0.providerName != DeepSeekBalance.providerName } + [deepseek]
        }
        if let ollama = UsageWidgetStore.cachedQuotas()
            .first(where: { $0.providerName == OllamaCloud.providerName })
        {
            quotas = quotas.filter { $0.providerName != OllamaCloud.providerName } + [ollama]
        }
        guard !quotas.isEmpty else { return }
        quotasAnsweredAt = Date()
        UsageWidgetStore.writeLive(fetched)
        UsageWarnings.evaluate(quotas: fetched)
        RangeRecorder.observe(quotas: quotas)
        if let deepseek = UsageWidgetStore.read()?.providers
            .first(where: { $0.providerName == DeepSeekBalance.providerName })
        {
            UsageWarnings.evaluate(providers: [deepseek])
        }
        if let ollama = UsageWidgetStore.read()?.providers
            .first(where: { $0.providerName == OllamaCloud.providerName })
        {
            UsageWarnings.evaluate(providers: [ollama])
        }
        forgetStoreReadings()
        applySnapshot()
    }

    func isLive(_ entry: SessionEntry) -> Bool {
        entry.session.isWorking || entry.session.backgroundWork != nil
            || SessionActivity.shared.status(for: entry.session.id) != .idle
    }

    /// Rebuilding the board is what everything that moves asks for, and almost none of them are
    /// asking for it now.
    ///
    /// A finished turn alone runs this three or four times in a row — the listing upsert, the
    /// activity change, the load's own pass — and the live cadence asks again every second or so,
    /// from a screen that is very often behind a chat nobody would see it redraw. So a request is a
    /// request: it is dropped entirely while Home is off screen or on its way off (`viewWillAppear`
    /// takes the deferred one), held back while a finger is on the list (the end of the scroll takes
    /// it), and otherwise gathered — `budgeted` requests, which are the listing's own, share one
    /// pass and the board keeps a quarter second between them. The deep link is the exception on
    /// the off-screen path: it is parked with a deadline and a notification tap must not wait
    /// behind a screen coming back.
    func applySnapshot(budgeted: Bool = false) {
        guard viewIfLoaded?.window != nil, !isUnderSettings, !isLeaving else {
            deferredSnapshot = true
            consumePendingDeepLink()
            return
        }
        guard !isUnderFinger else {
            deferredWhileTouching = true
            return
        }
        let wait = budgeted ? budgetedWait() : Double(Self.snapshotGather) / 1000
        if scheduledSnapshot, snapshotWait <= wait { return }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        scheduledSnapshot = true
        snapshotWait = wait
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.snapshotGeneration == generation, self.scheduledSnapshot
            else { return }
            self.scheduledSnapshot = false
            guard !self.isLeaving else {
                self.deferredSnapshot = true
                return
            }
            guard !self.isUnderFinger else {
                self.deferredWhileTouching = true
                return
            }
            self.renderSnapshotAway()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// How long a listing-driven request waits: a push's own notices arrive a few milliseconds
    /// apart and one row moving is one pass, not three. The board also holds itself to a quarter of
    /// a second between passes at most — a live turn pushes a listing every second or so, and a
    /// board of thousands does not need to rebuild faster than the tick it already draws at. A
    /// person's own press is never held to this; only the listing is.
    private func budgetedWait() -> TimeInterval {
        let since = Date().timeIntervalSince(lastRenderAt)
        return max(Double(Self.snapshotGather) / 1000, Self.snapshotSpacing - since)
    }

    /// How long a request waits before the board is rebuilt around it. One listing push arrives as
    /// several notices — the listing itself, the activity change, a desk refresh — and each of them
    /// used to buy a full pass of its own, so a single row moving cost the phone a tenth of a
    /// second in three pieces. Gathered, the burst costs one pass, and nothing a finger did is ever
    /// waiting on more than two frames.
    private static let snapshotGather = 40
    private static let snapshotSpacing: TimeInterval = 0.25

    /// Settings is a full-height sheet over the phone's board, leaving a sliver of it at the top
    /// edge and nothing a person reads, so Home holds still under it the way it does off screen: no
    /// repaint, no clock, no poll and no orb, and every frame goes to the list being scrolled.
    /// While an agent worked the clock alone rebuilt the whole board under the sheet once a second.
    /// The sheet starting to leave is Home appearing again, so the board is current as it slides
    /// out from under it.
    func setUnderSettings(_ covered: Bool) {
        guard covered != isUnderSettings else { return }
        isUnderSettings = covered
        agentsOrb.setHeld(covered, by: .settings)
        guard !covered else { return stopLiveRefresh() }
        guard viewIfLoaded?.window != nil else { return }
        if deferredSnapshot { renderSnapshot() }
        Task { await load() }
        startLiveRefresh()
    }

    func releaseDeferredSnapshotIfNeeded() {
        guard deferredWhileTouching else { return }
        deferredWhileTouching = false
        applySnapshot()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reachFurther(in: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { releaseDeferredSnapshotIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        releaseDeferredSnapshotIfNeeded()
    }
}
