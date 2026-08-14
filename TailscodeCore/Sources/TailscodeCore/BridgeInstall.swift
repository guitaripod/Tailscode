import CodingAgentKit
import Foundation

/// The install command the setup flow hands over, and the password logic around
/// it. A password only works if both sides carry the same one, so the app mints
/// it, embeds it in the command the user is about to run, and adopts it into
/// its own field the moment the command is taken away. Shared so every client's
/// first run makes the same argument with the same command.
public enum BridgeInstall {
    /// The one command that installs or updates a bridge: clone, build, config,
    /// and a service that survives a reboot. Bare, for surfaces that update an
    /// existing install; the setup flow bakes its minted password in instead.
    public static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash"

    /// The same one command for the other agent: opencode itself if the machine hasn't got it, a
    /// service that survives a reboot, and the check that keeps its model list current. That last
    /// part is not a nicety — a long-lived `opencode serve` resolves its providers once, at
    /// startup, so a model a plan gained today reaches no client at all until somebody restarts
    /// the server by hand, which nobody knows to do.
    public static let opencodeInstallCommand =
        "curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash"

    public static func command(for backend: AgentType, password: String) -> String {
        switch backend {
        case .openCode:
            return
                "curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | OPENCODE_SERVER_PASSWORD=\(password) bash"
        case .claudeCode:
            return
                "curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | BRIDGE_PASSWORD=\(password) bash"
        }
    }

    public static func makePassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzACDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in alphabet.randomElement() ?? "x" })
    }

    /// Pulls a password out of whatever was pasted: the whole
    /// `BRIDGE_PASSWORD=… claude-bridge` line off the other machine's terminal
    /// carries it, so take it rather than making the user retype.
    public static func password(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let separator = token.range(of: "="),
                token[token.startIndex..<separator.lowerBound].uppercased().hasSuffix("PASSWORD")
            else { continue }
            let value = token[separator.upperBound...].trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }
}
