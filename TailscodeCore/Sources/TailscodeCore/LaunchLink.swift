import CodingAgentKit
import Foundation

/// What a launch of the Linux client asks for with a link, read off the argument list alone so the
/// routing is testable without a window: a bare `tailscode://…` argument, which a desktop hands
/// the app when a link is opened, or `--connect tailscode://…`. `--connect <address>` with
/// anything else stays the headless save it has always been.
public enum LaunchLink {
    public enum Request: Sendable, Equatable {
        case none
        case link(String)
    }

    private static let valueFlags: Set<String> = ["--password", "--name", "--flight"]

    public static func request(arguments: [String]) -> Request {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if valueFlags.contains(argument) {
                index += 2
                continue
            }
            if argument == "--connect" {
                if index + 1 < arguments.count, looksLikeLink(arguments[index + 1]) {
                    return .link(arguments[index + 1])
                }
                index += 2
                continue
            }
            if looksLikeLink(argument) { return .link(argument) }
            index += 1
        }
        return .none
    }

    /// `--connect <address>` with a plain address: the headless save, not a link.
    public static func isHeadlessConnect(arguments: [String]) -> Bool {
        guard arguments.contains("--connect") else { return false }
        return request(arguments: arguments) == .none
    }

    private static func looksLikeLink(_ text: String) -> Bool {
        text.lowercased().hasPrefix("\(PairingLink.scheme)://")
    }
}
