import CodingAgentKit
import Foundation

/// Keeping a server current from the phone that talks to it.
///
/// The bridge runs on a machine the person holding the phone usually cannot open a terminal on, so
/// the app asks it to update itself and then watches. The watching is the hard part: the last step
/// of an update is a restart, so the server stops answering for a few seconds in the middle of the
/// job it was asked to do. A failed poll is therefore not a failure — the state lives on the
/// server's disk and is read back once it returns.
@MainActor
final class BridgeUpdater {
    enum State: Equatable {
        case unknown
        case checking
        case current(ServerUpdate)
        case available(ServerUpdate)
        case blocked(ServerUpdate)
        case unsupported
        case unreachable
        case working(ServerUpdate)
        case failed(ServerUpdate)
    }

    private(set) var state: State = .unknown
    var onChange: ((State) -> Void)?

    /// The one command that installs or updates a bridge, for a server that cannot do it itself.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash"

    private var backend: (any SelfUpdatingBackend)?
    private var poll: Task<Void, Never>?

    func stop() { poll?.cancel() }

    func attach(_ backend: (any CodingAgentBackend)?) {
        self.backend = backend as? any SelfUpdatingBackend
    }

    /// A check right after an update lands in the server's restart, so a refused connection is
    /// retried before it is believed: the answer is a few seconds away, not gone.
    /// `force` is how the watcher gets its answer: an ordinary check refuses to disturb an update
    /// in flight, and the check that ends one is made from inside it.
    func check(force: Bool = false) async {
        guard let backend else {
            set(.unsupported)
            return
        }
        if !force, case .working = state { return }
        set(.checking)
        for attempt in 0..<3 {
            do {
                let status = try await backend.updateStatus(checkingRemote: true)
                set(Self.state(for: status))
                if status.isRunning { watch() }
                return
            } catch AgentError.http(let code, _) where code == 404 {
                set(.unsupported)
                return
            } catch AgentError.unsupported {
                set(.unsupported)
                return
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        set(.unreachable)
    }

    func update() async {
        guard let backend else { return }
        AppLogger.connection.info("bridge update requested")
        do {
            let status = try await backend.startUpdate()
            guard status.isRunning else {
                set(Self.state(for: status))
                return
            }
            set(.working(status))
            watch()
        } catch {
            AppLogger.connection.error("bridge update refused: \(error.localizedDescription)")
            set(.unreachable)
        }
    }

    /// Polls until the server reports the job finished. A restart in the middle answers nothing;
    /// that reads as "still working", not as a failure, until the job is far past any plausible
    /// build time.
    private func watch() {
        poll?.cancel()
        poll = Task { [weak self] in
            let deadline = Date().addingTimeInterval(20 * 60)
            var unanswered = 0
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let backend = self.backend else { return }
                guard let status = try? await backend.updateStatus(checkingRemote: false) else {
                    unanswered += 1
                    if unanswered > 20 { self.set(.unreachable) }
                    continue
                }
                unanswered = 0
                if status.isRunning {
                    self.set(.working(status))
                    continue
                }
                await self.check(force: true)
                return
            }
        }
    }

    private static func state(for status: ServerUpdate) -> State {
        if status.isRunning { return .working(status) }
        if status.phase == .failed { return .failed(status) }
        if status.updateAvailable { return status.canUpdate ? .available(status) : .blocked(status) }
        if !status.canUpdate, status.reason != nil { return .blocked(status) }
        return .current(status)
    }

    private func set(_ next: State) {
        guard state != next else { return }
        state = next
        onChange?(next)
    }
}

extension BridgeUpdater.State {
    var status: ServerUpdate? {
        switch self {
        case .current(let status), .available(let status), .blocked(let status),
            .working(let status), .failed(let status):
            return status
        case .unknown, .checking, .unsupported, .unreachable:
            return nil
        }
    }
}
