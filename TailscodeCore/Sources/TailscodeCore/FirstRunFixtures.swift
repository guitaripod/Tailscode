import CodingAgentKit
import Foundation

/// Every state of first run, put on screen without a fleet: a name from `names` becomes a
/// `FirstRunState` a client draws through the ordinary plan, so a picture of "the machine refused"
/// is the real card and not a mock of it. Used by the desktops' drive hooks and selftests.
///
/// A name is `state` or `state+add` for the add-another mode. Failures take their cause after a
/// colon, as `failed:refused`.
public enum FirstRunFixtures {
    public static let causes = [
        "refused", "no-answer", "off-tailnet", "wants-password", "wrong-password", "not-an-agent",
        "unresolved", "tailnet-only",
    ]

    public static let names = [
        "checking", "tailscale-down", "machine-asking", "link-offered", "link-pasted", "probing",
        "signed-out", "connected",
    ] + causes.map { "failed:\($0)" }

    public static let host = "studio.tail1234.ts.net"

    public static func state(named raw: String, platform: FirstRunPlatform) -> FirstRunState? {
        let adding = raw.hasSuffix("+add")
        let name = adding ? String(raw.dropLast("+add".count)) : raw
        var state = FirstRunState(platform: platform, mode: adding ? .addition : .firstRun)
        state.tailscale = .up(address: "100.101.102.103")
        switch name {
        case "checking":
            state.tailscale = nil
        case "tailscale-down":
            state.tailscale = .daemonDown
        case "machine-asking":
            break
        case "link-offered":
            state.clipboard = link()
        case "link-pasted":
            useLink(&state)
            state.machine = .found(found())
        case "probing":
            useLink(&state)
            state.machine = .looking(label: "Studio")
        case "signed-out":
            useLink(&state)
            state.machine = .found(found())
            state.connection = .saved(name: "Studio")
            state.claude = .signedOut
        case "connected":
            useLink(&state)
            state.machine = .found(found())
            state.connection = .saved(name: "Studio")
            state.claude = .signedIn(account: "you@example.com")
            state.finished = true
        default:
            let cause = String(name.dropFirst("failed:".count))
            guard name.hasPrefix("failed:"), let diagnosis = failure(cause, platform) else { return nil }
            state.way = .paste
            state.typed = "\(host):4098"
            state.machine = .failed(diagnosis)
        }
        return state
    }

    private static func link() -> PairingLink {
        PairingLink(host: host, port: 4098, agent: .claude, name: "Studio")!
    }

    private static func found() -> FirstRunState.Found {
        FirstRunState.Found(
            agent: .claudeCode, version: "1.14.0", url: link().baseURL, label: "Studio")
    }

    private static func useLink(_ state: inout FirstRunState) {
        state.way = .link
        state.link = ConnectLinkPlan.make(link: link(), profiles: [])
    }

    private static func failure(_ cause: String, _ platform: FirstRunPlatform) -> ConnectDiagnosis? {
        let address = HostAddress(url: link().baseURL, portWasInferred: false)
        let outcome: ConnectionProbe.Outcome
        var reachability: PortReachability.Verdict?
        var sentPassword = false
        switch cause {
        case "refused":
            outcome = .unreachable("")
            reachability = .refused
        case "no-answer":
            outcome = .unreachable("")
            reachability = .timedOut
        case "off-tailnet":
            return ConnectDiagnosis.offTailnet(deviceName: platform.thisDevice)
        case "unresolved":
            outcome = .unreachable("")
            reachability = .nameNotResolved
        case "wants-password":
            outcome = .authFailed(.password)
        case "wrong-password":
            outcome = .authFailed(.password)
            sentPassword = true
        case "not-an-agent":
            outcome = .notAnAgentServer
        case "tailnet-only":
            outcome = .authFailed(.tailnetOnly)
        default:
            return nil
        }
        return ConnectDiagnosis.make(
            outcome: outcome, address: address, tailnetAddress: "100.101.102.103", alternatePort: nil,
            sentPassword: sentPassword, reachability: reachability, deviceName: platform.thisDevice)
    }
}
