import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// `/compact` never fires bare: it costs minutes, cannot be undone, and takes an instruction
    /// where the server accepts one. The sheet is where that gets said.
    func presentCompactPreflight(instruction: String = "") {
        let sheet = CompactPreflightViewController(
            messageCount: viewModel.state.messages.count(where: { $0.role != .system }),
            lastCompaction: viewModel.lastCompaction,
            initialInstruction: instruction,
            showsInstruction: viewModel.backend.capabilities.supportsCompactionInstructions,
            draftScope: compactionDraftScope
        ) { [weak self] instructions in
            self?.viewModel.compact(instructions: instructions)
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.large(), .medium()]
            presentation.selectedDetentIdentifier = .large
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// `/design` never fires bare either: it spends a whole turn drawing pictures on somebody
    /// else's machine, so the sheet states what it will do and what it will not touch first. The
    /// brief leaves as an ordinary prompt, so the board it produces lands in this transcript.
    func presentDesignPreflight(request: String = "") {
        let sheet = DesignPreflightViewController(request: request) { [weak self] brief in
            self?.sendDraft(brief.prompt)
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.large(), .medium()]
            presentation.selectedDetentIdentifier = .large
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// What the card says once the manifest has been read: the board's own title, how many
    /// alternatives it holds and the letters they are picked by. Asked for once per directory the
    /// first time the card is drawn, because a card that only ever names a folder makes the reader
    /// open a board to find out whether it is worth opening.
    func designBoard(for sighting: DesignSighting, row: String) -> DesignBoard? {
        guard case .board(let directory) = sighting.source else { return nil }
        if let manifest = designManifests[directory] {
            return DesignBoard(directory: directory, manifest: manifest)
        }
        guard let files = viewModel.backend as? any FileBrowsingBackend,
            designReads.insert(directory).inserted
        else { return nil }
        let path = DesignPaths.manifest(in: directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            await MainActor.run { [weak self] in
                guard let self, let text, let manifest = DesignManifest.parse(text) else { return }
                self.designManifests[directory] = manifest
                self.remeasureRow(row)
            }
        }
        return nil
    }

    /// A board opens over the conversation; a design published somewhere else is handed to the
    /// system, which is the only thing that can open it.
    func openDesign(_ source: DesignSource) {
        switch source {
        case .board(let directory):
            let board = DesignBoardViewController(
                directory: directory, backend: viewModel.backend
            ) { [weak self] prompt in
                self?.sendDraft(prompt)
            }
            let nav = UINavigationController(rootViewController: board)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case .artifact(let url):
            guard let link = URL(string: url) else { return }
            UIApplication.shared.open(link)
        }
    }

    func presentCompactionSummary(_ row: CompactionRow) {
        guard let compaction = row.compaction, row.isReadable else { return }
        let nav = UINavigationController(
            rootViewController: CompactionSummaryViewController(compaction: compaction))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    func presentGoalDetail() {
        guard let goal = viewModel.goal, goal.isActive else { return }
        let sheet = UIAlertController(
            title: String(localized: "Working toward"), message: goal.condition,
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "Stop pursuing this"), style: .destructive) {
                [weak self] _ in
                self?.viewModel.clearGoal()
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Keep going"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = goalChip
        sheet.popoverPresentationController?.sourceRect = goalChip.bounds
        present(sheet, animated: true)
    }
}

extension ChatViewController {
    /// Signing the machine back in is the one repair a phone can make from here, so the banner
    /// leads straight to it rather than to a retry that will fail the same way.
    func presentSignIn() {
        guard let authenticator = viewModel.authenticator else { return }
        let profile = ConnectionController.shared.profiles.first { $0.id == viewModel.contextID }
            ?? ConnectionController.shared.activeProfile
        guard let profile else { return }
        let signIn = ServerSignInViewController(profile: profile, backend: authenticator)
        signIn.onSignedIn = { [weak self] _ in
            guard let self else { return }
            self.viewModel.clearSignedOut()
            self.banner.hide()
            self.viewModel.refresh()
        }
        present(UINavigationController(rootViewController: signIn), animated: true)
    }
}

extension ChatViewController {
    func presentEffortSheet() {
        dialPill.openRail()
    }

    func presentUsage() {
        Task { @MainActor in
            guard viewModel.supportsUsage, let usage = await viewModel.usage(),
                usage.tokens != nil || usage.costUSD != nil
            else {
                self.presentToast(String(localized: "No usage recorded for this session yet."))
                return
            }
            var lines: [String] = []
            if let tokens = usage.tokens {
                lines.append(String(localized: "\(tokens.formatted()) tokens"))
            }
            if let cost = usage.costUSD {
                lines.append(String(format: "$%.4f", cost))
            }
            let alert = UIAlertController(
                title: String(localized: "Last turn usage"),
                message: lines.joined(separator: "\n"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            self.present(alert, animated: true)
        }
    }

    func presentFileBrowser() {
        guard let fb = viewModel.backend as? any FileBrowsingBackend else { return }
        Theme.Haptics.tap()
        let browser = FileBrowserViewController(backend: fb, profileID: viewModel.contextID)
        browser.onSelect = { [weak self] path in
            guard let self else { return }
            browser.dismiss(animated: true) {
                UIPasteboard.general.string = path
                self.presentToast(String(localized: "Path copied: \(path)"))
                self.composer.appendPath(path)
            }
        }
        let nav = UINavigationController(rootViewController: browser)
        present(nav, animated: true)
    }

    func presentJumpSheet() {
        let prompts = orderedIDs.compactMap { id -> (String, String)? in
            guard let row = rowsByID[id], row.role == .user, case .text(let text) = row.content
            else { return nil }
            return (id, String(text.prefix(50)))
        }
        guard !prompts.isEmpty else {
            presentToast(String(localized: "No earlier messages to jump to."))
            return
        }
        let sheet = UIAlertController(
            title: String(localized: "Jump to message"), message: nil,
            preferredStyle: .actionSheet)
        for (id, title) in prompts.suffix(15) {
            sheet.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.scrollTo(id: id)
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        sheet.popoverPresentationController?.sourceRect = composer.bounds
        present(sheet, animated: true)
    }
}

extension ChatViewController {
    func presentToast(_ message: String, duration: TimeInterval = 2.0) {
        let toast = ToastView(message: message)
        toast.flash(in: view, above: composer.topAnchor, duration: heldToastDuration(duration))
    }

    private func heldToastDuration(_ duration: TimeInterval) -> TimeInterval {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_TOAST_HOLD"].flatMap(Double.init)
                ?? duration
        #else
            return duration
        #endif
    }
}

extension ChatViewController {
    func presentError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
