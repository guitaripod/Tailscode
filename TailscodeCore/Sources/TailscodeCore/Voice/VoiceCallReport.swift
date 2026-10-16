import CodingAgentKit
import Foundation

/// The lines a call adds to a beta report: where the gateway is, what it said last, how the last
/// call ended. Plain English in every language, like the rest of the report.
public enum VoiceCallReport {
    public static func lines(endpoint: VoiceEndpoint, reach: VoiceReach, end: VoiceCallEnd? = nil) -> [String] {
        var lines = [
            "Gateway: \(endpoint.address)",
            "Protocol: \(VoiceWire.version)",
            "Gateway state: \(state(reach))",
        ]
        if let version = reach.gateway { lines.append("Gateway version: \(version)") }
        if let end { lines.append("Last call: \(outcome(end))") }
        return lines
    }

    private static func state(_ reach: VoiceReach) -> String {
        switch reach {
        case .unknown: return "not checked"
        case .checking: return "checking"
        case .ready: return "ready"
        case .stopped: return "model stopped, starts on demand"
        case .needsSetup: return "needs setup"
        case .loading: return "model loading"
        case .busy: return "busy"
        case .noGateway: return "no gateway"
        case .tooOld(let version): return "protocol \(version)"
        case .engineDown(let detail): return detail.map { "model down (\($0))" } ?? "model down"
        case .wantsPassword: return "wants a password"
        case .unreachable(let why): return "unreachable (\(why))"
        }
    }

    private static func outcome(_ end: VoiceCallEnd) -> String {
        switch end {
        case .hungUp: return "hung up"
        case .replaced: return "replaced by another call"
        case .lost: return "connection lost"
        case .couldNotConnect(let why): return "could not connect (\(why))"
        case .microphoneDenied: return "microphone denied"
        case .audioUnavailable(let why): return "audio unavailable (\(why))"
        case .gateway(let code, let message): return "gateway ended it (\(code): \(message))"
        }
    }
}
