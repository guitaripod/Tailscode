import AppKit
import Carbon.HIToolbox
import MidgarCore
import ServiceManagement
import TailscodeCore

/// Whether this Mac keeps Tailscode standing when it has no window, which is the whole promise
/// the quick ask's chord makes: a key claimed from every program is worth nothing if the app it
/// summons stopped existing when somebody closed its window.
///
/// Two facts make that promise: the app opens at login through the system's own login item, and
/// it lives in the menu bar while no window is open (the bar is `MacMenuBar`'s). Neither is
/// assumed — `SMAppService` is asked what the machine actually holds, because a person can turn
/// the item off in System Settings and this app must say so rather than promise a chord that is
/// not there.
@MainActor
final class MacAgent {
    static let shared = MacAgent()

    static let didChange = Notification.Name("tailscode.mac.agent.didChange")

    /// What the system says about this app's own login item. `needsApproval` is registered but
    /// blocked until the person allows it in System Settings, which is a different thing from off
    /// and is the one state that cannot be fixed from inside this app.
    enum LoginItem: Equatable {
        case off
        case on
        case needsApproval
        case unavailable
    }

    private(set) var loginItem: LoginItem = .off

    /// A launch the login item made rather than a person: the window stays closed and the menu bar
    /// is the app's whole face until something is asked of it.
    private(set) var launchedAtLogin = false

    /// The person's own no. The system's status is the truth about what is registered; this is
    /// what keeps the app from registering itself again the next time it launches after somebody
    /// deliberately turned it off.
    private let offKey = "tailscode.agent.loginItem.off"

    private init() {}

    /// What the chord reaches while the key it claimed is held. A registered login item means the
    /// process is there at every login; without one the key still only lasts as long as this
    /// launch, which is what the settings row must keep saying.
    var reach: SummonReach {
        loginItem == .on ? .readyInBackground : .whileRunning
    }

    var isKeptReady: Bool { loginItem != .off }

    func start() {
        read()
        adoptOnInstalledCopy()
    }

    /// Called before anything else in the launch, because the answer changes what the launch does:
    /// a login item's launch opens no window and takes no focus.
    func captureLaunchEvent() {
        launchedAtLogin = Self.eventSaysLoginItem()
    }

    /// A question that needs a real window — a model sheet, a party popover, a file chooser — is
    /// the moment the app comes forward. Typing a question never is: the panel answers over
    /// whatever was in front without taking the menu bar with it.
    static func claim() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func read() {
        loginItem = Self.status()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(!on, forKey: offKey)
        do {
            if on {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            MidgarLog.info(
                "login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)",
                category: .lifecycle)
        }
        read()
        MacSummon.shared.refresh()
    }

    /// The settings row's way into the one place that can finish an approval this app cannot.
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// An app the Finder can keep opening is an app whose login item still points somewhere when
    /// the next login comes. A build out of a checkout is not: registering one leaves a stale path
    /// behind the morning that working copy is replaced, so only an installed copy adopts itself
    /// and everybody else opts in by hand.
    private func adoptOnInstalledCopy() {
        guard !Self.isStagedRun else { return }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        guard !UserDefaults.standard.bool(forKey: offKey) else { return }
        guard SummonSettings.isEnabled else { return }
        guard loginItem == .off else { return }
        setEnabled(true)
    }

    private static var isStagedRun: Bool {
        let staged = ["--selftest", "--demo", "--shot", "--shot-live", "--bench", "--open", "--tree"]
        return CommandLine.arguments.contains(where: staged.contains)
    }

    private static func status() -> LoginItem {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// The one signature macOS uses for both kinds of login item: the open-application event with
    /// the property data saying it came from the login. It is read before the launch finishes,
    /// because the event that carried it is gone once `applicationDidFinishLaunching` returns.
    private static func eventSaysLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        guard event.eventID == AEEventID(kAEOpenApplication) else { return false }
        guard let data = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return data.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The app the question was asked over. A palette summoned from another program brings Tailscode
/// forward only long enough to take the keyboard; the program that was in front is put back the
/// moment the box goes away without opening a conversation. That is what makes the chord feel like
/// a surface of the desktop rather than a trip through another app.
@MainActor
enum MacFocus {
    private(set) static var leaveBehind: NSRunningApplication?

    static func remember() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            leaveBehind = nil
            return
        }
        leaveBehind = front
    }

    /// Called as the panel goes: nothing of this app's took the keyboard in its place — no chat
    /// opened, no sheet is up — so the program the person was in gets it back.
    static func restoreUnlessSomethingElseTookIt() {
        guard NSApp.isActive, NSApp.keyWindow == nil, let app = leaveBehind else { return }
        leaveBehind = nil
        app.activate()
    }
}
