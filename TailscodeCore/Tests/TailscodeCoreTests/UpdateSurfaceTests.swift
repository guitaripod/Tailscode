import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// An update is a standing fact, and the whole value of the surface is that it never says a
/// comfortable thing it does not know. So the proofs here are mostly about what it refuses to say:
/// no path that did not compare against something may reach "up to date", and no mark may stay lit
/// over something nobody can act on.
/// Nested under `DeviceStores` on purpose: every device-local store shares one
/// `UserDefaults`, and corelibs' is not safe to write from two threads at once, so a
/// suite that writes one has to be serialized against every other suite that does.
extension DeviceStores {
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

        /// The new thing a package install gets to see: the release feed is the one comparison it
        /// has, and a newer release must light the mark and hand over the manager's own line rather
        /// than offering a press this machine can never finish.
        @Test func aPackagedInstallSeesAReleaseItCannotInstallItself() {
            let install = AppInstall(
                kind: .packaged, version: "1.22", provenance: .appBundle,
                packager: "paru")
            let release = AppRelease(version: "1.24", provenance: .gitHubRelease, readAt: Self.now)
            let reading = UpdateReadings.app(
                install: install, release: release, command: "paru -Syu tailscode",
                checkedAt: Self.now)
            #expect(reading.verdict.offer?.target == "1.24")
            #expect(reading.invitation == .copyCommand("paru -Syu tailscode"))
            #expect(reading.stands())
            #expect(UpdateRollup(readings: [reading]).showsMark)
            #expect(reading.headline == Localized.text("Update to 1.24"))
            #expect(reading.detail(now: Self.now).contains("1.22"))
        }

        /// A release feed that answered nothing is not a release that answered "nothing newer" —
        /// the row says it could not check, and the offer is only claimed by a check that made it.
        @Test func aPackagedInstallWhoseFeedFailedSaysItCouldNotCheck() {
            let install = AppInstall(
                kind: .packaged, version: "1.22", provenance: .appBundle,
                packager: "paru")
            let reading = UpdateReadings.app(
                install: install, release: nil, failure: "Nothing came back.",
                command: "paru -Syu tailscode", checkedAt: Self.now)
            guard case .unverified(.unreachable) = reading.verdict else {
                Issue.record("a failed feed read as \(reading.verdict)")
                return
            }
            #expect(reading.invitation == .recheck)
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
        /// A machine that will take the update by itself is still behind — because it is — but it
        /// is not a request. Without this, a fleet with the policy on lights the chrome mark on
        /// every push to master and clears it ten minutes later, several times a day, which is how
        /// a mark stops being read.
        @Test func aSelfTakingMachineIsBehindWithoutAskingForAnything() {
            let taking = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.5.0", updateAvailable: true, behind: 3, canUpdate: true,
                        manager: "systemd",
                        automation: ServerUpdate.Automation(enabled: true))),
                checkedAt: Self.now)

            #expect(taking.verdict.offer?.commits == 3)
            #expect(!taking.stands())
            #expect(taking.automation?.willTake == true)
            #expect(taking.invitation == .installHere)
        }

        /// The policy being on is not the same as the machine being able to act on it. Anything it
        /// is holding off for puts the row back in front of a person.
        @Test func aMachineHoldingOffStillAsks() {
            let held = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.5.0", updateAvailable: true, behind: 3, canUpdate: true,
                        manager: "systemd",
                        automation: ServerUpdate.Automation(
                            enabled: true, holdingOff: "Held off after 2 failed attempts."))),
                checkedAt: Self.now)

            #expect(held.stands())
            #expect(held.automation?.willTake == false)
            #expect(held.automation?.sentence(now: Self.now).contains("failed") == true)
        }

        /// `behind` never expires while a person is the only one who can take it. A machine that
        /// takes its own stops being behind while nobody looks, so that offer has to go stale —
        /// otherwise the app spends the morning offering a version installed at two.
        @Test func aSelfTakingOfferGoesStaleAndAPersonsDoesNot() {
            let automation = UpdateAutomation(
                enabled: true, nextLookAt: Self.now.addingTimeInterval(1800), readAt: Self.now)
            let taking = UpdateReading(
                component: .server(profileID: "a"), title: "macbook",
                installed: VersionFact(text: "1.5.0", provenance: .serverBuild),
                verdict: .behind(UpdateOffer(version: "1.6.0", canInstallHere: true)),
                checkedAt: Self.now, automation: automation)
            let asked = UpdateReading(
                component: .server(profileID: "b"), title: "arch",
                installed: VersionFact(text: "1.5.0", provenance: .serverBuild),
                verdict: .behind(UpdateOffer(version: "1.6.0", canInstallHere: true)),
                checkedAt: Self.now)

            let later = Self.now.addingTimeInterval(6 * 3600)
            #expect(UpdateFreshness.decayed(taking, now: Self.now) == taking.verdict)
            if case .unverified(.stale) = UpdateFreshness.decayed(taking, now: later) {
            } else {
                Issue.record("a self-taking offer must expire on that machine's own schedule")
            }
            #expect(UpdateFreshness.decayed(asked, now: later) == asked.verdict)
        }

        /// A build that landed and was never started is one press, not a terminal instruction —
        /// and only where something would start the bridge again.
        @Test func aBuiltButUnstartedBridgeOffersItsOwnRestart() {
            let supervised = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", restartRequired: true,
                        manager: "launchd", busy: ServerUpdate.Busy(quiet: true),
                        canRestart: true)),
                checkedAt: Self.now)

            #expect(supervised.invitation == .restartHere(supervisor: "launchd", waitingFor: nil))
            #expect(supervised.verdict.offer?.canInstallHere == true)
            #expect(supervised.invitation?.finishesHere == true)
            #expect(supervised.invitation?.isOneClickInstall == false)
            #expect(supervised.needsOnlyRestart)
            #expect(supervised.headline == Localized.text("Restart to finish the update"))
            #expect(supervised.icon.symbol == "arrow.clockwise.circle.fill")
            #expect(supervised.detail(now: Self.now).contains("1.6.0"))
            #expect(supervised.detail(now: Self.now).contains("1.5.0"))
        }

        /// Trusting a machine to keep itself current is what takes the mark down for an ordinary
        /// update — and it cannot cover a build the machine has already finished with. A server
        /// waiting to be started will wait forever if the only surface that says so is the one
        /// nobody opened, which is exactly how a list came to disagree with the screen behind it.
        @Test func aBuildWaitingToStartStandsEvenOnAMachineThatUpdatesItself() {
            let trusted = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", restartRequired: true,
                        manager: "launchd", busy: ServerUpdate.Busy(quiet: true),
                        canRestart: true,
                        automation: ServerUpdate.Automation(enabled: true))),
                checkedAt: Self.now)

            #expect(trusted.automation?.willTake == true)
            #expect(trusted.stands())
            #expect(UpdateRollup(readings: [trusted]).showsMark)
            #expect(UpdateRollup(readings: [trusted]).restartableServers.count == 1)
            #expect(UpdateRollup(readings: [trusted]).installableServers.isEmpty)
        }

        /// A bridge nothing supervises would not come back, so the press is refused before it is
        /// offered rather than after it is pressed.
        @Test func anUnsupervisedBridgeIsHandedTheCommandInstead() {
            let manual = UpdateReadings.server(
                profileID: "a", title: "old box", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", restartRequired: true,
                        manager: "manual", canRestart: false)),
                checkedAt: Self.now)

            #expect(manual.invitation == .copyCommand(BridgeInstall.installCommand))
            #expect(manual.stands())
            #expect(manual.detail(now: Self.now).contains("by hand"))
        }

        /// The promise is what the press costs, and what it costs depends on what the machine is
        /// doing — so it is said before the press, not discovered after it.
        @Test func aBusyMachineSaysWhatARestartWouldStop() {
            let busy = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", restartRequired: true,
                        manager: "systemd",
                        busy: ServerUpdate.Busy(
                            quiet: false, turns: 2, reason: "2 turns are running."),
                        canRestart: true)),
                checkedAt: Self.now)

            #expect(
                busy.invitation
                    == .restartHere(
                        supervisor: "systemd", waitingFor: "2 turns are running."))
            #expect(busy.invitation?.promise?.contains("2 turns are running.") == true)
        }

        /// A restart is not an install, so a walk that rebuilds every machine must not sweep up one
        /// that only needed starting.
        @Test func updateEverythingSkipsAMachineThatOnlyNeedsStarting() {
            let rebuild = Self.reading(
                .behind(UpdateOffer(version: "1.6.0", canInstallHere: true)),
                component: .server(profileID: "a"))
            let restart = UpdateReading(
                component: .server(profileID: "b"), title: "macbook",
                installed: VersionFact(text: "1.5.0", provenance: .serverBuild),
                verdict: .behind(UpdateOffer(version: "1.6.0", canInstallHere: true)),
                invitation: .restartHere(supervisor: "systemd", waitingFor: nil), checkedAt: Self.now)
            let rollup = UpdateRollup(
                readings: [
                    UpdateReading(
                        component: rebuild.component, title: rebuild.title,
                        installed: rebuild.installed, verdict: rebuild.verdict,
                        invitation: .installHere, checkedAt: Self.now),
                    restart,
                ])

            #expect(rollup.installableServers.map(\.id) == ["server:a"])
            #expect(rollup.restartableServers.map(\.id) == ["server:b"])
            #expect(!rollup.canUpdateEverything)
        }

        /// An obstacle is named rather than summarised — but the naming must not become a second
        /// acknowledgement key, or the agent writing one more file on that machine relights a mark
        /// somebody deliberately set aside.
        @Test func anObstaclesOwnListIsOutsideWhatWasAcknowledged() {
            let one = UpdateOffer(
                version: nil, canInstallHere: false, blocked: "The checkout is dirty.",
                details: ["Sources/A.swift"], moreDetails: 0)
            let more = UpdateOffer(
                version: nil, canInstallHere: false, blocked: "The checkout is dirty.",
                details: ["Sources/A.swift", "Sources/B.swift"], moreDetails: 12)
            let first = Self.reading(.behind(one), component: .server(profileID: "a"))
            let second = Self.reading(.behind(more), component: .server(profileID: "a"))

            #expect(first.acknowledgeableIdentity == second.acknowledgeableIdentity)
            #expect(more.detailLines.last == "and 12 more")
        }

        /// A machine holding a finished build behind a running turn is working, not silent, and the
        /// wait has its own word rather than reading as a restart that never happened.
        @Test func waitingForAQuietMachineIsAStepWithWords() {
            let waiting = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", manager: "systemd", phase: .waiting,
                        busy: ServerUpdate.Busy(quiet: false, turns: 1))),
                checkedAt: Self.now)

            #expect(waiting.verdict.isBusy)
            #expect(waiting.headline.contains("waiting"))
            #expect(waiting.invitation == nil)
        }
        /// A wait can outlast any deadline worth polling through, and the machine is answering the
        /// whole time. Expiring it would print "an update started and never reported how it ended"
        /// about a machine that is saying exactly what it is doing.
        @Test func aMachineHoldingAFinishedBuildNeverExpiresIntoAbandonment() {
            let holding = Self.reading(
                .working(UpdateProgress(step: .waitingForQuiet, observedAt: Self.now)),
                component: .server(profileID: "a"))
            let building = Self.reading(
                .working(UpdateProgress(step: .building, observedAt: Self.now)),
                component: .server(profileID: "b"))
            let muchLater = Self.now.addingTimeInterval(8 * 3600)

            #expect(holding.verdict.isHolding)
            #expect(!building.verdict.isHolding)
            #expect(UpdateFreshness.decayed(holding, now: muchLater) == holding.verdict)
            if case .unverified(.interrupted) = UpdateFreshness.decayed(building, now: muchLater) {
            } else {
                Issue.record("a build nobody heard from again is abandoned")
            }
        }
        /// The trust must not become a way of never being told. A machine that says it keeps itself
        /// current and cannot install the thing in front of it is a machine nobody would ever hear
        /// from about it again.
        @Test func aSelfTakingMachineThatCannotInstallThisOneStillAsks() {
            let blocked = UpdateReadings.server(
                profileID: "a", title: "macbook", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.5.0", updateAvailable: true, behind: 3, canUpdate: false,
                        reason: "The checkout has 2 uncommitted changes.", manager: "systemd",
                        obstacle: ServerUpdate.Obstacle(
                            kind: "dirty", summary: "The checkout has 2 uncommitted changes.",
                            items: ["Sources/A.swift", "Sources/B.swift"]),
                        automation: ServerUpdate.Automation(enabled: true))),
                checkedAt: Self.now)

            #expect(blocked.verdict.offer?.canInstallHere == false)
            #expect(blocked.stands())
            #expect(blocked.verdict.offer?.detailLines.count == 2)
        }

        /// A machine that has not said whether anything is running on it has not said nothing is.
        @Test func aRestartPressNeverAssertsAnIdlenessNobodyReported() {
            let silentAboutItself = UpdateReadings.server(
                profileID: "a", title: "old bridge", subtitle: nil,
                outcome: .answered(
                    ServerUpdate(
                        version: "1.6.0", running: "1.5.0", restartRequired: true,
                        manager: "systemd", canRestart: true)),
                checkedAt: Self.now)

            guard case .restartHere(_, let waitingFor) = silentAboutItself.invitation else {
                Issue.record("a supervised build waiting to be loaded is one press")
                return
            }
            #expect(waitingFor != nil)
            #expect(silentAboutItself.invitation?.promise?.contains("few seconds") == false)
        }
    }
}
