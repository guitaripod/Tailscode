import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// Settings is seven pages the shell builds from one table: each must come out as a page that
    /// answers to its own name (the one `adw_preferences_window_set_visible_page_name` looks for),
    /// the shell must remember the page it was left on, and the theme cards must name the theme
    /// they show as chosen.
    static func checkSettingsPages() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("settings: \(label)") }
            checks += 1
        }
        let host = gtk_window_new()!
        defer { gtk_window_destroy(ptr(host)) }
        let context = SettingsContext(
            window: Gtk.WeakWidget(host), onLayoutChanged: {}, onShortcutsChanged: {},
            onShowCheatsheet: {}, onOrbChanged: {}, onUsageKeysChanged: {}, onOpenServers: {},
            onOpenUpdates: {}, isPaneShown: { _ in true }, setPaneShown: { _, _ in })
        try expect(SettingsPage.allCases.count == 7, "the same seven pages the Mac has")
        for page in SettingsPage.allCases {
            let built = page.build(context)
            let name = adw_preferences_page_get_name(ptr(built)).map { String(cString: $0) }
            try expect(name == page.rawValue, "\(page.rawValue) answers to its own name")
            let icon = adw_preferences_page_get_icon_name(ptr(built)).map { String(cString: $0) }
            try expect(icon == page.icon, "\(page.rawValue) wears its icon")
            let theme = gtk_icon_theme_get_for_display(gdk_display_get_default())
            try expect(
                gtk_icon_theme_has_icon(theme, page.icon) != 0,
                "\(page.rawValue)'s icon resolves under the icon theme in force")
        }

        let before = Preferences.settingsPage
        defer { if let before { Preferences.setSettingsPage(before) } }
        Preferences.setSettingsPage(SettingsPage.keyboard.rawValue)
        try expect(
            Preferences.settingsPage == SettingsPage.keyboard.rawValue,
            "the page Settings was left on is remembered")

        let picked = AppTheme.all.last!
        let grid = ThemeSwatchGrid(selected: AppTheme.all[0].id) { _ in }
        grid.select(picked.id)
        try expect(
            gtk_label_get_text(op(grid.captionWidget)).map { String(cString: $0) }?.hasPrefix(picked.name)
                == true,
            "the caption under the cards names the chosen theme")
        return checks
    }
}
