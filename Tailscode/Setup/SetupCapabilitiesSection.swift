import CodingAgentKit
import TailscodeCore
import UIKit

/// What a server screen draws as its Capabilities section: Core's `SetupCapabilityRow` for each
/// capability the machine can do, kept current from the desk's own snapshots for as long as the
/// screen is on show and not a moment longer. It owns the watch and the rows; the screen owns the
/// cells, and is told when anything changed.
@MainActor
final class SetupCapabilitiesSection {
    private(set) var rows: [SetupCapabilityRow] = []

    var onChange: (() -> Void)?

    private let targets: [SetupTarget]
    private var snapshots: [SetupTarget: SetupSnapshot] = [:]
    private var lifetime = PaneLifetime()
    private var following = false

    init(profileURL: URL, profileID: String? = nil) {
        targets = SetupTargets.targets(forProfileURL: profileURL, profileID: profileID)
    }

    func start() {
        guard !following else { return }
        following = true
        for target in targets {
            SetupGate.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
                Task { @MainActor in self?.receive(snapshot) }
            }
        }
    }

    func stop() {
        guard following else { return }
        following = false
        lifetime.cancelAll()
    }

    func target(for capability: String) -> SetupTarget? { targets.first { $0.capability == capability } }

    private func receive(_ snapshot: SetupSnapshot) {
        guard following else { return }
        snapshots[snapshot.target] = snapshot
        let next = targets.compactMap { target in snapshots[target].flatMap { SetupCapabilityRow.row(for: $0) } }
        guard next != rows else { return }
        rows = next
        onChange?()
    }
}
