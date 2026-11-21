import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Every machine's masters, read together for the sidebar's shelf, the Masters window, a master's
/// page and the chooser. Read with the app's own machine refresh, after anything done here, and
/// every ten seconds while a master surface is on screen — never on a clock of its own otherwise.
final class MasterDesk: @unchecked Sendable {
    static let shared = MasterDesk()
    static let didChange = Notification.Name("tailscode.masters.didChange")

    private let lock = NSLock()
    private var heldBoard = MasterBoard.empty
    private var heldServers: [String: any CodingAgentBackend] = [:]
    private var heldProfiles: [String: ConnectionProfile] = [:]
    private var loading = false
    private var again = false
    private var watchers: Set<String> = []
    private var beating = false
    private(set) var loadedOnce = false

    static let beat: UInt32 = 10_000

    var board: MasterBoard { lock.withLock { heldBoard } }

    func backend(profileID: String) -> (any CodingAgentBackend)? { lock.withLock { heldServers[profileID] } }

    func keeping(profileID: String) -> (any MachineExperts)? { backend(profileID: profileID) as? any MachineExperts }

    func profile(_ id: String) -> ConnectionProfile? { lock.withLock { heldProfiles[id] } }

    func row(profileID: String, expertID: String) -> MasterRow? { board.row(profileID: profileID, expertID: expertID) }

    /// The master a conversation is a task of, when the shelf knows it.
    func master(for entry: SessionEntry) -> MasterRow? { board.master(for: entry.session, profileID: entry.profileID) }

    /// The masters on one machine, for a chooser or a hand-over aimed there.
    func masters(on profileID: String) -> [MasterRow] { board.rows.filter { $0.profileID == profileID } }

    /// Whether a machine could keep masters at all, for a menu that has to decide without a round
    /// trip: a claude-bridge can, opencode and omp-bridge cannot. The surface it opens asks.
    static func mayKeepMasters(_ backend: (any CodingAgentBackend)?) -> Bool {
        guard let backend, backend is any MachineExperts else { return false }
        return backend.capabilities.supportsExperts
    }

    /// Whether the shelf knows this machine keeps masters: it answered with them, or it said it
    /// keeps them and did not answer this read.
    func keepsExperts(profileID: String) -> Bool {
        let board = self.board
        return board.machines.contains { $0.profileID == profileID }
            || board.unanswered.contains { $0.profileID == profileID }
    }

    /// Reads every machine again. A read already going takes this ask with it once it lands.
    func refresh() {
        let start: Bool = lock.withLock {
            if loading {
                again = true
                return false
            }
            loading = true
            return true
        }
        guard start else { return }
        Task { [weak self] in
            var servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)] = []
            for server in await MachineFeatures.servers() where server.backend is any MachineExperts {
                if !server.backend.capabilities.supportsExperts { _ = try? await server.backend.health() }
                servers.append(server)
            }
            let board = await MasterBoard.load(servers)
            guard let self else { return }
            let rerun: Bool = self.lock.withLock {
                self.heldBoard = board
                self.heldServers = Dictionary(servers.map { ($0.profile.id, $0.backend) }) { first, _ in first }
                self.heldProfiles = Dictionary(servers.map { ($0.profile.id, $0.profile) }) { first, _ in first }
                self.loading = false
                self.loadedOnce = true
                let rerun = self.again
                self.again = false
                return rerun
            }
            AppLog.write(.lifecycle, "masters: \(board.rows.count) on \(board.machines.count) machines")
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            if rerun { self.refresh() }
        }
    }

    /// Puts a board in hand without asking any machine — what the selftest draws its windows from.
    func seed(_ board: MasterBoard, servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)]) {
        lock.withLock {
            heldBoard = board
            heldServers = Dictionary(servers.map { ($0.profile.id, $0.backend) }) { first, _ in first }
            heldProfiles = Dictionary(servers.map { ($0.profile.id, $0.profile) }) { first, _ in first }
            loadedOnce = true
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A surface that shows masters says so while it is open, and the desk reads the machines
    /// every ten seconds for as long as any does.
    func watch(_ key: String) {
        let startBeat: Bool = lock.withLock {
            watchers.insert(key)
            guard !beating else { return false }
            beating = true
            return true
        }
        if startBeat { beatOnce() }
    }

    func unwatch(_ key: String) {
        lock.withLock { _ = watchers.remove(key) }
    }

    private func beatOnce() {
        Gtk.after(Self.beat) { [weak self] in
            guard let self, !Gtk.isQuitting else { return }
            let keepGoing: Bool = self.lock.withLock {
                if self.watchers.isEmpty {
                    self.beating = false
                    return false
                }
                return true
            }
            guard keepGoing else { return }
            self.refresh()
            self.beatOnce()
        }
    }
}
