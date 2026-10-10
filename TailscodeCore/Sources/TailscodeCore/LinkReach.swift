import Foundation

/// Which addresses a preview card may be fetched from.
///
/// A card is a request this device makes on a stranger's say-so: whatever an agent writes in a
/// message — or a page it read wrote into its answer — would otherwise become a GET from the
/// person's own machine, from inside their network. So only the public web gets a card: a name
/// that is not a single label and does not end in a suffix reserved for private use, and an
/// address that is not a literal in a loopback, private, link-local, tailnet or unspecified range.
/// An address that is refused is still a link; it just has no face but its host.
public enum LinkReach {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return false }
        return allows(host: host)
    }

    public static func allows(host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host.contains(":") { return false }
        if let octets = dottedQuad(host) { return !reserved(octets) }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        guard host.contains(".") else { return false }
        return !privateSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let privateSuffixes = [
        "localhost", "local", "localdomain", "lan", "internal", "intranet", "home", "corp",
        "home.arpa", "ts.net", "test", "invalid", "example",
    ]

    private static func dottedQuad(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func reserved(_ octets: [Int]) -> Bool {
        let (first, second) = (octets[0], octets[1])
        if first == 0 || first == 10 || first == 127 { return true }
        if first == 100, (64...127).contains(second) { return true }
        if first == 169, second == 254 { return true }
        if first == 172, (16...31).contains(second) { return true }
        if first == 192, second == 168 { return true }
        if first >= 224 { return true }
        return false
    }
}
