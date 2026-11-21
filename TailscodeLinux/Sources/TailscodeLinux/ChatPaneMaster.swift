import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The master this pane's conversation is a task of, as the shelf knows it.
    var masterRow: MasterRow? { entry.flatMap { MasterDesk.shared.master(for: $0) } }

    var isMasterTask: Bool { entry?.session.expertID != nil }

    /// The machine that keeps this conversation, when it keeps masters.
    var masterKeeper: (any MachineExperts)? {
        if let keeping = backend as? any MachineExperts, MasterDesk.mayKeepMasters(backend) { return keeping }
        return entry.flatMap { MasterDesk.shared.keeping(profileID: $0.profileID) }
    }

    /// Re-reads what a master task shows: its mark, and its debrief. A pane on any other chat
    /// clears both and stops listening.
    func refreshMasterSurface() {
        masterGeneration &+= 1
        let watchKey = "pane-\(id)"
        guard let entry, entry.session.expertID != nil else {
            dropMasterWatch()
            expertDebrief = nil
            masterDrawn = nil
            Gtk.removeChildren(of: masterBox)
            gtk_widget_set_visible(masterBox, 0)
            Gtk.removeChildren(of: masterMarkSlot)
            gtk_widget_set_visible(masterMarkSlot, 0)
            return
        }
        if masterWatch == nil {
            masterWatch = NotificationCenter.default.addObserver(
                forName: MasterDesk.didChange, object: nil, queue: nil
            ) { [weak self] _ in
                Gtk.onMain { [weak self] in
                    self?.renderMasterMark()
                    self?.loadMasterDebrief()
                }
            }
        }
        MasterDesk.shared.watch(watchKey)
        if !MasterDesk.shared.loadedOnce { MasterDesk.shared.refresh() }
        expertDebrief = nil
        masterDrawn = nil
        renderMasterMark()
        loadMasterDebrief()
    }

    /// Stops listening for the shelf and lets the desk's ten-second beat end once nothing else
    /// on screen shows a master: on a chat that is not a task, and when the pane closes.
    func dropMasterWatch() {
        MasterDesk.shared.unwatch("pane-\(id)")
        if let masterWatch { NotificationCenter.default.removeObserver(masterWatch) }
        masterWatch = nil
        masterPollSerial &+= 1
    }

    func renderMasterMark() {
        Gtk.removeChildren(of: masterMarkSlot)
        guard isMasterTask else {
            gtk_widget_set_visible(masterMarkSlot, 0)
            return
        }
        let mark: UnsafeMutablePointer<GtkWidget>
        if let row = masterRow {
            mark = MasterMarks.mark(row.master, size: .tiny)
            gtk_widget_set_tooltip_text(mark, row.master.name)
        } else {
            mark = MasterMarks.mark("✦", hue: .gray, size: .tiny)
        }
        gtk_box_append(ptr(masterMarkSlot), mark)
        if let row = masterRow {
            let name = Gtk.label(row.master.name, css: "row-detail", selectable: false)
            Gtk.margins(name, leading: 5)
            gtk_box_append(ptr(masterMarkSlot), name)
        }
        gtk_widget_set_visible(masterMarkSlot, 1)
    }

    /// Asks the machine for the task's debrief; a drafting one is asked again every few seconds
    /// until it has an answer.
    func loadMasterDebrief() {
        guard let sessionID, isMasterTask, let keeper = masterKeeper else { return }
        let generation = masterGeneration
        masterPollSerial &+= 1
        let poll = masterPollSerial
        track(Task { [weak self] in
            let read: Result<ExpertDebrief?, Error>
            do {
                read = .success(try await keeper.expertDebrief(sessionID: sessionID))
            } catch {
                read = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.masterGeneration == generation, self.sessionID == sessionID else { return }
                if case .success(let debrief) = read {
                    self.expertDebrief = debrief
                    self.renderDebriefCard()
                }
                guard self.expertDebrief?.state == .drafting else { return }
                Gtk.after(3_000) { [weak self] in
                    guard let self, self.masterGeneration == generation, self.masterPollSerial == poll else { return }
                    self.loadMasterDebrief()
                }
            }
        })
    }

    private var debriefKey: String {
        guard let debrief = expertDebrief else { return "none" }
        let rows = debrief.proposals.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",")
        let later = sessionID.map { masterLater.contains($0) } ?? false
        let turning = debrief.state == .failed && presence.isInFlight
        return "\(debrief.state.rawValue)|\(rows)|\(later)|\(masterBusy)|\(turning)|\(masterRow?.master.name ?? "")|\(debrief.failure ?? "")"
    }

    func renderDebriefCard() {
        let key = debriefKey
        guard key != masterDrawn else { return }
        masterDrawn = key
        Gtk.removeChildren(of: masterBox)
        guard let debrief = expertDebrief, let sessionID else {
            gtk_widget_set_visible(masterBox, 0)
            return
        }
        Gtk.margins(masterBox, top: 14, bottom: 6)
        if masterLater.contains(sessionID), debrief.state == .open {
            gtk_box_append(ptr(masterBox), laterLine(debrief))
        } else {
            gtk_box_append(ptr(masterBox), debriefCard(debrief))
        }
        gtk_widget_set_visible(masterBox, 1)
        if followsBottom { scrollToBottom() }
    }

    private var masterName: String { masterRow?.master.name ?? MasterWords.title }

    private func laterLine(_ debrief: ExpertDebrief) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(line, "master-journal")
        if let row = masterRow { gtk_box_append(ptr(line), MasterMarks.mark(row.master, size: .tiny)) }
        let words = Gtk.label(MasterWords.toReview(debrief.pending.count), css: "row-detail", selectable: false)
        Gtk.addClass(words, MasterMarks.toneClass(.attention))
        gtk_widget_set_hexpand(words, 1)
        gtk_label_set_xalign(op(words), 0)
        gtk_box_append(ptr(line), words)
        gtk_box_append(
            ptr(line),
            Gtk.button(Localized.text("Review"), css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let sessionID = self.sessionID else { return }
                    self.masterLater.remove(sessionID)
                    self.renderDebriefCard()
                }
            })
        return line
    }

    private func debriefCard(_ debrief: ExpertDebrief) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(card, "master-card")
        let headline = MasterReading.debriefHeadline(debrief, name: masterName)
        if headline.tone == .attention { Gtk.addClass(card, "master-card-attention") }
        if headline.tone == .failing { Gtk.addClass(card, "master-card-failing") }

        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(head, bottom: 8, leading: 14, trailing: 14)
        if let row = masterRow {
            gtk_box_append(ptr(head), MasterMarks.mark(row.master, size: .row))
        } else {
            gtk_box_append(ptr(head), MasterMarks.mark("✦", hue: .gray, size: .row))
        }
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(headline.text, css: "master-card-headline", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(words), title)
        let detailText = MasterReading.debriefDetail(debrief)
        if !detailText.isEmpty {
            let detail = Gtk.label(detailText, css: "master-card-detail", wrap: true, selectable: false)
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
            Gtk.addClass(box, "master-journal")
            Gtk.margins(box, bottom: 8, leading: 14, trailing: 14)
            let name = Gtk.label(
                MasterWords.journalEntry + " · " + journal.title, css: "master-journal-title", wrap: true,
                selectable: false)
            gtk_label_set_xalign(op(name), 0)
            gtk_box_append(ptr(box), name)
            let body = Gtk.label(
                MasterReading.journalPreview(journal), css: "master-journal-body", wrap: true, selectable: true)
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
            let later = Gtk.button(MasterWords.later, css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let sessionID = self.sessionID else { return }
                    self.masterLater.insert(sessionID)
                    self.renderDebriefCard()
                }
            }
            let all = Gtk.button(MasterWords.acceptAll, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.acceptAllProposals() }
            }
            for button in [later, all] {
                gtk_widget_set_sensitive(button, masterBusy ? 0 : 1)
                gtk_box_append(ptr(actions), button)
            }
            gtk_box_append(ptr(card), actions)
        case .failed:
            let again = Gtk.button(MasterWords.tryAgain, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.finishExpertTask() }
            }
            gtk_widget_set_sensitive(again, masterBusy || presence.isInFlight ? 0 : 1)
            gtk_box_append(ptr(actions), again)
            gtk_box_append(ptr(card), actions)
        case .drafting, .settled:
            break
        }
        return card
    }

    private func proposalRow(_ proposal: ExpertProposal, open: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "master-proposal")
        if proposal.state != .pending { Gtk.addClass(row, "master-proposal-done") }
        let tag = Gtk.label(MasterWords.opLabel(proposal.op).uppercased(), css: "master-op", selectable: false)
        Gtk.addClass(tag, "master-op-\(proposal.op.rawValue)")
        gtk_widget_set_valign(tag, GTK_ALIGN_START)
        Gtk.margins(tag, top: 2)
        gtk_box_append(ptr(row), tag)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        let title = Gtk.label(proposal.title, css: "master-proposal-title", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(words), title)
        if !proposal.summary.isEmpty {
            let summary = Gtk.label(proposal.summary, css: "master-proposal-summary", wrap: true, selectable: true)
            gtk_label_set_xalign(op(summary), 0)
            gtk_box_append(ptr(words), summary)
        }
        if !proposal.reason.isEmpty {
            let reason = Gtk.label(proposal.reason, css: "master-proposal-reason", wrap: true, selectable: true)
            gtk_label_set_xalign(op(reason), 0)
            gtk_box_append(ptr(words), reason)
        }
        gtk_box_append(ptr(row), words)

        if open, proposal.state == .pending {
            let buttons = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
            gtk_widget_set_valign(buttons, GTK_ALIGN_START)
            let id = proposal.id
            let accept = Gtk.button(MasterWords.accept(proposal.op), css: []) { [weak self] in
                Gtk.onMain { [weak self] in self?.decideProposal(accepted: [id], skipped: []) }
            }
            let skip = Gtk.button(MasterWords.skip, css: ["flat"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.decideProposal(accepted: [], skipped: [id]) }
            }
            for button in [accept, skip] {
                gtk_widget_set_sensitive(button, masterBusy ? 0 : 1)
                gtk_box_append(ptr(buttons), button)
            }
            gtk_box_append(ptr(row), buttons)
        } else if let state = MasterWords.proposalState(proposal.state, op: proposal.op) {
            let mark = Gtk.label(state, css: "row-meta", selectable: false)
            Gtk.addClass(mark, MasterMarks.toneClass(proposal.state == .accepted ? .good : .quiet))
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
        guard let sessionID, let keeper = masterKeeper, !masterBusy else { return }
        masterBusy = true
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
                self.masterBusy = false
                guard self.sessionID == sessionID else {
                    MasterDesk.shared.refresh()
                    return
                }
                switch outcome {
                case .success(let debrief): self.expertDebrief = debrief
                case .failure(let error): self.host?.toast(MachineWindow.words(error))
                }
                self.renderDebriefCard()
                MasterDesk.shared.refresh()
            }
        })
    }

    /// Finish task: the machine drafts the debrief on a fork of this task that is never saved.
    func finishExpertTask() {
        guard let sessionID, let keeper = masterKeeper, !masterBusy, !presence.isInFlight else { return }
        masterBusy = true
        track(Task { [weak self] in
            let outcome: Result<ExpertDebrief, Error>
            do {
                outcome = .success(try await keeper.finishExpertTask(sessionID: sessionID))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.masterBusy = false
                guard self.sessionID == sessionID else {
                    MasterDesk.shared.refresh()
                    return
                }
                switch outcome {
                case .success(let debrief):
                    self.expertDebrief = debrief
                    self.masterLater.remove(sessionID)
                    self.renderDebriefCard()
                    self.loadMasterDebrief()
                case .failure(let error):
                    self.host?.toast(MachineWindow.words(error))
                    self.renderDebriefCard()
                }
                MasterDesk.shared.refresh()
            }
        })
    }

    // MARK: Menus and the chooser

    /// The chat menu's master rows: finish a task, hand a chat over, make a master from it.
    func masterActionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry, MasterDesk.mayKeepMasters(backend) || MasterDesk.shared.keepsExperts(profileID: entry.profileID)
        else { return [] }
        var rows: [(String, String?, @Sendable () -> Void)] = []
        if isMasterTask, !presence.isInFlight {
            rows.append(
                (MasterWords.finishTask, MasterWords.finishTaskDetail,
                 { [weak self] in Gtk.onMain { [weak self] in self?.finishExpertTask() } }))
        }
        if let debrief = expertDebrief, debrief.state == .open, let sessionID, masterLater.contains(sessionID) {
            rows.append(
                (Localized.text("Review notes…"), MasterWords.toReview(debrief.pending.count),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self, let sessionID = self.sessionID else { return }
                     self.masterLater.remove(sessionID)
                     self.renderDebriefCard()
                 } }))
        }
        rows.append(
            (MasterWords.handToMaster, Localized.text("A new task with this conversation carried as a brief"),
             { [weak self] in Gtk.onMain { [weak self] in
                 guard let self else { return }
                 self.host?.presentHandOver(from: self)
             } }))
        if !isMasterTask {
            rows.append(
                (MasterWords.makeFromChat, Localized.text("Drafts a charter, notes and a bench from what happened here"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.makeMaster(from: self)
                 } }))
        }
        return rows
    }

    func chooserMasters() -> [MasterRow] {
        guard let entry, MasterDesk.mayKeepMasters(backend) || MasterDesk.shared.keepsExperts(profileID: entry.profileID)
        else { return [] }
        return MasterDesk.shared.masters(on: entry.profileID)
    }

    /// From a chat with words in it, the chooser says the conversation goes along.
    func chooserMasterNote() -> String? {
        guard let entry, hasCarriableWords else { return nil }
        return MasterWords.handOverNote(entry.session.title)
    }

    var hasCarriableWords: Bool {
        (lastState?.messages ?? []).contains { $0.role == .user }
    }

    /// The brief of this conversation, for a hand-over.
    func masterCarry() -> ConversationBrief? {
        guard let entry, let messages = lastState?.messages, !messages.isEmpty else { return nil }
        return ConversationBrief.make(title: entry.session.title, messages: messages, window: nil)
    }

    func pickedMaster(_ row: MasterRow) {
        host?.presentMasterTask(row, carry: hasCarriableWords ? masterCarry() : nil)
    }
}
