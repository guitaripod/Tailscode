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

        /// Puts a long log through the composer's own paste, so the fold beside the box can be
        /// photographed; `send` sends it under a question first, so the transcript's folded card
        /// is on screen too, and `read` opens the waiting paste in its reader.
        func stagePasteForVerification(_ mode: String) async {
            let log = (0..<46).map { index in
                "2026-11-11T12:04:\(String(format: "%02d", index)) worker-\(index % 4) ERROR bind 0.0.0.0:8080: address already in use"
            }.joined(separator: "\n")
            if mode.contains("send") {
                composer.setDraft("the workers keep dying on start, what is holding the port?")
                composerDidPasteLargeText(log)
                composer.triggerSend()
                try? await Task.sleep(for: .seconds(2))
            }
            let trace = (["Traceback (most recent call last):"] + (0..<18).map {
                "  File \"/srv/app/server.py\", line \(120 + $0), in serve"
            }).joined(separator: "\n")
            composer.setDraft("and this one after the restart?")
            composerDidPasteLargeText(trace)
            if mode.contains("read"), let id = pendingPastes.first?.id {
                try? await Task.sleep(for: .seconds(1))
                readPaste(id)
            }
        }

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

        func tourTakePartySlot(_ index: Int) {
            (presentedViewController as? PartyViewController)?.tourTake(slot: index)
        }
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
        /// `pins`, `pinscycle`, `star:<id>`, `auto`, `pick:<id>`, `level:<l>`, `rail[:<l>]`, `step`, `cycle`, `menu`, `party`, `partyedit`, `fleetparty`, `fleetpartykeep`, `model:<id>`.
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
            case "fleetparty", "fleetpartykeep":
                DialTour.fillFleetParty(localLevel: parts[0] == "fleetpartykeep" ? .keep : .server)
                presentParty()
            case "model":
                guard parts.count > 1 else { return }
                chooseModel(DialTour.selection(parts[1]))
            default: break
            }
        }
    }
#endif

#if DEBUG
    extension ChatViewController {
        static let stagedLongDraft =
            "The reconnect test still fails one run in five on CI after the jitter pin. Look at "
            + "`ReconnectScheduler` again: the backoff resets when the socket closes cleanly, but the "
            + "test server closes with 1001 and I think we treat that as clean. Check the close-code "
            + "table in @Sources/Pulse/Socket/CloseCodes.swift, add a test that closes with 1001 "
            + "mid-handshake, and make the scheduler keep its attempt count across a going-away close. "
            + "Keep the public API as it is. When it passes twenty runs in a row locally, commit it "
            + "with a message that says what the race was."

        /// A scripted walk through the composer for a run with no finger, steps split on `;`:
        /// `draft:<words>`, `long`, `lift`, `drop`, `at:<letters>`, `pick:<n>`, `code:<at>:<length>`,
        /// `quote:<at>:<length>`, `attach`, `last`, `send`, `focus`, `blur`, `clear`, `wait:<seconds>`,
        /// `nudge:<id>` (sends Resume or Status? from the chat's menu), `type:<words>` (a letter at
        /// a time, `|` for a new line) and `rewrite` (opens the last waiting message in the box). For timing: `prose:<length>` and `inked:<length>` fill the
        /// box, `shelf:<files>` gives the file list a project that size, and `bench:<name>:<keys>:
        /// <pattern>` and `drag:<frames>` log a `COMPOSE_BENCH` line.
        func stageCompose(_ script: String) async {
            for step in script.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "draft": composer.setDraft(argument, cursorAtEnd: true)
                case "long": composer.setDraft(Self.stagedLongDraft, cursorAtEnd: true)
                case "lift": composer.setLifted(true)
                case "drop": composer.setLifted(false)
                case "at": composer.setDraft("Why does @\(argument)", cursorAtEnd: true)
                case "pick": stageAcceptMention(Int(argument) ?? 0)
                case "code", "quote":
                    let span = argument.split(separator: ":").compactMap { Int($0) }
                    guard span.count == 2 else { continue }
                    composer.stageVerb(parts[0], over: NSRange(location: span[0], length: span[1]))
                case "attach": stageAttachment()
                case "type":
                    for letter in argument {
                        composer.insertText(letter == "|" ? "\n" : String(letter))
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                case "rewrite": takeBackLastQueued()
                case "nudge":
                    if let nudge = ChatNudge.all.first(where: { $0.id == argument }) {
                        sendNudge(nudge)
                    }
                case "last": composerDidAskForLastPrompt()
                case "send": composer.triggerSend()
                case "focus": composer.focus()
                case "blur": composer.unfocus()
                case "clear": composer.clear()
                case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
                case "prose": composer.setDraft(Self.stagedDraft(Self.stagedProse, length: Int(argument) ?? 3000), cursorAtEnd: true)
                case "inked": composer.setDraft(Self.stagedDraft(Self.stagedInk, length: Int(argument) ?? 3000), cursorAtEnd: true)
                case "shelf": mentionFinder?.stageShelf(Int(argument) ?? 6000)
                case "bench": await benchKeys(argument)
                case "drag": await benchDrag(frames: Int(argument) ?? 90)
                default: break
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        private static let stagedProse =
            "I want the stream to keep its place when the bridge restarts, and the queue to hold "
            + "whatever was typed while it was gone. "
        private static let stagedInk =
            "Look at @Sources/Pulse/Socket/CloseCodes.swift and `ReconnectScheduler`, then go "
            + "ultracode on the ```swift|let attempts = 3|``` part of @Tests/PulseTests/Jitter.swift. "

        private static func stagedDraft(_ unit: String, length: Int) -> String {
            let text = String(repeating: unit, count: length / unit.count + 1)
            return String(text.prefix(length)).replacingOccurrences(of: "|", with: "\n")
        }

        /// `bench:<name>:<keys>:<pattern>` types the pattern over and over, a key every 50 ms,
        /// `<` deleting and `|` starting a line, and logs what each key cost.
        private func benchKeys(_ argument: String) async {
            let parts = argument.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let keys = Int(parts[1]), !parts[2].isEmpty else { return }
            let pattern = Array(parts[2])
            let bench = ComposerBench()
            let changes = composer.stagedChanges
            let asks = composer.stagedAsks
            for index in 0..<keys {
                bench.time({ composer.stageKeystroke(pattern[index % pattern.count]) }, in: view)
                try? await Task.sleep(for: .milliseconds(50))
            }
            bench.finish(
                parts[0],
                extra: "changes=\(composer.stagedChanges - changes) asks=\(composer.stagedAsks - asks) chars=\(composer.rawText.utf16.count)")
        }

        /// `drag:<frames>` pulls the handle up a frame at a time and lets go.
        private func benchDrag(frames: Int) async {
            let bench = ComposerBench()
            for frame in 0..<frames {
                bench.time({ composer.stageDrag(travel: CGFloat(frame) * 6) }, in: view)
                try? await Task.sleep(for: .milliseconds(16))
            }
            composer.stageDragEnd()
            bench.finish("drag", extra: "chars=\(composer.rawText.utf16.count)")
        }

        /// Clips a drawn picture to the message the way a pasted screenshot arrives.
        private func stageAttachment() {
            let size = CGSize(width: 240, height: 240)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let colors = [UIColor.systemIndigo.cgColor, UIColor.systemPink.cgColor] as CFArray
                let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil)
                if let gradient {
                    context.cgContext.drawLinearGradient(
                        gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
            }
            guard let data = image.pngData() else { return }
            composerDidPasteImage(data, mime: "image/png")
        }
    }
#endif
