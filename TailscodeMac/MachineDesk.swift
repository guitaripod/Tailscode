import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// What every machine says about itself beyond its conversations: the schedules it keeps and the
/// agents it hosts beside its own. One reading for the whole app, so the sidebar's Scheduled
/// entry, the Scheduled window, each server's Agents section and the news line never disagree
/// about a machine. Read on a slow beat, at once when the servers change, and after every press
/// that changes a machine; a machine that keeps no schedules or hosts no agents answers 404, which
/// is read as "this machine cannot say" and draws nothing rather than an empty list.
@MainActor
final class MachineDesk {
    static let shared = MachineDesk()
    static let didChange = Notification.Name("tailscode.mac.machineDesk.didChange")

    private(set) var board = ScheduleBoard.empty
    private(set) var reports: [String: MachineAgentsReport] = [:]
    /// The machines whose last answer to `/schedules` was a list, empty or not.
    private(set) var keepers: Set<String> = []
    private(set) var loadedOnce = false
    private var beat: Timer?
    private var loading = false
    private var stagedDemo = false

    /// The machines this app talks to with the backend each is reached through. A staged demo
    /// answers with the demo world's machine alone, so a picture is never of somebody's fleet.
    func servers() -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)] {
        if stagedDemo, let backend = DemoWorld.backend(for: DemoWorld.claudeProfile.id) {
            return [(DemoWorld.claudeProfile, backend)]
        }
        return ServerDirectory.shared.profiles.compactMap { profile in
            ServerDirectory.shared.backend(for: profile).map { (profile, $0) }
        }
    }

    func profile(_ id: String) -> ConnectionProfile? {
        servers().first { $0.profile.id == id }?.profile
    }

    func scheduling(for profileID: String) -> (any MachineScheduling)? {
        servers().first { $0.profile.id == profileID }?.backend as? any MachineScheduling
    }

    func hosting(for profileID: String) -> (any MachineAgentHosting)? {
        servers().first { $0.profile.id == profileID }?.backend as? any MachineAgentHosting
    }

    func backend(for profileID: String) -> (any CodingAgentBackend)? {
        servers().first { $0.profile.id == profileID }?.backend
    }

    /// Whether a schedule can be kept by this machine: it answered with its list, or it said so
    /// in its status. Neither is a guess about a machine nobody has asked.
    func keepsSchedules(_ profileID: String) -> Bool {
        if keepers.contains(profileID) { return true }
        guard let backend = backend(for: profileID) else { return false }
        return backend.capabilities.supportsSchedules && backend is any MachineScheduling
    }

    var anyKeepsSchedules: Bool {
        !keepers.isEmpty || servers().contains { keepsSchedules($0.profile.id) }
    }

    /// The demo machine in place of the real ones, for `--open` and the selftest.
    func stageDemo() {
        stagedDemo = true
        board = .empty
        reports = [:]
        keepers = []
    }

    func start() {
        guard beat == nil else { return }
        NotificationCenter.default.addObserver(
            forName: ServerDirectory.didChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MachineDesk.shared.refreshSoon() }
        }
        beat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MachineDesk.shared.refreshSoon() }
        }
        Task { await refresh() }
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    /// Every machine asked at once, schedules and agents together.
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await refreshSchedules()
        await refreshAgents()
        loadedOnce = true
        announce()
    }

    func refreshSchedules() async {
        let servers = servers()
        let answers = await withTaskGroup(of: (Int, ScheduleBoard.Source?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    guard let scheduling = server.backend as? any MachineScheduling,
                        let schedules = try? await scheduling.machineSchedules()
                    else { return (index, nil) }
                    return (
                        index,
                        ScheduleBoard.Source(
                            profileID: server.profile.id, machine: server.profile.name, schedules: schedules)
                    )
                }
            }
            var found: [(Int, ScheduleBoard.Source)] = []
            for await (index, source) in group {
                if let source { found.append((index, source)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        keepers = Set(answers.map(\.profileID))
        board = ScheduleBoard.make(answers)
        announce()
    }

    func refreshAgents(refreshBrains: Bool = false) async {
        let servers = servers()
        let answers = await withTaskGroup(of: (String, MachineAgentsReport?).self) { group in
            for server in servers {
                group.addTask {
                    guard let hosting = server.backend as? any MachineAgentHosting else {
                        return (server.profile.id, nil)
                    }
                    return (server.profile.id, try? await hosting.machineAgents(refreshBrains: refreshBrains))
                }
            }
            var found: [String: MachineAgentsReport] = [:]
            for await (id, report) in group {
                if let report { found[id] = report }
            }
            return found
        }
        let gainedReady = answers.contains { id, report in
            let before = Set((reports[id]?.agents ?? []).filter { $0.state == .ready }.map(\.id))
            return !Set(report.agents.filter { $0.state == .ready }.map(\.id)).isSubset(of: before)
        }
        reports = answers
        if gainedReady { await refreshCatalogs() }
        announce()
    }

    /// One machine's agents, read again after a press there.
    @discardableResult
    func refreshAgents(profileID: String, refreshBrains: Bool = false) async -> MachineAgentsReport? {
        guard let hosting = hosting(for: profileID) else { return nil }
        let report = try? await hosting.machineAgents(refreshBrains: refreshBrains)
        let before = Set((reports[profileID]?.agents ?? []).filter { $0.state == .ready }.map(\.id))
        reports[profileID] = report
        let after = Set((report?.agents ?? []).filter { $0.state == .ready }.map(\.id))
        if !after.isSubset(of: before) { await refreshCatalogs() }
        announce()
        return report
    }

    /// A ready agent is a section of the model chooser, so the catalogs the chooser is built from
    /// are read again the moment one becomes ready rather than on their own slow clock.
    private func refreshCatalogs() async {
        for server in servers() {
            await ModelCatalogStore.refresh(profileID: server.profile.id, backend: server.backend)
        }
    }

    /// The agents found on a machine and never mentioned, for the news line. The first machine
    /// with any is the one spoken of.
    func news() -> (profileID: String, machine: String, agents: [MachineAgent])? {
        for server in servers() {
            let unseen = AgentNewsStore.unseen(reports[server.profile.id], profileID: server.profile.id)
            if !unseen.isEmpty { return (server.profile.id, server.profile.name, unseen) }
        }
        return nil
    }

    func schedule(profileID: String, id: String) -> ScheduleRow? {
        board.rows.first { $0.profileID == profileID && $0.schedule.id == id }
    }

    func row(id: String) -> ScheduleRow? {
        board.rows.first { $0.schedule.id == id || $0.id == id }
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
