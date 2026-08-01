#if canImport(Network)

import Foundation
import Network

/// Why a probe got nothing. An HTTP request that fails cannot tell "the machine
/// refused the port" (the agent isn't running) from "the machine never answered"
/// (asleep, or not on the tailnet) from "that name doesn't resolve" (MagicDNS is
/// off) — and those are three different things to tell the user. A raw TCP
/// connect can.
public enum PortReachability {
    public enum Verdict: Sendable, Equatable {
        case listening
        case refused
        case timedOut
        case nameNotResolved
    }

    public static func check(host: String, port: UInt16, timeout: Duration = .seconds(3)) async -> Verdict {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .timedOut }
        let (stream, continuation) = AsyncStream<Verdict>.makeStream()
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield(.listening)
                continuation.finish()
            case .waiting(let error), .failed(let error):
                continuation.yield(verdict(for: error))
                continuation.finish()
            case .cancelled:
                continuation.finish()
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        let expiry = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(.timedOut)
            continuation.finish()
        }
        var outcome = Verdict.timedOut
        for await value in stream {
            outcome = value
            break
        }
        expiry.cancel()
        connection.cancel()
        return outcome
    }

    private static func verdict(for error: NWError) -> Verdict {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .ECONNRESET: return .refused
            default: return .timedOut
            }
        case .dns: return .nameNotResolved
        default: return .timedOut
        }
    }
}

#endif
