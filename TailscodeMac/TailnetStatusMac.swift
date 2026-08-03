import Darwin
import Foundation

/// This Mac's own tailnet presence, read straight off the interface list — a `100.64.0.0/10`
/// (CGNAT) address on a `utun` interface exists only while the VPN is up and configured. The
/// same walk the phone does, and far cheaper than shelling out to a `tailscale` binary that may
/// live in three different places.
enum TailnetStatusMac {
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

    private static func numericHost(of addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        return buffer.withUnsafeMutableBufferPointer { host -> String? in
            guard let base = host.baseAddress,
                getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), base, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
            else { return nil }
            return String(validatingCString: base)
        }
    }

    private static func isTailnetAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
