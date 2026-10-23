import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The update surface where it can go wrong on this client: Core must refuse to call a machine
    /// current when nothing was actually compared, a fleet holding a machine nobody has heard from
    /// must not read as up to date, the Update Center must be able to build its own view, and the
    /// ledger must remember and forget exactly what it was told — the probe rows it writes are
    /// taken back out, because these stores are the real ones and a self-test that left marks
    /// behind would nag about a server that never existed.
    static func checkUpdates() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("updates: \(label)") }
            checks += 1
        }
        let now = Date()

        let quiet = UpdateReadings.server(
            profileID: "probe-quiet", title: "quiet", subtitle: "claude-bridge",
            outcome: .answered(ServerUpdate(version: "1.4.0", manager: "systemd")),
            checkedAt: now)
        if case .current = quiet.verdict {
            throw SelfTestFailure("updates: a server that never looked read as up to date")
        }
        checks += 1
        try expect(!quiet.verdict.compared, "an answer that compared nothing says so")
        try expect(!quiet.stands(), "a machine that cannot say does not hold the mark up")

        let behind = UpdateReadings.server(
            profileID: "probe-behind", title: "behind", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 3,
                    changes: ["a change", "another"], canUpdate: true, manager: "systemd")),
            checkedAt: now)
        try expect(behind.verdict.offer?.canInstallHere == true, "a bridge that can install offers")
        try expect(behind.invitation == .installHere, "and the offer is the one press")
        try expect(behind.stands(), "an update that exists holds the mark up")

        let current = UpdateReadings.server(
            profileID: "probe-current", title: "current", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.5.0",
                    remote: ServerUpdate.RemoteCheck(
                        checked: true, ok: true, at: now, ref: "origin/master"),
                    latestVersion: "1.5.0", canUpdate: true, manager: "systemd")),
            checkedAt: now)
        guard case .current = current.verdict else {
            throw SelfTestFailure("updates: a server that looked and found nothing is current")
        }
        checks += 1

        let owed = UpdateReadings.server(
            profileID: "probe-owed", title: "owed", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.6.0", running: "1.5.0", restartRequired: true,
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    canUpdate: true, manager: "systemd",
                    busy: ServerUpdate.Busy(
                        quiet: false, turns: 1, reason: "A turn is running on that machine."),
                    canRestart: true)),
            checkedAt: now)
        try expect(
            owed.invitation
                == .restartHere(
                    supervisor: "systemd", waitingFor: "A turn is running on that machine."),
            "a build already on a supervised machine is one press, not another build")
        try expect(
            owed.invitation?.promise != nil,
            "and the press says beforehand what a turn running there costs it")
        let owedFleet = UpdateRollup(readings: [owed])
        try expect(
            owedFleet.updateOrder.isEmpty,
            "update everything never rebuilds a machine that only needed starting")
        try expect(
            owedFleet.restartableServers.count == 1, "though it is named as one that needs starting")

        let stranded = UpdateReadings.server(
            profileID: "probe-stranded", title: "stranded", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.6.0", running: "1.5.0", restartRequired: true,
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    canUpdate: true, manager: "manual", canRestart: false)),
            checkedAt: now)
        try expect(
            stranded.invitation == .copyCommand(BridgeInstall.installCommand),
            "a machine with nothing to start it again is handed the command instead")

        let dirty = UpdateReadings.server(
            profileID: "probe-dirty", title: "dirty", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 1, canUpdate: false,
                    reason: "the checkout has uncommitted changes", manager: "systemd",
                    obstacle: ServerUpdate.Obstacle(
                        kind: "dirty", summary: "the checkout has uncommitted changes",
                        items: ["Sources/a.swift", "Sources/b.swift"], more: 3))),
            checkedAt: now)
        try expect(
            dirty.verdict.offer?.detailLines.count == 3,
            "an obstacle names what is in the way and says how much it left out")

        let selfTaking = UpdateReadings.server(
            profileID: "probe-auto", title: "auto", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 2, canUpdate: true,
                    manager: "systemd",
                    automation: ServerUpdate.Automation(
                        enabled: true, nextLookAt: now.addingTimeInterval(600)))),
            checkedAt: now)
        try expect(
            selfTaking.automation?.willTake == true,
            "a machine whose policy is on and has nothing in the way takes it itself")
        try expect(selfTaking.verdict.offer != nil, "it is still behind, because it is")
        try expect(
            !selfTaking.stands(),
            "but a machine that will take it itself is not a request that somebody act")

        try expect(
            UpdateCard(quiet).automation == nil,
            "a server too old for a policy is offered no automation at all")
        try expect(
            UpdateCard(selfTaking, now: now).automation != nil,
            "and a machine with one is offered it")

        let old = UpdateReadings.server(
            profileID: "probe-old", title: "old", subtitle: "claude-bridge",
            outcome: .routeMissing(version: "1.1.0"), checkedAt: now)
        try expect(!old.verdict.compared, "a bridge too old for the route compared nothing")
        try expect(
            old.invitation == .copyCommand(BridgeInstall.installCommand),
            "and is handed the one command instead")

        let mixed = UpdateRollup(readings: [quiet, current, old])
        try expect(!mixed.everythingChecked, "one machine that could not say sinks the whole claim")
        try expect(
            mixed.headline != Localized.text("Everything is up to date"),
            "a fleet with a silent machine never reads as up to date")
        try expect(
            UpdateRollup(readings: [current]).everythingChecked,
            "a fleet that all answered may say so")
        let standing = UpdateRollup(readings: [behind, quiet, current])
        try expect(standing.showsMark, "the mark stands for the offer")
        try expect(standing.motion == .still, "an offer is a settled fact and holds perfectly still")
        try expect(standing.updateOrder == [behind.component], "only what one press finishes")

        let board = UpdateBoardViewController()
        guard let boardScroll = board.view as? NSScrollView else {
            throw SelfTestFailure("updates: the board's view is not the scroll view it stands in as")
        }
        checks += 1
        try expect(
            boardScroll.documentView != nil, "the update board builds its own scrolling column")
        let footer = UpdateFooterView()
        footer.render()
        try expect(
            footer.isHidden == (UpdateLedger.rollup().chip == nil),
            "the standing mark is shown exactly when the rollup has a chip to say so")

        let neverChecked = UpdateReading(
            component: .server(profileID: "probe-neverchecked"), title: "neverchecked",
            installed: .unknown, verdict: .unverified(.neverChecked), product: "claude-bridge")
        let ahead = UpdateReading(
            component: .server(profileID: "probe-ahead"), title: "ahead",
            installed: VersionFact(text: "1.11.0", provenance: .serverBuild),
            verdict: .ahead(.ownBuild(published: "1.10.0")), product: "claude-bridge")
        let stageReadings =
            UpdateFixtures.readings(now: now)
            + [quiet, behind, current, owed, stranded, dirty, selfTaking, old, neverChecked, ahead]
        var seenStages: [UpdateCard.Stage] = []
        for reading in stageReadings {
            let busy = reading.id == neverChecked.id
            let card = UpdateCard(reading, busy: busy, now: now)
            if !seenStages.contains(card.stage) { seenStages.append(card.stage) }
            let view = UpdateCardView(style: .standalone)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 460).isActive = true
            view.apply(card)
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            try expect(
                size.height > 0 && size.height < 4000,
                "\(reading.title) (\(card.stage)): the card draws at a sane height, not \(size.height)"
            )
            try expect(
                size.width > 0, "\(reading.title) (\(card.stage)): the card draws at some width")
        }
        let everyStage: [UpdateCard.Stage] = [
            .checking, .upToDate, .updated, .available, .restartNeeded, .updating, .failed,
            .attention, .ahead,
        ]
        for stage in everyStage {
            try expect(seenStages.contains(stage), "no fixture or probe ever reaches the \(stage) stage")
        }

        let probeID = "selftest-\(UUID().uuidString)"
        let component = UpdateComponent.server(profileID: probeID)
        let probe = UpdateReadings.server(
            profileID: probeID, title: "selftest probe", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0", remote: ServerUpdate.RemoteCheck(checked: true, ok: true),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 1, canUpdate: true,
                    manager: "systemd")),
            checkedAt: now)
        UpdateLedger.record(probe)
        guard let remembered = UpdateLedger.remembered(component) else {
            throw SelfTestFailure("updates: a recorded reading did not come back")
        }
        checks += 1
        try expect(remembered.verdict == probe.verdict, "and came back as it went in")
        try expect(!UpdateLedger.isAcknowledged(remembered), "nothing is set aside until it is")
        UpdateLedger.acknowledge(remembered)
        try expect(UpdateLedger.isAcknowledged(remembered), "setting an offer aside is remembered")
        try expect(
            !UpdateLedger.rollup().standing.contains { $0.id == remembered.id },
            "a set-aside offer stops holding the mark up")
        UpdateLedger.forget(component)
        try expect(UpdateLedger.remembered(component) == nil, "the probe left nothing behind")
        try expect(
            UpdateLedger.acknowledgements()[component.key] == nil,
            "and took its acknowledgement with it")
        return checks
    }

    static func checkParity() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("parity: \(label)") }
            checks += 1
        }
        try expect(
            CapabilityRegistry.missingDefinitions.isEmpty, "every capability has a spec")
        for capability in AppCapability.allCases {
            switch ParityManifest.evidence(for: capability) {
            case .implemented(let anchor):
                try expect(!anchor.isEmpty, "\(capability.rawValue) names its anchor")
            case .partial(let anchor, let missing):
                try expect(
                    !anchor.isEmpty && !missing.isEmpty,
                    "\(capability.rawValue) names its anchor and its debt")
            case .gap(let reason), .notApplicable(let reason):
                try expect(!reason.isEmpty, "\(capability.rawValue) states its reason")
            case .varies:
                try expect(false, "\(capability.rawValue) resolves to one answer for this copy")
            }
        }
        for problem in MacParity.audit() {
            try expect(false, problem)
        }
        return checks
    }
}
