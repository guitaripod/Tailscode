import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Anything that is not a request to open a window is answered before AppKit starts. A Mac
/// reached over ssh has no window server, and `NSApplicationMain` blocks before it ever reaches
/// the delegate there — so the headless paths run on the main queue directly and the app is only
/// started when there is a screen to start it on.
enum MacCLI {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let usage = """
        tailscode-mac — drive your coding agents over Tailscale

          TailscodeMac                          open the window
          TailscodeMac --connect <address>      save a server (--password, --name, --opencode)
          TailscodeMac --selftest               check the whole chain with no display
          TailscodeMac --version
        """

    static let knownOptions: Set<String> = [
        "--selftest", "--connect", "--password", "--name", "--opencode",
        "--version", "--help", "-h",
    ]
}

/// `TailscodeMac --connect <address> [--password <pw>] [--name <label>] [--opencode]` saves a
/// server so the installed app has one without anything in its environment. The address is read
/// the same way the phone reads one, and the server is probed before it is saved — a typo fails
/// here, named, rather than becoming a row that never loads.
enum Connect {
    static var isRequested: Bool { CommandLine.arguments.contains("--connect") }

    static func run() async -> Never {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--connect"), index + 1 < arguments.count
        else {
            report(
                "usage: TailscodeMac --connect <address> [--password <pw>] [--name <label>] [--opencode]")
            exit(1)
        }
        let raw = arguments[index + 1]
        let backend: AgentType = arguments.contains("--opencode") ? .openCode : .claudeCode
        let password = value(of: "--password", in: arguments)
            ?? ProcessInfo.processInfo.environment["TAILSCODE_PASSWORD"]

        guard
            case .address(let address) = HostAddress.read(
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
            username: backend == .claudeCode ? "claude" : "opencode")

        do {
            let probe = profile.makeBackend(password: password)
            let health = try await ServerProbe.health(of: probe)
            let store = try ConnectionProfileStore()
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

if SelfTest.isRequested {
    Task { await SelfTest.run() }
    dispatchMain()
}

if CommandLine.arguments.contains("--version") {
    print("tailscode-mac \(MacCLI.version)")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(MacCLI.usage)
    exit(0)
}

if let stray = CommandLine.arguments.dropFirst().first(where: {
    $0.hasPrefix("-") && !MacCLI.knownOptions.contains($0)
}) {
    print("unknown option \(stray)\n\n\(MacCLI.usage)")
    exit(2)
}

if Connect.isRequested {
    Task { await Connect.run() }
    dispatchMain()
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
