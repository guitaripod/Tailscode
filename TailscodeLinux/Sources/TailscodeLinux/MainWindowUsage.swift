import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Quota is account state, not session state: polled on its own slow cadence and rendered in
    /// the sidebar footer.
    func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                await BackgroundGate.shared.untilVisible()
                let settled = await self?.refreshUsage() ?? true
                await BackgroundGate.shared.sleep(settled ? 120 : 15)
            }
        }
        BackgroundGate.shared.onShown { [weak self] in
            guard let self, self.isStanding else { return }
            self.renderUsage(self.lastQuotas)
        }
        startUsageTick(skipped: 0)
    }

    /// The numbers move on the poll's cadence; the words about them move on their own. A reset
    /// counted down two minutes at a time reads as a clock that has stopped, and an age that only
    /// grows when a fetch succeeds is exactly the age that cannot be trusted — so the strip is
    /// redrawn from what it already knows every minute, which costs one relayout of five rows.
    ///
    /// A minute nobody can see is not drawn, and a loop the governor is shedding draws one minute
    /// in ``BackgroundCadence/factor(for:)``; the strip is redrawn the moment the window is seen
    /// again (``BackgroundGate/onShown``), so neither is ever read.
    func startUsageTick(skipped: Int) {
        Gtk.after(60_000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.isStanding else { return }
                let owed = skipped + 1
                guard BackgroundGate.shared.isVisible,
                    owed >= BackgroundCadence.factor(for: BackgroundGate.shared.shedLevel)
                else {
                    self.startUsageTick(skipped: BackgroundGate.shared.isVisible ? owed : 0)
                    return
                }
                self.renderUsage(self.lastQuotas)
                self.startUsageTick(skipped: 0)
            }
        }
    }

    /// False while the profile list has not been seeded yet — the poll retries quickly then.
    func refreshUsage() async -> Bool {
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else { return false }
        let snapshot = await Self.collectQuotas(profiles: profiles)
        let answeredAt = Date()
        Gtk.onMain { [weak self] in
            guard let self else { return }
            if snapshot.isEmpty {
                if self.lastQuotas.isEmpty { self.quotasAnsweredAt = answeredAt }
            } else {
                self.lastQuotas = QuotaKeeping.carry(
                    snapshot, held: self.heldQuotas, now: answeredAt)
                self.heldQuotas = QuotaKeeping.remember(
                    snapshot, into: self.heldQuotas, now: answeredAt)
                self.quotasAnsweredAt = answeredAt
                ClockWatch.shared.setHoldings(from: self.lastQuotas)
                Self.recordRange(snapshot)
            }
            self.renderUsage(self.lastQuotas)
        }
        return true
    }

    /// Hands a fresh report to the range's history and raises the one notice it may owe. The account
    /// is recorded once however many machines reported it.
    static func recordRange(_ snapshot: [(String, UsageQuota)]) {
        let account = QuotaRollup.account(from: snapshot).map(\.quota)
        let notices = RangeStore.observe(quotas: account, announce: Notifier.notifyRunningLow)
        for notice in notices { Notifier.shared.raiseRunningLow(notice) }
    }

    /// Every quota every server can speak for, raw and per-machine, plus this device's own
    /// DeepSeek prepaid balance and the Ollama Cloud plan windows when their keys are set.
    /// Nothing is dropped here — ``QuotaRollup`` folds the reports into one holding per
    /// provider, so a second machine refines the account's numbers instead of being thrown away
    /// for arriving late.
    static func collectQuotas(profiles: [ConnectionProfile]) async -> [(String, UsageQuota)]
    {
        var quotas: [(String, UsageQuota)] = []
        if let reading = await DeepSeekBalance.refresh() {
            quotas.append(("", DeepSeekBalance.snapshot(for: reading)))
        }
        if let reading = await OllamaUsage.refresh() {
            quotas.append(("", OllamaCloud.snapshot(for: reading)))
        }
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { continue }
            var collected: [UsageQuota] = []
            if let quota = (try? await backend.usageQuota()) ?? nil { collected.append(quota) }
            collected += (try? await backend.additionalUsageQuotas()) ?? []
            for quota in QuotaReports.admitted(collected) {
                quotas.append((profile.name, quota))
            }
        }
        return quotas
    }

    func presentUsage() {
        let initial = lastQuotas
        Task {
            await UsagePanel.present(parent: sidebarPane, initial: initial) {
                let fresh = await Self.collectQuotas(
                    profiles: await ServerDirectory.shared.profiles())
                if !fresh.isEmpty { Gtk.onMain { Self.recordRange(fresh) } }
                return fresh
            }
        }
    }

    /// Quota as a glance, not a paragraph. ``QuotaGlance`` decides what the foot of the chat list
    /// says in every state and this draws it: the account rather than the machines, the full
    /// picture one click behind it, and the whole of it on hover for the facts no strip this size
    /// can carry.
    func renderUsage(_ quotas: [(String, UsageQuota)]) {
        let glance =
            usageDemo
            ?? QuotaGlance.make(
                from: quotas, answeredAt: quotasAnsweredAt, board: QuotaBoardStore.current,
                trail: RangeStore.trail)
        let signature =
            "\(usageBarsFit)|" + glance.lines.map {
                "\($0.kind.rawValue):\($0.text):\($0.trailing):\($0.tone.rawValue):\($0.fraction.map { String(format: "%.3f", $0) } ?? ""):\($0.slug ?? ""):\(Self.paceSignature($0.row))"
            }.joined(separator: "|") + "|\(glance.tooltip)"
        guard signature != usageStripSignature else { return }
        usageStripSignature = signature
        UsageStrip.render(glance, into: usageBox, bars: usageBarsFit)
    }

    /// What of a line's pace changes what is drawn: the tick and the tail, so a strip whose words
    /// held still is still redrawn when the pace moved.
    static func paceSignature(_ row: PaceRow?) -> String {
        guard let row else { return "" }
        let tick = row.tick.map { String(format: "%.3f", $0) } ?? ""
        let tail = row.tailEnd.map { String(format: "%.3f", $0) } ?? ""
        return "\(tick)/\(tail)/\(row.tailIsNews)"
    }

    /// The strip's bars are the first thing a narrow sidebar gives up, and the decision is the
    /// divider's position rather than the pane's allocation for the same reason the title's is:
    /// this runs from `notify::position`, before GTK has laid the pane out again.
    func fitUsageStrip() {
        let width =
            splitWidget.map { gtk_paned_get_position(op($0)) }
            ?? sidebarPane.map { gtk_widget_get_width($0) } ?? 0
        guard width > 0 else { return }
        let fits = width >= UsageStrip.barsNeed
        guard fits != usageBarsFit else { return }
        usageBarsFit = fits
        renderUsage(lastQuotas)
    }

    /// Pins the strip to one state so every one of them can be looked at headlessly — the states
    /// a real account only reaches by running out of quota at the right moment.
    func driverUsageState(_ name: String) {
        usageDemo = UsageDemo.glance(named: name)
        renderUsage(lastQuotas)
    }
}
