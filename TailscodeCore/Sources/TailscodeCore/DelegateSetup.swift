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

    /// The easy road: the agent already on that machine does the two commands and fits the ladder
    /// to the models the machine has. The request is written out and left unsent, so the person
    /// reads what will be done before anything is.
    public static func askTitle(agent: String) -> String {
        Localized.text("Ask %@ to set it up", agent)
    }

    public static var askDetail: String {
        Localized.text("Opens a new chat on this machine with the request written out. Read it, then send.")
    }

    public static var brief: String {
        Localized.text(
            "Set up the delegate dispatcher on this machine for Tailscode. 1. If `delegate` is not on the PATH, install it with `cargo install --git https://github.com/guitaripod/delegate` (install Rust with rustup first if cargo is missing, and ask me before installing anything else). 2. Run `delegate config init`, then read ~/.config/delegate/config.yml. 3. Fit its tiers to what this machine really has: check which agent CLIs are installed (omp, opencode, claude) and whether a local model server answers (llama-swap on 8081, Ollama on 11434), and edit the tiers so each one names a runner and model that exists here; leave out a tier this machine cannot run. 4. Run `delegate config check` and `delegate tiers` until both are clean. 5. Run `delegate install-service`, then prove it with `curl -s http://127.0.0.1:4100/v1/capabilities`. Report the tiers you configured, the version that answered, and anything you could not do. Do not commit anything.")
    }

    /// The other row a machine without a dispatcher offers: see the thing work before installing it.
    public static var rehearseTitle: String { Localized.text("Watch a packet climb first") }

    public static var rehearseDetail: String {
        Localized.text("A scripted run on a machine that does not exist.")
    }

    /// Whether the board should carry the road: a real machine this device has never reached,
    /// until it answers. A machine that answered before has a dispatcher, so its silence is a
    /// different fact and is said by the reach line instead.
    public static func isWanted(board: DelegateBoard, known: Bool) -> Bool {
        guard !DelegateDemo.isDemoHost(board.host), !known else { return false }
        return board.phase != .ready
    }
}
