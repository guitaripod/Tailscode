import CodingAgentKit
import Foundation

/// The `tailscode://connect` link a machine prints, read the way every client reads it: from a
/// pasted block of text, an opened URL or a scanned code, into either a link or the plain reason it
/// is not one.
///
/// `PairingLink` (the Kit) owns the format and refuses anything that breaks it with a bare `nil`.
/// A person pasting something needs to be told which of the several ways it can be wrong this is,
/// so the refusal is classified here, without ever echoing the pasted text back: a link is
/// untrusted input and its words are shown only after the Kit has cleaned them.
public enum ConnectLink {
    public enum Rejection: Sendable, Equatable {
        case empty
        case notALink
        case wrongAction
        case malformed
    }

    public enum Reading: Sendable, Equatable {
        case link(PairingLink)
        case rejected(Rejection)

        public var link: PairingLink? {
            if case .link(let link) = self { return link }
            return nil
        }
    }

    private static let prefix = "\(PairingLink.scheme)://"

    public static func read(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }
        guard let token = candidate(in: trimmed) else { return .rejected(.notALink) }
        if let link = PairingLink(string: token) { return .link(link) }
        return .rejected(isConnectAction(token) ? .malformed : .wrongAction)
    }

    public static func read(url: URL) -> Reading {
        read(url.absoluteString)
    }

    /// The link on a clipboard or in a message, when there is one: a pasted block often carries the
    /// link among other words, so the first thing shaped like one is the thing offered.
    public static func firstLink(in text: String) -> PairingLink? {
        read(text).link
    }

    /// What a log line may say about a link: everything but the key.
    public static func logLine(_ link: PairingLink) -> String {
        link.redacted
    }

    public static func logLine(rejection: Rejection) -> String {
        "connect link rejected: \(rejection)"
    }

    private static func candidate(in text: String) -> String? {
        if text.lowercased().hasPrefix(prefix), !text.contains(where: \.isWhitespace) { return text }
        let punctuation = CharacterSet(charactersIn: "\"'`<>(),;[]")
        for word in text.split(whereSeparator: \.isWhitespace) {
            let token = word.trimmingCharacters(in: punctuation)
            if token.lowercased().hasPrefix(prefix) { return token }
        }
        return nil
    }

    private static func isConnectAction(_ token: String) -> Bool {
        let rest = token.dropFirst(prefix.count)
        let action = rest.prefix { $0 != "?" && $0 != "/" }
        return action.lowercased() == PairingLink.action
    }
}

extension PairingAgent {
    public var agentType: AgentType {
        switch self {
        case .claude: return .claudeCode
        case .omp: return .omp
        case .opencode: return .openCode
        }
    }
}

extension AgentType {
    public var pairingAgent: PairingAgent {
        switch self {
        case .claudeCode: return .claude
        case .omp: return .omp
        case .openCode: return .opencode
        }
    }
}

extension PairingLink {
    /// Where the agent this link names answers, as the base URL a profile stores.
    public var baseURL: URL {
        URL(string: "http://\(bracketedHost):\(port)")!
    }
}
