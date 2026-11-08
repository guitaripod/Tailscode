import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Conversation: how the prompt box takes a message and how the transcript is drawn.
enum SettingsConversationPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let onLayoutChanged = context.onLayoutChanged
        addPromptBox(to: page, onLayoutChanged)
        addDictation(to: page)
        addTranscript(to: page, onLayoutChanged)
    }

    /// Dictation: the one language this machine's model hears, whether the chat's own words bias
    /// it, and the model on disk, with its size and a way to take it off again.
    private static func addDictation(to page: UnsafeMutablePointer<GtkWidget>) {
        let chord = ShortcutSet.load().effective["composer.dictate"]?.first
        let group = SettingsRows.group(
            DictationReading.settingsTitle, on: page,
            description: DictationReading.settingsFooter(device: Localized.text("computer"), chord: chord, surface: .pointer))
        SettingsRows.add(
            SettingsRows.infoRow(
                DictationReading.languageTitle, value: DictationReading.languageName(SherpaDictationRecognizer.language),
                subtitle: DictationModelReading.englishOnly), to: group)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: DictationReading.chatWordsTitle, subtitle: DictationReading.chatWordsFooter,
                value: DictationPreferences.usesChatWords
            ) { DictationPreferences.usesChatWords = $0 }, to: group)
        let row = DictationModelRow()
        SettingsRows.add(row.widget, to: group)
        SettingsRows.keep(row, alive: row.widget)
    }

    private static func addPromptBox(
        to page: UnsafeMutablePointer<GtkWidget>, _ onLayoutChanged: @escaping @Sendable () -> Void
    ) {
        let composer = SettingsRows.group(Localized.text("Prompt box"), on: page)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Return sends the message"),
                subtitle: Localized.text("Shift+Return writes a new line either way"),
                value: Preferences.sendOnReturn
            ) { Preferences.setSendOnReturn($0) }, to: composer)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Vim mode"),
                subtitle: Localized.text(
                    "Normal, visual and visual-line: motions, operators, text objects, registers, undo"),
                value: Preferences.vimComposer
            ) { value in
                Preferences.setVimComposer(value)
                onLayoutChanged()
            }, to: composer)
        SettingsRows.add(
            SettingsRows.spinRow(
                title: Localized.text("Grows to (lines)"),
                subtitle: Localized.text("Starts one line tall; scrolls past this height"),
                value: Double(Preferences.composerLines), lower: 1, upper: 20, step: 1
            ) { value in
                Preferences.setComposerLines(Int(value))
                onLayoutChanged()
            }, to: composer)
    }

    private static func addTranscript(
        to page: UnsafeMutablePointer<GtkWidget>, _ onLayoutChanged: @escaping @Sendable () -> Void
    ) {
        let transcript = SettingsRows.group(Localized.text("Transcript"), on: page)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Compact agent steps"),
                subtitle: Localized.text(
                    "Thinking and tool calls between prompts fold to one line you can open"),
                value: Preferences.compactTools
            ) { value in
                Preferences.setCompactTools(value)
                onLayoutChanged()
            }, to: transcript)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: ResponseStatsSetting.title,
                subtitle: ResponseStatsSetting.explanation,
                value: Preferences.responseStats
            ) { value in
                Preferences.setResponseStats(value)
                onLayoutChanged()
            }, to: transcript)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: LinkEmbedsSetting.title,
                subtitle: LinkEmbedsSetting.explanation,
                value: Preferences.linkEmbeds
            ) { value in
                Preferences.setLinkEmbeds(value)
                onLayoutChanged()
            }, to: transcript)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: AutoResumeSetting.title,
                subtitle: AutoResumeSetting.explanation,
                value: Preferences.autoResume
            ) { value in
                Preferences.setAutoResume(value)
            }, to: transcript)
        SettingsRows.add(
            SettingsRows.spinRow(
                title: Localized.text("Rows kept on screen"),
                subtitle: Localized.text(
                    "Older rows wait behind one button — this keeps a huge chat fast"),
                value: Double(Preferences.transcriptWindow), lower: 50, upper: 5000, step: 50
            ) { value in
                Preferences.setTranscriptWindow(Int(value))
                onLayoutChanged()
            }, to: transcript)
    }
}
