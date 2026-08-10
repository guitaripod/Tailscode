import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The quick-ask surface, drawn: one entry, the aim it remembered, and nothing else. Enter is
/// the whole ceremony — the words go out as a new conversation with no project directory on the
/// server named in the chip, and the window stays up only long enough for that server to answer,
/// so a failed mint keeps the question in hand rather than swallowing it. The aim is both halves
/// and both are the quick ask's own: tab or a click moves the machine, `m` or the model chip
/// opens the catalog, and `QuickAskDefaults` remembers each per server beside the composer's
/// memory rather than inside it.
final class QuickAskWindow: @unchecked Sendable {
    nonisolated(unsafe) private(set) static var open: QuickAskWindow?

    private let servers: [ConnectionProfile]
    private var targetIndex: Int
    private let onAsk:
        @Sendable (String, String, @escaping @Sendable (NewChatFailure?) -> Void) -> Void

    private let window: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let target: UnsafeMutablePointer<GtkWidget>
    private let model: UnsafeMutablePointer<GtkWidget>
    private let hint: UnsafeMutablePointer<GtkWidget>
    private var asking = false

    /// - Parameter onAsk: mints the conversation on the chosen server and answers with nothing
    ///   when it worked, or with the reason it did not; the words travel with the mint, so the
    ///   caller owns getting them sent once the chat exists.
    static func present(
        servers: [ConnectionProfile], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (String, String, @escaping @Sendable (NewChatFailure?) -> Void)
            -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = QuickAskWindow(
            servers: servers, preferredServer: preferredServer, parent: parent, onAsk: onAsk)
    }

    private init(
        servers: [ConnectionProfile], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (String, String, @escaping @Sendable (NewChatFailure?) -> Void)
            -> Void
    ) {
        self.servers = servers
        self.onAsk = onAsk
        let aimed = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        targetIndex = servers.firstIndex { $0.id == aimed } ?? 0

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Quick ask"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 520, -1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Ask anything — no project, no setup"))
        Gtk.addClass(entry, "model-search")
        hint = Gtk.label(
            Localized.text("enter to ask · tab for the server · m for the model · esc to close"),
            css: "chooser-hint", selectable: false)
        target = Gtk.button("", css: ["flat", "dim"]) {
            Gtk.onMain { QuickAskWindow.open?.cycleTarget() }
        }
        model = Gtk.button("", css: ["flat", "dim"]) {
            Gtk.onMain { QuickAskWindow.open?.chooseModel() }
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_window_set_child(ptr(window), column)

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(header),
            Gtk.label(Localized.text("Quick ask"), css: "section-header", selectable: false))
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        gtk_box_append(ptr(header), target)
        gtk_box_append(ptr(header), model)
        gtk_box_append(ptr(column), header)
        gtk_box_append(ptr(column), entry)
        gtk_box_append(ptr(column), hint)

        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.submit() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            if keyval == Keymap.escape {
                Gtk.onMain { [weak self] in self?.close() }
                return true
            }
            if keyval == Keymap.tab {
                Gtk.onMain { [weak self] in self?.cycleTarget() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("m").value), state & KeyChord.altMask != 0 {
                Gtk.onMain { [weak self] in self?.chooseModel() }
                return true
            }
            return false
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { QuickAskWindow.open = nil }
        }

        refreshTarget()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(entry)
        FileHandle.standardOutput.write(Data("ASK shown target=\(servers[targetIndex].name)\n".utf8))
    }

    private var targetServer: ConnectionProfile { servers[targetIndex] }

    private func cycleTarget() {
        guard servers.count > 1, !asking else { return }
        targetIndex = (targetIndex + 1) % servers.count
        refreshTarget()
        FileHandle.standardOutput.write(Data("ASK target=\(targetServer.name)\n".utf8))
    }

    private func refreshTarget() {
        let server = targetServer
        gtk_button_set_label(ptr(target), Localized.text("→ %@", server.name))
        gtk_button_set_label(
            ptr(model),
            ModelBadge.label(
                model: QuickAskDefaults.model(forProfileID: server.id),
                effort: QuickAskDefaults.effort(forProfileID: server.id)))
        gtk_widget_set_visible(model, ModelCatalogStore.cached(server.id).isEmpty ? 0 : 1)
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat.
    private func chooseModel() {
        guard !asking else { return }
        let server = targetServer
        ModelChooserWindow.present(
            sources: ModelFleet.sources(profiles: servers, current: server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id), parent: window
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                QuickAskDefaults.adopt(pick)
                if let index = self.servers.firstIndex(where: { $0.id == pick.profileID }) {
                    self.targetIndex = index
                }
                self.refreshTarget()
                FileHandle.standardOutput.write(
                    Data("ASK model=\(self.targetServer.name)\n".utf8))
            }
        }
    }

    /// The window outlives Enter the way the new-chat modal outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words back.
    private func submit() {
        guard !asking else { return }
        let text = Dialogs.entryText(entry).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        asking = true
        gtk_widget_set_sensitive(entry, 0)
        gtk_label_set_text(op(hint), Localized.text("Asking %@…", targetServer.name))
        let server = targetServer
        onAsk(server.id, text) { [weak self] failure in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let failure else {
                    QuickAskDefaults.record(profileID: server.id)
                    FileHandle.standardOutput.write(Data("ASK sent server=\(server.name)\n".utf8))
                    self.close()
                    return
                }
                self.asking = false
                gtk_widget_set_sensitive(self.entry, 1)
                gtk_widget_grab_focus(self.entry)
                gtk_label_set_text(op(self.hint), "\(failure.title) — \(failure.detail)")
                FileHandle.standardOutput.write(Data("ASK failed \(failure.title)\n".utf8))
            }
        }
    }

    func driveType(_ text: String) {
        gtk_editable_set_text(op(entry), text)
    }

    func driveGo() {
        submit()
    }

    private func close() {
        gtk_window_destroy(ptr(window))
        Self.open = nil
    }
}
