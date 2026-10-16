import CodingAgentKit
import Foundation

/// Which client is asking, because a few facts differ by desk and none of them is a reason for the
/// words to: a phone can scan a code and hand a message to the share sheet, a desktop can read
/// its own tailnet and watch for a machine to appear.
public enum FirstRunPlatform: String, Sendable, CaseIterable {
    case iPhone, iPad, mac, linux

    public var scansCodes: Bool { self == .iPhone || self == .iPad }
    public var sharesToComputer: Bool { self == .iPhone || self == .iPad }
    public var readsTailscale: Bool { self == .mac || self == .linux }
    public var watchesTailnet: Bool { self == .mac || self == .linux }
    public var isPhone: Bool { scansCodes }

    public var thisDevice: String {
        switch self {
        case .iPhone: return Localized.text("This iPhone")
        case .iPad: return Localized.text("This iPad")
        case .mac: return Localized.text("This Mac")
        case .linux: return Localized.text("This computer")
        }
    }
}

/// Everything first run knows, in one value the plan is drawn from. The engine changes it, the
/// plan reads it, and nothing else holds a fact about where the person is in the checklist.
public struct FirstRunState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case firstRun
        case addition
    }

    public enum Way: Sendable, Equatable {
        case choosing
        case paste
        case install
        case link
    }

    public struct Found: Sendable, Equatable {
        public let agent: AgentType
        public let version: String?
        public let url: URL
        public let label: String

        public init(agent: AgentType, version: String?, url: URL, label: String) {
            self.agent = agent
            self.version = version
            self.url = url
            self.label = label
        }
    }

    public enum Machine: Sendable, Equatable {
        case idle
        case looking(label: String)
        case found(Found)
        case holdsKey(label: String, agent: AgentType, url: URL)
        case failed(ConnectDiagnosis)
    }

    public enum Connection: Sendable, Equatable {
        case notYet
        case saving
        case saved(name: String)
        case failed(ConnectDiagnosis)
    }

    public enum Claude: Sendable, Equatable {
        case notAsked
        case checking
        case signedIn(account: String?)
        case signedOut
        case cannotSay
    }

    public enum Outcome: Sendable, Equatable {
        case openExisting(profileID: String)
    }

    public var mode: Mode = .firstRun
    public var platform: FirstRunPlatform
    public var offersTailnetScan = true
    public var tailscale: TailscaleReading?
    public var agent: AgentType = .claudeCode
    public var way: Way = .choosing
    public var link: ConnectLinkPlan?
    public var typed = ""
    public var password = ""
    public var passwordShown = false
    public var passwordNote: String?
    public var machine: Machine = .idle
    public var connection: Connection = .notYet
    public var claude: Claude = .notAsked
    public var install: BridgeInstall.Install?
    public var clipboard: PairingLink?
    public var notice: ConnectLinkReading.Message?
    public var offTailnetConfirmed = false
    public var finished = false
    public var outcome: Outcome?

    public init(platform: FirstRunPlatform, mode: Mode = .firstRun) {
        self.platform = platform
        self.mode = mode
    }

    public var hasLiveConnection: Bool {
        switch connection {
        case .saving, .saved: return true
        case .notYet, .failed: return false
        }
    }
}

extension TailscaleReading {
    /// Whether nothing can answer until this is fixed. A sandbox that cannot see the host's
    /// Tailscale is not that: it may well be connected, so the probe is allowed to find out.
    public var blocksReaching: Bool {
        switch self {
        case .up, .sandboxed: return false
        case .loggedOut, .daemonDown, .notInstalled: return true
        }
    }
}
