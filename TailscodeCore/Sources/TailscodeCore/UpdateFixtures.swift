import CodingAgentKit
import Foundation

/// One machine in every state a software card can be in, for looking at the cards without a fleet.
///
/// Each client's debug build can seed its ledger from here and open its update surface, so the
/// three desks are checked against the same seven machines rather than against whatever servers
/// happened to be reachable that afternoon. The readings are built through `UpdateReadings` from the
/// shapes a real bridge sends, so a card drawn from them is drawn by exactly the road a real answer
/// takes.
public enum UpdateFixtures {
    public static let profilePrefix = "fixture-"

    /// - Parameter only: the fixture machines to include, by the id after the prefix — `arch`,
    ///   `mini`, `studio`, `pi`, `box`, `old` — or all of them when empty. This app is always there.
    public static func readings(
        now: Date = Date(), appTitle: String = "Tailscode", only: Set<String> = []
    ) -> [UpdateReading] {
        let notes = ServerUpdate.Release(
            version: "1.10.0", commitsPastTag: 0,
            notes: [
                .init(
                    version: "1.10.0", date: "2026-09-23",
                    items: [
                        "Updates are followed step by step — download, build, waiting for idle, restart.",
                        "The app shows what is new in an update before you take it.",
                        "Live Activities stay on the Lock Screen after a turn finishes.",
                        "A chat that used agents stops showing as live once its last agent reports back.",
                        "Background work can be stopped from the app.",
                    ])
            ])
        let behind = ServerUpdate(
            version: "1.9.2", running: "1.9.2", remote: .init(checked: true, ok: true, at: now),
            latestVersion: "1.10.0", updateAvailable: true, behind: 6, canUpdate: true,
            manager: "systemd", busy: .init(quiet: true),
            automation: .init(enabled: false), release: notes)
        let building = ServerUpdate(
            version: "1.10.0", running: "1.9.2", manager: "launchd", phase: .building,
            busy: .init(quiet: false, turns: 1, reason: "A turn is running on that machine."),
            automation: .init(enabled: true),
            job: .init(
                id: "fixture-job", kind: .update, step: .build, from: "1.9.2", target: "1.10.0",
                startedAt: now.addingTimeInterval(-95)))
        let landed = ServerUpdate(
            version: "1.10.0", running: "1.10.0", remote: .init(checked: true, ok: true, at: now),
            latestVersion: "1.10.0", updateAvailable: false, behind: 0, canUpdate: true,
            manager: "systemd",
            automation: .init(
                enabled: true, lastTakenAt: now.addingTimeInterval(-7200), lastTarget: "1.10.0"),
            job: .init(
                id: "fixture-landed", kind: .update, automatic: true, step: .done,
                outcome: .succeeded, from: "1.9.2", target: "1.10.0", landed: "1.10.0",
                finishedAt: now.addingTimeInterval(-7200)))
        let failed = ServerUpdate(
            version: "1.9.2", running: "1.9.1", canUpdate: true, manager: "systemd", phase: .failed,
            log: "building (this takes a few minutes the first time)\n"
                + "error: only 900 MB free where the checkout lives; the build needs about 2 GB",
            automation: .init(enabled: false),
            job: .init(
                id: "fixture-failed", kind: .update, step: .build, outcome: .failed,
                from: "1.9.1", target: "1.10.0",
                reason: "Only 900 MB free where the checkout lives; the build needs about 2 GB",
                finishedAt: now.addingTimeInterval(-600)))

        var readings: [UpdateReading] = []
        func server(
            _ id: String, _ title: String, _ host: String, _ outcome: UpdateReadings.Outcome,
            agent: AgentType = .claudeCode, previous: UpdateReading? = nil, at: Date? = nil
        ) -> UpdateReading {
            UpdateReadings.server(
                profileID: profilePrefix + id, title: title,
                subtitle: "\(agent.displayName) · \(host)", product: UpdateProduct.name(for: agent),
                outcome: outcome, checkedAt: at ?? now, lastKnown: previous,
                installCommand: UpdateProduct.updateCommand(for: agent))
        }
        readings.append(
            UpdateReadings.app(
                install: AppInstall(
                    kind: .appStore, version: "1.53", build: "157", provenance: .appBundle),
                release: AppRelease(
                    version: "1.53", provenance: .appStore, readAt: now, storefront: "us"),
                storeURL: "https://apps.apple.com/app/id6791660932", checkedAt: now,
                title: appTitle))
        let offered = server("arch", "arch", "100.64.0.2", .answered(behind))
        readings.append(offered)
        let workingBefore = server("mini", "mac-mini", "100.64.0.3", .answered(behind))
        readings.append(
            server(
                "mini", "mac-mini", "100.64.0.3", .answered(building), previous: workingBefore,
                at: now.addingTimeInterval(-95)))
        let studioBefore = server("studio", "studio", "100.64.0.4", .answered(behind))
        readings.append(
            server("studio", "studio", "100.64.0.4", .answered(landed), previous: studioBefore))
        readings.append(server("pi", "pi", "100.64.0.5", .answered(failed)))
        readings.append(
            server(
                "box", "box", "100.64.0.6",
                .notSelfUpdating(
                    version: "1.4.2",
                    why: Localized.text(
                        "%@ updates itself with its own command, run on that machine.", "opencode")),
                agent: .openCode))
        readings.append(server("old", "old-laptop", "100.64.0.7", .routeMissing(version: "1.2.0")))
        guard !only.isEmpty else { return readings }
        return readings.filter { reading in
            guard case .server(let id) = reading.component else { return true }
            return only.contains(String(id.dropFirst(profilePrefix.count)))
        }
    }
}
