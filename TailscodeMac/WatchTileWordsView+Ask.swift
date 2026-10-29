import AppKit
import TailscodeCore

extension WatchTileWordsView {
    /// What the answers say now: where a press has got to, which of them are dead while one is out,
    /// and what a hold that was let go too soon is told. A failure's reason is shown beside them by
    /// the plan, and they stay live.
    func refreshAsk() {
        guard tile?.ask != nil, answers != .none else { return }
        let palette = face.palette
        let level = Self.levels[min(self.level, Self.levels.count - 1)]
        let font = face.type.prose(level.button, weight: .semibold)
        let busy: Bool
        switch phase {
        case .inFlight, .sent: busy = true
        case .idle, .failed: busy = false
        }
        let text = palette.text.watchColor()
        switch answers {
        case .holdAndDeny:
            deny.set(title: denyTitle(), font: font, ink: text)
            deny.wear(fill: NSColor.white.withAlphaComponent(0.08), rim: NSColor.white.withAlphaComponent(0.28))
            approve.set(title: approveTitle(), font: font, ink: text)
            approve.wear(
                fill: palette.working.watchColor(alpha: press == .holding ? 0.42 : 0.28),
                rim: palette.working.lifted(0.2).watchColor(alpha: 0.75))
            deny.isEnabled = !busy
            approve.isEnabled = !busy
            approve.toolTip = Localized.text("Press and hold to approve")
        case .openChat:
            chat.set(title: Localized.text("Open chat"), font: font, ink: text)
            chat.wear(
                fill: palette.needs.watchColor(alpha: 0.24), rim: palette.needs.lifted(0.2).watchColor(alpha: 0.7))
            chat.isEnabled = true
        case .none:
            break
        }
    }

    private func denyTitle() -> String {
        switch phase {
        case .inFlight(.deny): return Localized.text("Denying…")
        case .sent(.deny): return Localized.text("Denied")
        default: return Localized.text("Deny")
        }
    }

    private func approveTitle() -> String {
        switch phase {
        case .inFlight(.approve): return Localized.text("Approving…")
        case .sent(.approve): return Localized.text("Approved")
        default: break
        }
        switch press {
        case .holding: return Localized.text("Keep holding…")
        case .early: return Localized.text("Hold to approve")
        case .rest: return Localized.text("Approve")
        }
    }
}
