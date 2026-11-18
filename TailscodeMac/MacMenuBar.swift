import AppKit
import TailscodeCore

/// The app's face when it has no window: the menu bar item that keeps Tailscode standing for the
/// quick ask's chord. A chord claimed from every program is only as good as the process behind
/// it, so the app lives here between windows rather than in the Dock alone — one press asks, the
/// same press with the right button opens the small menu that says what else this copy can do and
/// how to stop it.
///
/// The item is present exactly while there is something to keep the app standing for: the quick
/// ask's chord, or a login item that opens this app at every login. Turning both off puts the app
/// back in the Dock with no second home, which is what a person asking to be left alone meant.
@MainActor
final class MacMenuBar: NSObject, NSMenuDelegate {
    static let shared = MacMenuBar()

    private var item: NSStatusItem?
    private weak var hub: MainWindowController?
    private let menu = NSMenu()
    private var visible = false
    private var watchers: [NSObjectProtocol] = []

    private override init() { super.init() }

    func start(hub: MainWindowController) {
        self.hub = hub
        guard item == nil, !Self.isStagedRun else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            let mark = NSImage(
                systemSymbolName: "sparkle",
                accessibilityDescription: Localized.text("Ask Tailscode"))
            mark?.isTemplate = true
            button.image = mark
            button.target = self
            button.action = #selector(pressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(Localized.text("Tailscode"))
        }
        item = status
        buildMenu()
        watch()
        apply()
    }

    /// A run that photographs or checks the app is not a run somebody keeps: a status item is the
    /// one piece of chrome that would sit on the screen after the window it belongs to is gone.
    private static var isStagedRun: Bool {
        let staged = ["--selftest", "--demo", "--shot", "--shot-live", "--bench", "--open", "--tree"]
        return CommandLine.arguments.contains(where: staged.contains)
    }

    /// The menu is only put on the item for the press that asked for it: a status item with a
    /// permanent menu swallows the plain click that is supposed to be the question.
    @objc private func pressed(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu =
            event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            hub?.summonQuickAsk()
            return
        }
        item?.menu = menu
        item?.button?.performClick(nil)
    }

    /// The menu belongs to the item only for the right press that asked for it; a status item
    /// holding one permanently would swallow the plain click that is supposed to be the question.
    func menuDidClose(_ menu: NSMenu) {
        item?.menu = nil
    }

    private func buildMenu() {
        menu.delegate = self
        add(Localized.text("Ask Tailscode…"), #selector(ask))
        add(Localized.text("Open Tailscode"), #selector(openWindow))
        menu.addItem(.separator())
        add(Localized.text("Start at Login"), #selector(toggleLoginItem))
        add(Localized.text("Settings…"), #selector(settings))
        menu.addItem(.separator())
        add(Localized.text("Quit Tailscode"), #selector(quit))
    }

    private func add(_ title: String, _ action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func ask() {
        hub?.summonQuickAsk()
    }

    @objc private func openWindow() {
        hub?.presentMainWindow()
    }

    @objc private func toggleLoginItem() {
        if MacAgent.shared.loginItem == .needsApproval {
            MacAgent.shared.openLoginItems()
            return
        }
        MacAgent.shared.setEnabled(MacAgent.shared.loginItem == .off)
    }

    @objc private func settings() {
        MacAgent.claim()
        hub?.presentPreferences()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func watch() {
        for name in [SummonSettings.didChange, MacAgent.didChange, MacSummon.didChange] {
            watchers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainThread.call { self?.apply() }
                })
        }
    }

    /// Whether the item belongs on the bar at all, which is the same question as whether the app
    /// is meant to be reachable with no window.
    private func apply() {
        let wanted = SummonSettings.isEnabled || MacAgent.shared.isKeptReady
        if wanted, !visible {
            item?.isVisible = true
            visible = true
        } else if !wanted, visible {
            item?.isVisible = false
            visible = false
        }
        refresh()
    }

    private func refresh() {
        let agent = MacAgent.shared
        if let entry = menu.items.first(where: { $0.action == #selector(toggleLoginItem) }) {
            entry.state = agent.loginItem == .off ? .off : .on
            entry.isEnabled = agent.loginItem != .unavailable
            entry.title =
                agent.loginItem == .needsApproval
                ? Localized.text("Approve Start at Login…") : Localized.text("Start at Login")
        }
        item?.button?.toolTip = Self.tooltip
    }

    /// What the bar's mark answers to, said where the pointer can find it: the chord as the
    /// person's own settings spell it, or the fact that no chord is claimed.
    private static var tooltip: String {
        guard SummonSettings.isEnabled else { return Localized.text("Ask Tailscode") }
        return Localized.text(
            "Ask Tailscode — %@", SummonSettings.chord.display(on: .apple))
    }
}
