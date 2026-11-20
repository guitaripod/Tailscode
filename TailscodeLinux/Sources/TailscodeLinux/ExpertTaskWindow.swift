import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A new task for an expert: what the task starts with, said as facts rather than settings — its
/// charter, its skills, its notes, its last tasks, its bench and guards, and how large the brief
/// is — then the words. A conversation handed over rides after them as a brief. Send asks the
/// machine to start the task and puts its conversation on screen.
final class ExpertTaskWindow: @unchecked Sendable {
    nonisolated(unsafe) static var current: ExpertTaskWindow?

    let row: ExpertRow
    let keeper: any MachineExperts
    let carry: ConversationBrief?
    let window: UnsafeMutablePointer<GtkWidget>
    let text: UnsafeMutablePointer<GtkWidget>
    let send: UnsafeMutablePointer<GtkWidget>
    let cancel: UnsafeMutablePointer<GtkWidget>
    let error: UnsafeMutablePointer<GtkWidget>
    var sending = false

    static func present(
        row: ExpertRow, keeper: any MachineExperts, carry: ConversationBrief?, text: String,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        current?.closeWindow()
        current = ExpertTaskWindow(row: row, keeper: keeper, carry: carry, text: text, parent: parent)
    }

    private init(
        row: ExpertRow, keeper: any MachineExperts, carry: ConversationBrief?, text initial: String,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        self.row = row
        self.keeper = keeper
        self.carry = carry
        let (window, content, actions) = Dialogs.windowWithActions(
            title: ExpertWords.newTask + " · " + row.expert.name, parent: parent, width: 600)
        self.window = window
        gtk_window_set_default_size(ptr(window), 600, 560)

        let head = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_halign(head, GTK_ALIGN_CENTER)
        Gtk.margins(head, top: 6, bottom: 4)
        gtk_box_append(ptr(head), ExpertMarks.mark(row.expert, size: .large))
        let starts = Gtk.label(
            ExpertWords.startsWith(row.expert.name), css: "expert-starts", wrap: true, selectable: false)
        gtk_label_set_justify(op(starts), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(starts), 0.5)
        gtk_box_append(ptr(head), starts)
        let chips = ExpertMarks.chips(ExpertReading.startsWith(row.expert))
        gtk_widget_set_halign(chips, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(head), chips)
        let tokens = Gtk.label(ExpertWords.tokens(row.expert.briefTokens), css: "expert-tokens", selectable: false)
        gtk_label_set_xalign(op(tokens), 0.5)
        gtk_box_append(ptr(head), tokens)
        gtk_box_append(ptr(content), head)

        if let carry {
            let note = Gtk.label(ExpertWords.handOverNote(carry.source), css: "expert-handover", wrap: true, selectable: false)
            gtk_label_set_xalign(op(note), 0)
            gtk_box_append(ptr(content), note)
        }

        let frame = gtk_frame_new(nil)!
        let view = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(ptr(UnsafeMutableRawPointer(view)), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        gtk_text_view_set_right_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        gtk_text_view_set_top_margin(ptr(UnsafeMutableRawPointer(view)), 8)
        gtk_text_view_set_bottom_margin(ptr(UnsafeMutableRawPointer(view)), 8)
        gtk_widget_set_size_request(view, -1, 120)
        if let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(view))) {
            gtk_text_buffer_set_text(buffer, initial, -1)
        }
        tailscode_set_accessible_label(view, ExpertWords.newTaskFor(row.expert.name))
        gtk_frame_set_child(ptr(frame), view)
        gtk_box_append(ptr(content), frame)
        text = view
        let hint = Gtk.label(ExpertWords.newTaskFor(row.expert.name), css: "expert-tokens", selectable: false)
        gtk_label_set_xalign(op(hint), 0)
        gtk_box_append(ptr(content), hint)

        error = Gtk.label("", css: "fact-bad", wrap: true, selectable: true)
        gtk_label_set_xalign(op(error), 0)
        gtk_widget_set_visible(error, 0)
        gtk_box_append(ptr(content), error)

        let pill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(pill), ExpertMarks.mark(row.expert, size: .tiny))
        var pillWords = row.expert.name
        if let model = row.expert.model {
            pillWords += " · " + ScheduleDetailWindow.modelWords(model, profileID: row.profileID)
        }
        gtk_box_append(ptr(pill), Gtk.label(pillWords, css: "row-detail", selectable: false))
        gtk_widget_set_hexpand(pill, 1)
        gtk_widget_set_halign(actions, GTK_ALIGN_FILL)
        gtk_box_append(ptr(actions), pill)

        let windowBits = UInt(bitPattern: window)
        cancel = Gtk.button(ExpertWords.cancel, css: ["flat"]) {
            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) { gtk_window_destroy(ptr(raw)) }
        }
        gtk_box_append(ptr(actions), cancel)
        send = Gtk.button(Localized.text("Send"), css: ["suggested-action"]) {
            Gtk.onMain { ExpertTaskWindow.current?.submit() }
        }
        gtk_box_append(ptr(actions), send)
        Gtk.onKey(view) { keyval, state in
            let enter = keyval == UInt32(GDK_KEY_Return) || keyval == UInt32(GDK_KEY_KP_Enter)
            guard enter, (state & GDK_CONTROL_MASK.rawValue) != 0 else { return false }
            Gtk.onMain { ExpertTaskWindow.current?.submit() }
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain {
                if let current = ExpertTaskWindow.current, UInt(bitPattern: current.window) == windowBits {
                    ExpertTaskWindow.current = nil
                }
            }
        }
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(view)
    }

    var typed: String {
        guard let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(text))) else { return "" }
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The type of a phrase into the composer, for the harness.
    func type(_ words: String) {
        guard let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(text))) else { return }
        gtk_text_buffer_set_text(buffer, words, -1)
    }

    func submit() {
        let words = typed
        guard !sending else { return }
        guard !words.isEmpty || carry != nil else {
            say(Localized.text("Say what the task is first."))
            return
        }
        sending = true
        gtk_widget_set_sensitive(send, 0)
        gtk_widget_set_sensitive(cancel, 0)
        let message = carry.map { $0.wrapped(with: words) } ?? words
        let request = ExpertTaskRequest(text: message)
        let keeper = self.keeper
        let row = self.row
        Task { [weak self] in
            let outcome: Result<ExpertTaskStarted, Error>
            do {
                outcome = .success(try await keeper.startExpertTask(row.expert.id, request))
            } catch {
                outcome = .failure(error)
            }
            ExpertDesk.shared.refresh()
            Gtk.onMain { [weak self] in
                guard let self else {
                    if case .success(let started) = outcome {
                        mainWindow?.openExpertTask(started.session, profileID: row.profileID)
                    }
                    return
                }
                switch outcome {
                case .success(let started):
                    self.closeWindow()
                    mainWindow?.openExpertTask(started.session, profileID: row.profileID)
                    mainWindow?.toast(ExpertWords.taskStarted(row.expert.name))
                case .failure(let error):
                    self.sending = false
                    gtk_widget_set_sensitive(self.send, 1)
                    gtk_widget_set_sensitive(self.cancel, 1)
                    self.say(MachineWindow.words(error))
                }
            }
        }
    }

    private func say(_ words: String) {
        gtk_label_set_text(op(error), words)
        gtk_widget_set_visible(error, 1)
    }

    func closeWindow() {
        if ExpertTaskWindow.current === self { ExpertTaskWindow.current = nil }
        gtk_window_destroy(ptr(window))
    }
}
