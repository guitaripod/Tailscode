import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A window that holds nothing but a feature's title and its beta mark, for looking at the mark and
/// its card on their own: a feature whose real surface is not on screen can still be photographed,
/// and the driver can prove what the mark did without a pointer.
final class BetaPreviewWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: [BetaFeature: BetaPreviewWindow] = [:]

    private let window: UnsafeMutablePointer<GtkWidget>
    let badge: BetaBadge

    static func present(feature: BetaFeature, parent: UnsafeMutablePointer<GtkWidget>?) -> BetaPreviewWindow {
        if let existing = open[feature] {
            gtk_window_present(ptr(existing.window))
            return existing
        }
        let preview = BetaPreviewWindow(feature: feature, parent: parent)
        open[feature] = preview
        return preview
    }

    private init(feature: BetaFeature, parent: UnsafeMutablePointer<GtkWidget>?) {
        badge = BetaBadge(feature: feature) { ["Preview: no feature surface is open"] }
        window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 520, 260)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let header = adw_header_bar_new()!
        let title = adw_window_title_new(feature.card.name, "")!
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), title)
        gtk_box_append(ptr(row), badge.widget)
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), row)
        gtk_window_set_titlebar(ptr(window), header)
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [badge] in
            badge.tearDown()
            Gtk.onMain { Self.open.removeValue(forKey: feature) }
        }
        gtk_window_present(ptr(window))
    }
}

extension MainWindow {
    /// `beta=delegate` or `beta=voiceCall`: shows that feature's mark and opens its card, then
    /// says what the mark did.
    func driveBeta(_ argument: String, parent: UnsafeMutablePointer<GtkWidget>?) {
        if argument == "changed" {
            BetaChangedPreview.present()
            return
        }
        guard let feature = BetaFeature(rawValue: argument) else {
            FileHandle.standardOutput.write(Data("BETA unknown feature \(argument)\n".utf8))
            return
        }
        let line: String
        switch feature {
        case .delegate:
            let demo = DelegateDemo.hosts.sorted().first
            let delegate = presentDelegate(host: demo)
            delegate.openBetaCard()
            line = delegate.betaReading
        case .voiceCall:
            let preview = BetaPreviewWindow.present(feature: feature, parent: parent)
            preview.badge.open()
            line = preview.badge.line
        }
        FileHandle.standardOutput.write(Data("BETA \(line)\n".utf8))
    }
}

/// The card as it reads when the person has seen an older release, which neither feature can show
/// for real yet because neither has authored a change: the delegate card with one invented line.
enum BetaChangedPreview {
    static func present() {
        let real = BetaFeature.delegate.card
        let card = BetaCard(
            name: real.name, symbol: real.symbol, glyph: real.glyph, title: real.title, lead: real.lead,
            paragraphs: Array(real.paragraphs.prefix(1)), works: real.works, rough: real.rough,
            changes: [BetaChange(since: SoftwareVersion("1.77")!, line: "A preview line standing in for a real change.")],
            reportName: real.reportName)
        let view = BetaCardView(card: card, freshness: .changed, onCopy: {}, onClose: {})
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 480, 520)
        gtk_window_set_child(ptr(window), view.widget)
        gtk_window_present(ptr(window))
    }
}
