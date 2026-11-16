import AppKit
import CodingAgentKit
import CoreGraphics
import Foundation
import TailscodeCore

/// This Mac's half of quiet at the desk: how long since the last keyboard, pointer or trackpad
/// input anywhere in the session, whether the screen is locked or the session switched away, and
/// a `DeskBeat` telling every server the person is here. A lock, a sleep, a switch of user and a
/// quit are told at once rather than at the next beat.
@MainActor
enum MacDeskSense {
    private static var beat: DeskBeat?
    private static var observers: [any NSObjectProtocol] = []

    /// Any input at all, the event source's own `kCGAnyInputEventType`: Swift cannot name the
    /// macro, but an imported C enum takes any raw value.
    private nonisolated static let anyInput = CGEventType(rawValue: ~UInt32(0))

    /// The input the session counts as someone being here, read one by one only if the any-input
    /// type were ever refused.
    private nonisolated static let inputs: [CGEventType] = [
        .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .tabletPointer,
    ]

    static var enabled: Bool { DeskKeys.reports { UserDefaults.standard.object(forKey: $0) } }

    /// A run that only stages, photographs, measures or checks the app has nobody at the desk.
    static var isStaged: Bool {
        let staged = ["--selftest", "--demo", "--shot", "--shot-live", "--bench", "--open", "--tree"]
        return CommandLine.arguments.contains(where: staged.contains)
    }

    static func start() {
        guard beat == nil, !isStaged else { return }
        let id = DeskKeys.id(
            { UserDefaults.standard.object(forKey: $0) },
            { key, value in UserDefaults.standard.set(value, forKey: key) })
        let made = DeskBeat(
            desk: id, name: hostName, enabled: enabled, sense: { reading() },
            servers: { await servers() })
        beat = made
        watchSession()
        Task { await made.start() }
    }

    nonisolated static func reading() -> DeskReading {
        let idle = (anyInput.map { [$0] } ?? inputs)
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min()
        return DeskReading(idle: idle, locked: isLocked)
    }

    /// A locked screen, or a session that is not the one on the console: somebody else's login
    /// is in front of the display.
    nonisolated static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true { return true }
        if let onConsole = session[kCGSessionOnConsoleKey] as? NSNumber, !onConsole.boolValue {
            return true
        }
        return false
    }

    /// The servers this Mac holds, once each however many profiles reach it.
    nonisolated static func servers() async -> [DeskServer] {
        await MainActor.run {
            let directory = ServerDirectory.shared
            var seen: Set<String> = []
            return directory.profiles.compactMap { profile -> DeskServer? in
                let key = profile.baseURL.absoluteString
                guard seen.insert(key).inserted, let backend = directory.backend(for: profile)
                else { return nil }
                return DeskServer(key: key, backend: backend)
            }
        }
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: DeskKeys.reports)
        guard let beat else { return }
        Task { await beat.setEnabled(MacDeskSense.enabled) }
    }

    static func look(_ sessionID: String) {
        guard let beat else { return }
        Task { await beat.look(sessionID) }
    }

    static func status() async -> DeskBeat.Status? {
        guard let beat else { return nil }
        return await beat.status
    }

    /// The app is quitting: the servers already listening hear it before the process goes, so a
    /// phone does not wait for this desk to fall silent. Bounded, because quitting must not hang
    /// on a server that does not answer.
    static func leave(waitingUpTo seconds: TimeInterval = 1.5) {
        guard let beat else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await beat.leave()
            done.signal()
        }
        _ = done.wait(timeout: .now() + seconds)
    }

    private static func watchSession() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(
                distributed.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { poke() }
                })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { goAway() }
                })
        }
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { poke() }
                })
        }
    }

    private static func poke() {
        guard let beat else { return }
        Task { await beat.poke() }
    }

    private static func goAway() {
        guard let beat else { return }
        Task { await beat.leave() }
    }

    private static var hostName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? Localized.text("This computer") : name
    }
}
