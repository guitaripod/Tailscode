import AppKit
import TailscodeCore

extension MainWindowController {
    /// What the composer and the transcript re-read after a preference they show was written
    /// from somewhere other than Settings: the same two hand-overs Settings makes after its own
    /// switches, so a key and a switch cannot leave the window in two different states.
    func composerPreferencesChanged() {
        transcript.composer.applyPreferences()
    }

    func transcriptPreferencesChanged() {
        splitPanes.eachPane { $0.applyUIScale() }
        Task { await sidebar.refresh() }
    }

    /// Light and dark swap places whatever the setting was, including "follow the system": a key
    /// that flips what is on screen right now is the only reading of "switch" that is not
    /// surprising, and it pins the face it lands on the way Settings' picker does.
    func toggleAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next: ThemeAppearance = dark ? .light : .dark
        ThemeSelection.setAppearance(next)
        MacTheme.Chrome.apply()
        toast(next.title)
    }

    func toggleCompactTools() {
        let defaults = UserDefaults.standard
        let current =
            defaults.object(forKey: "tailscode.compactTools") == nil
            ? true : defaults.bool(forKey: "tailscode.compactTools")
        defaults.set(!current, forKey: "tailscode.compactTools")
        transcriptPreferencesChanged()
        toast(
            current
                ? Localized.text("Agent steps stay open")
                : Localized.text("Agent steps fold to one line"))
    }

    func toggleVimComposer() {
        let defaults = UserDefaults.standard
        let current = defaults.bool(forKey: "tailscode.vimComposer")
        defaults.set(!current, forKey: "tailscode.vimComposer")
        composerPreferencesChanged()
        toast(current ? Localized.text("Vim mode off") : Localized.text("Vim mode on"))
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}
