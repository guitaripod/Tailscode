import CodingAgentKit
import Foundation

/// Every server's slash catalog, kept where all three clients read it from.
///
/// A catalog is a round trip to another machine, and a completion list that is empty for the first
/// second is a completion list nobody trusts. What each server last published is stored under its
/// own profile and survives the app, so the first keystroke is answered from memory and the fetch
/// only ever corrects it.
public enum CommandCatalogStore {
    static let prefix = "tailscode.commandCatalog."

    public static func cached(_ profileID: String) -> [AgentCommand] {
        guard let data = UserDefaults.standard.data(forKey: prefix + profileID),
            let commands = try? JSONDecoder().decode([AgentCommand].self, from: data)
        else { return [] }
        return commands
    }

    public static func store(_ commands: [AgentCommand], for profileID: String) {
        guard !commands.isEmpty, let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: prefix + profileID)
    }

    public static func forget(_ profileID: String) {
        UserDefaults.standard.removeObject(forKey: prefix + profileID)
    }

    /// Asks a server what it can be told to do and remembers the answer. Failure is silent: a
    /// machine that cannot be reached keeps the catalog it last gave.
    ///
    /// - Parameter directory: the project the commands are being resolved for. A quick ask has no
    ///   project, so it passes nil and gets the machine's own — its built-ins, the user's own
    ///   command files, plugins and skills, but nothing a repository contributes.
    @discardableResult
    public static func refresh(
        profileID: String, backend: any CodingAgentBackend, directory: String? = nil
    ) async -> [AgentCommand] {
        guard backend.capabilities.supportsCommands,
            let commands = try? await backend.availableCommands(directory: directory),
            !commands.isEmpty
        else { return cached(profileID) }
        store(commands, for: profileID)
        return commands
    }

    /// The catalog a composer should offer: what the server published, plus the one word this app
    /// answers itself.
    ///
    /// `/design` is contributed here rather than fetched because the app is what makes it mean
    /// anything — the brief states where the board goes and the board surface reads it back from
    /// there. A server that has a design command of its own loses the row rather than sharing it:
    /// two identical words in one list, only one of which does what the list says, is worse than
    /// one word that always does.
    public static func forComposer(_ commands: [AgentCommand], supportsDesign: Bool)
        -> [AgentCommand]
    {
        guard supportsDesign else { return commands }
        let rest = commands.filter { $0.name != SlashDispatch.designWord }
        return [designCommand] + rest
    }

    public static let designCommand = AgentCommand(
        name: SlashDispatch.designWord,
        details: Localized.text(
            "Draw a few alternatives for a surface, pick one, then have it built"),
        argumentHint: Localized.text("<what to design>"),
        source: .builtin,
        scope: "Tailscode")

    /// The catalog a surface with no conversation may offer.
    ///
    /// A quick ask mints its chat as it sends, so every command that reads a transcript has nothing
    /// to read: compacting a conversation with no turns in it is meaningless, and the preflight it
    /// would open is the one irreversible, minutes-long thing in the app. They are dropped before
    /// ranking rather than offered and then refused.
    public static func forQuickAsk(_ commands: [AgentCommand]) -> [AgentCommand] {
        commands.filter { !transcriptRelative.contains($0.name) }
    }

    private static let transcriptRelative: Set<String> = [
        "compact", "summarize", "context", "usage", "recap", "resume", "export", "clear",
    ]
}
