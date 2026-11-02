import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

extension HomeViewController {
    /// The one note after the Pro week, shown when Home is in front with nothing over it: which server stays connected and
    /// which rest, with the way to Pro and to choosing the server that stays.
    func presentProWeekEndIfDue() {
        guard ProAccess.shared.isProWeekEndNoticeDue, view.window != nil,
            (navigationController ?? self).presentedViewController == nil
        else { return }
        let saved = ConnectionController.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        let resting = saved.filter { ConnectionController.shared.isResting($0.id) }
        let kept = saved.filter { !ConnectionController.shared.isResting($0.id) }
        ProAccess.shared.markProWeekEndNoticeShown()
        let alert = UIAlertController(
            title: ProWeek.endedTitle,
            message: ProWeek.endedBody(kept: kept.map(\.name), resting: resting.map(\.name)),
            preferredStyle: .alert)
        let pro = UIAlertAction(title: String(localized: "Get Tailscode Pro"), style: .default) { [weak self] _ in
            guard let self else { return }
            ProUpgradeViewController.present(from: self)
        }
        alert.addAction(pro)
        if !resting.isEmpty {
            alert.addAction(
                UIAlertAction(title: ProWeek.chooseServerTitle, style: .default) { [weak self] _ in
                    self?.openSettings()
                })
        }
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        alert.preferredAction = pro
        present(alert, animated: true)
        MidgarLog.info("pro week end shown: \(kept.count) kept, \(resting.count) resting", category: .ui)
    }
}
