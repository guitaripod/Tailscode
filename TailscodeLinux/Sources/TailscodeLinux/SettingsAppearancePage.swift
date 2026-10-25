import CAdw
import CGtkShim
import Foundation
import TailscodeCore

enum SettingsAppearancePage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        installTheme(on: page, context: context)
        installReading(on: page, context: context)
        SettingsTypeSection.install(on: page, context: context)
        installLayout(on: page, context: context)
    }

    private static func installTheme(on page: UnsafeMutablePointer<GtkWidget>, context: SettingsContext) {
        let group = SettingsRows.group(
            Localized.text("Theme"), on: page,
            description: Localized.text("The canvas, the terminal and the chrome, together"))
        let grid = ThemeSwatchGrid(selected: Preferences.themeID) { theme in
            Preferences.setTheme(theme)
            MatrixTheme.install()
            context.onLayoutChanged()
        }
        SettingsRows.keep(grid, alive: page)
        SettingsRows.add(grid.widget, to: group)

        let faces = SettingsRows.group(nil, on: page)
        let appearances = Preferences.Appearance.allCases
        SettingsRows.add(
            SettingsRows.segmentedRow(
                title: Localized.text("Light or dark"),
                subtitle: Localized.text("Which of the theme's two faces it wears"),
                options: appearances.map(shortTitle),
                selected: appearances.firstIndex(of: Preferences.appearance) ?? 0
            ) { index in
                Preferences.setAppearance(appearances[index])
                Preferences.applyAppearance()
                MatrixTheme.install()
                context.onLayoutChanged()
                grid.repaint()
            },
            to: faces)
    }

    private static func shortTitle(_ appearance: Preferences.Appearance) -> String {
        switch appearance {
        case .system: return Localized.text("System")
        case .light: return Localized.text("Light")
        case .dark: return Localized.text("Dark")
        }
    }

    private static func installReading(on page: UnsafeMutablePointer<GtkWidget>, context: SettingsContext) {
        let group = SettingsRows.group(Localized.text("Reading"), on: page)
        let densities = ChatDensity.allCases
        SettingsRows.add(
            SettingsRows.segmentedRow(
                title: ChatDensitySetting.title, subtitle: ChatDensitySetting.explanation,
                options: densities.map(\.title),
                selected: densities.firstIndex(of: Preferences.chatDensity) ?? 0
            ) { index in
                Preferences.setChatDensity(densities[index])
            },
            to: group)
        let styles = ActivityStyle.allCases
        SettingsRows.add(
            SettingsRows.segmentedRow(
                title: ActivityStyleSetting.title, subtitle: ActivityStyleSetting.explanation,
                options: styles.map(\.title),
                selected: styles.firstIndex(of: Preferences.activityStyle) ?? 0
            ) { index in
                Preferences.setActivityStyle(styles[index])
            },
            to: group)
    }

    private static func installLayout(on page: UnsafeMutablePointer<GtkWidget>, context: SettingsContext) {
        let group = SettingsRows.group(
            Localized.text("Layout"), on: page,
            description: Localized.text(
                "Drag any divider to size a pane; the sizes are remembered."))
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Chat list"),
                subtitle: Localized.text("The conversations beside the one you are in"),
                value: context.isPaneShown(.sidebar)
            ) { context.setPaneShown(.sidebar, $0) },
            to: group)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Terminal"),
                subtitle: Localized.text(
                    "A shell under the conversation, in the project the chat is working in"),
                value: context.isPaneShown(.terminal)
            ) { context.setPaneShown(.terminal, $0) },
            to: group)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Reset the pane sizes"),
                subtitle: Localized.text("The chat list, the terminal and the splits go back to their first sizes")
            ) {
                Preferences.resetDividers()
                context.onLayoutChanged()
            },
            to: group)
    }
}
