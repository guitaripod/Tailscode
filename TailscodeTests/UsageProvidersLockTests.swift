import Foundation
import Synchronization
import Testing
import UIKit

@testable import Tailscode

/// The usage providers lock is a flock on a file in the shared container, and iOS kills an app
/// suspended while holding one (0xDEAD10CC). These pin that the flock is only ever held inside the
/// app's background-task hold, that a hold that is refused or ends early never keeps it, and that
/// the hold's background task is ended exactly once, never while the flock is held.
struct UsageProvidersLockTests {
    private final class RecordingHold: UsageLockHold {
        let lockFile: URL
        let events = Mutex<[String]>([])
        let holdingChecksLeft: Mutex<Int>
        let takesFlock: Bool

        init(lockFile: URL, holdingChecks: Int = .max, takesFlock: Bool = true) {
            self.lockFile = lockFile
            self.holdingChecksLeft = Mutex(holdingChecks)
            self.takesFlock = takesFlock
        }

        var isHolding: Bool {
            holdingChecksLeft.withLock { left in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }

        func flockTaken() -> Bool {
            events.withLock { $0.append("flockTaken") }
            return takesFlock
        }

        func release() {
            let free = UsageProvidersLockTests.isFree(lockFile)
            events.withLock { $0.append(free ? "release:lock-free" : "release:lock-taken") }
        }
    }

    private final class RecordingGuard: UsageLockSuspensionGuard {
        let hold: RecordingHold?
        let lockFile: URL
        let asked = Mutex<[String]>([])

        init(hold: RecordingHold?, lockFile: URL) {
            self.hold = hold
            self.lockFile = lockFile
        }

        func holdAwake(reason: String) -> (any UsageLockHold)? {
            let free = UsageProvidersLockTests.isFree(lockFile)
            asked.withLock { $0.append(free ? "hold:lock-free" : "hold:lock-taken") }
            return hold
        }
    }

    private static func freshLockFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "usage-lock-\(UUID().uuidString)", directoryHint: .notDirectory)
    }

    /// Whether another open file description could take the flock right now, the way the widget
    /// or the notification service would.
    fileprivate static func isFree(_ lockFile: URL) -> Bool {
        let descriptor = open(lockFile.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    @Test func aGrantedHoldWrapsTheFlockOnBothSides() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        let hold = RecordingHold(lockFile: lockFile)
        let keeper = RecordingGuard(hold: hold, lockFile: lockFile)
        var heldInside = false

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: keeper) {
            heldInside = !Self.isFree(lockFile)
        }

        #expect(heldInside)
        #expect(keeper.asked.withLock { $0 } == ["hold:lock-free"])
        #expect(hold.events.withLock { $0 } == ["flockTaken", "release:lock-free"])
        #expect(Self.isFree(lockFile))
    }

    @Test func aRefusedHoldWritesWithoutTakingTheFlock() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        let keeper = RecordingGuard(hold: nil, lockFile: lockFile)
        var ran = false
        var heldInside = true

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: keeper) {
            ran = true
            heldInside = !Self.isFree(lockFile)
        }

        #expect(ran)
        #expect(!heldInside)
        #expect(keeper.asked.withLock { $0 } == ["hold:lock-free"])
    }

    @Test func aHoldThatExpiresAsTheFlockComesLetsItGoBeforeWriting() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        let hold = RecordingHold(lockFile: lockFile, takesFlock: false)
        let keeper = RecordingGuard(hold: hold, lockFile: lockFile)
        var heldInside = true

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: keeper) {
            heldInside = !Self.isFree(lockFile)
        }

        #expect(!heldInside)
        #expect(hold.events.withLock { $0 } == ["flockTaken", "release:lock-free"])
    }

    @Test func aWriterWaitingOnAnotherProcessGivesUpWhenItsHoldEnds() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        let other = open(lockFile.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        #expect(flock(other, LOCK_EX) == 0)
        defer {
            flock(other, LOCK_UN)
            close(other)
        }
        let hold = RecordingHold(lockFile: lockFile, holdingChecks: 4)
        let keeper = RecordingGuard(hold: hold, lockFile: lockFile)
        var ran = false
        let started = ContinuousClock.now

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: keeper) { ran = true }

        #expect(ran)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(hold.events.withLock { $0 } == ["release:lock-taken"])
    }

    @Test func aWriterWithoutAGuardWaitsOutItsPatienceThenWrites() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        let other = open(lockFile.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        #expect(flock(other, LOCK_EX) == 0)
        defer {
            flock(other, LOCK_UN)
            close(other)
        }
        var ran = false
        let started = ContinuousClock.now

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: nil) { ran = true }

        let waited = ContinuousClock.now - started
        #expect(ran)
        #expect(waited >= UsageWidgetStore.flockPatience)
        #expect(waited < UsageWidgetStore.flockPatience + .seconds(1))
    }

    @Test func withoutAGuardTheFlockIsStillTaken() {
        let lockFile = Self.freshLockFile()
        defer { try? FileManager.default.removeItem(at: lockFile) }
        var heldInside = false

        UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: nil) {
            heldInside = !Self.isFree(lockFile)
        }

        #expect(heldInside)
        #expect(Self.isFree(lockFile))
    }

    @Test func noLockFileRunsTheBodyWithoutAskingForAHold() {
        let lockFile = Self.freshLockFile()
        let keeper = RecordingGuard(hold: RecordingHold(lockFile: lockFile), lockFile: lockFile)
        var ran = false

        UsageWidgetStore.withProvidersLock(lockFile: nil, keeper: keeper) { ran = true }

        #expect(ran)
        #expect(keeper.asked.withLock { $0 }.isEmpty)
    }

    @Test func concurrentWritersInOneProcessTakeTurnsWithoutAFlock() async {
        let inside = Mutex(0)
        let overlapped = Mutex(false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    UsageWidgetStore.withProvidersLock(lockFile: nil, keeper: nil) {
                        let count = inside.withLock { count in
                            count += 1
                            return count
                        }
                        if count > 1 { overlapped.withLock { $0 = true } }
                        Thread.sleep(forTimeInterval: 0.005)
                        inside.withLock { $0 -= 1 }
                    }
                }
            }
        }

        #expect(!overlapped.withLock { $0 })
    }

    private final class EndLog: Sendable {
        let ended = Mutex<[Int]>([])
        func end(_ identifier: UIBackgroundTaskIdentifier) {
            ended.withLock { $0.append(identifier.rawValue) }
        }
        var all: [Int] { ended.withLock { $0 } }
    }

    private func makeHold(_ log: EndLog) -> BackgroundTaskHold {
        BackgroundTaskHold { log.end($0) }
    }

    @Test func aReleasedHoldEndsItsTaskOnce() {
        let log = EndLog()
        let hold = makeHold(log)

        #expect(hold.adopt(UIBackgroundTaskIdentifier(rawValue: 7)))
        #expect(hold.isHolding)
        hold.release()
        hold.release()

        #expect(log.all == [7])
        #expect(!hold.isHolding)
    }

    @Test func anExpirationWhileTheFlockIsHeldWaitsForTheRelease() {
        let log = EndLog()
        let hold = makeHold(log)

        #expect(hold.adopt(UIBackgroundTaskIdentifier(rawValue: 3)))
        #expect(hold.flockTaken())
        hold.expire()
        #expect(log.all.isEmpty)
        #expect(!hold.isHolding)
        hold.release()

        #expect(log.all == [3])
    }

    @Test func anExpirationBeforeTheFlockEndsTheTaskAndRefusesTheFlock() {
        let log = EndLog()
        let hold = makeHold(log)

        #expect(hold.adopt(UIBackgroundTaskIdentifier(rawValue: 5)))
        hold.expire()
        #expect(log.all == [5])
        #expect(!hold.isHolding)
        #expect(!hold.flockTaken())
        hold.release()

        #expect(log.all == [5])
    }

    @Test func anExpirationBeforeTheIdentifierIsKnownEndsItOnAdoption() {
        let log = EndLog()
        let hold = makeHold(log)

        hold.expire()
        #expect(!hold.adopt(UIBackgroundTaskIdentifier(rawValue: 9)))
        hold.release()

        #expect(log.all == [9])
        #expect(!hold.isHolding)
    }

    @MainActor
    @Test func theAppGuardHoldsARealBackgroundTaskUntilReleased() throws {
        let keeper = BackgroundTaskLockGuard(application: UIApplication.shared)
        let hold = try #require(keeper.holdAwake(reason: "UsageProvidersLockTests"))

        #expect(hold.isHolding)
        #expect(hold.flockTaken())
        hold.release()
        #expect(!hold.isHolding)
    }
}
