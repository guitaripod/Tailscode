import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The speech model's row in Settings: what is on disk and the one thing to do about it — download
/// it, follow it while it downloads, or take it off this machine — kept current while the page is
/// open.
final class DictationModelRow: @unchecked Sendable {
    let widget = adw_action_row_new()!
    private let button = gtk_button_new()!
    private var watch: UUID?

    init() {
        adw_preferences_row_set_title(ptr(widget), DictationModelReading.modelLabel)
        Gtk.addClass(button, "flat")
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(widget), button)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.press() }
        }
        watch = DictationModelStore.shared.watch { [weak self] state in
            Gtk.onMain { [weak self] in self?.show(state) }
        }
    }

    deinit {
        if let watch { DictationModelStore.shared.unwatch(watch) }
    }

    private func show(_ state: DictationModelStore.State) {
        let subtitle: String
        let action: String
        switch state {
        case .installed:
            subtitle = "\(DictationModelPack.modelName) · \(DictationModelReading.onDisk) \(DictationReading.bytes(DictationModelStore.shared.bytesOnDisk))"
            action = DictationModelReading.remove
        case .installing(let download):
            subtitle = DictationModelReading.progress(done: download.done, total: download.total)
            action = DictationModelReading.cancel
        case .absent:
            subtitle = "\(DictationModelPack.modelName) · \(DictationReading.bytes(DictationModelPack.totalBytes)) · \(DictationModelPack.license)"
            action = DictationModelReading.download
        case .failed:
            subtitle = DictationModelReading.failed
            action = DictationReading.tryAgain
        }
        adw_action_row_set_subtitle(ptr(widget), subtitle)
        gtk_button_set_label(ptr(button), action)
    }

    private func press() {
        let store = DictationModelStore.shared
        switch store.state {
        case .installed: try? store.remove()
        case .installing: store.cancel()
        case .absent, .failed: store.install()
        }
    }
}
