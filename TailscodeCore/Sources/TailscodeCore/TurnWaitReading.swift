import Foundation

/// Whether a server can promise to tell this phone when a turn ends while Tailscode is closed —
/// the server side of the question. The device side (Background App Refresh, force-quit) governs
/// every server at once and lives in `BackgroundWakeReading` below, because a server that waits
/// perfectly well still says nothing when that standing fact is against it.
///
/// Toolkit-free like `TailscaleReading` and for the same reason: the type that actually decides
/// this, CodingAgentKit's `TurnWaitSupport`, post-dates the Kit version Core is pinned to, so a
/// caller reads that decision on its own copy of the Kit and turns it into one of these before
/// asking Core for the sentence. Nothing here names a wire route, a bridge, or a status code —
/// only what is true and what, if anything, fixes it.
public enum TurnWaitAvailability: Sendable, Equatable {
    /// This server holds the wait open and answers it when the turn ends or needs the person.
    case waits
    /// The server's generation supports the route; this particular server predates it.
    case serverTooOld(product: String)
    /// opencode 1.x has no route to wait on at all — a generation gap, not a version behind.
    case openCodeGeneration
    /// Tried just now and could not tell whether the server supports this at all — a transport
    /// failure, an auth problem, or anything else that says nothing about the server's age or
    /// generation. Never confused with `unknown`: this device did ask.
    case unreachable
    /// Not yet asked.
    case unknown

    /// The one line a server row or its detail screen wears about this. Never claims a wake the
    /// platform reserves the right to skip — that qualification lives in `BackgroundWakeReading`
    /// and the footers, said once rather than folded into every sentence here.
    public var sentence: String {
        switch self {
        case .waits:
            return Localized.text("Tells this iPhone when a turn ends, straight over your tailnet.")
        case .serverTooOld(let product):
            return Localized.text(
                "Update %@ to be told when a turn ends while Tailscode is closed.", product)
        case .openCodeGeneration:
            return Localized.text("opencode 1.x can't be waited on. opencode 2 can.")
        case .unreachable:
            return Localized.text(
                "Tailscode couldn't reach this server to find out whether it can be waited on.")
        case .unknown:
            return Localized.text("Tailscode hasn't checked yet whether this server can be waited on.")
        }
    }

    /// Whether this state is worth arming a wait for at all — `false` means there is nothing this
    /// device could hold open on the server, whatever Background App Refresh says.
    public var canWait: Bool {
        self == .waits
    }
}

/// The fact that overrides every server's own answer: iOS will not wake this app for a background
/// session event at all unless Background App Refresh is on for it, and no server's support
/// changes that. Shown once, in Settings ▸ Notifications, rather than repeated per server.
public enum BackgroundWakeReading {
    public static let deniedLine = Localized.text(
        "Background App Refresh is off for Tailscode, so a turn that ends while it's closed stays silent until you open it."
    )
    public static let openSettingsAction = Localized.text("Open Settings")
}

/// Standing notes shown wherever the wait itself is explained — never a warning about a fault,
/// since both are simply how a wait held from this phone, over its own tailnet, actually works.
public enum TurnWaitFooters {
    public static let forceQuit = Localized.text(
        "Swiping Tailscode away stops the wait until you open it again.")
    public static let privacy = Localized.text(
        "The wait itself runs straight over your tailnet. None of it passes through Midgar or Apple."
    )
}
