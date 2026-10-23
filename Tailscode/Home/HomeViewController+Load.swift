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
        guard clockTickTask == nil, viewIfLoaded?.window != nil, isSceneForeground else { return }
        clockTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                guard self.hasTickingCard else { continue }
                self.applySnapshot()
            }
        }
    }

    private func stopClockTick() {
        clockTickTask?.cancel()
        clockTickTask = nil
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
        guard liveRefreshTask == nil, viewIfLoaded?.window != nil, isSceneForeground else { return }
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
    /// activity change, the load's own pass — and the live cadence asks again every couple of
    /// seconds, from a screen that is very often behind a chat nobody would see it redraw. So a
    /// request is a request: it is dropped entirely while Home is off screen (`viewWillAppear`
    /// takes the deferred one), and otherwise coalesced to one pass per runloop turn, so a burst
    /// costs what one change costs. The deep link is the exception on the off-screen path — it is
    /// parked with a deadline and a notification tap must not wait behind a screen coming back.
    func applySnapshot() {
        guard viewIfLoaded?.window != nil else {
            deferredSnapshot = true
            consumePendingDeepLink()
            return
        }
        guard !scheduledSnapshot else { return }
        if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        {
            deferredWhileTouching = true
            return
        }
        scheduledSnapshot = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scheduledSnapshot else { return }
            self.scheduledSnapshot = false
            self.renderSnapshot()
        }
    }

    func releaseDeferredSnapshotIfNeeded() {
        guard deferredWhileTouching else { return }
        deferredWhileTouching = false
        applySnapshot()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { releaseDeferredSnapshotIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        releaseDeferredSnapshotIfNeeded()
    }
}
