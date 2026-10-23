import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension HomeViewController: HomeComposerBarDelegate {
    func homeComposer(_ bar: HomeComposerBar, didSend text: String) {
        composerSend(text)
    }

    func homeComposerDidTapDestination(_ bar: HomeComposerBar) {
        guard let aim = composerAim else { return }
        Theme.Haptics.tap()
        chooseComposeTarget(profile: aim.profile)
    }

    func homeComposerDidBeginEditing(_ bar: HomeComposerBar) {
        composerFollowsKeyboard(true)
        updateCommandPalette(for: bar.currentText)
        updateSuggestions()
        enhancement.prewarm()
    }

    func homeComposerTextDidChange(_ text: String) {
        if askLane == .video {
            ForgeRunner.shared.describe(text)
            updateSuggestions()
            return
        }
        if askLane == .image {
            ImageStudio.shared.rememberDraft(text)
            enhancement.updateInput(text)
            enhanceOverlay?.requestDismiss()
            composerBar.setEnhanceHint(enhancement.hasFreshSuggestions)
            updateSuggestions()
            return
        }
        updateCommandPalette(for: composerBar.currentText)
        updateSuggestions()
        enhancement.updateInput(composerBar.currentText)
        enhanceOverlay?.requestDismiss()
        guard let scope = composerDraftScope else { return }
        DraftStore.record(text, for: scope)
    }

    /// The bar has already thrown itself; what the lane means is decided here.
    func homeComposerDidToggleLane(_ bar: HomeComposerBar) {
        setLane(bar.lane, animated: false)
    }

    /// Photos and files are different errands, and only the ones this aim can carry out are
    /// offered: a model that cannot see is never handed a photo picker.
    func homeComposerAttachOptions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if abilities.vision {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    image: UIImage(systemName: "photo.on.rectangle")
                ) { [weak self] _ in self?.presentPhotoPicker() })
        } else if abilities.attachments {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    subtitle: String(localized: "This model can't see images."),
                    image: UIImage(systemName: "photo.on.rectangle"), attributes: .disabled
                ) { _ in })
        }
        if abilities.camera {
            actions.append(
                UIAction(title: String(localized: "Take Photo"), image: UIImage(systemName: "camera")
                ) { [weak self] _ in self?.presentCamera() })
        }
        if abilities.attachments {
            actions.append(
                UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")
                ) { [weak self] _ in self?.presentDocumentPicker() })
        }
        if UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
            actions.append(
                UIAction(
                    title: String(localized: "Paste"),
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in self?.pasteFromClipboard() })
        }
        return actions
    }

    /// A screenshot in hand is the commonest thing a phone has to show an agent, so pasting one
    /// attaches it rather than doing nothing at all.
    func homeComposerDidPasteImage(_ data: Data, mime: String) {
        guard abilities.vision else {
            toast(String(localized: "This model can't read pictures."))
            return
        }
        pastedImageCount += 1
        attach(data: data, name: "pasted-\(pastedImageCount).png", mime: mime)
    }

    /// A paste too large to read as a sentence becomes the file it already is, so the question
    /// stays a question and the wall of text rides beside it.
    func homeComposerDidPasteLargeText(_ text: String) {
        guard abilities.attachments, let data = text.data(using: .utf8) else {
            composerBar.insertText(text)
            return
        }
        composerBar.deleteSelection()
        attach(data: data, name: "pasted-\(UUID().uuidString.prefix(8)).txt", mime: "text/plain")
        toast(
            String(
                localized: "Attached \(text.count.formatted()) characters — sent with the message."))
    }

    /// Holding Send raises the on-device enhancement deck for words worth sharpening — the same
    /// gesture the chat's composer answers, because the front door is exactly where a vague
    /// sentence costs a whole round trip. In the picture lane the deck holds the brief written out
    /// by the machine that paints, which is the Enhance chip's own answer.
    func homeComposerDidLongPressSend(from view: UIView) {
        let text = composerBar.currentText
        guard !text.isEmpty else { return }
        enhancement.requestNow(for: text)
        presentEnhanceOverlay(original: text)
    }

    /// What the aimed machine can be told to do, read from memory first and corrected by the
    /// machine afterwards. Fetched with no directory even when the composer is aimed at a project:
    /// the catalog answers what this server knows, and the words that read a transcript are dropped
    /// because the conversation this send mints has none.
    func loadCommandsIfNeeded(for profile: ConnectionProfile) {
        guard catalogProfileID != profile.id else { return }
        catalogProfileID = profile.id
        commands = CommandCatalogStore.forQuickAsk(CommandCatalogStore.cached(profile.id))
        updateCommandPalette(for: composerBar.currentText)
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else {
            commands = []
            hideCommandPalette()
            return
        }
        Task { [weak self] in
            let fetched = await CommandCatalogStore.refresh(
                profileID: profile.id, backend: backend)
            guard let self, self.catalogProfileID == profile.id else { return }
            self.commands = CommandCatalogStore.forQuickAsk(fetched)
            self.updateCommandPalette(for: self.composerBar.currentText)
        }
    }

    /// The same reading the chat composer answers, drawn in the same list: candidates while the
    /// command is being named, that one command's signature once it is settled, and a word the
    /// catalog lacks said out loud rather than left to vanish under the caret.
    func updateCommandPalette(for text: String) {
        guard composerBar.isEditing, !composerBar.isHidden else { return hideCommandPalette() }
        switch SlashPresentation.of(
            text: text, commands: commands, recents: SlashRecents.surviving(in: commands))
        {
        case .hidden:
            hideCommandPalette()
        case .naming(let matches):
            commandPalette.update(
                with: .commands([
                    SlashCommandSection(
                        title: "",
                        commands: matches.map { paletteRow(for: $0.command, highlight: $0.highlight) })
                ]))
            showCommandPalette()
        case .arguments(let command, let typed):
            commandPalette.update(
                with: .arguments(command: paletteRow(for: command), typed: typed))
            showCommandPalette()
        case .noMatch(let query):
            commandPalette.update(
                with: .noMatch(
                    wording: SlashPresentation.noMatchWording("/\(query)", hasProject: false),
                    browse: nil))
            showCommandPalette()
        }
    }

    private func paletteRow(for command: AgentCommand, highlight: [Int] = []) -> SlashCommand {
        SlashCommand(
            id: "server:\(command.name)",
            keywords: [command.name.lowercased()],
            title: "/\(command.name)",
            subtitle: command.details,
            symbol: CommandSymbol.of(command),
            highlight: highlight.map { $0 + 1 },
            argumentHint: command.argumentHint,
            badge: command.scope,
            runsOnServer: true
        ) { [weak self] in self?.selectCommand(command) }
    }

    private func selectCommand(_ command: AgentCommand) {
        Theme.Haptics.selection()
        hideCommandPalette()
        composerBar.setText(command.takesArguments ? "/\(command.name) " : "/\(command.name)")
        composerBar.focus()
    }

    private func showCommandPalette() {
        guard commandPalette.isHidden else { return }
        commandPalette.alpha = 0
        commandPalette.isHidden = false
        UIView.animate(withDuration: 0.18) { self.commandPalette.alpha = 1 }
        updateSuggestions()
    }

    func hideCommandPalette() {
        guard !commandPalette.isHidden else { return }
        UIView.animate(
            withDuration: 0.15, animations: { self.commandPalette.alpha = 0 },
            completion: { _ in
                self.commandPalette.isHidden = true
                self.updateSuggestions()
            })
    }

    /// Home's composer has no session to belong to, so what is written in it belongs to where it
    /// is aimed: re-aiming the chip — or throwing the lane switch — stashes the text under the
    /// destination it was written for and hands back whatever was left unsent for the new one, the
    /// way switching chats does in a pane.
    func syncComposerDraft(to scope: DraftScope) {
        guard composerDraftScope != scope else { return }
        let carried = composerBar.rawText
        guard let previous = composerDraftScope else {
            composerDraftScope = scope
            if composerBar.currentText.isEmpty {
                composerBar.setText(DraftStore.text(for: scope))
            } else {
                DraftStore.record(carried, for: scope)
            }
            return
        }
        DraftStore.record(carried, for: previous)
        composerDraftScope = scope
        composerBar.setText(DraftStore.text(for: scope))
    }
}
