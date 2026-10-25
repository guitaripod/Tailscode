import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// The verbs a key can reach that are otherwise a trip through Settings: each applies and
    /// says what it did, because a switch flipped from the keyboard has no control to read back.
    func toggleAppearance() {
        let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        Preferences.setAppearance(dark ? .light : .dark)
        Preferences.applyAppearance()
        MatrixTheme.install()
        applyLayoutPreferences()
        toast(dark ? Localized.text("Light") : Localized.text("Dark"))
    }

    func toggleCompactTools() {
        let folded = !Preferences.compactTools
        Preferences.setCompactTools(folded)
        applyLayoutPreferences()
        toast(
            folded
                ? Localized.text("Agent steps fold to one line")
                : Localized.text("Agent steps stay open"))
    }

    func toggleVimComposer() {
        let on = !Preferences.vimComposer
        Preferences.setVimComposer(on)
        applyLayoutPreferences()
        toast(on ? Localized.text("Vim mode on") : Localized.text("Vim mode off"))
    }

    func toggleFullscreen() {
        guard let window else { return }
        if gtk_window_is_fullscreen(ptr(window)) != 0 {
            gtk_window_unfullscreen(ptr(window))
        } else {
            gtk_window_fullscreen(ptr(window))
        }
    }

    /// The nth row of the chat list as it is drawn now, so "open chat 2" means the second thing
    /// the person can see, not the second thing the server knows about.
    func openChat(number: Int) {
        guard number >= 1, number <= visible.count else { return }
        cursor = number - 1
        if cursor >= sidebarLimit { sidebarLimit = cursor + 60 }
        openCursor()
        revealCursorRow()
    }
}
