import AppKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore

extension MainWindowController {
    /// The one note after the Pro week, as a sheet on this window when nothing else is attached to it: which server stays
    /// connected and which rest, with the way to Pro and to the servers window where the kept server is chosen.
    func presentProWeekEndIfDue() {
        guard ProAccess.shared.isProWeekEndNoticeDue, let window, window.isVisible, window.attachedSheet == nil else {
            return
        }
        let saved = ServerDirectory.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        let resting = saved.filter { ServerDirectory.shared.isResting($0.id) }
        let kept = saved.filter { !ServerDirectory.shared.isResting($0.id) }
        ProAccess.shared.markProWeekEndNoticeShown()
        let alert = NSAlert()
        alert.messageText = ProWeek.endedTitle
        alert.informativeText = ProWeek.endedBody(kept: kept.map(\.name), resting: resting.map(\.name))
        alert.addButton(withTitle: Localized.text("Get Tailscode Pro"))
        if !resting.isEmpty { alert.addButton(withTitle: ProWeek.chooseServerTitle) }
        alert.addButton(withTitle: Localized.text("OK"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.presentPro()
            case .alertSecondButtonReturn where !resting.isEmpty: self?.presentServers()
            default: break
            }
        }
        MidgarLog.info("pro week end shown: \(kept.count) kept, \(resting.count) resting", category: .ui)
    }
}
