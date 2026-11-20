import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The expert this pane's conversation is a task of, as the shelf knows it.
    var expertRow: ExpertRow? { entry.flatMap { ExpertDesk.shared.expert(for: $0) } }

    var isExpertTask: Bool { entry?.session.expertID != nil }

    /// The machine that keeps this conversation, when it keeps experts.
    var expertKeeper: (any MachineExperts)? {
        if let keeping = backend as? any MachineExperts, ExpertDesk.mayKeepExperts(backend) { return keeping }
        return entry.flatMap { ExpertDesk.shared.keeping(profileID: $0.profileID) }
    }

    /// Re-reads what an expert task shows: its mark, and its debrief. A pane on any other chat
    /// clears both and stops listening.
    func refreshExpertSurface() {
        expertGeneration &+= 1
        let watchKey = "pane-\(id)"
        guard let entry, entry.session.expertID != nil else {
            dropExpertWatch()
            expertDebrief = nil
            expertDrawn = nil
            Gtk.removeChildren(of: expertBox)
            gtk_widget_set_visible(expertBox, 0)
            Gtk.removeChildren(of: expertMarkSlot)
            gtk_widget_set_visible(expertMarkSlot, 0)
            return
        }
        if expertWatch == nil {
            expertWatch = NotificationCenter.default.addObserver(
                forName: ExpertDesk.didChange, object: nil, queue: nil
            ) { [weak self] _ in
                Gtk.onMain { [weak self] in
                    self?.renderExpertMark()
                    self?.loadExpertDebrief()
                }
            }
        }
        ExpertDesk.shared.watch(watchKey)
        if !ExpertDesk.shared.loadedOnce { ExpertDesk.shared.refresh() }
        expertDebrief = nil
        expertDrawn = nil
        renderExpertMark()
        loadExpertDebrief()
    }

    /// Stops listening for the shelf and lets the desk's ten-second beat end once nothing else
    /// on screen shows an expert: on a chat that is not a task, and when the pane closes.
    func dropExpertWatch() {
        ExpertDesk.shared.unwatch("pane-\(id)")
        if let expertWatch { NotificationCenter.default.removeObserver(expertWatch) }
        expertWatch = nil
        expertPollSerial &+= 1
    }

    func renderExpertMark() {
        Gtk.removeChildren(of: expertMarkSlot)
        guard isExpertTask else {
            gtk_widget_set_visible(expertMarkSlot, 0)
            return
        }
        let mark: UnsafeMutablePointer<GtkWidget>
        if let row = expertRow {
            mark = ExpertMarks.mark(row.expert, size: .tiny)
            gtk_widget_set_tooltip_text(mark, row.expert.name)
        } else {
            mark = ExpertMarks.mark("✦", hue: .gray, size: .tiny)
        }
        gtk_box_append(ptr(expertMarkSlot), mark)
        if let row = expertRow {
            let name = Gtk.label(row.expert.name, css: "row-detail", selectable: false)
            Gtk.margins(name, leading: 5)
            gtk_box_append(ptr(expertMarkSlot), name)
        }
        gtk_widget_set_visible(expertMarkSlot, 1)
    }

    /// Asks the machine for the task's debrief; a drafting one is asked again every few seconds
    /// until it has an answer.
    func loadExpertDebrief() {
        guard let sessionID, isExpertTask, let keeper = expertKeeper else { return }
        let generation = expertGeneration
        expertPollSerial &+= 1
        let poll = expertPollSerial
        track(Task { [weak self] in
            let read: Result<ExpertDebrief?, Error>
            do {
                read = .success(try await keeper.expertDebrief(sessionID: sessionID))
            } catch {
                read = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.expertGeneration == generation, self.sessionID == sessionID else { return }
                if case .success(let debrief) = read {
                    self.expertDebrief = debrief
                    self.renderDebriefCard()
                }
                guard self.expertDebrief?.state == .drafting else { return }
                Gtk.after(3_000) { [weak self] in
                    guard let self, self.expertGeneration == generation, self.expertPollSerial == poll else { return }
                    self.loadExpertDebrief()
                }
            }
        })
    }

    private var debriefKey: String {
        guard let debrief = expertDebrief else { return "none" }
        let rows = debrief.proposals.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",")
        let later = sessionID.map { expertLater.contains($0) } ?? false
        let turning = debrief.state == .failed && presence.isInFlight
        return "\(debrief.state.rawValue)|\(rows)|\(later)|\(expertBusy)|\(turning)|\(expertRow?.expert.name ?? "")|\(debrief.failure ?? "")"
    }

    func renderDebriefCard() {
        let key = debriefKey
        guard key != expertDrawn else { return }
        expertDrawn = key
        Gtk.removeChildren(of: expertBox)
        guard let debrief = expertDebrief, let sessionID else {
            gtk_widget_set_visible(expertBox, 0)
            return
        }
        Gtk.margins(expertBox, top: 14, bottom: 6)
        if expertLater.contains(sessionID), debrief.state == .open {
            gtk_box_append(ptr(expertBox), laterLine(debrief))
        } else {
            gtk_box_append(ptr(expertBox), debriefCard(debrief))
        }
        gtk_widget_set_visible(expertBox, 1)
        if followsBottom { scrollToBottom() }
    }

    private var expertName: String { expertRow?.expert.name ?? ExpertWords.title }

    private func laterLine(_ debrief: ExpertDebrief) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(line, "expert-journal")
        if let row = expertRow { gtk_box_append(ptr(line), ExpertMarks.mark(row.expert, size: .tiny)) }
        let words = Gtk.label(ExpertWords.toReview(debrief.pending.count), css: "row-detail", selectable: false)
        Gtk.addClass(words, ExpertMarks.toneClass(.attention))
        gtk_widget_set_hexpand(words, 1)
        gtk_label_set_xalign(op(words), 0)
        gtk_box_append(ptr(line), words)
        gtk_box_append(
            ptr(line),
            Gtk.button(Localized.text("Review"), css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let sessionID = self.sessionID else { return }
                    self.expertLater.remove(sessionID)
                    self.renderDebriefCard()
                }
            })
        return line
    }

    private func debriefCard(_ debrief: ExpertDebrief) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(card, "expert-card")
        let headline = ExpertReading.debriefHeadline(debrief, name: expertName)
        if headline.tone == .attention { Gtk.addClass(card, "expert-card-attention") }
        if headline.tone == .failing { Gtk.addClass(card, "expert-card-failing") }

        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(head, bottom: 8, leading: 14, trailing: 14)
        if let row = expertRow {
            gtk_box_append(ptr(head), ExpertMarks.mark(row.expert, size: .row))
        } else {
            gtk_box_append(ptr(head), ExpertMarks.mark("✦", hue: .gray, size: .row))
        }
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(headline.text, css: "expert-card-headline", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(words), title)
        let detailText = ExpertReading.debriefDetail(debrief)
        if !detailText.isEmpty {
            let detail = Gtk.label(detailText, css: "expert-card-detail", wrap: true, selectable: false)
            gtk_label_set_xalign(op(detail), 0)
            gtk_box_append(ptr(words), detail)
        }
        gtk_box_append(ptr(head), words)
        if debrief.state == .drafting {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(op(spinner))
            gtk_widget_set_valign(spinner, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(head), spinner)
        }
        gtk_box_append(ptr(card), head)

        if let journal = debrief.journal {
            let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            Gtk.addClass(box, "expert-journal")
            Gtk.margins(box, bottom: 8, leading: 14, trailing: 14)
            let name = Gtk.label(
                ExpertWords.journalEntry + " · " + journal.title, css: "expert-journal-title", wrap: true,
                selectable: false)
            gtk_label_set_xalign(op(name), 0)
            gtk_box_append(ptr(box), name)
            let body = Gtk.label(
                ExpertReading.journalPreview(journal), css: "expert-journal-body", wrap: true, selectable: true)
            gtk_label_set_xalign(op(body), 0)
            gtk_box_append(ptr(box), body)
            gtk_box_append(ptr(card), box)
        }

        for proposal in debrief.proposals {
            gtk_box_append(ptr(card), proposalRow(proposal, open: debrief.state == .open))
        }

        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(actions, top: 8, bottom: 4, leading: 14, trailing: 14)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        switch debrief.state {
        case .open:
            let later = Gtk.button(ExpertWords.later, css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let sessionID = self.sessionID else { return }
                    self.expertLater.insert(sessionID)
                    self.renderDebriefCard()
                }
            }
            let all = Gtk.button(ExpertWords.acceptAll, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.acceptAllProposals() }
            }
            for button in [later, all] {
                gtk_widget_set_sensitive(button, expertBusy ? 0 : 1)
                gtk_box_append(ptr(actions), button)
            }
            gtk_box_append(ptr(card), actions)
        case .failed:
            let again = Gtk.button(ExpertWords.tryAgain, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.finishExpertTask() }
            }
            gtk_widget_set_sensitive(again, expertBusy || presence.isInFlight ? 0 : 1)
            gtk_box_append(ptr(actions), again)
            gtk_box_append(ptr(card), actions)
        case .drafting, .settled:
            break
        }
        return card
    }

    private func proposalRow(_ proposal: ExpertProposal, open: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "expert-proposal")
        if proposal.state != .pending { Gtk.addClass(row, "expert-proposal-done") }
        let tag = Gtk.label(ExpertWords.opLabel(proposal.op).uppercased(), css: "expert-op", selectable: false)
        Gtk.addClass(tag, "expert-op-\(proposal.op.rawValue)")
        gtk_widget_set_valign(tag, GTK_ALIGN_START)
        Gtk.margins(tag, top: 2)
        gtk_box_append(ptr(row), tag)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(proposal.title, css: "expert-proposal-title", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(words), title)
        if !proposal.summary.isEmpty {
            let summary = Gtk.label(proposal.summary, css: "expert-proposal-summary", wrap: true, selectable: true)
            gtk_label_set_xalign(op(summary), 0)
            gtk_box_append(ptr(words), summary)
        }
        if !proposal.reason.isEmpty {
            let reason = Gtk.label(proposal.reason, css: "expert-proposal-reason", wrap: true, selectable: true)
            gtk_label_set_xalign(op(reason), 0)
            gtk_box_append(ptr(words), reason)
        }
        gtk_box_append(ptr(row), words)

        if open, proposal.state == .pending {
            let buttons = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
            gtk_widget_set_valign(buttons, GTK_ALIGN_START)
            let id = proposal.id
            let accept = Gtk.button(ExpertWords.accept(proposal.op), css: []) { [weak self] in
                Gtk.onMain { [weak self] in self?.decideProposal(accepted: [id], skipped: []) }
            }
            let skip = Gtk.button(ExpertWords.skip, css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.decideProposal(accepted: [], skipped: [id]) }
            }
            for button in [accept, skip] {
                gtk_widget_set_sensitive(button, expertBusy ? 0 : 1)
                gtk_box_append(ptr(buttons), button)
            }
            gtk_box_append(ptr(row), buttons)
        } else if let state = ExpertWords.proposalState(proposal.state, op: proposal.op) {
            let mark = Gtk.label(state, css: "row-meta", selectable: false)
            Gtk.addClass(mark, ExpertMarks.toneClass(proposal.state == .accepted ? .good : .quiet))
            gtk_widget_set_valign(mark, GTK_ALIGN_START)
            gtk_box_append(ptr(row), mark)
        }
        return row
    }

    func acceptAllProposals() {
        guard let debrief = expertDebrief else { return }
        decideProposal(accepted: debrief.pending.map(\.id), skipped: nil)
    }

    /// Writes one decision, or all of them: a nil `skipped` settles every proposal not accepted.
    func decideProposal(accepted: [String], skipped: [String]?) {
        guard let sessionID, let keeper = expertKeeper, !expertBusy else { return }
        expertBusy = true
        renderDebriefCard()
        let decision = ExpertDebriefDecision(accepted: accepted, skipped: skipped)
        track(Task { [weak self] in
            let outcome: Result<ExpertDebrief, Error>
            do {
                outcome = .success(try await keeper.decideExpertDebrief(sessionID: sessionID, decision))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.expertBusy = false
                guard self.sessionID == sessionID else {
                    ExpertDesk.shared.refresh()
                    return
                }
                switch outcome {
                case .success(let debrief): self.expertDebrief = debrief
                case .failure(let error): self.host?.toast(MachineWindow.words(error))
                }
                self.renderDebriefCard()
                ExpertDesk.shared.refresh()
            }
        })
    }

    /// Finish task: the machine drafts the debrief on a fork of this task that is never saved.
    func finishExpertTask() {
        guard let sessionID, let keeper = expertKeeper, !expertBusy, !presence.isInFlight else { return }
        expertBusy = true
        track(Task { [weak self] in
            let outcome: Result<ExpertDebrief, Error>
            do {
                outcome = .success(try await keeper.finishExpertTask(sessionID: sessionID))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.expertBusy = false
                guard self.sessionID == sessionID else {
                    ExpertDesk.shared.refresh()
                    return
                }
                switch outcome {
                case .success(let debrief):
                    self.expertDebrief = debrief
                    self.expertLater.remove(sessionID)
                    self.renderDebriefCard()
                    self.loadExpertDebrief()
                case .failure(let error):
                    self.host?.toast(MachineWindow.words(error))
                    self.renderDebriefCard()
                }
                ExpertDesk.shared.refresh()
            }
        })
    }

    // MARK: Menus and the chooser

    /// The chat menu's expert rows: finish a task, hand a chat over, make an expert from it.
    func expertActionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry, ExpertDesk.mayKeepExperts(backend) || ExpertDesk.shared.keepsExperts(profileID: entry.profileID)
        else { return [] }
        var rows: [(String, String?, @Sendable () -> Void)] = []
        if isExpertTask, !presence.isInFlight {
            rows.append(
                (ExpertWords.finishTask, ExpertWords.finishTaskDetail,
                 { [weak self] in Gtk.onMain { [weak self] in self?.finishExpertTask() } }))
        }
        if let debrief = expertDebrief, debrief.state == .open, let sessionID, expertLater.contains(sessionID) {
            rows.append(
                (Localized.text("Review notes…"), ExpertWords.toReview(debrief.pending.count),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self, let sessionID = self.sessionID else { return }
                     self.expertLater.remove(sessionID)
                     self.renderDebriefCard()
                 } }))
        }
        rows.append(
            (ExpertWords.handToExpert, Localized.text("A new task with this conversation carried as a brief"),
             { [weak self] in Gtk.onMain { [weak self] in
                 guard let self else { return }
                 self.host?.presentHandOver(from: self)
             } }))
        if !isExpertTask {
            rows.append(
                (ExpertWords.makeFromChat, Localized.text("Drafts a charter, notes and a bench from what happened here"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.makeExpert(from: self)
                 } }))
        }
        return rows
    }

    func chooserExperts() -> [ExpertRow] {
        guard let entry, ExpertDesk.mayKeepExperts(backend) || ExpertDesk.shared.keepsExperts(profileID: entry.profileID)
        else { return [] }
        return ExpertDesk.shared.experts(on: entry.profileID)
    }

    /// From a chat with words in it, the chooser says the conversation goes along.
    func chooserExpertNote() -> String? {
        guard let entry, hasCarriableWords else { return nil }
        return ExpertWords.handOverNote(entry.session.title)
    }

    var hasCarriableWords: Bool {
        (lastState?.messages ?? []).contains { $0.role == .user }
    }

    /// The brief of this conversation, for a hand-over.
    func expertCarry() -> ConversationBrief? {
        guard let entry, let messages = lastState?.messages, !messages.isEmpty else { return nil }
        return ConversationBrief.make(title: entry.session.title, messages: messages, window: nil)
    }

    func pickedExpert(_ row: ExpertRow) {
        host?.presentExpertTask(row, carry: hasCarriableWords ? expertCarry() : nil)
    }
}
