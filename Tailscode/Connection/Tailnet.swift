import CodingAgentKitApple
import Darwin
import Foundation
import UIKit

/// The Tailscale API access token, in the Keychain. Discovery and Settings both
/// edit the same credential, so it lives here rather than inside whichever
/// screen happened to ask for it first.
@MainActor
enum TailnetCredentials {
    private static let keychain = KeychainSecretStore()
    private static let tokenKey = "tailscale.token"
    private static let scanKey = "tailscale.lastScan"

    static var token: String? {
        let stored = (try? keychain.value(for: tokenKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    static func setToken(_ value: String) throws {
        try keychain.setValue(value, for: tokenKey)
        AppLogger.connection.info("tailscale token saved")
    }

    static func clearToken() {
        try? keychain.removeValue(for: tokenKey)
        UserDefaults.standard.removeObject(forKey: scanKey)
        AppLogger.connection.info("tailscale token cleared")
    }

    struct Scan: Codable {
        var date: Date
        var deviceCount: Int
        var serverCount: Int
    }

    static var lastScan: Scan? {
        guard let data = UserDefaults.standard.data(forKey: scanKey) else { return nil }
        return try? JSONDecoder().decode(Scan.self, from: data)
    }

    static func recordScan(devices: Int, servers: Int) {
        let scan = Scan(date: Date(), deviceCount: devices, serverCount: servers)
        guard let data = try? JSONEncoder().encode(scan) else { return }
        UserDefaults.standard.set(data, forKey: scanKey)
    }
}

/// Whether Tailscale is actually carrying traffic on this device. Every server
/// in this app is reached over the tailnet, so "the VPN is off" and "your server
/// is down" produce identical failures — and the first one is the common case,
/// the one the user can fix in ten seconds, and the one no amount of retrying
/// will resolve.
enum TailnetStatus {
    /// This device's Tailscale address, read straight off the interface list. A
    /// tailnet address is a `100.64.0.0/10` (CGNAT) address on a `utun`
    /// interface; nothing is present unless the VPN is up and configured.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                let name = String(validatingCString: interface.ifa_name), name.hasPrefix("utun")
            else { continue }
            guard let address = numericHost(of: addr), isTailnetAddress(address) else { continue }
            return address
        }
        return nil
    }

    static var isConnected: Bool { localAddress() != nil }

    private static func numericHost(of addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let resolved = buffer.withUnsafeMutableBufferPointer { host -> String? in
            guard let base = host.baseAddress,
                getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), base, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
            else { return nil }
            return String(validatingCString: base)
        }
        return resolved
    }

    private static func isTailnetAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// The Tailscale app, falling back to its App Store page when it isn't
    /// installed — the two cases the user is actually in when the tailnet is
    /// down, and both are one tap from here.
    @MainActor
    static func openTailscaleApp() {
        let app = URL(string: "tailscale://")!
        let store = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
        UIApplication.shared.open(app, options: [:]) { opened in
            guard !opened else { return }
            UIApplication.shared.open(store)
        }
    }
}
