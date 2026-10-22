import CodingAgentKit
import Foundation
import TailscodeCore

/// The tailnet asked, once and without a window, which agents answer. First run uses it while a
/// person installs a machine: the first answer is the baseline, and a machine in a later one that
/// was not there before is the one being installed. The store build asks the API; the direct build
/// asks the command line. Either road that comes back empty is a watch that waits, not a failure.
enum FirstRunMachineScan {
    static func once() async -> [TailnetScanner.Suggestion] {
        let listing = await MacTailnetList.load(includingThisMachine: true)
        guard !listing.devices.isEmpty else { return [] }
        let found = await DiscoverySurvey.within(30) {
            await TailnetScanner().scan(devices: listing.devices)
        }
        return found ?? []
    }
}
