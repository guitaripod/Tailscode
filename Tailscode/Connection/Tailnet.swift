import CodingAgentKit
import CodingAgentKitApple
import Darwin
import Foundation
import MidgarCore
import TailscodeCore
import UIKit

/// The Tailscale API access token, in the Keychain. Discovery and Settings both
/// edit the same credential, so it lives here rather than inside whichever
/// screen happened to ask for it first.
@MainActor
enum TailnetCredentials {
    private static let keychain = KeychainSecretStore()
    private static let tokenKey = "tailscale.token"
    private static let scanKey = "tailscale.lastScan"
    private static let rejectedKey = "tailscale.rejected"
    private static let knownKey = "tailscale.known"

    static var token: String? {
        let stored = (try? keychain.value(for: tokenKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    /// Whether the token is absent, working, or one Tailscale refused. A refused token stays stored
    /// so Settings can say so, and is never sent again until the person replaces it.
    static var key: TailnetKey {
        guard hasToken else { return .none }
        return UserDefaults.standard.bool(forKey: rejectedKey) ? .rejected : .saved
    }

    static func setToken(_ value: String) throws {
        try keychain.setValue(value, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
        MidgarLog.info("tailscale token saved", category: .connection)
    }

    static func clearToken() {
        try? keychain.removeValue(for: tokenKey)
        UserDefaults.standard.removeObject(forKey: scanKey)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
        UserDefaults.standard.removeObject(forKey: knownKey)
        MidgarLog.info("tailscale token cleared", category: .connection)
    }

    static func markRejected() {
        UserDefaults.standard.set(true, forKey: rejectedKey)
        MidgarLog.error("tailscale refused the saved token", category: .connection)
    }

    static var knownMachines: KnownMachines? {
        guard let data = UserDefaults.standard.data(forKey: knownKey) else { return nil }
        return try? JSONDecoder().decode(KnownMachines.self, from: data)
    }

    static var rememberedDevices: [TailscaleDevice] {
        knownMachines?.devices() ?? []
    }

    static func remember(_ listing: [TailscaleDevice]) {
        guard let data = try? JSONEncoder().encode(KnownMachines.remembering(listing)) else { return }
        UserDefaults.standard.set(data, forKey: knownKey)
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

/// The tailnet's machines as this phone can get them: Tailscale's own list when the token works,
/// and the machines it last saw when the token is missing or has stopped working. A phone cannot
/// ask the daemon, so the token is the only live source — and the memory is what keeps a token that
/// expires in the middle of a quarter from taking discovery with it.
@MainActor
enum TailnetDirectory {
    struct Listing {
        let devices: [TailscaleDevice]
        let fromMemory: Bool
    }

    enum Failure: Error {
        case needsKey
        case rejected
        case unavailable(Error)
    }

    static func load() async throws -> Listing {
        let key = TailnetCredentials.key
        if key == .saved, let token = TailnetCredentials.token {
            do {
                let devices = try await TailscaleClient().fetchDevices(with: token)
                TailnetCredentials.remember(devices)
                return Listing(devices: devices, fromMemory: false)
            } catch where TailscaleClient.isRejection(error) {
                TailnetCredentials.markRejected()
            } catch {
                guard !TailnetCredentials.rememberedDevices.isEmpty else { throw Failure.unavailable(error) }
                MidgarLog.error(
                    "tailscale listing failed, using remembered machines: \(error.localizedDescription)",
                    category: .connection
                )
            }
        }
        let remembered = TailnetCredentials.rememberedDevices
        if !remembered.isEmpty { return Listing(devices: remembered, fromMemory: true) }
        throw TailnetCredentials.key == .rejected ? Failure.rejected : Failure.needsKey
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
        #if DEBUG
            switch ProcessInfo.processInfo.environment["TAILSCODE_FAKE_TAILNET"] {
            case "down": return nil
            case "up": return "100.101.102.103"
            default: break
            }
        #endif
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

    /// The same fact in the shared vocabulary, for the Core surfaces that take a
    /// ``TailscaleReading`` rather than an address.
    ///
    /// A phone can only see whether a tailnet address exists here: it cannot ask whether the
    /// daemon is stopped or the account signed out, because on iOS Tailscale is another app with
    /// its own sandbox. So the absent case is only ever read for `isUp` and handed to
    /// ``ConnectDiagnosis``, which words it as this device not being on the tailnet and offers the
    /// one door a phone has — none of the four states' own sentences is ever shown here, since
    /// three of them would be claims this device is in no position to make.
    static var reading: TailscaleReading {
        guard let address = localAddress() else { return .daemonDown }
        return .up(address: address)
    }

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
