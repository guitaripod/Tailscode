import AppKit
import CodingAgentKit
import CodingAgentKitApple
import MidgarKit
import TailscodeCore
import UserNotifications

/// The settings window: every knob the Mac app has, live — nothing here needs an OK, because the
/// only honest way to pick a behavior is to watch it change. The keys are the same
/// `tailscode.*` defaults the Linux desktop and the phone read, so a preference is a fact about
/// the person, not about the toolkit. The theme is the one preference whose result is the window
/// you are picking it in; type size is the other, so it is shown with a preview of the lines it
/// moves, and ⌘± zooms the whole window on top of it.
@MainActor
final class PreferencesWindow: NSWindowController, NSWindowDelegate {
    let onComposerChanged: @MainActor () -> Void
    let onTranscriptChanged: @MainActor () -> Void
    let onReloadShortcuts: @MainActor () -> Void
    let linesLabel = NSTextField(labelWithString: "")
    let windowLabel = NSTextField(labelWithString: "")
    let hapticLabel = NSTextField(labelWithString: "")
    let summonButton = NSButton(title: "", target: nil, action: nil)
    let summonState = NSTextField(wrappingLabelWithString: "")
    var summonRecorder: Any?
    var hapticStop = -1
    /// What Settings asks the window it belongs to, because the servers, the updates, the pro
    /// unlock, the cheatsheet and the panes are the window's own and Settings only points at them.
    struct Actions {
        var manageServers: @MainActor () -> Void = {}
        var openUpdates: @MainActor () -> Void = {}
        var openPro: @MainActor () -> Void = {}
        var showCheatsheet: @MainActor () -> Void = {}
        var isSidebarShown: @MainActor () -> Bool = { true }
        var setSidebarShown: @MainActor (Bool) -> Void = { _ in }
        var isTerminalShown: @MainActor () -> Bool = { false }
        var setTerminalShown: @MainActor (Bool) -> Void = { _ in }
    }

    var actions = Actions()
    let permissionState = NSTextField(wrappingLabelWithString: "")
    let permissionButton = NSButton(title: "", target: nil, action: nil)
    let cacheState = NSTextField(wrappingLabelWithString: "")
    let cacheButton = NSButton(title: "", target: nil, action: nil)
    weak var typeSection: TypeSettingsView?
    private var tabs: NSTabViewController?
    let watchAccounts = NSStackView()
    let deepseekRow = NSStackView()
    let ollamaRow = NSStackView()
    /// The block the accounts notification calls. A block observer is held by the notification
    /// centre rather than by this window, so it outlives the window unless it is handed back —
    /// `nonisolated(unsafe)` because `deinit` is the one place that must reach it and `deinit` is
    /// not on the main actor.
    private nonisolated(unsafe) var accountsWatch: (any NSObjectProtocol)?
    private nonisolated(unsafe) var summonWatch: (any NSObjectProtocol)?

    init(
        onComposerChanged: @escaping @MainActor () -> Void,
        onTranscriptChanged: @escaping @MainActor () -> Void,
        onReloadShortcuts: @escaping @MainActor () -> Void
    ) {
        self.onComposerChanged = onComposerChanged
        self.onTranscriptChanged = onTranscriptChanged
        self.onReloadShortcuts = onReloadShortcuts
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.openSize.width, height: Self.openSize.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.contentMinSize = NSSize(width: 620, height: 440)
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TailscodeSettingsPanes2")
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        #if !TAILSCODE_MAS
            accountsWatch = NotificationCenter.default.addObserver(
                forName: MediaAccounts.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainThread.call { self?.renderWatchAccounts() }
            }
        #endif
        summonWatch = NotificationCenter.default.addObserver(
            forName: MacSummon.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.renderSummon() }
        }
    }

    deinit {
        if let accountsWatch { NotificationCenter.default.removeObserver(accountsWatch) }
        if let summonWatch { NotificationCenter.default.removeObserver(summonWatch) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The size the window opens at the first time: wide enough for seven toolbar pages and tall
    /// enough that most pages are read without scrolling.
    static let openSize = NSSize(width: 660, height: 680)

    /// Every row reads its value from a store as it is built, and this window is kept for the life
    /// of the app — so the pages are made at each presentation rather than once. A demo world
    /// left, a type scale stepped, a default written from somewhere else: all of it is true again
    /// the next time the window is opened. The page that was open stays open.
    func present(selecting pane: Int? = nil) {
        install(selecting: pane)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The page a name stands for — `appearance`, `conversation`, `notifications`, `accounts`,
    /// `keyboard` or `advanced` — for a launch argument that wants to look at one.
    static func page(named name: String) -> Int? {
        Pane.allCases.firstIndex { String(describing: $0) == name }
    }

    /// Switches the open window to a page the way a click on its toolbar does, for a check that
    /// wants to see what a person sees after the first click rather than at presentation.
    func select(pageNamed name: String) {
        guard let index = Self.page(named: name) else { return }
        tabs?.selectedTabViewItemIndex = index
    }

    /// Opens on the type controls, for a menu item that is about nothing else: they are a section
    /// of the Appearance page, below the theme, and the one thing wanted would otherwise be a
    /// page and a scroll away.
    func presentTypeSize() {
        present(selecting: Pane.allCases.firstIndex(of: .appearance))
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let typeSection else { return }
        typeSection.scrollToVisible(typeSection.bounds)
    }

    /// Puts freshly made pages in the window without moving the window: replacing a window's
    /// content controller resizes it to the controller's own size, which would undo whatever
    /// shape the person gave Settings.
    func install(selecting pane: Int?) {
        guard let window else { return }
        let frame = window.frame
        let wasShown = window.isVisible
        let controller = makeTabs(selecting: pane ?? tabs?.selectedTabViewItemIndex ?? 0)
        tabs = controller
        window.contentViewController = controller
        if wasShown {
            window.setFrame(frame, display: true)
        } else if !window.setFrameUsingName("TailscodeSettingsPanes2") {
            window.setContentSize(Self.openSize)
            window.center()
        }
    }

    /// The theme is the second axis, and it is the one AppKit has no trait for: a colour already
    /// handed out keeps answering for the theme it was made under, so the window the theme is
    /// picked in has to redraw itself along with the rest of the app. The rebuild waits a turn
    /// because the control that asked for it is inside what is being replaced.
    @objc private func repaint() {
        DispatchQueue.main.async { [weak self] in
            MainThread.call {
                guard let self, let window = self.window, window.isVisible else { return }
                self.install(selecting: nil)
            }
        }
    }

    /// A recorder left running would keep swallowing every keystroke in the app after the window
    /// that started it is gone.
    func windowWillClose(_ notification: Notification) {
        stopRecordingSummon()
    }

    /// The monitor is application-wide and answers every press with nothing, so a recorder still
    /// armed when the keyboard moves on would eat what is typed into the composer next door.
    /// Recording is a state of this window, and it ends with the window's turn at the keyboard.
    func windowDidResignKey(_ notification: Notification) {
        stopRecordingSummon()
    }

    var defaults: UserDefaults { .standard }

    var sendOnReturn: Bool {
        defaults.object(forKey: "tailscode.sendOnReturn") as? Bool ?? true
    }

    var vimComposer: Bool {
        defaults.bool(forKey: "tailscode.vimComposer")
    }

    var composerLines: Int {
        let stored = defaults.integer(forKey: "tailscode.composerLines")
        return stored == 0 ? 12 : min(20, max(1, stored))
    }

    var compactTools: Bool {
        if defaults.object(forKey: "tailscode.compactTools") == nil { return true }
        return defaults.bool(forKey: "tailscode.compactTools")
    }

    var transcriptWindow: Int {
        let stored = defaults.integer(forKey: "tailscode.transcriptWindow")
        return stored == 0 ? 400 : min(5000, max(50, stored))
    }

    /// The catalog with the platform's own answer at its head — "System" is not a theme, it is the
    /// choice to have none, and on a Mac whose materials Apple drew that is a real answer.
    static var themeIDs: [String] { [ThemeSelection.systemID] + AppTheme.all.map(\.id) }
}
