import CodingAgentKit
import Foundation

/// Where a Mac's preview host is: on its own port, beside whatever else the machine runs. The key
/// is the machine, so a password typed once serves every pane that previews on it.
public struct PreviewAccess: Sendable, Codable, Hashable, Identifiable {
    public var host: String
    public var port: Int
    public var name: String?

    public var id: String { host }

    public init(host: String, port: Int = PreviewClient.defaultPort, name: String? = nil) {
        self.host = host
        self.port = port
        self.name = name
    }

    /// The secret-store key the host's password is kept under on this device.
    public var secretKey: String { "preview.\(host)" }

    public var address: String { "\(host):\(port)" }

    public var label: String { name ?? host }

    public func config(password: String?) -> ServerConfig? {
        PreviewClient.config(host: host, port: port, password: password)
    }
}

/// Every preview host this device knows about, under one `tailscode.*` key like every other store.
public enum PreviewAccessStore {
    public static let key = "tailscode.preview.hosts"
    public static let didChange = Notification.Name("tailscode.preview.didChange")

    public static func all(defaults: UserDefaults = .standard) -> [PreviewAccess] {
        guard let data = defaults.data(forKey: key),
            let list = try? JSONDecoder().decode([PreviewAccess].self, from: data)
        else { return [] }
        return list
    }

    public static func access(host: String, defaults: UserDefaults = .standard) -> PreviewAccess? {
        all(defaults: defaults).first { $0.host == host }
    }

    public static func remember(_ access: PreviewAccess, defaults: UserDefaults = .standard) {
        var list = all(defaults: defaults).filter { $0.host != access.host }
        list.append(access)
        write(list, defaults: defaults)
    }

    public static func forget(host: String, defaults: UserDefaults = .standard) {
        write(all(defaults: defaults).filter { $0.host != host }, defaults: defaults)
    }

    private static func write(_ list: [PreviewAccess], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// What a probe of the host's port says, in words a server screen can wear.
public enum PreviewReach: Sendable, Equatable {
    case unknown
    case checking
    case answering(version: String)
    case wantsPassword
    case refused
    case unreachable(String)

    public var asksForPassword: Bool { self == .wantsPassword || self == .refused }

    public var isAnswering: Bool {
        if case .answering = self { return true }
        return false
    }

    public var line: String {
        switch self {
        case .unknown: return Localized.text("Not checked")
        case .checking: return Localized.text("Checking…")
        case .answering(let version): return Localized.text("Preview host %@ is answering", version)
        case .wantsPassword: return Localized.text("Answering, set to ask for its password")
        case .refused: return Localized.text("The password was refused")
        case .unreachable(let reason): return Localized.text("Not answering: %@", reason)
        }
    }
}

public enum PreviewProbe {
    /// Asks the host who it is. A refusal that names a password is the one answer worth asking
    /// a person for one; every other failure is reported as the machine not answering.
    public static func probe(_ access: PreviewAccess, password: String?) async -> PreviewReach {
        guard let config = access.config(password: password) else { return .unreachable(access.address) }
        do {
            let status = try await PreviewClient(config: config).status()
            return .answering(version: status.version)
        } catch AgentError.http(let code, _) where code == 401 || code == 403 {
            return password == nil ? .wantsPassword : .refused
        } catch AgentError.http(let code, _) where code == 404 {
            return .unreachable(Localized.text("That address is not a preview host"))
        } catch {
            return .unreachable(String(describing: error))
        }
    }
}
