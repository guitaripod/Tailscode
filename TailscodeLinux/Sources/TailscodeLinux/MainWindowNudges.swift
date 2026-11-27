import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Sends a nudge to every chosen chat at once. A chat a pane is showing goes through that
    /// pane's ordinary send, so it is echoed there at once; the rest go straight to their servers
    /// together. What happened is one sentence, and the list is asked again so the rows that
    /// started a turn say so.
    func sendNudge(_ nudge: ChatNudge, to chosen: [SessionEntry]) {
        var direct: [SessionEntry] = []
        var sentHere = 0
        var workingHere = 0
        for entry in chosen {
            guard let pane = pane(showing: entry), pane.conversation != nil else {
                direct.append(entry)
                continue
            }
            if pane.sendsBusy {
                workingHere += 1
            } else {
                pane.sendNudge(nudge)
                sentHere += 1
            }
        }
        Task { [weak self] in
            let outcome = await ChatNudgeRun.send(nudge, to: direct) { entry in
                await Self.nudgeBackend(for: entry)
            }
            let whole = ChatNudgeOutcome(
                nudge: nudge, sent: outcome.sent + sentHere, working: outcome.working + workingHere,
                failed: outcome.failed, reason: outcome.reason)
            FileHandle.standardOutput.write(Data("NUDGE \(nudge.id) \(whole.sentence)\n".utf8))
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if whole.failed > 0 {
                    self.activePane.setNotice(whole.sentence)
                } else {
                    self.toast(whole.sentence)
                }
            }
            await self?.refresh()
        }
    }

    func pane(showing entry: SessionEntry) -> ChatPane? {
        var found: ChatPane?
        splitHost.eachPane { pane in
            guard found == nil, pane.sessionID == entry.session.id,
                pane.entry?.profileID == entry.profileID
            else { return }
            found = pane
        }
        return found
    }

    static func nudgeBackend(for entry: SessionEntry) async -> (any CodingAgentBackend)? {
        guard
            let profile = await ServerDirectory.shared.profiles().first(where: {
                $0.id == entry.profileID
            })
        else { return nil }
        return await ServerDirectory.shared.backend(for: profile)
    }
}
