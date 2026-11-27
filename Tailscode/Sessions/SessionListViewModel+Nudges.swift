import CodingAgentKit
import TailscodeCore
import UIKit

extension SessionListViewModel {
    /// Sends a nudge to every chosen chat at once, straight to its server on the model and level
    /// its row names, then lists the servers again, because the chats it reached have just begun
    /// a turn and their rows should say so.
    func sendNudge(_ nudge: ChatNudge, to entries: [SessionEntry]) async -> ChatNudgeOutcome {
        var backends: [String: any CodingAgentBackend] = [:]
        for entry in entries where backends[entry.profileID] == nil {
            backends[entry.profileID] = backend(for: entry)
        }
        let resolved = backends
        let outcome = await ChatNudgeRun.send(nudge, to: entries) { resolved[$0.profileID] }
        if outcome.sent > 0 { await load(fresh: true) }
        return outcome
    }

    /// One menu item for each nudge a listed chat can take now, none while its turn is out.
    func nudgeActions(
        for entry: SessionEntry, report: @escaping @MainActor (ChatNudgeOutcome) -> Void
    ) -> [UIAction] {
        guard !ChatNudge.turnOpen(entry) else { return [] }
        return ChatNudge.all.map { nudge in
            UIAction(
                title: nudge.title, subtitle: nudge.hint, image: UIImage(systemName: nudge.symbol)
            ) { [weak self] _ in
                Theme.Haptics.send()
                Task { [weak self] in
                    guard let self else { return }
                    report(await self.sendNudge(nudge, to: [entry]))
                }
            }
        }
    }
}
