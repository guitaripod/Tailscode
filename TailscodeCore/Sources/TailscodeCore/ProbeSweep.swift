import CodingAgentKit
import Foundation

/// The whole "which agent answers this address" question, asked properly: every candidate URL
/// from `HostAddress.probeCandidates()`, each probed with the username retry claude-bridge
/// demands, ranked so the most informative answer wins. One `health()` call against one guessed
/// port — what the desktop add-server dialogs used to do — cannot tell "wrong port" from "not
/// running" from "wants a password"; this can.
public enum ProbeSweep {
    public static let interactivePolicy = ConnectionPolicy(
        requestTimeout: .seconds(10), resourceTimeout: .seconds(15))
    /// A probe fired while the user is still typing needs a much shorter leash than one they
    /// asked for.
    public static let typingPolicy = ConnectionPolicy(
        requestTimeout: .seconds(4), resourceTimeout: .seconds(6))

    public struct Verdict: Sendable {
        public let url: URL
        public let outcome: ConnectionProbe.Outcome
    }

    public static func username(for backend: AgentType) -> String {
        backend == .openCode ? "opencode" : "claude"
    }

    /// Retries with the other backend's Basic-auth username on `.authFailed`: the caller's
    /// backend may be a port guess, and claude-bridge rejects a correct password sent under the
    /// wrong username.
    public static func probe(
        baseURL: URL, password: String?, preferring backend: AgentType,
        policy: ConnectionPolicy, retryUnreachable: Bool
    ) async -> ConnectionProbe.Outcome {
        guard let password, !password.isEmpty else {
            return await ConnectionProbe().probe(
                baseURL: baseURL, credentials: nil, policy: policy,
                retryUnreachable: retryUnreachable)
        }
        let outcome = await ConnectionProbe().probe(
            baseURL: baseURL,
            credentials: BasicCredentials(username: username(for: backend), password: password),
            policy: policy, retryUnreachable: retryUnreachable)
        guard case .authFailed = outcome else { return outcome }
        let other: AgentType = backend == .openCode ? .claudeCode : .openCode
        return await ConnectionProbe().probe(
            baseURL: baseURL,
            credentials: BasicCredentials(username: username(for: other), password: password),
            policy: policy, retryUnreachable: retryUnreachable)
    }

    /// Probes every candidate and keeps the most informative verdict, stopping early once an
    /// answer settles the question — an agent answered, or something demanded a password.
    public static func best(
        address: HostAddress, password: String?, preferring backend: AgentType,
        policy: ConnectionPolicy = interactivePolicy, retryUnreachable: Bool = true
    ) async -> Verdict {
        var best = Verdict(url: address.url, outcome: .unreachable(""))
        var bestRank = -1
        for url in address.probeCandidates() {
            let outcome = await probe(
                baseURL: url, password: password, preferring: backend,
                policy: policy, retryUnreachable: retryUnreachable)
            let rank = Self.rank(outcome)
            if rank > bestRank {
                best = Verdict(url: url, outcome: outcome)
                bestRank = rank
            }
            switch outcome {
            case .ok, .authFailed: return best
            case .unreachable, .notAnAgentServer: continue
            }
        }
        return best
    }

    private static func rank(_ outcome: ConnectionProbe.Outcome) -> Int {
        switch outcome {
        case .ok: return 3
        case .authFailed: return 2
        case .notAnAgentServer: return 1
        case .unreachable: return 0
        }
    }
}
