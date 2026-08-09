import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// An update is a standing fact, and the whole value of the surface is that it never says a
/// comfortable thing it does not know. So the proofs here are mostly about what it refuses to say:
/// no path that did not compare against something may reach "up to date", and no mark may stay lit
/// over something nobody can act on.
@Suite struct UpdateSurfaceTests {
    private static let now = Date(timeIntervalSince1970: 1_770_000_000)

    private static func reading(_ verdict: UpdateVerdict, component: UpdateComponent = .app)
        -> UpdateReading
    {
        UpdateReading(
            component: component, title: "Tailscode",
            installed: VersionFact(text: "1.9", provenance: .appBundle), verdict: verdict,
            checkedAt: now)
    }

    @Test func versionsRankByNumberNotByText() {
        #expect(SoftwareVersion("1.9")! < SoftwareVersion("1.10")!)
        #expect(SoftwareVersion("v1.5")! < SoftwareVersion("v1.5-12-gab34cd")!)
        #expect(SoftwareVersion("1.9") == SoftwareVersion("v1.9.0"))
        #expect(SoftwareVersion("2.0-beta.1")! < SoftwareVersion("2.0")!)
    }

    /// `git describe --always` on a checkout with no tags answers a bare hash, and one hash in
    /// thirty is all digits. Read as a version it outranks every release ever published.
    @Test func aBareCommitIsNotAVersion() {
        #expect(SoftwareVersion("1234567") == nil)
        #expect(SoftwareVersion("ab34cd7") == nil)
        #expect(SoftwareVersion("unknown") == nil)
        #expect(SoftwareVersion("2026.08.09") != nil)
    }

    @Test func twoBuildsOffOneTagAreNotTheSameBuild() {
        let comparison = VersionComparison.between(
            installed: "1.2.0-5-gaaaaaaa", available: "1.2.0-5-gbbbbbbb")
        #expect(comparison == .notComparable)
        #expect(
            VersionComparison.between(installed: "1.2.0-dirty", available: "1.2.0")
                == .notComparable)
        #expect(VersionComparison.between(installed: "1.9", available: "1.10") == .newerAvailable)
        #expect(VersionComparison.between(installed: "1.9 (30)", available: "1.10") == .notComparable)
    }

    /// The whole doctrine in one assertion: a server that answered without ever consulting the
    /// project must not be reported as current.
    @Test func aServerThatNeverLookedIsNotCurrent() {
        let status = ServerUpdate(version: "1.2.0", canUpdate: true, manager: "systemd")
        let reading = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil, outcome: .answered(status),
            checkedAt: Self.now)
        guard case .unverified(.notReported) = reading.verdict else {
            Issue.record("a bridge that reported no remote fields read as \(reading.verdict)")
            return
        }
        #expect(reading.headline != Localized.text("Up to date"))
    }

    @Test func aServerThatLookedAndFoundNothingIsCurrent() {
        let status = ServerUpdate(
            version: "1.2.0", remote: ServerUpdate.RemoteCheck(checked: true, ok: true),
            behind: 0, canUpdate: true, manager: "systemd")
        let reading = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil, outcome: .answered(status),
            checkedAt: Self.now)
        guard case .current = reading.verdict else {
            Issue.record("a bridge that looked and found nothing read as \(reading.verdict)")
            return
        }
    }

    @Test func aFailedFetchIsNamedRatherThanReadAsGoodNews() {
        let status = ServerUpdate(
            version: "1.2.0",
            remote: ServerUpdate.RemoteCheck(
                checked: true, ok: false, error: "Could not reach the project: timed out"),
            canUpdate: true, manager: "systemd")
        let reading = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil, outcome: .answered(status),
            checkedAt: Self.now)
        guard case .unverified(.notReported(let why)) = reading.verdict else {
            Issue.record("a failed fetch read as \(reading.verdict)")
            return
        }
        #expect(why.contains("timed out"))
    }

    /// A build that landed and was never started is the checkout's version, not the process's.
    @Test func aBuiltButUnrestartedServerIsNotCurrent() {
        let status = ServerUpdate(
            version: "1.3.0", running: "1.2.0", restartRequired: true,
            remote: ServerUpdate.RemoteCheck(checked: true, ok: true), behind: 0, canUpdate: true,
            manager: "manual")
        let reading = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil, outcome: .answered(status),
            checkedAt: Self.now)
        #expect(reading.verdict.offer != nil)
        #expect(reading.installed.text == "1.2.0")
        #expect(reading.installed.provenance == .serverBuild)
    }

    @Test func aServerTooOldForTheRouteSaysSo() {
        let reading = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil,
            outcome: .routeMissing(version: "1.0.0"), checkedAt: Self.now)
        guard case .unverified(.notReported) = reading.verdict else {
            Issue.record("an old bridge read as \(reading.verdict)")
            return
        }
        #expect(reading.installed.text == "1.0.0")
        #expect(reading.invitation != nil)
    }

    @Test func aStoreThatHasNotCaughtUpIsNotABuildOfYourOwn() {
        let install = AppInstall(kind: .appStore, version: "1.10", provenance: .appBundle)
        let release = AppRelease(version: "1.9", provenance: .appStore, readAt: Self.now)
        let reading = UpdateReadings.app(
            install: install, release: release, checkedAt: Self.now)
        guard case .ahead(.storeLagging) = reading.verdict else {
            Issue.record("an App Store build ahead of its record read as \(reading.verdict)")
            return
        }
    }

    @Test func aTestFlightBuildIsNeverSentToTheStore() {
        let install = AppInstall(kind: .testFlight, version: "1.10", provenance: .appBundle)
        let release = AppRelease(version: "1.9", provenance: .appStore, readAt: Self.now)
        let reading = UpdateReadings.app(
            install: install, release: release, storeURL: "itms-apps://example", checkedAt: Self.now)
        guard case .ahead(.testFlight) = reading.verdict else {
            Issue.record("a TestFlight build read as \(reading.verdict)")
            return
        }
        #expect(reading.invitation == nil)
    }

    @Test func aDirtyCheckoutIsNeverOfferedAPress() {
        let checkout = CheckoutState(
            path: "/src", describe: "v1.5-3-gaaaaaaa", commit: "aaaaaaa", isDirty: true, behind: 3,
            upstream: "origin/master")
        let reading = UpdateReadings.app(
            install: AppInstall(kind: .sourceBuild, version: "1.9", provenance: .installStamp),
            release: nil, checkout: checkout, checkedAt: Self.now)
        #expect(reading.verdict.offer?.canInstallHere == false)
        #expect(reading.invitation != .installHere)
    }

    /// A checkout with commits of its own cannot be fast-forwarded, and the surface has to say that
    /// rather than reporting a tree it cannot touch as current.
    @Test func aDivergedCheckoutIsBlockedNotCurrent() {
        let checkout = CheckoutState(
            path: "/src", describe: "v1.5-3-gaaaaaaa", commit: "aaaaaaa", isDirty: false, behind: 0,
            ahead: 2, upstream: "origin/master")
        let reading = UpdateReadings.app(
            install: AppInstall(kind: .sourceBuild, version: "1.9", provenance: .installStamp),
            release: nil, checkout: checkout, checkedAt: Self.now)
        guard case .blocked = reading.verdict else {
            Issue.record("a diverged checkout read as \(reading.verdict)")
            return
        }
    }

    @Test func currentExpiresAndFailureBecomesHistory() {
        let stale = UpdateFreshness.decayed(
            .current(checkedAt: Self.now, against: .unknown), checkedAt: Self.now,
            now: Self.now.addingTimeInterval(48 * 3600))
        guard case .unverified(.stale) = stale else {
            Issue.record("an old current did not expire: \(stale)")
            return
        }
        let old = UpdateFreshness.decayed(
            .failed(UpdateFailure(reason: "boom", at: Self.now)), checkedAt: Self.now,
            now: Self.now.addingTimeInterval(48 * 3600))
        guard case .unverified(.interrupted) = old else {
            Issue.record("a month-old failure still stands: \(old)")
            return
        }
        let behind = UpdateFreshness.decayed(
            .behind(UpdateOffer(version: "2.0", canInstallHere: true)), checkedAt: Self.now,
            now: Self.now.addingTimeInterval(48 * 3600))
        #expect(behind.offer != nil)
    }

    /// A running update is the one thing on this surface that legitimately takes an hour, and the
    /// mark must not go out the instant it starts.
    @Test func anUpdateInFlightSurvivesBeingRemembered() {
        let progress = UpdateProgress(step: .building, observedAt: Self.now)
        let fresh = UpdateFreshness.decayed(
            .working(progress), checkedAt: Self.now, now: Self.now.addingTimeInterval(120))
        #expect(fresh.isBusy)
        let abandoned = UpdateFreshness.decayed(
            .working(progress), checkedAt: Self.now, now: Self.now.addingTimeInterval(3 * 3600))
        guard case .unverified(.interrupted) = abandoned else {
            Issue.record("an hours-old build still reads as running: \(abandoned)")
            return
        }
    }

    /// Silence is not news about the software. A machine that stops answering must not clear a mark
    /// it was already holding up — that is the mark going out for the one reason it must not.
    @Test func aSleepingMachineKeepsTheOfferItAlreadyMade() {
        let offered = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil,
            outcome: .answered(
                ServerUpdate(
                    version: "1.2.0", remote: ServerUpdate.RemoteCheck(checked: true, ok: true),
                    latestVersion: "1.3.0", updateAvailable: true, behind: 4, canUpdate: true,
                    manager: "systemd")),
            checkedAt: Self.now)
        #expect(offered.stands())

        let asleep = UpdateReadings.server(
            profileID: "a", title: "mini", subtitle: nil, outcome: .silent("nothing came back"),
            checkedAt: Self.now, lastKnown: offered)
        #expect(asleep.stands())
        #expect(asleep.verdict.offer?.commits == 4)
        #expect(asleep.detail(now: Self.now).contains("nothing came back"))

        let neverKnown = UpdateReadings.server(
            profileID: "b", title: "other", subtitle: nil, outcome: .silent("nothing came back"),
            checkedAt: Self.now)
        #expect(!neverKnown.stands())
    }

    /// Every client asks its machines concurrently from tasks with no shared isolation, and the
    /// ledger is one blob: without serialisation a machine's row is silently dropped.
    @Test func concurrentAnswersDoNotOverwriteEachOther() async {
        let key = UpdateLedger.readingsKey
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    UpdateLedger.record(
                        Self.reading(
                            .behind(UpdateOffer(version: "2.0", canInstallHere: true)),
                            component: .server(profileID: "s\(index)")))
                }
            }
        }
        #expect(UpdateLedger.remembered(now: Self.now).count == 8)
    }

    /// A clock that moved backwards makes every stored date look like the future.
    @Test func aFutureCheckIsTreatedAsUnknownRatherThanFresh() {
        let future = Self.now.addingTimeInterval(3600)
        let decayed = UpdateFreshness.decayed(
            .current(checkedAt: future, against: .unknown), checkedAt: future, now: Self.now)
        guard case .unverified(.stale(let when)) = decayed else {
            Issue.record("a future check read as \(decayed)")
            return
        }
        #expect(when == nil)
    }

    @Test func settingAnUpdateAsideLastsExactlyAsLongAsTheOffer() {
        let offered = Self.reading(
            .behind(UpdateOffer(version: "2.0", canInstallHere: true)))
        let identity = offered.acknowledgeableIdentity
        #expect(identity != nil)
        #expect(offered.stands())
        #expect(!offered.stands(acknowledged: true))

        let newer = Self.reading(.behind(UpdateOffer(version: "2.1", canInstallHere: true)))
        #expect(newer.acknowledgeableIdentity != identity)

        let blocked = Self.reading(
            .behind(UpdateOffer(version: "2.0", canInstallHere: false, blocked: "dirty")))
        #expect(blocked.acknowledgeableIdentity != identity)

        let cleared = Self.reading(.behind(UpdateOffer(version: "2.0", canInstallHere: true)))
        #expect(cleared.acknowledgeableIdentity == identity)
    }

    @Test func nothingSettledOrImpossibleHoldsTheMarkUp() {
        #expect(!Self.reading(.blocked("no checkout")).stands())
        #expect(!Self.reading(.unverified(.unreachable("offline"))).stands())
        #expect(!Self.reading(.ahead(.ownBuild(published: "1.5"))).stands())
        #expect(!Self.reading(.current(checkedAt: Self.now, against: .unknown)).stands())
        #expect(Self.reading(.failed(UpdateFailure(reason: "boom", at: Self.now))).stands())
    }

    @Test func aRollupOfMachinesThatNeverLookedClaimsNothing() {
        let rollup = UpdateRollup(readings: [
            Self.reading(.blocked("no checkout"), component: .server(profileID: "a")),
            Self.reading(.unverified(.unreachable("offline")), component: .server(profileID: "b")),
        ])
        #expect(!rollup.everythingChecked)
        #expect(rollup.headline != Localized.text("Everything is up to date"))
        #expect(!rollup.showsMark)
    }

    @Test func theMarkIsOneCharacterWideAndNeverLouderThanItsRows() {
        let blocked = Self.reading(
            .behind(UpdateOffer(version: "2.0", canInstallHere: false, blocked: "dirty")),
            component: .server(profileID: "a"))
        #expect(UpdateRollup(readings: [blocked]).tone == .quiet)

        let many = (0..<12).map {
            Self.reading(
                .behind(UpdateOffer(version: "2.0", canInstallHere: true)),
                component: .server(profileID: "s\($0)"))
        }
        #expect(UpdateRollup(readings: many).mark?.count == 1)
    }

    /// The app's own update is never part of "update everything": on a desktop it replaces the
    /// process that would be watching the others.
    @Test func updateEverythingLeavesThisAppAlone() {
        let rollup = UpdateRollup(readings: [
            Self.reading(.behind(UpdateOffer(version: "2.0", canInstallHere: true))),
            Self.reading(
                .behind(UpdateOffer(version: "2.0", canInstallHere: true)),
                component: .server(profileID: "a")),
            Self.reading(
                .behind(UpdateOffer(version: "2.0", canInstallHere: true)),
                component: .server(profileID: "b")),
        ])
        #expect(rollup.updateOrder.count == 2)
        #expect(!rollup.updateOrder.contains(.app))
    }

    /// The script the desktops hand off to must never install what a failed build left behind, and
    /// must never call that success.
    @Test func theSelfUpdateScriptGuardsEveryStage() {
        let script = SourceUpdatePlan.script(
            source: "/src", stateDirectory: "/state", build: ["swift build -c release"],
            install: ["install -m 0755 a b"], relaunch: "/bin/true", verify: "b --version",
            waitFor: 4242)
        #expect(script.contains("swift build -c release || fail"))
        #expect(script.contains("install -m 0755 a b || fail"))
        #expect(script.contains("git status --porcelain"))
        #expect(script.contains("kill -0 4242"))
        #expect(!script.contains("date +%s"))
    }

    @Test func anInterruptedSelfUpdateSettlesRatherThanRunningForever() {
        let state = SourceUpdatePlan.State(
            phase: .building, startedAt: Self.now.addingTimeInterval(-3600))
        #expect(SourceUpdatePlan.settled(state, now: Self.now)?.phase == .failed)
        let future = SourceUpdatePlan.State(
            phase: .building, startedAt: Self.now.addingTimeInterval(3600))
        #expect(SourceUpdatePlan.settled(future, now: Self.now)?.phase == .failed)
    }

    /// A stamp that does not describe the binary running is not evidence, and the surface has to
    /// fall back rather than send a build command at somebody else's tree.
    @Test func anInstallStampIsBelievedOnlyWhenItMatches() {
        let stamp = InstallStamp(
            component: "tailscode-linux", installedAt: Self.now, installedBy: "install-linuxapp.sh",
            binary: InstallStamp.Binary(path: "/bin/t", size: 100, modifiedAt: Self.now),
            source: InstallStamp.Source(
                path: "/src", describe: "v1.5", commit: "aaaaaaa", dirty: false))
        let matching = InstallStamp.Evidence(
            executablePath: "/bin/t", size: 100, modifiedAt: Self.now, sourceIsCheckout: true,
            sourceHasCommit: true)
        #expect(stamp.describes(matching))
        #expect(
            !stamp.describes(
                InstallStamp.Evidence(
                    executablePath: "/bin/t", size: 101, modifiedAt: Self.now,
                    sourceIsCheckout: true, sourceHasCommit: true)))
        #expect(
            !stamp.describes(
                InstallStamp.Evidence(
                    executablePath: "/bin/t", size: 100, modifiedAt: Self.now,
                    sourceIsCheckout: true, sourceHasCommit: false)))
    }

    @Test func theLedgerSurvivesARowItCannotRead() {
        let key = UpdateLedger.readingsKey
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let good = Self.reading(
            .behind(UpdateOffer(version: "2.0", canInstallHere: true)),
            component: .server(profileID: "a"))
        guard let encoded = try? JSONEncoder().encode([good]),
            var array = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any]
        else {
            Issue.record("could not build the fixture")
            return
        }
        array.append(["component": ["nonsense": true]])
        guard let mixed = try? JSONSerialization.data(withJSONObject: array) else {
            Issue.record("could not build the fixture")
            return
        }
        UserDefaults.standard.set(mixed, forKey: key)
        #expect(UpdateLedger.remembered(now: Self.now).count == 1)
    }
}
