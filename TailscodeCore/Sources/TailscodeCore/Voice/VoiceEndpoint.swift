import CodingAgentKit
import Foundation

/// Where the voice gateway is for one server: beside the agent, on its own port, found from a
/// profile's address exactly the way the delegate daemon is. The gateway listens on the tailnet
/// only and asks for a password only when it was started with one, so a secret is kept only for
/// a gateway that wants it.
///
/// The key is the machine, not the profile, for the same reason `DelegateAccess` keys by host:
/// two profiles on one host share one gateway and one password.
public struct VoiceEndpoint: Sendable, Hashable, Identifiable {
    public let host: String
    public let port: Int

    public var id: String { host }

    public init(host: String, port: Int = VoiceWire.port) {
        self.host = host
        self.port = port
    }

    public init?(profileURL: URL) {
        guard let host = DelegateAccess.host(of: profileURL), !host.isEmpty else { return nil }
        self.init(host: host)
    }

    public var callURL: URL { url(scheme: "ws", path: VoiceWire.callPath) }

    public var healthURL: URL { url(scheme: "http", path: VoiceWire.healthPath) }

    public var address: String { "\(host):\(port)" }

    public var isDemo: Bool { VoiceDemo.isDemoHost(host) }

    /// The secret-store key the gateway's password is kept under on this device.
    public var secretKey: String { "voice.\(host)" }

    public func password(in secrets: any SecretStore) -> String? {
        (try? secrets.value(for: secretKey)) ?? nil
    }

    public func remember(password: String, in secrets: any SecretStore) {
        try? secrets.setValue(password, for: secretKey)
    }

    public func forgetPassword(in secrets: any SecretStore) {
        try? secrets.removeValue(for: secretKey)
    }

    private func url(scheme: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path
        return components.url ?? URL(fileURLWithPath: path)
    }
}
