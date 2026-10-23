import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// Quota is account state, not session state: polled on its own slow cadence — quickly only
    /// while the profile list has not been seeded yet — and rendered in the sidebar footer, the
    /// way the phone keeps it on the Home board.
    func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
        startUsageTick()
    }

    private func refreshUsage() async -> Bool {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else { return false }
        let snapshot = await Self.collectQuotas(profiles: profiles)
        if snapshot.isEmpty {
            if lastQuotas.isEmpty { quotasAnsweredAt = Date() }
        } else {
            let now = Date()
            lastQuotas = QuotaKeeping.carry(snapshot, held: heldQuotas, now: now)
            heldQuotas = QuotaKeeping.remember(snapshot, into: heldQuotas, now: now)
            quotasAnsweredAt = now
            observeRange(snapshot)
            publishWidgetSnapshot(snapshot)
        }
        sidebar.renderUsage(lastQuotas, answeredAt: quotasAnsweredAt)
        return true
    }

    /// What the account's windows did, written down for the pace to be read from, and the ones on
    /// course to run out before they reset said once. A provider two servers report is one account,
    /// so the sample is taken from the rollup rather than from each report.
    private func observeRange(_ reports: [(String, UsageQuota)]) {
        guard !reports.isEmpty else { return }
        let notices = RangeStore.observe(
            quotas: QuotaRollup.account(from: reports).map(\.quota),
            announce: MacNotifier.notifyRunningLow)
        for notice in notices { MacNotifier.shared.raiseRunningLow(notice) }
    }

    /// The quotas outlive the window they were fetched in. Every poll that came back with numbers
    /// leaves them where the widget extension can find them without this app running, and asks
    /// WidgetKit to redraw — a widget showing a figure from yesterday is the one lie this surface
    /// can tell, and an empty answer is left alone precisely so the stored one can age into CACHED
    /// rather than into nothing. Only what this poll actually read is written: a reading served
    /// from the last good one must not be stamped as read now.
    private func publishWidgetSnapshot(_ fresh: [(String, UsageQuota)]) {
        #if !TAILSCODE_MAS
            let quotas = QuotaRollup.account(from: fresh).map(\.quota)
            Self.widgetWrites.async { UsageWidgetStore.writeLive(quotas) }
        #endif
    }

    #if !TAILSCODE_MAS
        /// Where the widget's snapshot is written: off the main thread, one write at a time. The
        /// snapshot sits in the app group behind a file lock, and a copy signed ad hoc reaches that
        /// group only once the person has answered macOS's "access data from other apps" prompt —
        /// until then `open` does not return, and a window waiting on it is a window that has
        /// stopped answering from the first quota poll of the launch.
        private static let widgetWrites = DispatchQueue(
            label: "com.guitaripod.tailscode.widget-snapshot", qos: .utility)
    #endif

    /// The numbers move on the poll's cadence; the words about them move on their own, so a reset
    /// counted down two minutes at a time does not read as a clock that has stopped and an age
    /// only grows when there is something to grow from.
    private func startUsageTick() {
        usageTick?.invalidate()
        usageTick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sidebar.renderUsage(self.lastQuotas, answeredAt: self.quotasAnsweredAt)
            }
        }
    }

    /// Every quota every server can speak for: the agent's own, plus whatever other providers
    /// the machine holds accounts for (a bridge also reports Grok), plus this Mac's own account
    /// facts — the DeepSeek prepaid balance and the Ollama Cloud plan windows — when their keys
    /// are set. Nothing is dropped here — ``QuotaRollup`` folds the reports into one holding per
    /// provider, so a second machine refines the account's numbers instead of being thrown away
    /// for arriving late.
    private static func collectQuotas(profiles: [ConnectionProfile]) async
        -> [(String, UsageQuota)]
    {
        var quotas: [(String, UsageQuota)] = []
        if let reading = await DeepSeekBalance.refresh() {
            quotas.append(("", DeepSeekBalance.snapshot(for: reading)))
        }
        if let reading = await OllamaUsage.refresh() {
            quotas.append(("", OllamaCloud.snapshot(for: reading)))
        }
        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else { continue }
            var collected: [UsageQuota] = []
            if let quota = (try? await backend.usageQuota()) ?? nil { collected.append(quota) }
            collected += (try? await backend.additionalUsageQuotas()) ?? []
            for quota in QuotaReports.admitted(collected) {
                quotas.append((profile.name, quota))
            }
        }
        return quotas
    }

    /// The usage board, one window per app, held in a property because a window presented from a
    /// local is dead on arrival — released while shown, its buttons do nothing.
    func presentUsageWindow() {
        if usageWindow == nil {
            usageWindow = UsageWindowController(
                initial: lastQuotas,
                refresh: { [weak self] in
                    let fresh = await Self.collectQuotas(profiles: ServerDirectory.shared.profiles)
                    self?.observeRange(fresh)
                    return fresh
                },
                onAnalytics: { [weak self] in self?.presentAnalytics() })
        }
        usageWindow?.present()
    }

    /// The month in numbers, one window per app, held in a property because a window presented
    /// from a local is dead on arrival — released while shown, its buttons do nothing.
    func presentAnalytics() {
        if analyticsWindow == nil {
            analyticsWindow = AnalyticsWindowController { window in
                await Self.collectAnalytics(window: window)
            }
        }
        analyticsWindow?.present()
    }

    /// The whole account: every Claude server's ledger over the default window, merged by Core.
    /// One machine answering once is enough — a second profile on the same host must not double
    /// the money — and a server that cannot answer is named so its absence is a stated fact.
    private static func collectAnalytics(window: UsageWindow) async -> UsageAnalytics? {
        var reports: [(name: String, report: UsageAnalyticsReport)] = []
        var missing: [String] = []
        var seenHosts = Set<String>()
        for profile in ServerDirectory.shared.profiles {
            let host = "\(profile.baseURL.host ?? profile.id):\(profile.baseURL.port ?? 0)"
            guard seenHosts.insert(host).inserted else { continue }
            let name = ServerLabel.display(profile)
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                missing.append(name)
                continue
            }
            do {
                if let report = try await backend.usageAnalytics(days: window.days)
                {
                    await UsageAnalytics.rememberModels(profileID: profile.id, backend: backend)
                    reports.append((name, report))
                } else {
                    missing.append(name)
                }
            } catch AgentError.decoding {
                missing.append(name)
            } catch {
                continue
            }
        }
        let profileIDs = ServerDirectory.shared.profiles.map(\.id)
        return UsageAnalytics(
            servers: reports, missingServers: missing, window: window,
            modelNames: UsageAnalytics.modelNames(profileIDs: profileIDs),
            contextWindows: UsageAnalytics.contextWindows(profileIDs: profileIDs))
    }
}
