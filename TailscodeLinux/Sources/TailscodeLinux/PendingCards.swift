import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The cards a turn stops on, docked at the end of the transcript where the CLI would be sitting
/// at a prompt: an approval with its three answers on keys, and a question as a form. Both are
/// states of the conversation, not messages in it.
enum PendingCards {
    static func permission(
        _ request: PermissionRequest,
        respond: @escaping @Sendable (PermissionDecision) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-permission")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(heading), Gtk.label("⏸", css: "glyph-running", selectable: false))
        let what = request.title ?? request.toolName ?? Localized.text("a tool")
        let title = Gtk.label(
            Localized.text("Allow %@?", what), css: "card-title", wrap: true)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        if let tool = request.toolName, request.title != nil, tool != request.title {
            gtk_box_append(ptr(card), Gtk.label(tool, css: "tool-detail", selectable: false))
        }

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Allow once · y"), css: ["suggested-action"]) {
                respond(.once)
            })
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Always · a")) { respond(.always) })
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Deny · n"), css: ["destructive-action"]) {
                respond(.reject)
            })
        gtk_box_append(ptr(card), buttons)
        return card
    }

    /// One question item at a time, which keeps the single-select fast path a single click. The
    /// collected answers go out through the caller, which routes them by message or by API as the
    /// backend demands.
    static func question(
        _ request: QuestionRequest, in entry: SessionEntry?,
        submit: @escaping @Sendable ([[String]]) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-question")

        let collector = AnswerCollector(
            request: request, profileID: entry?.profileID ?? "",
            sessionID: entry?.session.id ?? request.sessionID, submit: submit)

        for (index, item) in request.questions.enumerated() {
            let section = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            if !item.header.isEmpty {
                gtk_box_append(
                    ptr(section), Gtk.label(item.header.uppercased(), css: "section-header", selectable: false))
            }
            gtk_box_append(ptr(section), Gtk.label(item.question, css: "card-title", wrap: true))

            let single = !item.multiple && request.questions.count == 1
            for option in item.options {
                let row = Gtk.button(option.label, css: ["answer-option"]) {
                    if single {
                        collector.submitSingle(option.label)
                    } else {
                        collector.toggle(question: index, option: option.label)
                    }
                }
                gtk_widget_set_halign(row, GTK_ALIGN_START)
                if !option.description.isEmpty {
                    gtk_widget_set_tooltip_text(row, option.description)
                }
                gtk_box_append(ptr(section), row)
                collector.register(question: index, option: option.label, widget: row)
            }

            if item.custom || item.options.isEmpty {
                let entry = gtk_entry_new()!
                gtk_entry_set_placeholder_text(
                    ptr(entry), Localized.text("Your own answer…"))
                Gtk.addClass(entry, "mono")
                let scope = collector.draftScope(question: index)
                gtk_editable_set_text(op(entry), DraftStore.text(for: scope))
                let entryBits = UInt(bitPattern: entry)
                Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits),
                        let text = gtk_editable_get_text(op(raw))
                    else { return }
                    DraftStore.record(String(cString: text), for: scope)
                }
                Gtk.connect(UnsafeMutableRawPointer(entry), "activate") {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits),
                        let text = gtk_editable_get_text(op(raw))
                    else { return }
                    let answer = String(cString: text).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard !answer.isEmpty else { return }
                    if single {
                        collector.submitSingle(answer)
                    } else {
                        collector.setCustom(question: index, answer: answer)
                    }
                }
                gtk_box_append(ptr(section), entry)
            }
            gtk_box_append(ptr(card), section)
        }

        if request.questions.count > 1 || request.questions.contains(where: \.multiple) {
            let submitRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(
                ptr(submitRow),
                Gtk.button(Localized.text("Answer"), css: ["suggested-action"]) {
                    collector.submitAll()
                })
            gtk_box_append(ptr(card), submitRow)
        }
        return card
    }

    /// The minutes-long summarize as a card docked where the turn would be: the sweeping glyph
    /// says something is being turned over, the words say what and for how long. The elapsed line
    /// is handed back so the pane's own one-second clock can keep it honest without rebuilding the
    /// card.
    static func compacting(
        startedAt: Date, waiting: Bool,
        elapsedLabel: (UnsafeMutablePointer<GtkWidget>) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let story = CompactionStory.running(startedAt: startedAt, waiting: waiting)
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-compaction")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let glyph = Gtk.label("◐", css: "glyph-running", selectable: false)
        let glyphBits = UInt(bitPattern: glyph)
        ActivityPulse.apply(ActivityKind.compacting.icon, to: glyph, text: "◐") { text in
            guard let raw = UnsafeMutableRawPointer(bitPattern: glyphBits) else { return }
            gtk_label_set_text(op(raw), text)
        }
        gtk_box_append(ptr(heading), glyph)
        let title = Gtk.label(story.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(story.detail, css: "tool-detail", wrap: true, selectable: false)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        if let footnote = story.footnote {
            let elapsed = Gtk.label(footnote, css: "seam-footnote", selectable: false)
            gtk_widget_set_halign(elapsed, GTK_ALIGN_START)
            gtk_box_append(ptr(card), elapsed)
            elapsedLabel(elapsed)
        }
        return card
    }

    /// A refused compaction leads with the reason and ends on the one fact that matters: nothing
    /// was lost.
    static func compactionFailure(_ reason: String) -> UnsafeMutablePointer<GtkWidget> {
        let story = CompactionStory.failed(reason)
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "card")
        Gtk.addClass(card, "card-compaction-failed")

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(heading), Gtk.label("✗", css: "glyph-error", selectable: false))
        let title = Gtk.label(story.title, css: "card-title", wrap: true, selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(heading), title)
        gtk_box_append(ptr(card), heading)

        let detail = Gtk.label(story.detail, css: "agent-text", wrap: true)
        gtk_widget_set_halign(detail, GTK_ALIGN_START)
        gtk_box_append(ptr(card), detail)

        if let footnote = story.footnote {
            let label = Gtk.label(footnote, css: "seam-footnote", wrap: true, selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            gtk_box_append(ptr(card), label)
        }
        return card
    }

    /// Selections for a multi-question or multi-select ask, kept next to the widgets that show
    /// them. Lives as long as its card does; the card is rebuilt when the ask resolves.
    private final class AnswerCollector: @unchecked Sendable {
        private let request: QuestionRequest
        private let profileID: String
        private let sessionID: String
        private let submit: @Sendable ([[String]]) -> Void
        private var chosen: [Int: [String]] = [:]
        private var custom: [Int: String] = [:]
        private var options: [String: UInt] = [:]

        init(
            request: QuestionRequest, profileID: String, sessionID: String,
            submit: @escaping @Sendable ([[String]]) -> Void
        ) {
            self.request = request
            self.profileID = profileID
            self.sessionID = sessionID
            self.submit = submit
        }

        /// A question outlives a restart because it is derived from the transcript, so a free-typed
        /// answer half-written for it does too — keyed by the ask and which of its questions.
        func draftScope(question: Int) -> DraftScope {
            .answer(
                profileID: profileID, sessionID: sessionID,
                questionID: "\(request.id)#\(question)")
        }

        func register(question: Int, option: String, widget: UnsafeMutablePointer<GtkWidget>) {
            options["\(question):\(option)"] = UInt(bitPattern: widget)
        }

        func submitSingle(_ answer: String) {
            forgetDrafts()
            submit([[answer]])
        }

        func toggle(question: Int, option: String) {
            var current = chosen[question] ?? []
            let multiple = request.questions.indices.contains(question)
                && request.questions[question].multiple
            if let index = current.firstIndex(of: option) {
                current.remove(at: index)
            } else {
                if !multiple { current = [] }
                current.append(option)
            }
            chosen[question] = current
            restyle(question)
        }

        func setCustom(question: Int, answer: String) {
            custom[question] = answer
            if !request.questions[question].multiple { chosen[question] = [] }
            restyle(question)
        }

        func submitAll() {
            forgetDrafts()
            var answers: [[String]] = []
            for index in request.questions.indices {
                var selected = chosen[index] ?? []
                if let extra = custom[index], !extra.isEmpty { selected.append(extra) }
                if selected.isEmpty { selected = [Localized.text("(no answer)")] }
                answers.append(selected)
            }
            submit(answers)
        }

        private func forgetDrafts() {
            for index in request.questions.indices {
                DraftStore.clear(draftScope(question: index))
            }
        }

        private func restyle(_ question: Int) {
            guard request.questions.indices.contains(question) else { return }
            let selected = Set(chosen[question] ?? [])
            for option in request.questions[question].options {
                guard let bits = options["\(question):\(option.label)"],
                    let raw = UnsafeMutableRawPointer(bitPattern: bits)
                else { continue }
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                if selected.contains(option.label) {
                    gtk_widget_add_css_class(widget, "answer-selected")
                } else {
                    gtk_widget_remove_css_class(widget, "answer-selected")
                }
            }
        }
    }
}
