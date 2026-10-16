import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// What a client does with a link it has read.
///
/// A link only ever prefills: the agent is chosen, the address and port filled, the machine probed
/// without being asked, and the checklist lands with its rows already proven. The one thing it
/// carries that is worth stealing, the machine's password, is held back until the person has
/// pressed Connect, so a link naming a host nobody should trust gets nothing but an anonymous
/// health request.
public struct ConnectLinkPlan: Sendable, Equatable {
    public enum Destination: Sendable, Equatable {
        case firstRun
        case confirmAddition
        case openExisting(profileID: String)
    }

    public let link: PairingLink
    public let destination: Destination
    public let agent: AgentType
    public let baseURL: URL
    public let displayName: String
    public let isOnTailnet: Bool
    public let carriesKey: Bool

    public init(link: PairingLink, destination: Destination) {
        self.link = link
        self.destination = destination
        self.agent = link.agent.agentType
        self.baseURL = link.baseURL
        self.displayName = ConnectLinkReading.displayName(link)
        self.isOnTailnet = link.isTailnetAddress
        self.carriesKey = link.key != nil
    }

    public static func make(
        link: PairingLink, profiles: [ConnectionProfile], devices: [TailscaleDevice] = []
    ) -> ConnectLinkPlan {
        let existing = profiles.first {
            ConfiguredServers.isConfigured(link.baseURL, profiles: [$0], devices: devices)
        }
        if let existing {
            return ConnectLinkPlan(link: link, destination: .openExisting(profileID: existing.id))
        }
        return ConnectLinkPlan(
            link: link, destination: profiles.isEmpty ? .firstRun : .confirmAddition)
    }

    public var probesAutomatically: Bool {
        if case .openExisting = destination { return false }
        return isOnTailnet
    }

    public var opensExisting: Bool {
        if case .openExisting = destination { return true }
        return false
    }

    /// The password the link carried, released only once the person has confirmed. Every road
    /// that would send it to a host or write it to a keychain asks here.
    public func key(confirmed: Bool) -> String? {
        confirmed ? link.key : nil
    }

    public var lines: [String] {
        var lines = [ConnectLinkReading.agentLine(link)]
        if !isOnTailnet { lines.append(ConnectLinkReading.notOnTailnet(link)) }
        if carriesKey { lines.append(ConnectLinkReading.keyNote) }
        lines.append(ConnectLinkReading.savedNothing)
        return lines
    }

    public var logLine: String {
        "connect link \(ConnectLink.logLine(link)) → \(destination)"
    }
}
