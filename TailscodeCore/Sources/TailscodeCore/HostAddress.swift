import CodingAgentKit
import Foundation

/// Everything a person plausibly has on hand when they connect — a bare address
/// from `tailscale ip -4`, a MagicDNS name, `host:port`, a full URL, or a whole
/// line copied out of the server's own startup log — resolved to one base URL.
/// The old form demanded a scheme and a port and rejected the two inputs users
/// actually have.
public struct HostAddress: Equatable, Sendable {
    public static let openCodePort = 4096
    public static let claudeCodePort = 4098
    public static let ompPort = 4099

    public let url: URL
    /// True when the app supplied the port rather than the user. The other
    /// agent's port is then worth probing too, which makes the agent choice
    /// almost never matter.
    public let portWasInferred: Bool

    public init(url: URL, portWasInferred: Bool) {
        self.url = url
        self.portWasInferred = portWasInferred
    }

    public enum Reading: Equatable, Sendable {
        case empty
        case address(HostAddress)
        /// `0.0.0.0` and `::` are what a server binds to, never where it lives.
        case bindAll
        case unsupportedScheme(String)
        case invalid
    }

    public static func port(for backend: AgentType) -> Int {
        switch backend {
        case .openCode: return openCodePort
        case .claudeCode: return claudeCodePort
        case .omp: return ompPort
        }
    }

    public static func read(_ raw: String, defaultPort: Int) -> Reading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let token = candidateToken(in: trimmed) else { return .invalid }

        var working = token
        for (prefix, replacement) in [("ws://", "http://"), ("wss://", "https://")] {
            if working.lowercased().hasPrefix(prefix) {
                working = replacement + working.dropFirst(prefix.count)
            }
        }
        if let separator = working.range(of: "://") {
            let scheme = working[working.startIndex..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return .unsupportedScheme(scheme) }
        } else {
            working = "http://" + working
        }

        guard var components = URLComponents(string: working), let host = components.host,
            !host.isEmpty, isPlausibleHost(host)
        else { return .invalid }
        if host == "0.0.0.0" || host == "::" { return .bindAll }

        let inferred = components.port == nil
        components.port = components.port ?? defaultPort
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { return .invalid }
        return .address(HostAddress(url: url, portWasInferred: inferred))
    }

    /// The addresses worth probing, best guess first: when the user never named a
    /// port, the other agent's default is the single most likely correction.
    public func probeCandidates() -> [URL] {
        guard portWasInferred, let port = url.port else { return [url] }
        let alternates = [Self.openCodePort, Self.claudeCodePort, Self.ompPort]
            .filter { $0 != port }
        var candidates: [URL] = [url]
        for candidate in alternates {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { continue }
            components.port = candidate
            if let candidateURL = components.url { candidates.append(candidateURL) }
        }
        return candidates
    }

    public var displayHost: String {
        guard let host = url.host else { return url.absoluteString }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// Private-range hosts trip iOS's Local Network prompt; a denial there fails
    /// every later probe as a plain timeout, so it is worth naming separately.
    public var isPrivateRange: Bool {
        guard let host = url.host else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        return false
    }

    public var isTailnetRange: Bool {
        guard let host = url.host else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// A pasted log line or a sentence carries the address inside it; take the
    /// most URL-shaped word rather than refusing the paste.
    private static func candidateToken(in text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;()[]<>"))
        }
        guard !words.isEmpty else { return nil }
        if let explicit = words.first(where: { $0.contains("://") }) { return trimTrailingSlash(explicit) }
        if words.count == 1 { return trimTrailingSlash(words[0]) }
        let hostish = words.first { word in
            guard word.contains(".") || word.contains(":") else { return false }
            guard !word.hasPrefix("-") else { return false }
            return isPlausibleHost(String(word.split(separator: ":").first ?? ""))
        }
        return hostish.map(trimTrailingSlash)
    }

    private static func trimTrailingSlash(_ value: String) -> String {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count < 254 else { return false }
        if host.hasPrefix("[") { return host.hasSuffix("]") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = host.first, first.isLetter || first.isNumber else { return false }
        return true
    }
}
