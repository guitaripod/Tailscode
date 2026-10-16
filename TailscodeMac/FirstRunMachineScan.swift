import CodingAgentKit
import Foundation
import TailscodeCore

#if !TAILSCODE_MAS

    /// The tailnet asked, once and without a window, which agents answer. First run uses it while a
    /// person installs a machine: the first answer is the baseline, and a machine in a later one that
    /// was not there before is the one being installed.
    enum FirstRunMachineScan {
        static func once() async -> [TailnetScanner.Suggestion] {
            let survey = await Task.detached(priority: .utility) { DiscoverySurvey.read() }.value
            let devices = survey.scannable(includingThisMachine: true)
            guard !devices.isEmpty else { return [] }
            let found = await DiscoverySurvey.within(30) {
                await TailnetScanner().scan(devices: devices)
            }
            return found ?? []
        }
    }

#endif
