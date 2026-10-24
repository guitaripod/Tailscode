import TailscodeCore
import UIKit

extension ChatViewController {
    #if DEBUG
        func openFirstCompactionSummary() {
            guard let row = orderedIDs.compactMap({ id -> CompactionRow? in
                guard case .compaction(let row) = rowsByID[id]?.content else { return nil }
                return row
            }).first else { return }
            presentCompactionSummary(row)
        }

        func scrollToFirstAgentGroup() {
            guard let id = orderedIDs.first(where: { id in
                guard case .subagentGroup = rowsByID[id]?.content else { return false }
                return true
            }) else { return }
            userScrolledUp = true
            scrollTo(id: id)
        }

        var tourScrollView: UIScrollView { collectionView }

        func tourRevealFirstSubagent() {
            guard let agent = viewModel.trackedSubagents.first else { return }
            revealSubagent(id: agent.id)
        }

        func tourScrollToCompaction() {
            guard let id = orderedIDs.first(where: { id in
                guard case .compaction = rowsByID[id]?.content else { return false }
                return true
            }) else { return }
            userScrolledUp = true
            scrollTo(id: id)
        }

        func tourAllowPermission() {
            guard let request = pendingPermission else { return }
            viewModel.respond(to: request, decision: .once)
        }

        func tourAnswerQuestion(option: Int) async {
            await answerPendingQuestion(option: option)
        }

        func tourPresentModelPicker() { presentModelPicker() }

        func tourPresentEffortSheet() { presentEffortSheet() }

        func tourPresentSubagents() { presentSubagents(viewModel.trackedSubagents) }

        func tourPresentCompactPreflight() { presentCompactPreflight() }

        func tourPresentDesignPreflight(_ request: String) {
            presentDesignPreflight(request: request)
        }

        /// The board over a demo board rather than a server's files, so the surface can be
        /// photographed without a machine on the other end spending minutes drawing mocks.
        func tourPresentDesignBoard() {
            let board = DesignBoardViewController(
                board: DesignDemo.board, pages: DesignDemo.pages, onSend: { _ in })
            let nav = UINavigationController(rootViewController: board)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        }

        func tourOpenCompactionSummary() { openFirstCompactionSummary() }

        func tourPresentFileBrowser() { presentFileBrowser() }

        func tourPresentJumpSheet() { presentJumpSheet() }

        func tourPresentUsage() { presentUsage() }

        func tourScrollToBottom() { scrollToBottom(animated: true) }

        func tourConfirmRevert(toMessageID messageID: String) {
            guard let message = viewModel.state.messages.first(where: { $0.id == messageID })
            else { return }
            confirmRevert(to: message)
        }

        func tourRevert(toMessageID messageID: String) {
            guard let message = viewModel.state.messages.first(where: { $0.id == messageID })
            else { return }
            performRevert(to: message)
        }

        func tourRestoreRevert() { viewModel.restoreRevert() }

        func tourScrollToTop() {
            userScrolledUp = true
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }

        /// The palette is driven by what is in the composer, so the tour opens it the
        /// same way a thumb does — by putting a slash there.
        func tourOpenCommandPalette() {
            composer.setDraft("/", focus: true)
            composerTextDidChange("/")
        }

        func tourClearComposer() {
            composer.clear()
            composerTextDidChange("")
        }

        func tourSetDraft(_ text: String) {
            composer.setDraft(text, focus: true)
            composerTextDidChange(text)
        }

        func tourOpenCommandCatalog() { presentCommandCatalog() }

        func tourType(_ text: String, perCharacter: Double) async {
            for index in text.indices {
                let partial = String(text[text.startIndex...index])
                composer.setDraft(partial, focus: true)
                composerTextDidChange(partial)
                try? await Task.sleep(for: .seconds(perCharacter))
            }
        }

        func tourSend(_ text: String) { composerDidSend(text) }

        func tourDismissSheet() { presentedViewController?.dismiss(animated: true) }

        /// Runs the identical closure a tap on the palette row runs, including the
        /// composer clear, the palette dismissal and the selection haptic.
        func tourRunAppCommand(_ keyword: String) {
            appCommands().first { $0.keywords.contains(keyword) }?.run()
        }

        func tourPickQuestionOption(_ option: Int, question: Int = 0) {
            guard let request = pendingQuestion,
                request.questions.indices.contains(question)
            else { return }
            var picked = questionSelection.picked[question] ?? []
            if request.questions[question].multiple {
                if !picked.insert(option).inserted { picked.remove(option) }
            } else {
                picked = [option]
            }
            questionSelection.picked[question] = picked
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(["question:\(request.id)"])
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func tourSubmitQuestion() {
            guard let request = pendingQuestion,
                let answers = questionSelection.answers(for: request),
                answeredQuestionIDs.insert(request.id).inserted
            else { return }
            viewModel.answerQuestion(request, answers: answers)
        }

        func tourPromptRename(to newTitle: String) {
            promptRename()
            (presentedViewController as? UIAlertController)?.textFields?.first?.text = newTitle
        }

        func tourConfirmRename(to newTitle: String) {
            presentedViewController?.dismiss(animated: true)
            Task {
                try? await viewModel.rename(to: newTitle)
                self.title = navDisplayTitle
            }
        }

        func tourToggleSaved() { toggleSaved() }

        func tourDismissKeyboard() { view.endEditing(true) }
    #endif
}

extension ChatViewController {
    #if DEBUG
        /// Answers whatever the agent asks with one of its offered options, so the
        /// ask-and-answer round trip can be verified without driving touches.
        func answerPendingQuestion(option: Int) async {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let request = pendingQuestion,
                    answeredQuestionIDs.insert(request.id).inserted
                else { continue }
                viewModel.answerQuestion(
                    request,
                    answers: request.questions.map { item in
                        item.options.indices.contains(option) ? [item.options[option].label] : []
                    })
                return
            }
        }
    #endif
}

#if DEBUG
    extension ChatViewController {
        /// One step of a scripted walk through the model dial, for the headless screenshot run:
        /// `pins`, `pinscycle`, `star:<id>`, `auto`, `pick:<id>`, `level:<l>`, `rail[:<l>]`, `step`, `cycle`, `menu`, `party`, `partyedit`, `model:<id>`.
        func tourDial(_ verb: String) async {
            let parts = verb.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "pins", "pinscycle":
                DialTour.pinPairs()
                updateNavControls()
                if parts[0] == "pinscycle" { cyclePreset(by: 1) }
            case "star":
                guard parts.count > 1 else { return }
                DialTour.star(parts[1])
                updateNavControls()
            case "auto":
                _ = viewModel.selectModel(nil)
                viewModel.setEffort(nil)
                updateNavControls()
            case "pick":
                guard parts.count > 1 else { return }
                _ = viewModel.selectModel(DialTour.selection(parts[1]))
                updateNavControls()
            case "level", "rail":
                if parts.count > 1 {
                    viewModel.setEffort(parts[1])
                    updateNavControls()
                    try? await Task.sleep(for: .seconds(0.6))
                }
                if parts[0] == "rail" { dialPill.openRail() }
            case "step": stepEffort(by: -1)
            case "cycle": cyclePreset(by: 1)
            case "menu": dialPill.openMenu()
            case "party", "partyedit":
                DialTour.fillParty()
                presentParty(editing: parts[0] == "partyedit")
            case "model":
                guard parts.count > 1 else { return }
                chooseModel(DialTour.selection(parts[1]))
            default: break
            }
        }
    }
#endif
