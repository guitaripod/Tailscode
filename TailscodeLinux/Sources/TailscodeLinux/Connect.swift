import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `tailscode --connect <address> [--password <pw>] [--name <label>] [--opencode|--omp]` saves a
/// server so the installed app has one without anything in its environment.
///
/// The address is read the same way the phone reads one — a bare tailnet IP, a MagicDNS name, a
/// host:port, or a full URL — and the port is inferred from the backend when it is missing. The
/// server is probed before it is saved, so a typo fails here rather than becoming a row that never
/// loads.
enum Connect {
    static var isRequested: Bool { Arguments.contains("--connect") }

    static func run() async -> Never {
        let arguments = Arguments.all
        guard let index = arguments.firstIndex(of: "--connect"),
            index + 1 < arguments.count
        else {
            report(
                "usage: tailscode --connect <address> [--password <pw>] [--name <label>] [--opencode|--omp]"
            )
            exit(1)
        }
        let raw = arguments[index + 1]
        let backend: AgentType =
            arguments.contains("--omp")
            ? .omp : arguments.contains("--opencode") ? .openCode : .claudeCode
        let password = value(of: "--password", in: arguments)
            ?? ProcessInfo.processInfo.environment["TAILSCODE_PASSWORD"]

        guard case .address(let address) = HostAddress.read(
            raw, defaultPort: HostAddress.port(for: backend))
        else {
            report("that address did not read as a server: \(raw)")
            exit(1)
        }

        let profile = ConnectionProfile(
            id: UUID().uuidString,
            name: value(of: "--name", in: arguments) ?? address.displayHost,
            backend: backend,
            baseURL: address.url,
            username: ProbeSweep.username(for: backend))

        do {
            let probe = profile.makeBackend(password: password)
            let health = try await probe.health()
            let store = LinuxProfileStore()
            try store.save(profile, password: password)
            report("saved \(profile.name) — \(health.version ?? "connected")")
            exit(0)
        } catch {
            report("could not reach \(address.url.absoluteString): \(error)")
            exit(1)
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
