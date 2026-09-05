import Foundation

/// The road from a machine with no dispatcher to one that answers: two commands, said once, each
/// copyable, so the first board a person meets is not a dead end that names a port. The daemon
/// trusts the tailnet, so nothing is pasted back here. The words are here; a client draws two
/// rows and a copy gesture.
public enum DelegateSetup {
    public struct Step: Sendable, Hashable, Identifiable {
        public var title: String
        public var detail: String
        public var command: String

        public var id: String { title }

        public init(title: String, detail: String, command: String) {
            self.title = title
            self.detail = detail
            self.command = command
        }
    }

    public static var title: String { Localized.text("Put a dispatcher on this machine") }

    public static func lead(serverName: String) -> String {
        Localized.text("Two commands in a shell on %@. The daemon lets your tailnet in without a password, so nothing comes back here. Tap a row to copy its command.", serverName)
    }

    public static var steps: [Step] {
        [
            Step(
                title: Localized.text("Install delegate"),
                detail: Localized.text("Rust's cargo builds it from the source and puts it in ~/.cargo/bin."),
                command: "cargo install --git https://github.com/guitaripod/delegate"),
            Step(
                title: Localized.text("Write its config and start it"),
                detail: Localized.text(
                    "config init writes ~/.config/delegate/config.yml and host.yml; install-service starts it as a user service on port 4100, trusting the tailnet."),
                command: "delegate config init && delegate install-service"),
        ]
    }

    public static var copied: String { Localized.text("Copied") }

    /// Whether the board should carry the road: a real machine this device has never reached,
    /// until it answers. A machine that answered before has a dispatcher, so its silence is a
    /// different fact and is said by the reach line instead.
    public static func isWanted(board: DelegateBoard, known: Bool) -> Bool {
        guard !DelegateDemo.isDemoHost(board.host), !known else { return false }
        return board.phase != .ready
    }
}
