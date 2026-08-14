import Foundation

/// Whether this machine is on a tailnet, and if not, which of the four different reasons it is.
///
/// "Not connected — run `tailscale up`" was one red pill standing for a machine that has never had
/// Tailscale installed, one whose daemon is not running, one signed out, and one that cannot see
/// its own host from inside a sandbox. Those need four different things done about them, and only
/// one of them is `tailscale up` — so a single sentence sends most people to a terminal to run a
/// command that will not help. Each state here carries what is true, what to do, and whether the app
/// can do it, which is what lets the first-run checklist stay a checklist rather than become advice.
///
/// Toolkit-free on purpose: the states and their words are decided once and every client draws
/// them, and the remedy is an intent each client wires to its own door.
public enum TailscaleReading: Sendable, Equatable {
    /// On the tailnet, with this machine's address.
    case up(address: String)
    /// Installed and running, but not signed in to any tailnet.
    case loggedOut
    /// Installed, but nothing is answering — the service is not running.
    case daemonDown
    /// Not on this machine at all.
    case notInstalled
    /// Running inside a sandbox that cannot see the host's Tailscale, which is not the same thing
    /// as this machine not being on a tailnet, and must never be shown as if it were.
    case sandboxed

    public enum Remedy: Sendable, Equatable {
        /// Send them to the download page — nothing the app can do for them.
        case install(url: String)
        /// Sign this machine in. Runs a command that prints a URL and waits.
        case signIn(command: String)
        /// Start the service.
        case start(command: String)
        /// Grant the sandbox the permission it needs to see the host.
        case grantHostAccess(command: String)
        /// Nothing to do.
        case none
    }

    public static let downloadURL = "https://tailscale.com/download/linux"

    public var isUp: Bool {
        if case .up = self { return true }
        return false
    }

    public var address: String? {
        if case .up(let address) = self { return address }
        return nil
    }

    /// The short line beside the step, in the words of what is true rather than of what to type.
    public var title: String {
        switch self {
        case .up(let address): return address
        case .loggedOut: return Localized.text("Signed out")
        case .daemonDown: return Localized.text("Not running")
        case .notInstalled: return Localized.text("Not installed")
        case .sandboxed: return Localized.text("Cannot see it")
        }
    }

    /// What a person needs to understand before the button makes sense.
    public var detail: String? {
        switch self {
        case .up:
            return nil
        case .loggedOut:
            return Localized.text(
                "Tailscale is here but not signed in. Sign this machine into the same account as "
                    + "the computer that runs your agent.")
        case .daemonDown:
            return Localized.text(
                "Tailscale is installed but its service is not running, so this machine has no "
                    + "tailnet address yet.")
        case .notInstalled:
            return Localized.text(
                "Tailscale is what puts this machine and the computer running your agent on the "
                    + "same private network. It is free for personal use.")
        case .sandboxed:
            return Localized.text(
                "Tailscode is running in a sandbox and cannot reach this machine's Tailscale to "
                    + "ask. It may well be connected — this app just cannot see it from in here.")
        }
    }

    public var remedy: Remedy {
        switch self {
        case .up: return .none
        case .loggedOut: return .signIn(command: "tailscale up")
        case .daemonDown: return .start(command: "sudo systemctl enable --now tailscaled")
        case .notInstalled: return .install(url: Self.downloadURL)
        case .sandboxed:
            return .grantHostAccess(
                command: "flatpak override --user --talk-name=org.freedesktop.Flatpak "
                    + "io.github.guitaripod.Tailscode")
        }
    }

    /// What the button says. Nil when there is nothing to press.
    public var actionTitle: String? {
        switch remedy {
        case .install: return Localized.text("Get Tailscale")
        case .signIn: return Localized.text("Sign in to Tailscale")
        case .start: return Localized.text("Start Tailscale")
        case .grantHostAccess: return Localized.text("How to allow this")
        case .none: return nil
        }
    }

    /// The activity tone this state wears, so a client picks a colour without inventing a mapping.
    public var tone: ActivityTone {
        switch self {
        case .up: return .live
        case .loggedOut, .daemonDown, .notInstalled: return .attention
        case .sandboxed: return .quiet
        }
    }

    /// Read a reading out of what the CLI actually answered. `BackendState` is Tailscale's own word
    /// for which of these it is; the two failure shapes above it are the ones the CLI cannot report
    /// because it never ran.
    ///
    /// - Parameters:
    ///   - found: whether the `tailscale` binary could be run at all.
    ///   - sandboxed: whether this process is inside a sandbox that hides the host.
    ///   - backendState: the `BackendState` field of `tailscale status --json`.
    ///   - address: the first IPv4 tailnet address, when there is one.
    public static func read(
        found: Bool, sandboxed: Bool, backendState: String?, address: String?
    ) -> TailscaleReading {
        if let address, !address.isEmpty, backendState == nil || backendState == "Running" {
            return .up(address: address)
        }
        guard found else { return sandboxed ? .sandboxed : .notInstalled }
        switch backendState {
        case "Running":
            return address.map(TailscaleReading.up) ?? .daemonDown
        case "NeedsLogin", "NoState", "Starting":
            return .loggedOut
        case "Stopped":
            return .daemonDown
        default:
            return sandboxed ? .sandboxed : .daemonDown
        }
    }
}
