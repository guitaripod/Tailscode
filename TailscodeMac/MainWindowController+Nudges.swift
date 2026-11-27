import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// Sends a nudge to every chosen chat at once. A chat a pane is showing goes through that
    /// pane's ordinary send, so it is echoed there at once; the rest go straight to their servers
    /// together. What happened is one sentence, and the list is asked again so the rows that
    /// started a turn say so.
    func sendNudge(_ nudge: ChatNudge, to chosen: [SessionEntry]) {
        var direct: [SessionEntry] = []
        var sentHere = 0
        var workingHere = 0
        for entry in chosen {
            guard let pane = pane(showing: entry) else {
                direct.append(entry)
                continue
            }
            if pane.composer.running {
                workingHere += 1
            } else {
                pane.composer.sendNudge(nudge)
                sentHere += 1
            }
        }
        var backends: [String: any CodingAgentBackend] = [:]
        for profile in ServerDirectory.shared.profiles
        where direct.contains(where: { $0.profileID == profile.id }) {
            backends[profile.id] = ServerDirectory.shared.backend(for: profile)
        }
        let resolved = backends
        Task { [weak self] in
            let outcome = await ChatNudgeRun.send(nudge, to: direct) { entry in
                resolved[entry.profileID]
            }
            let whole = ChatNudgeOutcome(
                nudge: nudge, sent: outcome.sent + sentHere, working: outcome.working + workingHere,
                failed: outcome.failed, reason: outcome.reason)
            guard let self else { return }
            if whole.failed > 0 { self.setNotice(whole.sentence) } else { self.toast(whole.sentence) }
            await self.sidebar.refresh()
        }
    }

    private func pane(showing entry: SessionEntry) -> TranscriptViewController? {
        var found: TranscriptViewController?
        splitPanes.eachPane { pane in
            guard found == nil, let shown = pane.currentEntry,
                shown.session.id == entry.session.id, shown.profileID == entry.profileID,
                pane.composer.lastState != nil
            else { return }
            found = pane
        }
        return found
    }
}
