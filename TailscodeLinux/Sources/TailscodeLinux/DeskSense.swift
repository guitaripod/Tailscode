import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// This computer's half of quiet at the desk: reads how long the desktop has gone without input
/// and whether it is locked, and keeps a `DeskBeat` telling every server the person is here. A
/// build under `.build/` stays silent unless asked, because the headless harness would otherwise
/// report the same desk from a display nobody sits at.
enum DeskSense {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var beat: DeskBeat?

    static var enabled: Bool {
        DeskKeys.reports { SettingsFile.stored(forKey: $0) ?? UserDefaults.standard.object(forKey: $0) }
    }

    static var isSilenced: Bool {
        DesktopGuard.isDevelopmentBuild && ProcessInfo.processInfo.environment["TAILSCODE_DESK"] != "1"
    }

    /// Starts once the window exists, on the main thread: the compositor answers on the app's own
    /// display connection.
    static func start() {
        guard !isSilenced, lock.withLock({ beat == nil }) else { return }
        tailscode_desk_idle_begin()
        let id = DeskKeys.id(
            { SettingsFile.stored(forKey: $0) ?? UserDefaults.standard.object(forKey: $0) },
            { SettingsFile.set($1, forKey: $0) })
        let made = DeskBeat(
            desk: id, name: hostName, enabled: enabled, sense: { reading() },
            servers: { await servers() })
        lock.withLock { beat = made }
        tailscode_desk_watch(
            { event, value, _ in DeskSense.handle(event: event, value: value) }, nil)
        Task { await made.start() }
    }

    static func reading() -> DeskReading {
        let idle = tailscode_desk_idle_seconds()
        return DeskReading(idle: idle < 0 ? nil : idle, locked: tailscode_desk_locked() == 1)
    }

    /// The servers this computer holds, once each however many profiles reach it.
    static func servers() async -> [DeskServer] {
        let directory = ServerDirectory.shared
        guard await !directory.isDemoMode() else { return [] }
        var seen: Set<String> = []
        var found: [DeskServer] = []
        for profile in await directory.profiles() {
            let key = profile.baseURL.absoluteString
            guard seen.insert(key).inserted, let backend = await directory.backend(for: profile)
            else { continue }
            found.append(DeskServer(key: key, backend: backend))
        }
        return found
    }

    static func look(_ sessionID: String) {
        guard let beat = lock.withLock({ beat }) else { return }
        Task { await beat.look(sessionID) }
    }

    static func setEnabled(_ on: Bool) {
        SettingsFile.set(on, forKey: DeskKeys.reports)
        guard let beat = lock.withLock({ beat }) else { return }
        Task { await beat.setEnabled(DeskSense.enabled) }
    }

    static func status() async -> DeskBeat.Status? {
        guard let beat = lock.withLock({ beat }) else { return nil }
        return await beat.status
    }

    /// The app is going: tells every server, waiting a moment for them to hear it, so a phone
    /// does not wait for this desk to fall silent.
    static func leave(waitingUpTo seconds: TimeInterval = 1.5) {
        guard let beat = lock.withLock({ beat }) else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await beat.leave()
            done.signal()
        }
        _ = done.wait(timeout: .now() + seconds)
    }

    private static func handle(event: Int32, value: Int32) {
        guard let beat = lock.withLock({ beat }) else { return }
        if event == Int32(TAILSCODE_DESK_SLEEP.rawValue), value == 1 {
            Task { await beat.leave() }
        } else {
            Task { await beat.poke() }
        }
    }

    private static var hostName: String {
        let full = ProcessInfo.processInfo.hostName
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty || short == "localhost" ? Localized.text("This computer") : short
    }
}
