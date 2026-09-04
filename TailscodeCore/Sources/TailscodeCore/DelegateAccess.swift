import CodingAgentKit
import Foundation

/// Where the daemon is for one server: beside the agent, on its own port, behind its own password.
///
/// The key is the machine, not the profile. Two profiles on one host (opencode and a bridge) share
/// one dispatcher, so a password typed once serves both, and removing one profile leaves the
/// dispatcher reachable through the other.
public struct DelegateAccess: Sendable, Codable, Hashable, Identifiable {
    public var host: String
    public var port: Int
    public var enabled: Bool

    public var id: String { host }

    public init(host: String, port: Int = DelegateClient.defaultPort, enabled: Bool = true) {
        self.host = host
        self.port = port
        self.enabled = enabled
    }

    /// The secret-store key the daemon's password is kept under on this device.
    public var secretKey: String { "delegate.\(host)" }

    public var address: String { "\(host):\(port)" }

    public func config(password: String?) -> ServerConfig? {
        DelegateClient.config(host: host, port: port, password: password)
    }

    /// The host a profile's address names, which is what the daemon is looked up by.
    public static func host(of url: URL) -> String? { url.host }
}

/// Every daemon this device knows about, under one `tailscode.*` key like every other store here.
public enum DelegateAccessStore {
    public static let key = "tailscode.delegate.servers"
    public static let didChange = Notification.Name("tailscode.delegate.didChange")

    public static func all(defaults: UserDefaults = .standard) -> [DelegateAccess] {
        guard let data = defaults.data(forKey: key),
            let list = try? JSONDecoder().decode([DelegateAccess].self, from: data)
        else { return [] }
        return list
    }

    public static func access(host: String, defaults: UserDefaults = .standard) -> DelegateAccess? {
        all(defaults: defaults).first { $0.host == host }
    }

    public static func remember(_ access: DelegateAccess, defaults: UserDefaults = .standard) {
        var list = all(defaults: defaults).filter { $0.host != access.host }
        list.append(access)
        write(list, defaults: defaults)
    }

    public static func forget(host: String, defaults: UserDefaults = .standard) {
        write(all(defaults: defaults).filter { $0.host != host }, defaults: defaults)
    }

    private static func write(_ list: [DelegateAccess], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// What a probe of the daemon's port says, in words a server screen can wear.
public enum DelegateReach: Sendable, Equatable {
    case unknown
    case checking
    case answering(version: String)
    case wantsPassword
    case refused
    case unreachable(String)

    public var line: String {
        switch self {
        case .unknown: return Localized.text("Not checked")
        case .checking: return Localized.text("Checking…")
        case .answering(let version): return Localized.text("delegate %@ is answering", version)
        case .wantsPassword: return Localized.text("Answering, wants its password")
        case .refused: return Localized.text("The password was refused")
        case .unreachable(let reason): return Localized.text("Not answering: %@", reason)
        }
    }

    public var tone: ActivityTone {
        switch self {
        case .unknown, .checking: return .quiet
        case .answering: return .live
        case .wantsPassword, .refused: return .attention
        case .unreachable: return .danger
        }
    }

    public var isAnswering: Bool {
        if case .answering = self { return true }
        return false
    }
}
