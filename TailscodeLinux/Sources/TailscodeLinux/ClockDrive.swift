import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// `clock=glance`, `clock=sheet`, `clock=scrub:<minute>`, `clock=follow`, `clock=notify`,
    /// `clock=search:<words>`, `clock=copy:<iso|utc|epoch>`, `clock=close`: the world clock's
    /// surfaces put on screen without a pointer, so a screenshot of them is the same twice. Each
    /// says what it did on one line.
    func driveClock(_ argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "glance":
            clockChip.showGlance()
        case "sheet":
            clockChip.hideGlance()
            presentClock()
        case "scrub":
            MeridianSheet.current?.driveScrub(minute: Int(value) ?? 0)
        case "follow":
            MeridianSheet.current?.driveFollow()
        case "notify":
            MeridianSheet.current?.driveNotify()
        case "search":
            MeridianSheet.current?.driveSearch(value)
        case "copy":
            MeridianSheet.current?.driveCopy(value)
        case "close":
            clockChip.hideGlance()
            MeridianSheet.close()
        default:
            break
        }
        let sheet = MeridianSheet.current?.summary ?? "sheet=shut"
        FileHandle.standardOutput.write(Data("CLOCK \(clockChip.line) \(sheet)\n".utf8))
    }
}
