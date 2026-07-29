import CodingAgentKit
import Foundation

/// Turns a probe outcome into the one thing that is actually wrong and the one
/// tap that fixes it. A failed connection used to read `Unreachable: <URLError>`,
/// which blames the server for what is usually a VPN toggle on the phone.
struct ConnectDiagnosis: Equatable {
    enum Fix: Equatable {
        case none
        case openTailscale
        case openAppSettings
        case retry
        case retryOtherPort(URL)
        case usePlainHTTP(URL)
        case revealPassword
        case seePro
    }

    let symbol: String
    let title: String
    let detail: String
    let fix: Fix
    let actionTitle: String?

    static func make(
        outcome: ConnectionProbe.Outcome,
        address: HostAddress,
        tailnetAddress: String?,
        alternatePort: URL?,
        sentPassword: Bool,
        reachability: PortReachability.Verdict?
    ) -> ConnectDiagnosis? {
        switch outcome {
        case .ok:
            return nil
        case .authFailed:
            guard sentPassword else {
                return ConnectDiagnosis(
                    symbol: "lock",
                    title: String(localized: "This server wants a password"),
                    detail: String(
                        localized:
                            "Good news: something is answering at \(address.displayHost). Enter the password it was started with — for claude-bridge that is BRIDGE_PASSWORD."
                    ),
                    fix: .revealPassword,
                    actionTitle: nil)
            }
            return ConnectDiagnosis(
                symbol: "lock.trianglebadge.exclamationmark",
                title: String(localized: "That password was rejected"),
                detail: String(
                    localized:
                        "The server answered, so the address is right. claude-bridge wants the password you passed as BRIDGE_PASSWORD; opencode needs none unless you set one."
                ),
                fix: .revealPassword,
                actionTitle: nil)
        case .notAnAgentServer:
            if address.url.scheme == "https", let plain = plainHTTP(for: address.url) {
                return ConnectDiagnosis(
                    symbol: "lock.slash",
                    title: String(localized: "https can't work here"),
                    detail: String(
                        localized:
                            "A tailnet address can't present a certificate for itself, so TLS fails before the agent is reached. Tailscale already encrypts the link."
                    ),
                    fix: .usePlainHTTP(plain),
                    actionTitle: String(localized: "Use http instead"))
            }
            let detail = String(
                localized:
                    "Something is listening on \(address.displayHost), but it isn't opencode or claude-bridge. opencode serves port 4096, claude-bridge port 4098."
            )
            if let alternatePort, let port = alternatePort.port {
                return ConnectDiagnosis(
                    symbol: "questionmark.app",
                    title: String(localized: "That isn't an agent server"),
                    detail: detail,
                    fix: .retryOtherPort(alternatePort),
                    actionTitle: String(localized: "Try port \(port)"))
            }
            return ConnectDiagnosis(
                symbol: "questionmark.app",
                title: String(localized: "That isn't an agent server"),
                detail: detail,
                fix: .retry,
                actionTitle: String(localized: "Try again"))
        case .unreachable(let underlying):
            AppLogger.connection.info("probe unreachable: \(underlying)")
            if address.url.scheme == "https", let plain = plainHTTP(for: address.url) {
                return ConnectDiagnosis(
                    symbol: "lock.slash",
                    title: String(localized: "https can't work here"),
                    detail: String(
                        localized:
                            "A tailnet address can't present a certificate for itself, so TLS fails before the agent is reached. Tailscale already encrypts the link."
                    ),
                    fix: .usePlainHTTP(plain),
                    actionTitle: String(localized: "Use http instead"))
            }
            if tailnetAddress == nil {
                return ConnectDiagnosis(
                    symbol: "wifi.exclamationmark",
                    title: String(localized: "This iPhone isn't on your tailnet"),
                    detail: String(
                        localized:
                            "Nothing can answer until Tailscale is connected here. Open it, sign in to the same account as your computer, then come back."
                    ),
                    fix: .openTailscale,
                    actionTitle: String(localized: "Open Tailscale"))
            }
            switch reachability {
            case .refused:
                return ConnectDiagnosis(
                    symbol: "bolt.horizontal.circle",
                    title: String(localized: "Nothing is listening on \(address.displayHost)"),
                    detail: String(
                        localized:
                            "The machine is reachable, so the address is right — but no agent is bound to that port. Start it there, and make sure it binds 0.0.0.0 rather than localhost."
                    ),
                    fix: .retry,
                    actionTitle: String(localized: "Try again"))
            case .nameNotResolved:
                return ConnectDiagnosis(
                    symbol: "questionmark.circle",
                    title: String(localized: "Can't resolve that name"),
                    detail: String(
                        localized:
                            "This iPhone can't turn \(address.url.host ?? "that name") into an address. MagicDNS may be off — use the machine's 100.x address instead."
                    ),
                    fix: .retry,
                    actionTitle: String(localized: "Try again"))
            case .listening:
                return ConnectDiagnosis(
                    symbol: "questionmark.app",
                    title: String(localized: "\(address.displayHost) answered, but not as an agent"),
                    detail: String(
                        localized:
                            "The port is open and something is on it, yet it didn't respond as opencode or claude-bridge. Check the port — 4096 for opencode, 4098 for claude-bridge."
                    ),
                    fix: alternatePort.map { .retryOtherPort($0) } ?? .retry,
                    actionTitle: alternatePort?.port.map { String(localized: "Try port \($0)") }
                        ?? String(localized: "Try again"))
            case .timedOut, .none:
                if address.isPrivateRange {
                    return ConnectDiagnosis(
                        symbol: "network.slash",
                        title: String(localized: "No answer from \(address.displayHost)"),
                        detail: String(
                            localized:
                                "That is a local-network address. If Local Network access is off for Tailscode, every attempt fails as a timeout — check it in Settings, or use the machine's 100.x tailnet address instead."
                        ),
                        fix: .openAppSettings,
                        actionTitle: String(localized: "Open Settings"))
                }
                return ConnectDiagnosis(
                    symbol: "moon.zzz",
                    title: String(localized: "No answer from \(address.displayHost)"),
                    detail: String(
                        localized:
                            "This iPhone is on the tailnet but that machine never replied. It may be asleep, offline, or signed into a different tailnet."
                    ),
                    fix: .retry,
                    actionTitle: String(localized: "Try again"))
            }
        }
    }

    private static func plainHTTP(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "http"
        return components.url
    }
}
