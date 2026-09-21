import CodingAgentKit
import Foundation

/// What each kind of server wants for a password, said once so every desk says the same thing.
///
/// The bridges always want one — the password in the install command. opencode 1 wants one only
/// if somebody set it, and opencode 2 always wants one: given none it makes one up and prints it
/// at start, so a field that reads as optional for opencode teaches a person to leave it empty
/// and then be refused. A form beside an install command says the rule for the kind picked; a
/// field that does not yet know its kind says the rule for all of them; a refusal names where the
/// password lives on the machine.
public enum ServerPasswordRule {
    /// The rule for one kind, beside the install command the app minted for it.
    public static func line(for backend: AgentType) -> String {
        switch backend {
        case .claudeCode:
            return Localized.text(
                "claude-bridge always needs a password — the one in the command above.")
        case .omp:
            return Localized.text(
                "omp-bridge always needs a password — the one in the command above.")
        case .openCode:
            return Localized.text(
                "opencode 2 always needs a password — the one in the command above. opencode 1 needs one only if you set it."
            )
        }
    }

    /// Every kind at once, under a password field that does not yet know which server it is for.
    public static var summary: String {
        Localized.text(
            "claude-bridge, omp-bridge and opencode 2 always want one — BRIDGE_PASSWORD, OMP_PASSWORD, OPENCODE_SERVER_PASSWORD or the one opencode printed when it started. opencode 1 only if you set one."
        )
    }

    /// What a server that answered and refused is asking for, and where to look for it.
    public static func refusalDetail(host: String) -> String {
        Localized.text(
            "Good news: something is answering at %@. Enter the password it was started with — BRIDGE_PASSWORD for claude-bridge and omp-bridge, OPENCODE_SERVER_PASSWORD for opencode 2, or the one opencode printed when it started.",
            host)
    }
}
