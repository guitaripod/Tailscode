import AppKit
import CodingAgentKit
import TailscodeCore

extension QuickAskPanel {
    /// The question in the box, put off to one of a handful of times said the way a person says
    /// them. It keeps the aim showing now, and this Mac asks it at the hour.
    func offerLater() {
        guard !asking, gathering == nil else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus(Localized.text("Type the question first, then choose when."))
            return
        }
        guard attachments.isEmpty else {
            setStatus(Localized.text("A question for later carries words only."))
            return
        }
        if case .command = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: ServerDirectory.shared.backend(for: targetServer)?
                .resolvesCommandsFromPromptText == true
        ).kind {
            setStatus(Localized.text("A command runs now — send it with enter."))
            return
        }
        let now = Date()
        let menu = NSMenu()
        for choice in QuickAskLaterChoice.allCases {
            menu.addItem(ClosureMenuItem(title: choice.words(now: now)) { [weak self] in
                self?.schedule(choice)
            })
        }
        let anchor = editor
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
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
        editor.setText("", caretAtEnd: true)
        DraftStore.clear(.quickAsk(profileID: server.id))
        renderStarters()
        refreshStarterVisibility()
        setStatus(
            Localized.text("Asks %@ on %@ — esc closes", QuickAskLaterWords.when(later), server.name))
        editor.focus()
    }

    /// What is waiting, under the starters: each question with when it asks next, a click opening
    /// what can be done with it, and one line saying who does the asking.
    func laterRows() -> [NSView] {
        let waiting = QuickAskLaterStore.all()
        guard !waiting.isEmpty else { return [] }
        var rows: [NSView] = []
        for later in waiting {
            let id = later.id
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: Localized.text("Ask now")) {
                QuickAskLaterStore.askNow(id: id)
            })
            menu.addItem(ClosureMenuItem(title: Localized.text("Remove")) {
                QuickAskLaterStore.remove(id: id)
            })
            var row: NSView?
            row = QuickAskTiles.recent(
                title: later.headline, age: QuickAskLaterWords.when(later), symbol: "clock"
            ) {
                guard let row else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: row.bounds.height), in: row)
            }
            row?.menu = menu
            if let row { rows.append(row) }
        }
        let reach = NSTextField(wrappingLabelWithString: QuickAskLaterWords.reach)
        reach.font = MacTheme.Ramp.font(.panelFootnote)
        reach.textColor = MacTheme.Color.secondaryLabel
        rows.append(reach)
        return rows
    }
}
