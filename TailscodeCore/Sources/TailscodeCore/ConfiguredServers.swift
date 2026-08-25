import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Whether a server the scan found is one the app already has. The scan meets a
/// machine by MagicDNS name one day and by its 100.x address the next, and a
/// profile was saved under whichever the person typed — so a raw host comparison
/// answers "new" about a server you have been chatting with for months, and the
/// scan offers you a second copy of it. Every name a machine is known by, on
/// both sides of the comparison, has to collapse onto one answer.
public enum ConfiguredServers {
    /// Every spelling of `host` the tailnet would recognize: itself, plus the
    /// DNS name and address of any peer that owns it. Names are case-folded and
    /// stripped of the trailing dot MagicDNS carries.
    public static func aliases(
        of host: String, devices: [TailscaleDevice]
    ) -> Set<String> {
        var spellings: Set<String> = [normalize(host)]
        for device in devices {
            let names = [device.hostname, device.name ?? ""].map(normalize)
                .filter { !$0.isEmpty }
            let addresses = device.addresses.map(normalize).filter { !$0.isEmpty }
            if names.contains(normalize(host)) {
                spellings.formUnion(addresses)
                spellings.formUnion(names)
            }
            if addresses.contains(normalize(host)) {
                spellings.formUnion(names)
            }
        }
        return spellings
    }

    /// Whether the server at `url` is one of `profiles`, judged over every name
    /// the tailnet knows it by.
    public static func isConfigured(
        _ url: URL, profiles: [ConnectionProfile], devices: [TailscaleDevice]
    ) -> Bool {
        let port = url.port ?? defaultPort
        let host = url.host ?? ""
        guard !host.isEmpty else { return false }
        let spellings = aliases(of: host, devices: devices)
        return profiles.contains { profile in
            guard (profile.baseURL.port ?? defaultPort) == port else { return false }
            return spellings.contains(normalize(profile.baseURL.host ?? ""))
        }
    }

    private static let defaultPort = 4096

    private static func normalize(_ raw: String) -> String {
        var name = raw.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }
}
