import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Synchronization

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

    /// Asked for every row a list draws, of a handful of servers, so each answer is kept: the
    /// case-insensitive search behind it was a tenth of Home's refresh on an iPhone XS.
    public static func display(name: String, backend: AgentType) -> String {
        let key = "\(backend.rawValue)\u{1}\(name)"
        if let known = displays.withLock({ $0[key] }) { return known }
        let agent = agent(backend)
        let label = name.range(of: agent, options: .caseInsensitive) == nil ? "\(name) · \(agent)" : name
        displays.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[key] = label
        }
        return label
    }

    private static let displays = Mutex<[String: String]>([:])

    public static func display(_ profile: ConnectionProfile) -> String {
        display(name: profile.name, backend: profile.backend)
    }

    public static func address(_ profile: ConnectionProfile) -> String {
        guard let host = profile.baseURL.host else { return profile.baseURL.absoluteString }
        guard let port = profile.baseURL.port else { return host }
        return "\(host):\(port)"
    }
}
