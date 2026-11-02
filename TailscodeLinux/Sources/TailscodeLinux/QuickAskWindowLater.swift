import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension QuickAskWindow {
    /// The question in the box, put off to one of a handful of times said the way a person says
    /// them. It keeps the aim showing now, and this computer asks it at the hour.
    func offerLater() {
        guard !asking, gathering == nil else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setHint(Localized.text("Type the question first, then choose when."))
            return
        }
        guard attachments.isEmpty else {
            setHint(Localized.text("A question for later carries words only."))
            return
        }
        if case .command = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: promptTextGrammar[targetServer.id] == true
        ).kind {
            setHint(Localized.text("A command runs now — send it with enter."))
            return
        }
        let now = Date()
        let rows: [(title: String, detail: String?, action: @Sendable () -> Void)] =
            QuickAskLaterChoice.allCases.map { choice in
                (choice.words(now: now), nil, { Gtk.onMain { QuickAskWindow.open?.schedule(choice) } })
            }
        let width = Double(gtk_widget_get_width(send))
        Gtk.contextMenu(on: send, x: width / 2, y: 0, rows: rows)
    }

    func schedule(_ choice: QuickAskLaterChoice) {
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asking, !text.isEmpty else { return }
        let server = targetServer
        let later = QuickAskLater(
            text: text, profileID: server.id,
            model: QuickAskDefaults.model(forProfileID: server.id)?.rawValue,
            effort: QuickAskDefaults.effort(forProfileID: server.id),
            fireAt: choice.fireDate(now: Date()), repeats: choice.repeats)
        QuickAskLaterStore.save(later)
        releaseHold()
        write("")
        DraftStore.clear(.quickAsk(profileID: server.id))
        setHint(
            Localized.text("Asks %@ on %@ — esc closes", QuickAskLaterWords.when(later), server.name))
        AppLog.write(.ui, "ASK later id=\(later.id) repeats=\(later.repeats.rawValue)")
        editor.focus()
    }

    /// What is waiting, under the starters: each question with when it asks next, a click opening
    /// what can be done with it, and one line saying who does the asking.
    func renderLater() {
        let waiting = QuickAskLaterStore.all()
        guard !waiting.isEmpty else { return }
        gtk_box_append(ptr(starters), section(QuickAskLaterWords.section))
        for later in waiting {
            let row = laterRow(later)
            gtk_box_append(ptr(starters), row)
        }
        let reach = Gtk.label(QuickAskLaterWords.reach, css: "ask-hint", wrap: true, selectable: false)
        gtk_label_set_xalign(op(reach), 0)
        gtk_box_append(ptr(starters), reach)
    }

    private func laterRow(_ later: QuickAskLater) -> UnsafeMutablePointer<GtkWidget> {
        let id = later.id
        let row = recentRow(title: later.headline, age: QuickAskLaterWords.when(later), glyph: "◷") {}
        let hold = Gtk.WeakWidget(row)
        let menu: @Sendable (Double, Double) -> Void = { x, y in
            Gtk.onMain {
                guard let held = hold.widget else { return }
                Gtk.contextMenu(
                    on: held, x: x, y: y,
                    rows: [
                        (Localized.text("Ask now"), nil, { Gtk.onMain { QuickAskLaterStore.askNow(id: id) } }),
                        (Localized.text("Remove"), nil, { Gtk.onMain { QuickAskLaterStore.remove(id: id) } }),
                    ])
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(row), "clicked") {
            Gtk.onMain {
                guard let held = hold.widget else { return }
                menu(Double(gtk_widget_get_width(held)) / 2, Double(gtk_widget_get_height(held)))
            }
        }
        Gtk.onRightClick(row, menu)
        return row
    }
}
