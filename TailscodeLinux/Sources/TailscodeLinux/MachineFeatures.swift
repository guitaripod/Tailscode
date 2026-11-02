import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// What a machine keeps besides conversations — its own schedules, the agents it hosts — read the
/// way the Kit learns it: from the server's own `/status`, asked once if this process has not yet.
enum MachineFeatures {
    struct Reading: Sendable {
        var schedules: Bool
        var agents: Bool
    }

    static func read(_ backend: any CodingAgentBackend) async -> Reading {
        var capabilities = backend.capabilities
        if !capabilities.supportsSchedules || !capabilities.supportsMachineAgents {
            _ = try? await backend.health()
            capabilities = backend.capabilities
        }
        var schedules = capabilities.supportsSchedules && backend is any MachineScheduling
        var agents = capabilities.supportsMachineAgents && backend is any MachineAgentHosting
        if !schedules, let scheduling = backend as? any MachineScheduling {
            schedules = (try? await scheduling.machineSchedules()) != nil
        }
        if !agents, let hosting = backend as? any MachineAgentHosting {
            agents = (try? await hosting.machineAgents(refreshBrains: false)) != nil
        }
        return Reading(schedules: schedules, agents: agents)
    }

    /// Whether a backend could keep schedules at all, for a menu that has to decide without a
    /// round trip: a bridge can, opencode cannot. The sheet it opens asks the machine itself and
    /// says so when an older bridge cannot.
    static func mayKeepSchedules(_ backend: (any CodingAgentBackend)?) -> Bool {
        guard let backend else { return false }
        return backend.capabilities.supportsSchedules || backend is any MachineScheduling
    }

    /// Every configured machine with the backend that reaches it.
    static func servers() async -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)] {
        let profiles = await ServerDirectory.shared.profiles()
        var servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)] = []
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { continue }
            servers.append((profile, backend))
        }
        return servers
    }

    /// The machines that keep schedules, each asked once.
    static func schedulingServers() async -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)] {
        var kept: [(profile: ConnectionProfile, backend: any CodingAgentBackend)] = []
        for server in await servers() where await read(server.backend).schedules {
            kept.append(server)
        }
        return kept
    }

    /// This computer as a schedule's maker is named to the machine that keeps it.
    static var deviceName: String {
        let host = ProcessInfo.processInfo.hostName
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}
