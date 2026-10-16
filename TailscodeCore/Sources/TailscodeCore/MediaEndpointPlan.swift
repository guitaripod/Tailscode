import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Where the renderer probably is, before anybody has said. The machine that runs the agent is
/// overwhelmingly the machine with the card, and ComfyUI answers on 8188 unless told otherwise, so
/// the first guess is the server's own host on that port — found by asking, never by typing.
public enum MediaEndpointPlan {
    public enum Origin: Sendable, Equatable {
        case perProfile
        case derived
    }

    public struct Choice: Sendable, Equatable {
        public let endpoint: ForgeEndpoint
        public let profileID: String
        public let profileName: String
        public let origin: Origin

        public var renderer: ForgeRenderer { ForgeRenderer(endpoint: endpoint) }
    }

    /// The renderer for a server: the one filed against that server, else its own host. A demo
    /// server has no machine behind it, so it never suggests one.
    public static func choose(
        profiles: [ConnectionProfile], preferring id: String? = nil,
        filed: (String) -> ForgeEndpoint? = { ForgeStore.endpoint(forProfile: $0) }
    ) -> Choice? {
        let real = profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        let ordered = real.filter { $0.id == id } + real.filter { $0.id != id }
        for profile in ordered {
            if let kept = filed(profile.id) {
                return Choice(
                    endpoint: kept, profileID: profile.id, profileName: profile.name, origin: .perProfile)
            }
            guard let host = profile.baseURL.host, !host.isEmpty else { continue }
            return Choice(
                endpoint: ForgeEndpoint(host: host), profileID: profile.id, profileName: profile.name,
                origin: .derived)
        }
        return nil
    }

    /// Whether a verdict is enough to keep a guess: ComfyUI answering, or starting up behind a
    /// socket that already accepts. A machine that answers nothing keeps nothing filed, so a wrong
    /// guess never opens a picture lane that has no machine behind it.
    public static func confirms(_ verdict: MediaVerdict) -> Bool {
        switch verdict.comfy {
        case .answering, .starting: return true
        case .refused, .loopbackOnly, .timedOut, .unresolved, .notComfy: return false
        }
    }
}
