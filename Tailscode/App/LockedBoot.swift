import Foundation
import MidgarCore
import TailscodeCore
import UIKit
import os

/// The part of a launch that reads what the app has saved, held back while the phone cannot read it.
///
/// `BootSeal` says when that is: after a restart and before the first unlock, when iOS still wakes
/// the app for a silent push, a background refresh or a finished transfer. A launch that built
/// itself then read no active server and no purchase and kept those answers for as long as it
/// lived, so opening the app while that process was still alive showed the welcome screen and a
/// copy that had forgotten it was Pro. A launch that finds its data sealed now does only what iOS
/// insists on before a launch returns; the rest waits here for the unlock, and the handlers a
/// background wake reaches ask `isOpen` and do nothing until it is.
@MainActor
enum LockedBoot {
    nonisolated private static let opened = OSAllocatedUnfairLock(initialState: false)
    private static var held: (() -> Void)?

    /// Whether the launch has been finished. Read from any thread: a background task's handler
    /// runs on a queue of the system's choosing.
    nonisolated static var isOpen: Bool { opened.withLock { $0 } }

    private static var observer: (any NSObjectProtocol)?

    /// Runs `boot` now when saved data can be read, and once the phone has been unlocked when it
    /// cannot.
    static func begin(_ application: UIApplication, boot: @escaping () -> Void) {
        guard isSealed(application) else {
            opened.withLock { $0 = true }
            noteOpened()
            boot()
            return
        }
        MidgarLog.info(
            "launched before the first unlock: the launch waits until saved data can be read",
            category: .lifecycle)
        held = boot
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { open(forAWindow: false) }
        }
    }

    private static func isSealed(_ application: UIApplication) -> Bool {
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_BOOT_SEALED"] != nil { return true }
        #endif
        return BootSeal.isSealed(evidence(application))
    }

    /// Finishes a held launch. The unlock calls it, and so does a window about to be shown, which
    /// iOS allows only on a phone that has been unlocked: nothing a person can see ever waits on
    /// the seal's own reading of the disk. Preferences are asked for again first, because this
    /// process met them sealed.
    static func open(forAWindow: Bool) {
        guard !isOpen else { return }
        opened.withLock { $0 = true }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let boot = held
        held = nil
        if !forAWindow, staysBlind(application: UIApplication.shared) {
            MidgarLog.error(
                "preferences still read empty after the unlock: ending this background launch so the next one starts clean",
                category: .lifecycle)
            exit(0)
        }
        MidgarLog.info("saved data is readable: finishing the launch", category: .lifecycle)
        noteOpened()
        boot?()
    }

    /// Whether this process still cannot see preferences an unlocked phone holds: the system says
    /// data is readable, an earlier launch wrote preferences, and none of them read back. Such a
    /// process would build itself wrong, so while nobody is looking at it, it ends instead, and
    /// the next wake or the person's own launch starts with everything readable. A launch that a
    /// window is waiting on never asks this: a process a person is opening is never ended.
    private static func staysBlind(application: UIApplication) -> Bool {
        guard application.applicationState == .background, application.isProtectedDataAvailable else {
            return false
        }
        let seen = evidence(application)
        return seen.preferencesFileExists && !seen.canaryReadsBack
    }

    private static func noteOpened() {
        guard let key = BootSeal.canaryKeys.last, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    private static func evidence(_ application: UIApplication) -> BootSeal.Evidence {
        let manager = FileManager.default
        let servers = manager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConnectionStore.appGroup)?
            .appendingPathComponent("CodingAgentKit/profiles.json")
        let serversExist = servers.map { manager.fileExists(atPath: $0.path) } ?? false
        let preferences = manager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences/\(Bundle.main.bundleIdentifier ?? "").plist")
        return BootSeal.Evidence(
            protectedDataAvailable: application.isProtectedDataAvailable,
            serversFileExists: serversExist,
            serversFileOpens: serversExist && opens(servers),
            preferencesFileExists: preferences.map { manager.fileExists(atPath: $0.path) } ?? false,
            canaryReadsBack: BootSeal.canaryKeys.contains { UserDefaults.standard.object(forKey: $0) != nil })
    }

    private static func opens(_ file: URL?) -> Bool {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        try? handle.close()
        return true
    }
}
