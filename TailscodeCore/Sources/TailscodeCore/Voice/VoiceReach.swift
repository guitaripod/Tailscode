import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a server's gateway says about calling, read from `GET /health`. Every state that is not
/// `ready` carries a reason a person can act on, written once in `VoiceCallReading`.
public enum VoiceReach: Sendable, Equatable {
    case unknown
    case checking
    case ready(gateway: String)
    case stopped(gateway: String)
    case needsSetup
    case loading
    case busy
    case noGateway
    case tooOld(protocol: Int)
    case engineDown(detail: String?)
    case wantsPassword
    case unreachable(String)

    public var canStart: Bool {
        switch self {
        case .ready, .stopped: return true
        default: return false
        }
    }

    public var asksForPassword: Bool { self == .wantsPassword }

    /// The one line that says why a call can or cannot start.
    public var line: String { VoiceCallReading.reason(for: self) }

    public var tone: ActivityTone {
        switch self {
        case .unknown, .checking, .stopped: return .quiet
        case .ready: return .live
        case .loading, .busy, .wantsPassword, .needsSetup: return .attention
        case .noGateway, .tooOld, .engineDown, .unreachable: return .danger
        }
    }

    public var gateway: String? {
        switch self {
        case .ready(let gateway), .stopped(let gateway): return gateway
        default: return nil
        }
    }
}

public struct VoiceHTTPAnswer: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// One GET, so a test can answer a health check without a network and a platform can bring its own.
public protocol VoiceHealthFetching: Sendable {
    func get(_ url: URL, bearer: String?, timeout: TimeInterval) async throws -> VoiceHTTPAnswer
}

public struct URLSessionVoiceHealthFetcher: VoiceHealthFetching {
    public init() {}

    public func get(_ url: URL, bearer: String?, timeout: TimeInterval) async throws -> VoiceHTTPAnswer {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return VoiceHTTPAnswer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// Asks a gateway whether a call can start. It never throws: every failure is a `VoiceReach`.
public struct VoiceReachProbe: Sendable {
    public static let timeout: TimeInterval = 2

    private let fetcher: any VoiceHealthFetching
    private let timeout: TimeInterval

    public init(fetcher: any VoiceHealthFetching = URLSessionVoiceHealthFetcher(), timeout: TimeInterval = VoiceReachProbe.timeout) {
        self.fetcher = fetcher
        self.timeout = timeout
    }

    public func read(_ endpoint: VoiceEndpoint, bearer: String? = nil) async -> VoiceReach {
        if endpoint.isDemo { return .ready(gateway: VoiceDemo.gatewayVersion) }
        do {
            let answer = try await withinDeadline {
                try await fetcher.get(endpoint.healthURL, bearer: bearer, timeout: timeout)
            }
            return Self.reading(answer)
        } catch {
            return Self.reading(error)
        }
    }

    public static func reading(_ answer: VoiceHTTPAnswer) -> VoiceReach {
        switch answer.status {
        case 200:
            guard let health = try? JSONDecoder().decode(VoiceHealth.self, from: answer.body) else {
                return .noGateway
            }
            return reading(health)
        case 401, 403:
            return .wantsPassword
        case 404:
            return .noGateway
        default:
            return .unreachable(VoiceCallReading.httpStatus(answer.status))
        }
    }

    public static func reading(_ health: VoiceHealth) -> VoiceReach {
        guard health.protocolVersion == VoiceWire.version else {
            return .tooOld(protocol: health.protocolVersion)
        }
        switch health.engine {
        case .ready: return .ready(gateway: health.gateway)
        case .stopped: return .stopped(gateway: health.gateway)
        case .needsSetup: return .needsSetup
        case .loading: return .loading
        case .busy: return .busy
        case .down: return .engineDown(detail: health.detail.flatMap { $0.isEmpty ? nil : VoiceText.ascii($0) })
        }
    }

    public static func reading(_ error: Error) -> VoiceReach {
        if error is VoiceDeadline { return .unreachable(VoiceCallReading.timedOut) }
        guard let failure = error as? URLError else { return .unreachable(error.localizedDescription) }
        switch failure.code {
        case .cannotConnectToHost:
            return .noGateway
        case .timedOut:
            return .unreachable(VoiceCallReading.timedOut)
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return .unreachable(VoiceCallReading.machineUnreachable)
        default:
            return .unreachable(failure.localizedDescription)
        }
    }

    private func withinDeadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let limit = timeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                throw VoiceDeadline()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VoiceDeadline() }
            return first
        }
    }
}

struct VoiceDeadline: Error {}
