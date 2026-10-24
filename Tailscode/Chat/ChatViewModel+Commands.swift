import MidgarCore
import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    var supportsServerCommands: Bool { backend.capabilities.supportsCommands }
    /// Whether the agent reads its own slash grammar out of the prompt text. A CLI-backed agent
    /// does, so a typed command must go out untouched rather than through the command route.
    var resolvesCommandsFromPromptText: Bool { backend.resolvesCommandsFromPromptText }
    var supportsGoals: Bool { backend.capabilities.supportsGoals }
    var goal: SessionGoal? { state.goal }

    /// Whether a design board could be read back at all. The brief is only worth spending a turn
    /// on where this server hands files over — otherwise the mocks would be written somewhere no
    /// client could ever open them.
    var supportsDesign: Bool { backend.capabilities.supportsFileBrowsing }

    /// The machine this chat's profile names, which is where its dispatcher would be.
    var delegateHost: String? {
        ConnectionController.shared.profiles.first { $0.id == contextID }.flatMap { DelegateAccess.host(of: $0.baseURL) }
    }

    /// Where this chat's app can be watched running: its machine's preview host, when this device
    /// has agreed to use one, and the folder the agent works in on that machine.
    var previewTarget: PreviewTarget? {
        PreviewEntry.target(host: delegateHost, directory: session.directory)
    }

    /// A chat whose machine is known by name can hand a task to that machine's dispatcher.
    var supportsDelegate: Bool { delegateHost?.isEmpty == false }

    /// What the composer offers: the server's catalog, plus the words this app answers itself.
    var composerCommands: [AgentCommand] {
        CommandCatalogStore.forComposer(serverCommands, supportsDesign: supportsDesign, supportsDelegate: supportsDelegate)
    }

    /// A packet started from this chat: its machine, the words as the goal, and the directory the
    /// chat works in as the repository.
    func delegateHandoff(goal: String) -> DelegateHandoff? {
        guard let host = delegateHost, !host.isEmpty else { return nil }
        return DelegateHandoff(
            host: host, serverName: serverName.isEmpty ? host : serverName, goal: goal, repo: session.directory ?? "")
    }

    /// The server's command catalog, fetched once per chat. A server that can't answer leaves the
    /// list empty and the palette shows only the app's own actions.
    func loadServerCommands() {
        guard supportsServerCommands, serverCommands.isEmpty else { return }
        Task { [weak self] in
            guard let self,
                let commands = try? await backend.availableCommands(
                    directory: session.directory), !commands.isEmpty
            else { return }
            self.serverCommands = commands
            self.onCommandsChange?()
        }
    }

    /// Runs a server-side command. Where a command is just prompt text (any CLI-backed agent) it
    /// goes through the ordinary send path, so it echoes into the transcript, engages the thinking
    /// state, and starts a Live Activity exactly like a typed message — anything else would make
    /// the app look frozen until the server streamed something back. A command is a turn either
    /// way, so it leaves carrying the model and effort the composer is wearing: a run that carried
    /// nothing let the server answer on its own default, and the chat then renamed itself after a
    /// model nobody picked.
    func run(_ command: AgentCommand, arguments: String? = nil) {
        if backend.resolvesCommandsFromPromptText {
            send(command.invocation(arguments: arguments))
            return
        }
        let model = selectedModel
        let effort = currentEffort
        if isBusy {
            MidgarLog.info(
                "command queued session=\(session.id) name=\(command.name) queue=\(queue.count + 1)", category: .chat)
            hold(
                QueuedSend(
                    text: command.invocation(arguments: arguments), model: model, effort: effort,
                    kind: .command(name: command.name, arguments: arguments ?? "")))
            return
        }
        runNow(command, arguments: arguments, model: model, effort: effort)
    }

    /// A command is a turn the server runs from its own catalog, so it goes straight out — an
    /// echo row would wait for a user message no backend writes for it.
    func runNow(
        _ command: AgentCommand, arguments: String?, model: ModelSelection?, effort: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await conversation.run(
                    command, arguments: arguments, model: model, reasoningEffort: effort)
            } catch {
                self.onError?(String(localized: "Couldn't run /\(command.name)."))
            }
        }
    }

    var supportsCompaction: Bool { backend.capabilities.supportsCompaction }

    /// A compaction in flight, or the one that was just refused. The transcript records finished
    /// ones itself — this is only the part of the story that has no row of its own yet.
    var compactionActivity: CompactionActivity? { state.compaction }

    /// The most recent finished compaction, so the app can say what the last one cost before
    /// asking for another.
    var lastCompaction: Compaction? {
        state.messages.reversed()
            .lazy
            .flatMap { $0.parts }
            .compactMap { part -> Compaction? in
                guard case .compaction(let value) = part.kind else { return nil }
                return value
            }
            .first
    }

    /// Compaction is a turn like any other — it echoes, engages the thinking state, and queues
    /// behind a running one — so it goes out through the ordinary send path.
    func compact(instructions: String?) {
        let command = AgentCommand(name: "compact", details: "", source: .builtin)
        run(command, arguments: instructions)
    }

    func setGoal(_ condition: String) {
        run(AgentCommand(name: "goal", details: "", source: .builtin), arguments: condition)
    }

    func clearGoal() {
        run(AgentCommand(name: "goal", details: "", source: .builtin), arguments: "clear")
    }
}
