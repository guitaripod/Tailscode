import CodingAgentKit
import Foundation

/// What the slash surface should show right now — naming a command, filling its arguments, or
/// saying a name the catalog lacks. Toolkit-free so every client makes the same decision and only
/// paints differently.
public enum SlashPresentation: Sendable, Equatable {
    /// Not a slash draft, or vim is not typing — hide the surface.
    case hidden
    /// Still choosing which command; empty `matches` with an empty query is "nothing to show yet".
    case naming(matches: [SlashMatch])
    /// The command is settled; show its signature and hint while the argument is written.
    case arguments(command: AgentCommand, typed: String)
    /// A word the catalog does not have — say so rather than vanishing under the caret.
    case noMatch(query: String)

    /// Decide from the draft and the server's catalog. Recents only affect naming rank.
    public static func of(
        text: String, commands: [AgentCommand], recents: [String] = []
    ) -> SlashPresentation {
        switch SlashStage.of(text) {
        case .none:
            return .hidden
        case .naming(let query):
            let matches = SlashCompletion.ranked(commands, query: query, recents: recents)
            if matches.isEmpty, !query.isEmpty { return .noMatch(query: query) }
            if matches.isEmpty { return .hidden }
            return .naming(matches: matches)
        case .arguments(let name, let typed):
            guard let command = commands.first(where: { $0.name == name }) else {
                return .hidden
            }
            return .arguments(command: command, typed: typed)
        }
    }

    public var isVisible: Bool {
        switch self {
        case .hidden: return false
        case .naming, .arguments, .noMatch: return true
        }
    }

    /// What a surface says when the catalog has never heard the word being typed.
    ///
    /// A quick ask carries no project, so a repository's own command files are not in its catalog
    /// and could not be resolved by the turn it starts either. Saying only "no such command" would
    /// be true of the ask and false of the machine, and the person would go looking for a command
    /// that exists.
    public static func noMatchWording(_ query: String, hasProject: Bool) -> String {
        hasProject
            ? Localized.text("No command called %@", query)
            : Localized.text("No command called %@ outside a project", query)
    }
}

/// Source labels for the browsable catalog — one wording so iOS, Linux and Mac group the same.
public enum CommandCatalogGrouping {
    public static let sourceOrder: [AgentCommand.Source] = [
        .builtin, .project, .user, .plugin, .skill, .mcp, .custom,
    ]

    public static func sourceTitle(_ source: AgentCommand.Source) -> String {
        switch source {
        case .builtin: return Localized.text("Built in")
        case .user: return Localized.text("Yours")
        case .project: return Localized.text("This project")
        case .plugin: return Localized.text("Plugins")
        case .mcp: return Localized.text("MCP servers")
        case .skill: return Localized.text("Skills")
        case .custom: return Localized.text("Other")
        }
    }

    /// Unsearched: Recent first, then each source alphabetically. Searched: one ranked run that
    /// also matches details and scopes the ranking never sees.
    public static func sections(
        commands: [AgentCommand], query: String
    ) -> [(id: String, title: String, commands: [AgentCommand])] {
        let recents = SlashRecents.surviving(in: commands)
            .compactMap { name in commands.first { $0.name == name } }
        guard !query.isEmpty else {
            var out: [(String, String, [AgentCommand])] = []
            if !recents.isEmpty {
                out.append(("·recent", Localized.text("Recent"), recents))
            }
            let recentNames = Set(recents.map(\.name))
            for source in sourceOrder {
                let members = commands
                    .filter { $0.source == source && !recentNames.contains($0.name) }
                    .sorted { $0.name < $1.name }
                guard !members.isEmpty else { continue }
                out.append((source.rawValue, sourceTitle(source), members))
            }
            return out
        }

        let ranked = Set(SlashCompletion.ranked(commands, query: query).map(\.command.name))
        let byDetails = commands.filter {
            !ranked.contains($0.name)
                && ($0.details.localizedCaseInsensitiveContains(query)
                    || ($0.scope?.localizedCaseInsensitiveContains(query) ?? false))
        }
        let ordered =
            SlashCompletion.ranked(commands, query: query).map(\.command)
            + byDetails.sorted { $0.name < $1.name }
        guard !ordered.isEmpty else { return [] }
        return [("·results", Localized.text("Results"), ordered)]
    }
}
