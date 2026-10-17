import CodingAgentKit
import Foundation
import TailscodeCore
import UIKit

/// Where a fresh quota report becomes the range's memory and, rarely, one notification.
///
/// Every surface that lands numbers hands them here: the trail is what a pace reads its recent
/// rate from, and the announcement is the one thing a person can still act on — a window on course
/// to run out before it resets. A notice is decided only while the app is not in front: the
/// ledger rings once per window, so a notice raised to a screen nobody would be shown it on would
/// use up the window's only ring.
@MainActor
enum RangeRecorder {
    static func observe(quotas: [UsageQuota]) {
        guard !quotas.isEmpty else { return }
        let announce =
            AppPreferences.notifyRunningLow && UIApplication.shared.applicationState != .active
        for notice in RangeStore.observe(quotas: quotas, announce: announce) {
            NotificationManager.notify(
                kind: .runningLow, title: notice.title, body: notice.body,
                identifier: "usage:low:\(notice.id)|\(Int(notice.resetsAt.timeIntervalSince1970))")
            AppLogger.session.info("range: running-low notice raised for \(notice.id)")
        }
    }
}
