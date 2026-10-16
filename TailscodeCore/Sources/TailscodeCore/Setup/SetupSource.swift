import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct SetupHTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    public let method: Method
    public let url: URL
    public let bearer: String?
    public let body: Data?
    public let timeout: TimeInterval

    public init(method: Method, url: URL, bearer: String? = nil, body: Data? = nil, timeout: TimeInterval = 4) {
        self.method = method
        self.url = url
        self.bearer = bearer
        self.body = body
        self.timeout = timeout
    }
}

/// One request and its answer, so a test can play a daemon without a network and a platform can bring
/// its own transport.
public protocol SetupHTTPFetching: Sendable {
    func send(_ request: SetupHTTPRequest) async throws -> VoiceHTTPAnswer
}

public struct URLSessionSetupHTTP: SetupHTTPFetching {
    public init() {}

    public func send(_ request: SetupHTTPRequest) async throws -> VoiceHTTPAnswer {
        var built = URLRequest(url: request.url, timeoutInterval: request.timeout)
        built.httpMethod = request.method.rawValue
        if let bearer = request.bearer, !bearer.isEmpty {
            built.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body = request.body {
            built.httpBody = body
            built.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: built)
        return VoiceHTTPAnswer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// What asking a machine for a capability's report came to. A machine that does not answer at all is
/// `absent` when nothing is listening there (the daemon was never installed, which is a fact the
/// checklist turns into the one command that installs it) and `unreachable` when the machine itself
/// cannot be spoken to.
public enum SetupSourceAnswer: Sendable, Equatable {
    case report(SetupReport)
    case absent(SetupReport)
    case wantsPassword
    case unreachable(String)
}

public enum SetupSourceError: Error, Sendable, Equatable {
    case wantsPassword
    case unreachable(String)
    case refused(String)
    case gone
}

/// Where one capability's report comes from and how its fixes run. The daemon's own HTTP is one
/// source (`VoiceSetupSource`); a check the client runs itself is another, registered by whoever owns
/// that capability, and a demo host has a scripted one.
public protocol SetupSource: Sendable {
    var capability: String { get }

    func report(for target: SetupTarget) async -> SetupSourceAnswer
    func start(fix: String, for target: SetupTarget) async throws -> SetupJob
    func job(id: String, for target: SetupTarget) async throws -> SetupJob
    func cancel(job id: String, for target: SetupTarget) async throws
}

/// The voice gateway's `/setup`, `/setup/fix` and `/setup/jobs/{id}` on its own port, asked the way
/// its `/health` is: with the password this device holds for that machine, if any.
public struct VoiceSetupSource: SetupSource {
    public let capability = SetupCapability.voice

    private let http: any SetupHTTPFetching
    private let password: @Sendable (VoiceEndpoint) -> String?

    public init(http: any SetupHTTPFetching = URLSessionSetupHTTP(), password: @escaping @Sendable (VoiceEndpoint) -> String?) {
        self.http = http
        self.password = password
    }

    public func report(for target: SetupTarget) async -> SetupSourceAnswer {
        let endpoint = Self.endpoint(of: target)
        do {
            let answer = try await http.send(request(.get, SetupWire.setupPath, endpoint))
            switch answer.status {
            case 200:
                return decodeReport(answer.body) ?? .unreachable(VoiceCallReading.httpStatus(answer.status))
            case 401, 403:
                return .wantsPassword
            case 404:
                return await olderOrAbsent(endpoint)
            default:
                return .unreachable(VoiceCallReading.httpStatus(answer.status))
            }
        } catch {
            return Self.answer(for: error)
        }
    }

    public func start(fix: String, for target: SetupTarget) async throws -> SetupJob {
        let endpoint = Self.endpoint(of: target)
        let body = try SetupCodec.encode(SetupFixRequest(fix: fix))
        let answer = try await send(request(.post, SetupWire.fixPath, endpoint, body: body))
        guard let job = try? SetupCodec.decode(SetupJob.self, from: answer.body) else {
            throw SetupSourceError.refused(VoiceCallReading.httpStatus(answer.status))
        }
        return job
    }

    public func job(id: String, for target: SetupTarget) async throws -> SetupJob {
        let endpoint = Self.endpoint(of: target)
        let answer = try await send(request(.get, "\(SetupWire.jobsPath)/\(id)", endpoint))
        guard let job = try? SetupCodec.decode(SetupJob.self, from: answer.body) else {
            throw SetupSourceError.refused(VoiceCallReading.httpStatus(answer.status))
        }
        return job
    }

    public func cancel(job id: String, for target: SetupTarget) async throws {
        let endpoint = Self.endpoint(of: target)
        _ = try await send(request(.delete, "\(SetupWire.jobsPath)/\(id)", endpoint))
    }

    public static func endpoint(of target: SetupTarget) -> VoiceEndpoint {
        VoiceEndpoint(host: target.host, port: target.port ?? VoiceWire.port)
    }

    /// The synthetic report of a machine with no gateway: one open check whose only fix is the
    /// command that installs it.
    public static func absentReport() -> SetupReport {
        SetupReport(
            capability: SetupCapability.voice, available: true, ready: false,
            checks: [
                SetupCheck(
                    id: "voice.gateway", state: .todo,
                    fix: SetupFix(
                        id: VoiceBridgeInstall.installFixID, kind: .command, command: VoiceBridgeInstall.installCommand))
            ])
    }

    public static func outdatedReport(version: String) -> SetupReport {
        SetupReport(
            capability: SetupCapability.voice, available: true, ready: false,
            checks: [
                SetupCheck(
                    id: "voice.gateway", state: .todo, facts: ["version": version],
                    fix: SetupFix(
                        id: VoiceBridgeInstall.installFixID, kind: .command, command: VoiceBridgeInstall.installCommand))
            ])
    }

    private func olderOrAbsent(_ endpoint: VoiceEndpoint) async -> SetupSourceAnswer {
        do {
            let answer = try await http.send(request(.get, VoiceWire.healthPath, endpoint))
            guard answer.status == 200 else { return .absent(Self.absentReport()) }
            let version = (try? JSONDecoder().decode(VoiceHealth.self, from: answer.body))?.gateway
            return .absent(version.map(Self.outdatedReport) ?? Self.absentReport())
        } catch {
            return Self.answer(for: error)
        }
    }

    private func decodeReport(_ body: Data) -> SetupSourceAnswer? {
        let reports = (try? SetupCodec.decode([SetupReport].self, from: body))
            ?? (try? SetupCodec.decode(SetupReport.self, from: body)).map { [$0] }
        guard let reports else { return nil }
        guard let voice = reports.first(where: { $0.capability == capability }) else { return nil }
        return .report(voice)
    }

    private func request(_ method: SetupHTTPRequest.Method, _ path: String, _ endpoint: VoiceEndpoint, body: Data? = nil)
        -> SetupHTTPRequest
    {
        var components = URLComponents()
        components.scheme = "http"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = path
        return SetupHTTPRequest(
            method: method, url: components.url ?? endpoint.healthURL, bearer: password(endpoint), body: body)
    }

    private func send(_ request: SetupHTTPRequest) async throws -> VoiceHTTPAnswer {
        let answer: VoiceHTTPAnswer
        do {
            answer = try await http.send(request)
        } catch {
            throw Self.failure(for: error)
        }
        switch answer.status {
        case 200..<300: return answer
        case 401, 403: throw SetupSourceError.wantsPassword
        case 404: throw SetupSourceError.gone
        default: throw SetupSourceError.refused(VoiceCallReading.httpStatus(answer.status))
        }
    }

    static func answer(for error: Error) -> SetupSourceAnswer {
        guard let failure = error as? URLError else { return .unreachable(error.localizedDescription) }
        switch failure.code {
        case .cannotConnectToHost: return .absent(absentReport())
        case .timedOut: return .unreachable(VoiceCallReading.timedOut)
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return .unreachable(SetupReading.unreachableAdvice)
        default: return .unreachable(failure.localizedDescription)
        }
    }

    static func failure(for error: Error) -> SetupSourceError {
        if case .unreachable(let why) = answer(for: error) { return .unreachable(why) }
        return .unreachable(SetupReading.unreachableAdvice)
    }
}
