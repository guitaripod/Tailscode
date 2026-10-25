import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One page of Settings: a name and an icon for the switcher, and what it holds. The same seven
/// the Mac's toolbar has, in the same order, so a setting is found in the same place on both.
enum SettingsPage: String, CaseIterable {
    case general
    case appearance
    case conversation
    case notifications
    case accounts
    case keyboard
    case advanced

    var title: String {
        switch self {
        case .general: return Localized.text("General")
        case .appearance: return Localized.text("Appearance")
        case .conversation: return Localized.text("Conversation")
        case .notifications: return Localized.text("Notifications")
        case .accounts: return Localized.text("Accounts")
        case .keyboard: return Localized.text("Keyboard")
        case .advanced: return Localized.text("Advanced")
        }
    }

    var icon: String {
        switch self {
        case .general: return "preferences-system-symbolic"
        case .appearance: return "applications-graphics-symbolic"
        case .conversation: return "chat-message-new-symbolic"
        case .notifications: return "preferences-system-notifications-symbolic"
        case .accounts: return "system-users-symbolic"
        case .keyboard: return "input-keyboard-symbolic"
        case .advanced: return "applications-engineering-symbolic"
        }
    }

    func build(_ context: SettingsContext) -> UnsafeMutablePointer<GtkWidget> {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(ptr(page), title)
        adw_preferences_page_set_icon_name(ptr(page), icon)
        adw_preferences_page_set_name(ptr(page), rawValue)
        switch self {
        case .general: SettingsGeneralPage.fill(page, context)
        case .appearance: SettingsAppearancePage.fill(page, context)
        case .conversation: SettingsConversationPage.fill(page, context)
        case .notifications: SettingsNotificationsPage.fill(page, context)
        case .accounts: SettingsAccountsPage.fill(page, context)
        case .keyboard: SettingsKeyboardPage.fill(page, context)
        case .advanced: SettingsAdvancedPage.fill(page, context)
        }
        return page
    }
}

/// What a page may ask of the window it lives in. Settings points at things the main window owns —
/// the layout, the shortcut table, the machines, the updates — and never reaches into them, so a
/// page is only ever a set of rows and a handful of these.
final class SettingsContext: @unchecked Sendable {
    let window: Gtk.WeakWidget
    let onLayoutChanged: @Sendable () -> Void
    let onShortcutsChanged: @Sendable () -> Void
    let onShowCheatsheet: @Sendable () -> Void
    let onOrbChanged: @Sendable () -> Void
    let onUsageKeysChanged: @Sendable () -> Void
    let onOpenServers: @Sendable () -> Void
    let onOpenUpdates: @Sendable () -> Void
    let isPaneShown: @Sendable (Pane) -> Bool
    let setPaneShown: @Sendable (Pane, Bool) -> Void

    /// The panes Settings can show or hide: the ones with a switch beside them on the Mac.
    enum Pane: Sendable {
        case sidebar
        case terminal
    }

    init(
        window: Gtk.WeakWidget,
        onLayoutChanged: @escaping @Sendable () -> Void,
        onShortcutsChanged: @escaping @Sendable () -> Void,
        onShowCheatsheet: @escaping @Sendable () -> Void,
        onOrbChanged: @escaping @Sendable () -> Void,
        onUsageKeysChanged: @escaping @Sendable () -> Void,
        onOpenServers: @escaping @Sendable () -> Void,
        onOpenUpdates: @escaping @Sendable () -> Void,
        isPaneShown: @escaping @Sendable (Pane) -> Bool,
        setPaneShown: @escaping @Sendable (Pane, Bool) -> Void
    ) {
        self.window = window
        self.onLayoutChanged = onLayoutChanged
        self.onShortcutsChanged = onShortcutsChanged
        self.onShowCheatsheet = onShowCheatsheet
        self.onOrbChanged = onOrbChanged
        self.onUsageKeysChanged = onUsageKeysChanged
        self.onOpenServers = onOpenServers
        self.onOpenUpdates = onOpenUpdates
        self.isPaneShown = isPaneShown
        self.setPaneShown = setPaneShown
    }
}

/// The settings window: seven pages in an Adwaita preferences window — a switcher across the top,
/// search across every row of every page — and every control applying live, because the only
/// honest way to pick a size or a theme is to watch it change. There is one: asking for Settings
/// while it is open raises it, on the page asked for.
enum SettingsWindow {
    private static let current = OpenWindow()

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, page requested: SettingsPage? = nil,
        onLayoutChanged: @escaping @Sendable () -> Void,
        onShortcutsChanged: @escaping @Sendable () -> Void,
        onShowCheatsheet: @escaping @Sendable () -> Void,
        onOrbChanged: @escaping @Sendable () -> Void,
        onUsageKeysChanged: @escaping @Sendable () -> Void,
        onOpenServers: @escaping @Sendable () -> Void,
        onOpenUpdates: @escaping @Sendable () -> Void,
        isPaneShown: @escaping @Sendable (SettingsContext.Pane) -> Bool,
        setPaneShown: @escaping @Sendable (SettingsContext.Pane, Bool) -> Void
    ) {
        if let open = current.window.flatMap(\.widget) {
            if let requested { show(requested, in: open) }
            gtk_window_present(ptr(open))
            return
        }
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Settings"))
        gtk_window_set_default_size(ptr(window), 780, 780)
        if let parent { gtk_window_set_transient_for(ptr(window), ptr(parent)) }
        gtk_window_set_modal(ptr(window), 0)
        gtk_window_set_destroy_with_parent(ptr(window), 1)

        let context = SettingsContext(
            window: Gtk.WeakWidget(window),
            onLayoutChanged: onLayoutChanged, onShortcutsChanged: onShortcutsChanged,
            onShowCheatsheet: onShowCheatsheet, onOrbChanged: onOrbChanged,
            onUsageKeysChanged: onUsageKeysChanged, onOpenServers: onOpenServers,
            onOpenUpdates: onOpenUpdates, isPaneShown: isPaneShown, setPaneShown: setPaneShown)
        for page in SettingsPage.allCases {
            adw_preferences_window_add(ptr(window), ptr(page.build(context)))
        }
        show(requested ?? remembered, in: window)

        let bits = UInt(bitPattern: window)
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "visible-page-name") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
                let name = adw_preferences_window_get_visible_page_name(ptr(raw))
            else { return }
            Preferences.setSettingsPage(String(cString: name))
        }
        current.window = Gtk.WeakWidget(window)
        gtk_window_present(ptr(window))
    }

    private static var remembered: SettingsPage {
        Preferences.settingsPage.flatMap(SettingsPage.init(rawValue:)) ?? .general
    }

    private static func show(_ page: SettingsPage, in window: UnsafeMutablePointer<GtkWidget>) {
        adw_preferences_window_set_visible_page_name(ptr(window), page.rawValue)
    }

    private final class OpenWindow: @unchecked Sendable {
        var window: Gtk.WeakWidget?
    }
}
