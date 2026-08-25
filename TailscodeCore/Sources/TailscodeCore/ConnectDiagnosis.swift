import CodingAgentKit
import Foundation

/// Turns a probe outcome into the one thing that is actually wrong and the one
/// tap that fixes it. A failed connection used to read `Unreachable: <URLError>`,
/// which blames the server for what is usually a VPN toggle on this machine.
/// Toolkit-free: `symbol` is an SF Symbols name that desktop clients map to
/// their own glyphs, and `fix` is an intent each client wires to its own door.
public struct ConnectDiagnosis: Equatable, Sendable {
    public enum Fix: Equatable, Sendable {
        case none
        case openTailscale
        case openAppSettings
        case retry
        case retryOtherPort(URL)
        case usePlainHTTP(URL)
        case revealPassword
        case seePro
        /// The thing that is wrong is on the other machine, and what fixes it is a line run there.
        /// The client puts it on the clipboard and says so — never an instruction to go and read
        /// somebody's documentation, which is what "start it there" used to mean.
        case copyCommand(String)
    }

    public let symbol: String
    public let title: String
    public let detail: String
    public let fix: Fix
    public let actionTitle: String?

    public init(symbol: String, title: String, detail: String, fix: Fix, actionTitle: String?) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.fix = fix
        self.actionTitle = actionTitle
    }

    public static func make(
        outcome: ConnectionProbe.Outcome,
        address: HostAddress,
        tailnetAddress: String?,
        alternatePort: URL?,
        sentPassword: Bool,
        reachability: PortReachability.Verdict?,
        deviceName: String = Localized.text("This device"),
        offersLocalNetworkSettings: Bool = false
    ) -> ConnectDiagnosis? {
        switch outcome {
        case .ok:
            return nil
        case .authFailed:
            guard sentPassword else {
                return ConnectDiagnosis(
                    symbol: "lock",
                    title: Localized.text("This server wants a password"),
                    detail: Localized.text(
                        "Good news: something is answering at %@. Enter the password it was started with — for claude-bridge that is BRIDGE_PASSWORD.",
                        address.displayHost),
                    fix: .revealPassword,
                    actionTitle: nil)
            }
            return ConnectDiagnosis(
                symbol: "lock.trianglebadge.exclamationmark",
                title: Localized.text("That password was rejected"),
                detail: Localized.text(
                    "The server answered, so the address is right. claude-bridge wants the password you passed as BRIDGE_PASSWORD; opencode needs none unless you set one."
                ),
                fix: .revealPassword,
                actionTitle: nil)
        case .notAnAgentServer:
            if address.url.scheme == "https", let plain = plainHTTP(for: address.url) {
                return httpsDiagnosis(plain: plain)
            }
            let detail = Localized.text(
                "Something is listening on %@, but it isn't an agent this app knows. opencode serves 4096, claude-bridge 4098, omp-bridge 4099.",
                address.displayHost)
            if let alternatePort, let port = alternatePort.port {
                return ConnectDiagnosis(
                    symbol: "questionmark.app",
                    title: Localized.text("That isn't an agent server"),
                    detail: detail,
                    fix: .retryOtherPort(alternatePort),
                    actionTitle: Localized.text("Try port %@", "\(port)"))
            }
            return ConnectDiagnosis(
                symbol: "questionmark.app",
                title: Localized.text("That isn't an agent server"),
                detail: detail,
                fix: .retry,
                actionTitle: Localized.text("Try again"))
        case .unreachable:
            if address.url.scheme == "https", let plain = plainHTTP(for: address.url) {
                return httpsDiagnosis(plain: plain)
            }
            if tailnetAddress == nil { return offTailnet(deviceName: deviceName) }
            switch reachability {
            case .refused:
                return ConnectDiagnosis(
                    symbol: "bolt.horizontal.circle",
                    title: Localized.text("Nothing is listening on %@", address.displayHost),
                    detail: Localized.text(
                        "The machine is reachable, so the address is right — but no agent is bound to that port. Start it there, and make sure it binds 0.0.0.0 rather than localhost."
                    ),
                    fix: .retry,
                    actionTitle: Localized.text("Try again"))
            case .nameNotResolved:
                return unresolvable(
                    deviceName: deviceName,
                    host: address.url.host ?? Localized.text("that name"))
            case .listening:
                return ConnectDiagnosis(
                    symbol: "questionmark.app",
                    title: Localized.text("%@ answered, but not as an agent", address.displayHost),
                    detail: Localized.text(
                        "The port is open and something is on it, yet it didn't respond as a known agent. Check the port — 4096 opencode, 4098 claude-bridge, 4099 omp-bridge."
                    ),
                    fix: alternatePort.map { .retryOtherPort($0) } ?? .retry,
                    actionTitle: alternatePort?.port.map { Localized.text("Try port %@", "\($0)") }
                        ?? Localized.text("Try again"))
            case .timedOut, .none:
                if offersLocalNetworkSettings, address.isPrivateRange {
                    return ConnectDiagnosis(
                        symbol: "network.slash",
                        title: Localized.text("No answer from %@", address.displayHost),
                        detail: Localized.text(
                            "That is a local-network address. If Local Network access is off for Tailscode, every attempt fails as a timeout — check it in Settings, or use the machine's 100.x tailnet address instead."
                        ),
                        fix: .openAppSettings,
                        actionTitle: Localized.text("Open Settings"))
                }
                return noAnswer(deviceName: deviceName, displayHost: address.displayHost)
            }
        }
    }

    /// The one condition that makes every probe fail identically however right the address is. Said
    /// in one place because the agent connection and the renderer fail the same way when this
    /// machine is not on the tailnet at all, and two wordings would read as two problems.
    public static func offTailnet(deviceName: String) -> ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "wifi.exclamationmark",
            title: Localized.text("%@ isn't on your tailnet", deviceName),
            detail: Localized.text(
                "Nothing can answer until Tailscale is connected here. Open it, sign in to the same account as your other machine, then come back."
            ),
            fix: .openTailscale,
            actionTitle: Localized.text("Open Tailscale"))
    }

    static func unresolvable(deviceName: String, host: String) -> ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "questionmark.circle",
            title: Localized.text("Can't resolve that name"),
            detail: Localized.text(
                "%@ can't turn %@ into an address. MagicDNS may be off — use the machine's 100.x address instead.",
                deviceName, host),
            fix: .retry,
            actionTitle: Localized.text("Try again"))
    }

    static func noAnswer(deviceName: String, displayHost: String) -> ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "moon.zzz",
            title: Localized.text("No answer from %@", displayHost),
            detail: Localized.text(
                "%@ is on the tailnet but that machine never replied. It may be asleep, offline, or signed into a different tailnet.",
                deviceName),
            fix: .retry,
            actionTitle: Localized.text("Try again"))
    }
}

extension ConnectDiagnosis {
    /// The same service for the renderer, asked of a raw port rather than of an agent.
    ///
    /// ComfyUI is not an agent server and never answers a `health()`, so the only question that can
    /// be asked of it cheaply is whether the port is open — which is exactly the question
    /// `PortReachability` exists to answer, and exactly the three failures the server flow already
    /// explains. Two of the three sentences are therefore literally the server flow's, because they
    /// are true of any machine on a tailnet; only the refusal is the renderer's own, and it is the
    /// one that matters — a port refusing on a machine that is up means ComfyUI is not running
    /// there, or is bound to localhost where nothing else can see it.
    public static func forge(
        verdict: PortReachability.Verdict, endpoint: ForgeEndpoint, tailnet: TailscaleReading?,
        deviceName: String = Localized.text("This device")
    ) -> ConnectDiagnosis? {
        switch verdict {
        case .listening:
            return nil
        case .nameNotResolved:
            return unresolvable(deviceName: deviceName, host: endpoint.host)
        case .refused:
            return ConnectDiagnosis(
                symbol: "bolt.horizontal.circle",
                title: Localized.text("Nothing is rendering on %@", endpoint.host),
                detail: Localized.text(
                    "The machine answered, so the address is right — but nothing is listening on %@. Start ComfyUI there, and make sure it binds 0.0.0.0 rather than localhost.",
                    "\(endpoint.port)"),
                fix: .copyCommand(ForgeSetup.startCommand),
                actionTitle: ForgeSetup.startCommandTitle)
        case .timedOut:
            if let tailnet, !tailnet.isUp { return offTailnet(deviceName: deviceName) }
            return noAnswer(deviceName: deviceName, displayHost: endpoint.displayHost)
        }
    }

    private static func httpsDiagnosis(plain: URL) -> ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "lock.slash",
            title: Localized.text("https can't work here"),
            detail: Localized.text(
                "A tailnet address can't present a certificate for itself, so TLS fails before the agent is reached. Tailscale already encrypts the link."
            ),
            fix: .usePlainHTTP(plain),
            actionTitle: Localized.text("Use http instead"))
    }

    private static func plainHTTP(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "http"
        return components.url
    }
}
