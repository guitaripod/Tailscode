import CodingAgentKit
import UIKit
import UserNotifications

/// Everything an agent or a human needs to explain a broken install, in one
/// paste: build, tailnet, notification authorization, push registration per
/// bridge, reachability, and the usage configuration. Assembling this by hand
/// from the log viewer was the alternative.
@MainActor
enum DiagnosticsReport {
    static func build() async -> String {
        var lines: [String] = []
        lines.append("Tailscode \(version)")
        lines.append(
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) "
                + "· \(UIDevice.current.model)")
        lines.append("Generated \(Self.timestamp.string(from: Date()))")

        lines.append("")
        lines.append("[Tailnet]")
        lines.append("Tailscale address: \(TailnetStatus.localAddress() ?? "none detected")")
        lines.append("API token: \(TailnetCredentials.hasToken ? "present" : "absent")")
        if let scan = TailnetCredentials.lastScan {
            lines.append(
                "Last scan: \(Self.timestamp.string(from: scan.date)) — "
                    + "\(scan.deviceCount) device(s), \(scan.serverCount) server(s)")
        }

        lines.append("")
        lines.append("[Notifications]")
        let status = await NotificationManager.authorizationStatus()
        lines.append("Authorization: \(Self.describe(status))")
        lines.append("Turn complete: \(AppPreferences.notifyTurnComplete)")
        lines.append("Approvals: \(AppPreferences.notifyApprovals)")
        lines.append("Usage warnings: \(AppPreferences.notifyUsageWarnings)")
        lines.append("Server pushes: \(AppPreferences.pushAlertsEnabled)")
        lines.append("Live Activities: \(AppPreferences.liveActivitiesEnabled)")
        lines.append("APNs token: \(PushRegistrar.hasToken ? "received" : "not received")")

        lines.append("")
        lines.append("[Servers]")
        let profiles = ConnectionController.shared.profiles
        if profiles.isEmpty { lines.append("none saved") }
        for profile in profiles {
            var parts = ["\(profile.name) — \(profile.backend.displayName)"]
            parts.append(profile.baseURL.absoluteString)
            switch ServerHealthMonitor.entry(for: profile.id) {
            case .some(let entry): parts.append(entry.reachable ? "reachable" : "unreachable")
            case .none: parts.append("unchecked")
            }
            if profile.id == ConnectionController.shared.activeProfileID { parts.append("default") }
            if profile.backend == .claudeCode {
                parts.append("push: \(PushRegistrar.state(for: profile.baseURL).label)")
            }
            lines.append(parts.joined(separator: " · "))
        }
        if ConnectionController.shared.isDemoMode { lines.append("demo mode active") }

        lines.append("")
        lines.append("[Usage]")
        lines.append("opencode go monthly cap: $\(GoCaps.monthlyCap)")
        lines.append(
            "Billing day: \(GoCaps.billingDay == 0 ? "auto" : String(GoCaps.billingDay))")
        let cached = UsageWidgetStore.cachedQuotas()
        lines.append(
            "Widget snapshot: "
                + (cached.isEmpty
                    ? "empty" : cached.map(\.providerName).joined(separator: ", ")))

        lines.append("")
        lines.append("[App]")
        lines.append("Pro: \(ProStore.shared.isPro)")
        lines.append("Appearance: \(AppPreferences.appearance.title)")
        lines.append("Compact agent steps: \(AppPreferences.compactActivity)")
        lines.append("Log file: \(LogFileWriter.shared.currentURL.lastPathComponent)")
        return lines.joined(separator: "\n")
    }

    private static var version: String {
        let info = { (key: String) in Bundle.main.object(forInfoDictionaryKey: key) as? String }
        return "\(info("CFBundleShortVersionString") ?? "?") (\(info("CFBundleVersion") ?? "?"))"
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
