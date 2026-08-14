import CodingAgentKit
import Foundation

/// Asking a machine to start its server over, in the words every client uses for it.
///
/// A server that has been up for a week is running the model list, the config and the plugins it
/// resolved a week ago, and the machine it runs on is usually one the person asking cannot open a
/// terminal on. So the restart belongs where the server is explained, next to everything else about
/// it — and it belongs behind a sentence, because a restart is not free: whatever the machine is
/// answering right now stops where it stands.
public enum ServerRestart {
    public static var title: String { Localized.text("Restart server") }

    public static var detail: String {
        Localized.text("Picks up new models, config and plugins")
    }

    public static func confirmTitle(_ serverName: String) -> String {
        Localized.text("Restart %@?", serverName)
    }

    /// What it costs, said before the press rather than after it. The count is what this device
    /// knows is running on that machine, so it is stated only when there is something to state.
    public static func confirmBody(workingTurns: Int) -> String {
        let base = Localized.text(
            "The server stops answering for a few seconds and comes back with everything it reads at startup — models, config, plugins.")
        guard workingTurns > 0 else { return base }
        let cost =
            workingTurns == 1
            ? Localized.text("A turn is running on it. Restarting stops it where it stands.")
            : Localized.text(
                "%lld turns are running on it. Restarting stops them where they stand.",
                workingTurns)
        return base + "\n\n" + cost
    }

    public static var action: String { Localized.text("Restart") }
    public static var underway: String { Localized.text("Restarting…") }

    public static var symbol: String { "arrow.clockwise.circle" }
    public static var glyph: String { "⟳" }

    /// A server that cannot restart itself is offered the setup that makes it able to, in the same
    /// breath that says the restart failed: the failure and the fix are one decision, and a machine
    /// set up by hand is the one machine most in need of a press that does the setting up.
    public static var setupTitle: String { Localized.text("Set up this server") }

    public static var setupDetail: String {
        Localized.text(
            "This server was started by hand, so nothing on it can restart it. One press installs the managed service that keeps its model list current and lets every device restart it — no terminal needed on that machine.")
    }

    public static var setupAction: String { Localized.text("Set up") }
    public static var setupUnderway: String { Localized.text("Setting up…") }

    public static var setupFailedTitle: String { Localized.text("Setup did not take") }

    public static var setupFailedDetail: String {
        Localized.text(
            "The install ran but the machine does not restart cleanly. Run the opencode setup command on it by hand, then try again.")
    }

    /// A restart that failed and cannot be offered a setup either — the honest refusal, said the
    /// same on every desk.
    public static var refusedTitle: String { Localized.text("Cannot restart") }

    public static func refused(_ serverName: String) -> String {
        Localized.text("%@ cannot restart itself.", serverName)
    }

    /// Whether a machine can be offered the setup at all — a backend with no route for it should
    /// never show a press that cannot land.
    public static func isSettable(_ backend: any CodingAgentBackend) -> Bool {
        backend is any ServeManagerBackend
    }

    /// Whether this server can be asked at all. A machine set up by hand has no restart command on
    /// it, and the ask fails at the ask rather than looking like a restart that did nothing — but
    /// a client should not offer what a backend has no route for in the first place.
    public static func isOffered(_ backend: any CodingAgentBackend) -> Bool {
        backend is any RestartableBackend
    }

    /// The same question asked of a server nobody has connected to yet, so a row can be there on
    /// the first frame rather than appearing under the reader once a probe lands. A bridge answers
    /// no here because its restart is part of its update, where it belongs.
    public static func isOffered(_ backend: AgentType) -> Bool { backend == .openCode }
}
