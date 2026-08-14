import CodingAgentKit
import Foundation
import TailscodeCore

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
        public let os: String
        /// The MagicDNS name with its trailing dot taken off, which is what a URL wants.
        public let dnsName: String

        /// The shape the shared `TailnetScanner` reads. `lastSeen` is deliberately left empty:
        /// the daemon reports the zero date for a peer that is online right now, and a scanner
        /// that parsed that would read every reachable machine as last seen in the year one and
        /// refuse to probe any of them. Online is the fact this reading actually has.
        public var device: TailscaleDevice {
            TailscaleDevice(
                id: address, name: dnsName.isEmpty ? nil : dnsName, hostname: hostname,
                addresses: [address], os: os, lastSeen: nil)
        }
    }

    public let address: String?
    public let peers: [Peer]
    /// Which of the four ways this machine can be off a tailnet it is, when it is off one. Carried
    /// beside the address rather than derived from its absence, because a nil address is the one
    /// thing every failure has in common and the differences are what a person can act on.
    public let reading: TailscaleReading

    public init(address: String?, peers: [Peer], reading: TailscaleReading? = nil) {
        self.address = address
        self.peers = peers
        if let reading {
            self.reading = reading
        } else if let address {
            self.reading = .up(address: address)
        } else {
            self.reading = Packaging.isFlatpak ? .sandboxed : .daemonDown
        }
    }

    public static func read() -> TailnetStatusLinux {
        let answer = runTailscale()
        guard let data = answer.output else {
            return TailnetStatusLinux(
                address: nil, peers: [],
                reading: TailscaleReading.read(
                    found: answer.ran, sandboxed: Packaging.isFlatpak, backendState: nil,
                    address: nil))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TailnetStatusLinux(
                address: nil, peers: [],
                reading: TailscaleReading.read(
                    found: true, sandboxed: Packaging.isFlatpak, backendState: nil, address: nil))
        }
        let selfNode = root["Self"] as? [String: Any]
        let address = (selfNode?["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        let reading = TailscaleReading.read(
            found: true, sandboxed: Packaging.isFlatpak,
            backendState: root["BackendState"] as? String, address: address)
        let rawPeers: [Any] = Array((root["Peer"] as? [String: Any])?.values ?? [:].values)
        let peers: [Peer] = rawPeers.compactMap { value in
            guard let peer = value as? [String: Any],
                let name = (peer["HostName"] as? String) ?? (peer["DNSName"] as? String),
                let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") })
            else { return nil }
            var dns = (peer["DNSName"] as? String) ?? ""
            while dns.hasSuffix(".") { dns.removeLast() }
            return Peer(
                hostname: name, address: ip, online: (peer["Online"] as? Bool) ?? false,
                os: (peer["OS"] as? String) ?? "", dnsName: dns)
        }
        return TailnetStatusLinux(
            address: address, peers: peers.sorted { $0.hostname < $1.hostname }, reading: reading)
    }

    /// The peers worth asking, in the scanner's own shape. Only what is online — a machine that
    /// is asleep answers nothing and costs the scan a full timeout apiece — and the scanner
    /// drops the phones and TVs that could never run an agent anyway.
    public func scannableDevices() -> [TailscaleDevice] {
        TailnetScanner.scannableDevices(peers.filter(\.online).map(\.device))
    }

    /// The daemon is asked over its own CLI rather than its socket: `tailscaled.sock` is root-owned
    /// on most distributions, and under Flatpak it is outside the sandbox entirely — as is the CLI,
    /// since `/usr` inside a sandbox is the runtime's rather than the machine's. So a sandboxed
    /// build asks the host through `flatpak-spawn`, which needs the Flatpak D-Bus name the manifest
    /// requests; where that permission has not been granted the call fails and the reading says it
    /// cannot see, which is a different sentence from "this machine is not connected".
    ///
    /// - Returns: whether the CLI ran at all, and what it printed. The two are separate facts: a
    ///   `tailscale` that is not installed and one that answered "signed out" both produce no
    ///   usable JSON and mean entirely different things.
    private static func runTailscale() -> (ran: Bool, output: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        if Packaging.isFlatpak {
            process.arguments = ["flatpak-spawn", "--host", "tailscale", "status", "--json"]
        } else {
            process.arguments = ["tailscale", "status", "--json"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (false, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 127 is the shell's word for "no such command", which is how a machine without Tailscale
        // — or a sandbox without the permission to ask the host — answers.
        let ran = process.terminationStatus != 127
        // A signed-out daemon answers with JSON *and* a non-zero status, and that JSON is the only
        // place `BackendState` says so — dropping it would collapse "signed out" into "not here".
        guard process.terminationStatus == 0 else { return (ran, data.isEmpty ? nil : data) }
        return (true, data)
    }
}
