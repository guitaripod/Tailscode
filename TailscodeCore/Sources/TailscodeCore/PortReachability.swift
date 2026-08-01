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

#else

import Foundation
import Glibc

/// The Linux half: a non-blocking POSIX connect distinguishes the same three answers Network
/// framework does — the port refused (nothing listening), silence (asleep or off the tailnet),
/// and a name that never resolved (MagicDNS off).
public enum PortReachability {
    public enum Verdict: Sendable, Equatable {
        case listening
        case refused
        case timedOut
        case nameNotResolved
    }

    public static func check(
        host: String, port: UInt16, timeout: Duration = .seconds(3)
    ) async -> Verdict {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        return await Task.detached(priority: .userInitiated) {
            probe(host: host, port: port, timeout: seconds)
        }.value
    }

    private static func probe(host: String, port: UInt16, timeout: Double) -> Verdict {
        var hints = addrinfo()
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &results) == 0, let first = results else {
            return .nameNotResolved
        }
        defer { freeaddrinfo(results) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return .timedOut }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connected = connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if connected == 0 { return .listening }
        guard errno == EINPROGRESS else {
            return errno == ECONNREFUSED ? .refused : .timedOut
        }

        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, Int32(timeout * 1000))
        guard ready > 0 else { return .timedOut }

        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else {
            return .timedOut
        }
        switch soError {
        case 0: return .listening
        case ECONNREFUSED, ECONNRESET: return .refused
        default: return .timedOut
        }
    }
}

#endif
