import Foundation

/// This machine's tailnet address, and the peers it can see.
///
/// The iOS reading walks `getifaddrs` for a `utun` in 100.64/10. That does not port: glibc's
/// `sockaddr` has no `sa_len`, its `sa_family_t` is a different width, and Tailscale on Linux
/// presents a renamable `tailscale0` — or, under `--tun=userspace-networking`, no interface at all.
/// `tailscale status --json` answers the same question directly and also returns the peer list,
/// which is what discovery needs anyway.
public struct TailnetStatusLinux: Sendable {
    public struct Peer: Sendable, Hashable {
        public let hostname: String
        public let address: String
        public let online: Bool
    }

    public let address: String?
    public let peers: [Peer]

    public static func read() -> TailnetStatusLinux {
        guard let data = runTailscale() else { return TailnetStatusLinux(address: nil, peers: []) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TailnetStatusLinux(address: nil, peers: [])
        }
        let selfNode = root["Self"] as? [String: Any]
        let address = (selfNode?["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        let rawPeers: [Any] = Array((root["Peer"] as? [String: Any])?.values ?? [:].values)
        let peers: [Peer] = rawPeers.compactMap { value in
            guard let peer = value as? [String: Any],
                let name = (peer["HostName"] as? String) ?? (peer["DNSName"] as? String),
                let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") })
            else { return nil }
            return Peer(hostname: name, address: ip, online: (peer["Online"] as? Bool) ?? false)
        }
        return TailnetStatusLinux(
            address: address, peers: peers.sorted { $0.hostname < $1.hostname })
    }

    /// The daemon is asked over its own CLI rather than its socket: `tailscaled.sock` is root-owned
    /// on most distributions and outside the sandbox under Flatpak, while the CLI is on PATH and
    /// already has the permission it needs.
    private static func runTailscale() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tailscale", "status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
