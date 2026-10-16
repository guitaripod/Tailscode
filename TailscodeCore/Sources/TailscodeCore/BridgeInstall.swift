import CodingAgentKit
import Foundation

/// The install command the setup flow hands over, and the password logic around
/// it. Where a machine trusts the tailnet there is no password at all (`needsPassword`); where it
/// cannot, a password only works if both sides carry the same one, so the app mints it, embeds it
/// in the command the user is about to run, and adopts it into its own field the moment the
/// command is taken away. Shared so every client's first run makes the same argument with the
/// same command.
public enum BridgeInstall {
    /// Whether the install command must carry a password for this agent.
    ///
    /// claude-bridge asks tailscaled who is on the other end of a connection and admits a node
    /// signed into the machine's own Tailscale account without one (`BRIDGE_TAILNET_AUTH`, default
    /// `same-user`; the gate arrived in commit e4194a2 of 2026-08-31 and is in every tag from
    /// 1.7.2). omp-bridge 0.8 has no such gate and refuses to start without `OMP_PASSWORD`;
    /// opencode has none either, and opencode 2 always wants `OPENCODE_SERVER_PASSWORD`. A fresh
    /// install always fetches the current claude-bridge, so the first-run command never meets a
    /// build older than the gate; a machine that already runs an older one is met by the probe
    /// answering 401 and the password step that follows it.
    public static func needsPassword(_ agent: AgentType) -> Bool {
        switch agent {
        case .claudeCode: return false
        case .omp, .openCode: return true
        }
    }

    public struct Install: Sendable, Equatable {
        public let agent: AgentType
        public let command: String
        /// The password the command sets, or nil where the machine admits this tailnet without one.
        public let password: String?

        public init(agent: AgentType, command: String, password: String?) {
            self.agent = agent
            self.command = command
            self.password = password
        }
    }

    /// The command a first run shows for `agent`, minting a password only where `needsPassword`.
    public static func install(for agent: AgentType, password: String? = nil) -> Install {
        guard needsPassword(agent) else {
            return Install(agent: agent, command: installCommand, password: nil)
        }
        let secret = password ?? makePassword()
        return Install(agent: agent, command: command(for: agent, password: secret), password: secret)
    }

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
        case .omp:
            return
                "curl -fsSL https://raw.githubusercontent.com/guitaripod/omp-bridge/master/install.sh | OMP_REPO=https://github.com/guitaripod/omp-bridge OMP_PASSWORD=\(password) bash"
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
