import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// A question handed to this conversation from somewhere else — a quick ask that minted it, or
    /// one aimed at the chat this device is already looking at.
    ///
    /// It arrives as a decision rather than as words: the quick ask asked the shared grammar what
    /// the text turns out to be before it minted anything, so a command runs here through the
    /// command route instead of reaching the model as the word it was typed as.
    func deliver(_ send: QuickAskSend, attachments: [PromptAttachment]) {
        switch send.kind {
        case .prompt:
            guard isViewLoaded else {
                viewModel.send(send.text, attachments: attachments)
                return
            }
            sendDraft(send.text, attachments: attachments)
        case .command(let command, let arguments):
            SlashRecents.record(command.name)
            keepInHand(attachments)
            viewModel.run(command, arguments: arguments)
        }
    }

    /// Pictures and files that came with a question whose words turned out to be a command. The
    /// command route carries no attachments, so rather than drop them on the way in they are put
    /// where this chat's composer keeps anything else waiting: in hand, for the next message.
    private func keepInHand(_ attachments: [PromptAttachment]) {
        guard !attachments.isEmpty else { return }
        loadViewIfNeeded()
        pendingAttachments.append(contentsOf: attachments)
        updateAttachmentStrip()
    }
}

extension ChatViewController {
    func promptRename() {
        let alert = UIAlertController(
            title: String(localized: "Rename conversation"), message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.viewModel.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Rename"), style: .default) {
                [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self, !title.isEmpty, title != self.viewModel.title else { return }
            Task {
                do {
                    try await self.viewModel.rename(to: title)
                    self.title = self.navDisplayTitle
                    Theme.Haptics.success()
                } catch {
                    self.presentToast(String(localized: "Couldn't rename this conversation."))
                }
            }
        })
        present(alert, animated: true)
    }

    func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "Clear conversation?"),
            message: String(localized: "This starts a fresh conversation on the agent."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Clear"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            self?.viewModel.clearConversation()
        })
        present(alert, animated: true)
    }
}

extension ChatViewController {
    /// What is being typed into an ask, written down as it is typed. The card is rebuilt from the
    /// transcript on every launch, so an answer half-written when the app closed has nowhere else
    /// to live.
    func recordAnswerDrafts(
        _ selection: QuestionCell.Selection, for request: QuestionRequest
    ) {
        for index in request.questions.indices {
            DraftStore.record(
                selection.custom[index] ?? "", for: answerDraftScope(for: request, questionIndex: index))
        }
    }

    func clearAnswerDrafts(for request: QuestionRequest) {
        for index in request.questions.indices {
            DraftStore.clear(answerDraftScope(for: request, questionIndex: index))
        }
    }

    /// What was typed towards a question before the app was closed on it, put back on the card the
    /// question comes back on.
    func restoredSelection(for request: QuestionRequest?) -> QuestionCell.Selection {
        var selection = QuestionCell.Selection()
        guard let request else { return selection }
        for index in request.questions.indices {
            let text = DraftStore.text(for: answerDraftScope(for: request, questionIndex: index))
            if !text.isEmpty { selection.custom[index] = text }
        }
        return selection
    }

    /// The keyboard rising for an answer typed into a card halfway up the transcript would leave
    /// the card under it, so the transcript comes with it.
    func revealPendingCard() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.userScrolledUp = false
            self.scrollToBottom(animated: true)
        }
    }

    @objc func dismissKeyboard() { view.endEditing(true) }

    func forkConversation() {
        Task { @MainActor in
            do {
                let session = try await viewModel.fork()
                let forked = ChatViewModel(
                    backend: viewModel.backend, session: session, contextID: viewModel.contextID,
                    serverName: viewModel.serverName)
                Theme.Haptics.success()
                showConversation(ChatViewController(viewModel: forked))
            } catch {
                presentToast(String(localized: "Couldn't fork this conversation."))
            }
        }
    }
}

extension ChatViewController {
    private func transcriptMarkdown() -> String {
        var out: [String] = []
        for id in orderedIDs {
            guard let row = rowsByID[id], !id.hasPrefix("ts:") else { continue }
            let who = row.role == .user ? String(localized: "You") : String(localized: "Agent")
            let body: String
            switch row.content {
            case .text(let text):
                body = text
            case .code(let block):
                let fence = block.language ?? ""
                body = "```\(fence)\n\(block.source)\n```"
            case .table(let table):
                body = table.markdown
            case .tableDraft(let draft):
                body = draft.reading
            case .activity(let steps):
                body = steps.map {
                    switch $0 {
                    case .reasoning(let text): return text
                    case .tool(let call): return "[\(call.title ?? call.name)]"
                    }
                }.joined(separator: "\n")
            case .brain(let brainRow):
                body = brain.markdown(for: brainRow.turnID)
            case .subagent(let card):
                body = Self.subagentMarkdown(card)
            case .workflow(let run):
                body = Self.workflowMarkdown(run)
            case .subagentGroup(let group):
                body = "_" + String(localized: "\(group.total) agents") + "_"
            case .taskBoard(let board):
                body = board.items.map { item in
                    let mark = item.status == .completed ? "x" : " "
                    return "- [\(mark)] \(item.subject)"
                }.joined(separator: "\n")
            case .file(let file), .image(let file):
                body = "[file: \(file.path ?? file.filename ?? String(localized: "attachment"))]"
            case .compaction(let row):
                out.append(Self.compactionMarkdown(row))
                continue
            case .modelSeam(let seam):
                out.append("_\(seam.line)_")
                continue
            case .carried(let reading):
                out.append("_\(reading.line)_")
                continue
            case .answerless(let turn):
                body = "_\(turn.title) — \(turn.detail)_"
            case .designBoard(let sighting):
                let reading = DesignCardReading.make(sighting: sighting, board: nil)
                body = "_\(reading.title) — \(reading.detail)_"
            case .failed(let turn):
                body = "_\(turn.title) — \(turn.reason)_"
            case .responseStats, .timestamp:
                continue
            case .linkRail:
                continue
            case .pictures(let files):
                body = files.map {
                    "[file: \($0.path ?? $0.filename ?? String(localized: "attachment"))]"
                }.joined(separator: " ")
            case .note(let line):
                out.append("_\(line.text)_")
                continue
            }
            out.append("**\(who):** \(body)")
        }
        return out.joined(separator: "\n\n")
    }

    func copyTranscript() {
        UIPasteboard.general.string = transcriptMarkdown()
        Theme.Haptics.success()
        presentToast(String(localized: "Transcript copied to clipboard."))
    }

    func shareTranscript() {
        let name = navDisplayTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "transcript" : name).md")
        do {
            try transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentToast(String(localized: "Couldn't export the transcript."))
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }
}
