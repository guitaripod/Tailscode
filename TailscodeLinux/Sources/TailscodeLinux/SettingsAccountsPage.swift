import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Accounts: the video sign-ins and the keys this machine keeps for usage.
enum SettingsAccountsPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let watch = SettingsRows.group(
            WatchAccounts.heading, on: page, description: WatchAccounts.description)
        renderWatchAccounts(into: watch, parent: context.window)
        addUsage(page, context)
    }

    private static func addUsage(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let usage = SettingsRows.group(
            Localized.text("Usage"), on: page,
            description: Localized.text(
                "The full quota picture lives at the foot of the chat list; the Ollama Cloud and DeepSeek keys are the account facts this machine keeps."
            ))
        let window = context.window
        let onUsageKeysChanged = context.onUsageKeysChanged

        let deepseekRow = DeepSeekRowHeld()
        let refreshDeepseekRow: @Sendable () -> Void = {
            guard let held = deepseekRow.hold?.widget else { return }
            adw_action_row_set_subtitle(ptr(held), keyState(hasToken: DeepSeekCredentials.hasToken))
        }
        let deepseek = SettingsRows.buttonRow(
            Localized.text("DeepSeek API key"),
            subtitle: keyState(hasToken: DeepSeekCredentials.hasToken),
            label: Localized.text("Edit")
        ) {
            guard let parent = window.widget else { return }
            DeepSeekKeyDialog.present(parent: parent) {
                refreshDeepseekRow()
                onUsageKeysChanged()
            }
        }
        deepseekRow.hold = Gtk.WeakWidget(deepseek)
        SettingsRows.add(deepseek, to: usage)

        let ollamaRow = OllamaRowHeld()
        let refreshOllamaRow: @Sendable () -> Void = {
            guard let held = ollamaRow.hold?.widget else { return }
            adw_action_row_set_subtitle(ptr(held), keyState(hasToken: OllamaCredentials.hasToken))
        }
        let ollama = SettingsRows.buttonRow(
            Localized.text("Ollama Cloud API key"),
            subtitle: keyState(hasToken: OllamaCredentials.hasToken),
            label: Localized.text("Edit")
        ) {
            guard let parent = window.widget else { return }
            OllamaKeyDialog.present(parent: parent) {
                refreshOllamaRow()
                onUsageKeysChanged()
            }
        }
        ollamaRow.hold = Gtk.WeakWidget(ollama)
        SettingsRows.add(ollama, to: usage)
    }

    private static func keyState(hasToken: Bool) -> String {
        hasToken ? Localized.text("Saved in the app's secret store") : Localized.text("Not set")
    }

    /// The two video accounts, drawn and redrawn in place. A row's whole content changes the moment
    /// somebody signs in or out, and the settings window is built once — so the group takes back
    /// exactly the rows it put there and adds fresh ones, rather than the window being rebuilt.
    private static func renderWatchAccounts(
        into group: UnsafeMutablePointer<GtkWidget>, parent parentHold: Gtk.WeakWidget,
        added: WatchRowsHeld = WatchRowsHeld()
    ) {
        for bits in added.rows {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            adw_preferences_group_remove(ptr(group), ptr(raw))
        }
        added.rows = []

        let groupHold = Gtk.WeakWidget(group)
        let refill: @Sendable () -> Void = {
            Gtk.onMain {
                guard let heldGroup = groupHold.widget else { return }
                renderWatchAccounts(into: heldGroup, parent: parentHold, added: added)
            }
        }
        for row in WatchAccounts.rows() {
            let source = row.source
            let note = row.note
            let subtitle = note.map { "\(row.detail)\n\($0)" } ?? row.detail
            let built = SettingsRows.buttonRow(row.title, subtitle: subtitle, label: row.actionTitle) {
                switch row.action {
                case .signIn:
                    Gtk.onMain {
                        guard let held = parentHold.widget else { return }
                        WatchSignInDialog.present(
                            parent: held, source: source, onFinished: refill)
                    }
                case .signOut:
                    MediaAccounts.signOut(source)
                    SettingsFile.capture()
                    refill()
                case .configure:
                    Gtk.onMain {
                        guard let held = parentHold.widget else { return }
                        YouTubeSetupDialog.present(parent: held, onSaved: refill)
                    }
                }
            }
            adw_action_row_set_subtitle_lines(ptr(built), 0)
            SettingsRows.add(built, to: group)
            added.rows.append(UInt(bitPattern: built))
        }
    }
}

/// The account rows the settings group currently owns, so a refill takes back exactly what it put
/// there. Adwaita's group keeps its rows in an internal list box, so walking children to find them
/// finds the wrong widgets.
final class WatchRowsHeld: @unchecked Sendable {
    var rows: [UInt] = []
}

/// The DeepSeek key row's pointer, so the subtitle can restate the key's presence after the editor
/// changes it — the settings window is built once and the row must answer honestly in place.
final class DeepSeekRowHeld: @unchecked Sendable {
    var hold: Gtk.WeakWidget?
}

/// The Ollama Cloud key row's pointer, so the subtitle can restate the key's presence after the
/// editor changes it — the settings window is built once and the row must answer honestly in place.
final class OllamaRowHeld: @unchecked Sendable {
    var hold: Gtk.WeakWidget?
}
