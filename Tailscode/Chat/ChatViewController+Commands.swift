import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// The palette follows the caret through the two halves of a slash invocation: a ranked list
    /// while the command is still being named, that one command's own argument hint once it is
    /// settled. It never simply vanishes on a word the catalog lacks — that reads as the app
    /// losing the draft, when in fact the words are about to be sent as an ordinary message.
    func updateCommandPalette(for text: String) {
        switch SlashStage.of(text) {
        case .none:
            hideCommandPalette()
        case .naming(let query):
            presentCommandList(query: query)
        case .arguments(let name, let typed):
            presentArgumentHint(name: name, typed: typed)
        }
    }

    private func presentCommandList(query: String) {
        let sections = commandSections(query: query)
        guard sections.contains(where: { !$0.commands.isEmpty }) else {
            guard !query.isEmpty else { return hideCommandPalette() }
            commandPalette.update(
                with: .noMatch(
                    wording: SlashPresentation.noMatchWording(
                        "/\(query)", hasProject: viewModel.session.directory != nil),
                    browse: browseCommand()))
            showCommandPalette()
            return
        }
        commandPalette.update(with: .commands(sections))
        showCommandPalette()
    }

    /// Only a real server command earns the argument stage: the app's own rows take no arguments,
    /// so holding one on screen while somebody types past it would promise something untrue.
    private func presentArgumentHint(name: String, typed: String) {
        guard let command = viewModel.composerCommands.first(where: { $0.name == name }) else {
            hideCommandPalette()
            return
        }
        commandPalette.update(with: .arguments(command: makeServerCommand(command), typed: typed))
        showCommandPalette()
    }

    private func showCommandPalette() {
        guard commandPalette.isHidden else { return }
        commandPalette.alpha = 0
        commandPalette.isHidden = false
        UIView.animate(withDuration: 0.18) { self.commandPalette.alpha = 1 }
    }

    func hideCommandPalette() {
        guard !commandPalette.isHidden else { return }
        UIView.animate(
            withDuration: 0.15, animations: { self.commandPalette.alpha = 0 },
            completion: { _ in self.commandPalette.isHidden = true })
    }

    private func makeCommand(
        _ keywords: [String], _ title: String, _ subtitle: String, _ symbol: String,
        _ action: @escaping () -> Void
    ) -> SlashCommand {
        SlashCommand(
            id: "app:\(keywords.first ?? title)", keywords: keywords, title: title,
            subtitle: subtitle, symbol: symbol
        ) { [weak self] in
            self?.composer.clear()
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            action()
        }
    }

    /// `/` addresses two machines: the app and the agent. They stay in separate sections so
    /// nobody expects `/copy` to reach the server or `/compact` to be a local trick — and the
    /// handful of commands this device actually reaches for sits above both, because a phone
    /// types the same three all week.
    private func commandSections(query: String) -> [SlashCommandSection] {
        let recentNames = SlashRecents.surviving(in: viewModel.composerCommands)
        let ranked = SlashCompletion.ranked(
            viewModel.composerCommands, query: query, recents: recentNames)
        let app = appCommands().compactMap { command -> SlashCommand? in
            guard let highlight = Self.appMatch(command, query: query) else { return nil }
            var matched = command
            matched.highlight = highlight
            return matched
        }

        guard !ranked.isEmpty || !viewModel.composerCommands.isEmpty else {
            return [SlashCommandSection(title: "", commands: app)]
        }

        var server = ranked.map { makeServerCommand($0.command, highlight: $0.highlight) }
        let recentRows =
            query.isEmpty
            ? Array(server.prefix { recentNames.contains(commandName(of: $0)) }.prefix(4)) : []
        if !recentRows.isEmpty {
            let taken = Set(recentRows.map(\.id))
            server = server.filter { !taken.contains($0.id) }
        }
        if !server.isEmpty, let browse = browseCommand() { server.append(browse) }

        return [
            SlashCommandSection(title: String(localized: "Recent"), commands: recentRows),
            SlashCommandSection(title: String(localized: "On the server"), commands: server),
            SlashCommandSection(title: String(localized: "In Tailscode"), commands: app),
        ]
    }

    private func commandName(of row: SlashCommand) -> String {
        String(row.id.dropFirst("server:".count))
    }

    /// An app row answers to its own vocabulary — `/m`, `/think`, `/retry` — so the letters that
    /// matched are found against whichever keyword hit, then mapped onto the title when the title
    /// happens to carry them. A keyword-only hit still shows, just without tinted letters.
    private static func appMatch(_ command: SlashCommand, query: String) -> [Int]? {
        guard !query.isEmpty else { return [] }
        let title = command.title.lowercased()
        if let range = title.range(of: query) {
            let start = title.distance(from: title.startIndex, to: range.lowerBound)
            return Array(start..<(start + query.count))
        }
        return command.keywords.contains { $0.hasPrefix(query) } ? [] : nil
    }

    private func browseCommand() -> SlashCommand? {
        let total = viewModel.composerCommands.count
        guard total > 0 else { return nil }
        return SlashCommand(
            id: "app:·browse",
            keywords: ["all", "commands", "browse", "help"],
            title: String(localized: "All commands"),
            subtitle: String(localized: "Browse the \(total) this server offers"),
            symbol: "square.grid.2x2"
        ) { [weak self] in
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            self?.presentCommandCatalog()
        }
    }

    private func makeServerCommand(_ command: AgentCommand, highlight: [Int] = []) -> SlashCommand {
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
        ) { [weak self] in
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            self?.selectServerCommand(command)
        }
    }

    /// Picking a command that takes arguments lands it in the composer to be completed rather than
    /// firing bare — a tap is a choice, not a submission. `/goal` gets a purpose-built prompt
    /// because a stop condition is a different kind of writing from a message.
    private func selectServerCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        if command.name == "goal" {
            composer.clear()
            presentGoalComposer()
            return
        }
        if command.name == "compact", viewModel.supportsCompaction {
            composer.clear()
            presentCompactPreflight()
            return
        }
        if command.name == SlashDispatch.designWord, viewModel.supportsDesign {
            composer.clear()
            presentDesignPreflight(request: "")
            return
        }
        if command.name == SlashDispatch.delegateWord, viewModel.supportsDelegate {
            composer.clear()
            handOff(goal: "")
            return
        }
        guard !command.takesArguments else {
            composer.setDraft("/\(command.name) ", focus: true)
            return
        }
        runServerCommand(command, arguments: nil)
    }

    /// A command the person typed out and sent. Unlike a pick, this is a submission: a command
    /// that wants arguments and was sent without them runs bare, exactly as a terminal would,
    /// rather than being handed back for editing.
    func runServerCommand(_ command: AgentCommand, arguments: String?) {
        SlashRecents.record(command.name)
        if command.name == "goal", arguments == nil {
            composer.clear()
            presentGoalComposer()
            return
        }
        if command.name == "compact", viewModel.supportsCompaction {
            composer.clear()
            presentCompactPreflight(instruction: arguments ?? "")
            return
        }
        if command.name == SlashDispatch.designWord, viewModel.supportsDesign {
            composer.clear()
            presentDesignPreflight(request: arguments ?? "")
            return
        }
        if command.name == SlashDispatch.delegateWord, viewModel.supportsDelegate {
            composer.clear()
            DraftStore.clear(draftScope)
            handOff(goal: arguments ?? "")
            return
        }
        composer.clear()
        DraftStore.clear(draftScope)
        viewModel.run(command, arguments: arguments)
    }

    /// Opens the packet composer on this chat's machine, with the words as the goal and the chat's
    /// own directory as the repository, behind the same gate as every other door into delegation.
    func handOff(goal: String) {
        guard let handoff = viewModel.delegateHandoff(goal: goal) else { return }
        MidgarLog.info(
            "delegate handoff from session \(self.viewModel.session.id) to \(handoff.host) repo=\(handoff.repo)", category: .session)
        DelegateGate.compose(from: self, handoff: handoff)
    }

    func presentCommandCatalog() {
        let catalog = CommandCatalogViewController(commands: viewModel.composerCommands)
        catalog.onPick = { [weak self] command in self?.selectServerCommand(command) }
        let nav = UINavigationController(rootViewController: catalog)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large(), .medium()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    func appCommands() -> [SlashCommand] {
        var list: [SlashCommand] = []
        if viewModel.supportsModelSelection {
            list.append(
                makeCommand(
                    ["model", "m"], String(localized: "Model"),
                    viewModel.selectedModel?.modelID ?? String(localized: "Choose a model"),
                    "cpu"
                ) { [weak self] in self?.presentModelPicker() })
        }
        if viewModel.supportsReasoningEffort, !viewModel.reasoningEffortOptions.isEmpty {
            list.append(
                makeCommand(
                    ["effort", "reasoning", "think"], String(localized: "Reasoning effort"),
                    viewModel.currentEffort?.capitalized ?? String(localized: "Default"),
                    "gauge.with.dots.needle.50percent"
                ) { [weak self] in self?.presentEffortSheet() })
        }
        if viewModel.canRegenerate {
            list.append(
                makeCommand(
                    ["regenerate", "retry"], String(localized: "Regenerate"),
                    String(localized: "Re-run the last prompt"),
                    "arrow.clockwise"
                ) { [weak self] in self?.viewModel.regenerate() })
        }
        if viewModel.supportsUsage {
            list.append(
                makeCommand(
                    ["usage", "cost", "tokens"], String(localized: "Usage & cost"),
                    String(localized: "Tokens and spend for this session"),
                    "gauge.with.dots.needle.bottom.50percent"
                ) { [weak self] in self?.presentUsage() })
        }
        if viewModel.supportsFileBrowsing {
            list.append(
                makeCommand(
                    ["browse", "file", "path"], String(localized: "Browse files"),
                    String(localized: "Open file browser on server"),
                    "folder.fill"
                ) { [weak self] in self?.presentFileBrowser() })
        }
        if viewModel.canFork {
            list.append(
                makeCommand(
                    ["fork", "branch"], String(localized: "Fork conversation"),
                    String(localized: "Branch to explore a different direction"),
                    "arrow.triangle.branch"
                ) { [weak self] in self?.forkConversation() })
        }
        list.append(
            makeCommand(
                ["jump", "goto"], String(localized: "Jump to message"),
                String(localized: "Scroll to an earlier prompt"), "list.bullet"
            ) { [weak self] in self?.presentJumpSheet() })
        list.append(
            makeCommand(
                ["copy", "transcript"], String(localized: "Copy transcript"),
                String(localized: "Copy the whole conversation"),
                "doc.on.doc"
            ) { [weak self] in self?.copyTranscript() })
        if viewModel.canClear {
            list.append(
                makeCommand(
                    ["clear", "reset"], String(localized: "Clear conversation"),
                    String(localized: "Start fresh on the agent"), "eraser"
                ) { [weak self] in self?.confirmClear() })
        }
        return list
    }
}
