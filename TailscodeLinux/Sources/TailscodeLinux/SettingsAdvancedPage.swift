import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Advanced: what a bug report needs, what the app keeps on disk, the opt-in for plain words from a
/// local model, and work that is not ready.
enum SettingsAdvancedPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        addDiagnostics(to: page)
        addStorage(to: page)
        SettingsPlainWords.add(to: page)
        addAlpha(page, context)
    }

    private static func addDiagnostics(to page: UnsafeMutablePointer<GtkWidget>) {
        let diagnostics = SettingsRows.group(Localized.text("Diagnostics"), on: page)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Copy diagnostics"), subtitle: AppLog.current.path,
                label: Localized.text("Copy")
            ) {
                Gtk.copyToClipboard(AboutWindow.diagnostics())
            }, to: diagnostics)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Logs"),
                subtitle: Localized.text("The flight recorder and the app's own log, for a bug report"),
                label: Localized.text("Show folder")
            ) {
                open(AppLog.directory)
            }, to: diagnostics)
    }

    private static func addStorage(to page: UnsafeMutablePointer<GtkWidget>) {
        let storage = SettingsRows.group(Localized.text("Storage"), on: page)
        let held = PicturesRowHeld()
        let row = SettingsRows.buttonRow(
            Localized.text("Cached pictures"), subtitle: cacheState(),
            label: Localized.text("Clear")
        ) {
            ImageCache.clear()
            Gtk.onMain {
                guard let widget = held.hold?.widget else { return }
                adw_action_row_set_subtitle(ptr(widget), cacheState())
            }
        }
        held.hold = Gtk.WeakWidget(row)
        SettingsRows.add(row, to: storage)
    }

    private static func addAlpha(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let onOrbChanged = context.onOrbChanged
        let alpha = SettingsRows.group(
            Localized.text("Alpha"), on: page,
            description: Localized.text(
                "Early work, off by default: it may cost battery, change shape, or leave"))
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Presence orb"),
                subtitle: Localized.text(
                    "A GPU-rendered creature at the foot of the chat list, breathing what every conversation is doing"),
                value: Preferences.presenceOrb
            ) { value in
                Preferences.setPresenceOrb(value)
                onOrbChanged()
            }, to: alpha)
    }

    private static func cacheState() -> String {
        let bytes = ImageCache.bytesUsed()
        guard bytes > 0 else { return Localized.text("Nothing kept yet") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return Localized.text("%@ kept so chats open faster", size)
    }

    private static func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.path]
        try? process.run()
    }
}

/// The cached-pictures row's pointer, so its subtitle can restate the size after a clear — the
/// settings window is built once and the row must answer honestly in place.
final class PicturesRowHeld: @unchecked Sendable {
    var hold: Gtk.WeakWidget?
}
