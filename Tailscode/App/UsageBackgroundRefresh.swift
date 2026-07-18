import BackgroundTasks
import Foundation

/// Periodic background refresh of every usage source, so the widgets keep moving even
/// when neither the app nor a widget timeline reload has run: live Claude/Grok quotas
/// first (one cheap request per bridge), then an opencode scan trimmed to fit the
/// ~30-second `BGAppRefreshTask` window. Writes stay silent and a single throttled
/// reload at the end spends the widget budget at most once per pass.
enum UsageBackgroundRefresh {
    static let taskIdentifier = "com.guitaripod.tailscode.usage-refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.session.info("usage: background refresh scheduled")
        } catch {
            AppLogger.session.error("usage: background refresh submit failed: \(error.localizedDescription)")
        }
    }

    /// `BGAppRefreshTask` predates Sendable but `setTaskCompleted` is documented
    /// thread-safe, so handing it into the MainActor task is fine.
    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            AppLogger.session.info("usage: background refresh started")
            let quotas = await LiveQuotaFetcher.fetch(deadline: 10)
            if !quotas.isEmpty { UsageWidgetStore.writeLive(quotas, reload: false) }
            if !Task.isCancelled {
                let entries = ConnectionController.shared.opencodeBackends()
                if !entries.isEmpty {
                    await UsageScanner.scanOpencode(
                        backends: entries.map { ($0.profile.name, $0.backend) },
                        budget: .background,
                        reload: false)
                }
            }
            UsageWidgetStore.reloadTimelinesThrottled()
            AppLogger.session.info(
                "usage: background refresh finished — \(quotas.count) live quota(s)"
                    + (Task.isCancelled ? " (expired early)" : ""))
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
