import CodingAgentKit
import Foundation

/// Whether the Tailscale credential a phone keeps is there and still works. A phone cannot ask the
/// daemon who is on its tailnet, so it reads the device list from Tailscale's API with a token the
/// person minted — and a token is the one thing in this app that expires on its own.
public enum TailnetKey: String, Codable, Sendable, Equatable {
    case none
    case saved
    /// Tailscale refused it: expired, revoked or mistyped. Kept so the person is told, never sent
    /// again as if it worked.
    case rejected

    /// The value beside the token's row in Settings.
    public var settingsValue: String {
        switch self {
        case .none: return Localized.text("Not set")
        case .saved: return Localized.text("Saved in Keychain")
        case .rejected: return Localized.text("Stopped working — tap to replace")
        }
    }
}

/// The machines a phone last saw on the tailnet, kept so that a token that stops working does not
/// stop the app finding them. The list is a memory, not a fact: nothing in it says a machine is on
/// now, so every entry is asked and the ones that do not answer cost a timeout and nothing else.
public struct KnownMachines: Codable, Equatable, Sendable {
    public static let maxAge: TimeInterval = 60 * 60 * 24 * 45

    public let devices: [TailscaleDevice]
    public let savedAt: Date

    public init(devices: [TailscaleDevice], savedAt: Date) {
        self.devices = devices
        self.savedAt = savedAt
    }

    /// What is worth remembering from a live listing: machines that could host an agent. Whether
    /// each was online is dropped on purpose — it described the moment of the scan, and carried
    /// forward it would make every remembered machine read as asleep.
    public static func remembering(_ listing: [TailscaleDevice], now: Date = Date()) -> KnownMachines {
        let hosts = TailnetScanner.scannableDevices(listing, now: now).map { device -> TailscaleDevice in
            var remembered = device
            remembered.lastSeen = nil
            remembered.connectedToControl = nil
            return remembered
        }
        return KnownMachines(devices: hosts, savedAt: now)
    }

    /// The remembered machines, or none once the memory is old enough that a machine renamed or
    /// retired since would be asked about by a name nobody uses.
    public func devices(now: Date = Date()) -> [TailscaleDevice] {
        now.timeIntervalSince(savedAt) <= Self.maxAge ? devices : []
    }
}

/// What the discovery screen says and offers, from three facts: is this phone on a tailnet, does it
/// hold a working key, and how many machines does it remember. Every case has one primary action
/// that is the thing most likely to put a machine on screen.
public struct TailnetDiscoveryReading: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openTailscale
        case addKey
        case replaceKey
        case scan
        case scanRemembered
    }

    public let headline: String
    public let primary: Action
    public let secondary: Action?

    public var canScan: Bool { primary == .scan || primary == .scanRemembered }

    public static func read(tailnetUp: Bool, key: TailnetKey, remembered: Int) -> TailnetDiscoveryReading {
        guard tailnetUp else {
            return TailnetDiscoveryReading(
                headline: Localized.text("This phone isn't on your tailnet. Turn Tailscale on and the scan starts by itself."),
                primary: .openTailscale, secondary: nil)
        }
        switch (key, remembered > 0) {
        case (.saved, _):
            return TailnetDiscoveryReading(
                headline: Localized.text("Tap Scan to discover servers on your tailnet."),
                primary: .scan, secondary: .replaceKey)
        case (.none, true):
            return TailnetDiscoveryReading(
                headline: Localized.text("No Tailscale token, but this phone remembers %lld machines. Ask them again, or add a token to find new ones.", remembered),
                primary: .scanRemembered, secondary: .addKey)
        case (.none, false):
            return TailnetDiscoveryReading(
                headline: Localized.text("Add a Tailscale API access token to discover servers."),
                primary: .addKey, secondary: nil)
        case (.rejected, true):
            return TailnetDiscoveryReading(
                headline: Localized.text("Tailscale no longer accepts your token, so new machines can't be listed. This phone still remembers %lld machines it can ask.", remembered),
                primary: .scanRemembered, secondary: .replaceKey)
        case (.rejected, false):
            return TailnetDiscoveryReading(
                headline: Localized.text("Tailscale no longer accepts your token. It expired or was revoked — add a new one to list your machines."),
                primary: .replaceKey, secondary: nil)
        }
    }

    public static func title(of action: Action, key: TailnetKey) -> String {
        switch action {
        case .openTailscale: return Localized.text("Open Tailscale")
        case .addKey: return Localized.text("Add access token")
        case .replaceKey: return key == .rejected ? Localized.text("Add a new token") : Localized.text("Update token")
        case .scan: return Localized.text("Scan tailnet")
        case .scanRemembered: return Localized.text("Scan remembered machines")
        }
    }

    /// Said under a finished scan whose token Tailscale refused: the results are real, and the
    /// reason there may be fewer than expected is not on the screen unless it is said.
    public static let rejectedNote = Localized.text(
        "Your Tailscale token stopped working, so only remembered machines were asked. Add a new one to find new machines.")

    /// The line a finished scan ends on when it asked a remembered list rather than Tailscale.
    public static func rememberedNote(count: Int) -> String {
        Localized.text("Asked %lld remembered machines.", count)
    }
}

/// The words around the token editor: what it is for, what it costs, and what became of a token
/// that was tried. A token is checked with Tailscale before it is kept, so a wrong one is said
/// here, at the moment it is pasted, rather than later as a scan that finds nothing.
public enum TailnetTokenReading {
    public static let note = Localized.text(
        "Stored only in the Keychain and used solely to list your Tailscale devices — connecting to a server never needs it. Tailscale tokens last at most 90 days; when one stops working Tailscode says so and keeps asking the machines it already knows."
    )

    public static let checking = Localized.text("Checking with Tailscale…")

    public static let rejected = Localized.text(
        "Tailscale didn't accept that token. Check that you copied all of it and that it hasn't expired.")

    public static let unreachable = Localized.text(
        "Couldn't reach Tailscale to check the token. Check your connection and try again.")
}
