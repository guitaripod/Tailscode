import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A server's Capabilities section on the server screen: a row for each capability the machine
/// reports as available, with its state and one line, and a tap that opens the checklist behind it;
/// one quiet invitation for a machine whose gateway does not answer; nothing at all for a capability
/// the machine can never do.
///
/// The rows are Core's `SetupCapabilityRow`, built from the same desk snapshots the checklist reads,
/// so the section and the window can never disagree. The desk polls for them only while this object
/// holds its lifetime, which the server screen ends when it closes.
final class SetupCapabilitiesRows: @unchecked Sendable {
    private let container = adw_preferences_row_new()!
    private let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let heading = Gtk.label(SetupCapabilityRow.sectionTitle, css: "setup-section", selectable: false)
    private let targets: [SetupTarget]
    private let parent: @Sendable () -> UnsafeMutablePointer<GtkWidget>?
    private let lifetime = PaneLifetime()
    private var snapshots: [SetupTarget: SetupSnapshot] = [:]
    private var drawn: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var drawnKeys: [String: String] = [:]
    private var stopped = false

    private static let glyphTones = ActivityTone.allCases.map(\.glyphCSS)

    init(profileURL: URL, parent: @escaping @Sendable () -> UnsafeMutablePointer<GtkWidget>?) {
        self.parent = parent
        targets = SetupTargets.targets(forProfileURL: profileURL)
        Gtk.margins(column, top: 10, bottom: 10, leading: 12, trailing: 12)
        gtk_box_append(ptr(column), heading)
        gtk_list_box_row_set_child(ptr(container), column)
        gtk_list_box_row_set_activatable(ptr(container), 0)
        gtk_list_box_row_set_selectable(ptr(container), 0)
        gtk_widget_set_visible(container, 0)
    }

    /// The row to add to a server's expander, in the place the section belongs. It is hidden until
    /// a capability has something to say, so a machine that answers nothing shows nothing.
    var row: UnsafeMutablePointer<GtkWidget> { container }

    func start() {
        for target in targets {
            SetupRunner.shared.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
                Gtk.onMain { [weak self] in self?.receive(snapshot) }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        lifetime.cancelAll()
    }

    var rowCount: Int { drawn.count }

    var isShown: Bool { gtk_widget_get_visible(container) != 0 }

    var summary: String {
        targets.compactMap { target in
            snapshots[target].flatMap { SetupCapabilityRow.row(for: $0) }.map { "\($0.capability)=\($0.chip)|\($0.line)" }
        }.joined(separator: " ")
    }

    private func receive(_ snapshot: SetupSnapshot) {
        guard !stopped else { return }
        snapshots[snapshot.target] = snapshot
        render()
    }

    private func render() {
        var any = false
        for target in targets {
            let row = snapshots[target].flatMap { SetupCapabilityRow.row(for: $0) }
            guard let row else {
                if let stale = drawn.removeValue(forKey: target.capability) {
                    gtk_box_remove(ptr(column), stale)
                    drawnKeys[target.capability] = nil
                }
                continue
            }
            any = true
            let key = "\(row.title)|\(row.chip)|\(row.line)|\(row.icon.glyph)|\(row.quiet)"
            if drawnKeys[target.capability] == key { continue }
            if let stale = drawn.removeValue(forKey: target.capability) { gtk_box_remove(ptr(column), stale) }
            let widget = makeRow(row, target: target)
            drawn[target.capability] = widget
            drawnKeys[target.capability] = key
            gtk_box_append(ptr(column), widget)
        }
        gtk_widget_set_visible(container, any ? 1 : 0)
    }

    private func makeRow(_ row: SetupCapabilityRow, target: SetupTarget) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let glyph = Gtk.label(row.icon.glyph, selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(glyph, 18, -1)
        Gtk.setTone(glyph, row.icon.tone.glyphCSS, from: Self.glyphTones)
        ActivityPulse.apply(row.icon, to: glyph)
        gtk_box_append(ptr(line), glyph)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(row.title, css: "preview-row-title", selectable: false)
        let detail = Gtk.label(row.line, css: "preview-row-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(detail), 44)
        gtk_box_append(ptr(words), title)
        gtk_box_append(ptr(words), detail)
        gtk_box_append(ptr(line), words)

        let chip = Gtk.label(row.chip, css: row.quiet ? "dim" : "setup-chip", selectable: false)
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), chip)
        let chevron = Gtk.label("›", css: "dim", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), chevron)

        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "setup-capability")
        gtk_button_set_child(ptr(button), line)
        tailscode_set_accessible_label(button, row.spoken)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.open(target) }
        }
        return button
    }

    func open(_ target: SetupTarget) {
        guard !stopped else { return }
        let lines: @Sendable () -> [String] = {
            target.capability == SetupCapability.voice
                ? VoiceCallRunner.shared.report(for: VoiceSetupSource.endpoint(of: target)) : []
        }
        SetupWindow.present(target: target, parent: parent(), reportLines: lines)
    }

    func openFirst() {
        guard let target = targets.first else { return }
        open(target)
    }
}
