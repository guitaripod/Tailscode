import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// One naming convention for servers everywhere they appear: the machine name the user chose,
/// the agent it runs spelled out, and addresses without URL scheme noise. Two agents on one
/// machine share a name and differ by agent, so the name alone never has to encode both.
public enum ServerLabel {
    public static func agent(_ backend: AgentType) -> String {
        switch backend {
        case .openCode: return "opencode"
        case .claudeCode: return "Claude Code"
        case .omp: return "Oh My Pi"
        }
    }

    public static func display(name: String, backend: AgentType) -> String {
        let agent = agent(backend)
        guard name.range(of: agent, options: .caseInsensitive) == nil else { return name }
        return "\(name) · \(agent)"
    }

    public static func display(_ profile: ConnectionProfile) -> String {
        display(name: profile.name, backend: profile.backend)
    }

    public static func address(_ profile: ConnectionProfile) -> String {
        guard let host = profile.baseURL.host else { return profile.baseURL.absoluteString }
        guard let port = profile.baseURL.port else { return host }
        return "\(host):\(port)"
    }
}
