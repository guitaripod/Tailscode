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

    /// How a server carries out a restart. opencode is asked and forgotten: the connection the ask
    /// went over dies with the process. A bridge holds the restart behind its own idle check and
    /// reports it as a job, so it is followed the way an update is.
    public enum Course: Sendable, Equatable {
        case asked
        case followed
    }

    public static func course(for agent: AgentType) -> Course {
        agent == .openCode ? .asked : .followed
    }

    /// What it costs, said before the press rather than after it. The count is what this device
    /// knows is running on that machine, so it is stated only when there is something to state.
    public static func confirmBody(for agent: AgentType, workingTurns: Int) -> String {
        switch course(for: agent) {
        case .asked: return askedBody(workingTurns: workingTurns)
        case .followed: return followedBody(workingTurns: workingTurns)
        }
    }

    private static func askedBody(workingTurns: Int) -> String {
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

    /// A bridge never takes a turn with it, so the cost is time rather than work: it waits.
    private static func followedBody(workingTurns: Int) -> String {
        let base = Localized.text(
            "It waits until nothing is running on it, then restarts and comes back with everything it reads at startup — models, config, plugins.")
        guard workingTurns > 0 else { return base }
        let wait =
            workingTurns == 1
            ? Localized.text("A turn is running on it. The restart waits for it to finish.")
            : Localized.text(
                "%lld turns are running on it. The restart waits for them to finish.",
                workingTurns)
        return base + "\n\n" + wait
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

    /// How this backend would be restarted, or nil when it has no route for it. A machine set up by
    /// hand has no restart command on it, and the ask fails at the ask rather than looking like a
    /// restart that did nothing — but a client should not offer what a backend has no route for.
    public static func course(for backend: any CodingAgentBackend) -> Course? {
        if backend is any SelfUpdatingBackend { return .followed }
        if backend is any RestartableBackend { return .asked }
        return nil
    }

    public static func isOffered(_ backend: any CodingAgentBackend) -> Bool {
        course(for: backend) != nil
    }

    public static var allTitle: String { Localized.text("Restart all servers") }

    public static func allConfirmTitle(_ count: Int) -> String {
        Localized.text("Restart all %lld servers?", count)
    }

    /// What restarting everything costs. `openCodeTurns` is nil when no opencode server is among
    /// them: that is the one kind that cannot wait for a quiet moment, so it is named only when it
    /// is there to be named.
    public static func allConfirmBody(openCodeTurns: Int?) -> String {
        let base = Localized.text(
            "Each server waits until nothing is running on it, then restarts and comes back with everything it reads at startup.")
        guard let openCodeTurns else { return base }
        let cost =
            openCodeTurns == 0
            ? Localized.text("opencode cannot wait, so it restarts at once.")
            : openCodeTurns == 1
                ? Localized.text(
                    "opencode cannot wait, so it restarts at once and stops the turn it is running.")
                : Localized.text(
                    "opencode cannot wait, so it restarts at once and stops the %lld turns it is running.",
                    openCodeTurns)
        return base + "\n\n" + cost
    }

    /// The turns an opencode server among these would stop, or nil when there is none. It is the one
    /// kind that cannot wait for a quiet moment, so it is the only one whose turns are a cost.
    public static func openCodeTurns(among servers: [(agent: AgentType, workingTurns: Int)]) -> Int? {
        let openCode = servers.filter { $0.agent == .openCode }
        guard !openCode.isEmpty else { return nil }
        return openCode.reduce(0) { $0 + $1.workingTurns }
    }

    public static func allUnderway(done: Int, total: Int) -> String {
        Localized.text("%lld of %lld restarted…", done, total)
    }

    public static func allRefused(_ names: [String]) -> String {
        Localized.text("Couldn't restart %@.", names.joined(separator: ", "))
    }
}
