import Foundation
import MidgarCore
import os
import QuartzCore

/// Where the window's time goes, named so it can be read rather than guessed.
///
/// Every interval here is a signpost, which costs next to nothing unless Instruments is recording —
/// the Points of Interest track then shows each chat opened, each state applied, each body opened
/// and each list redrawn against the frames around it. The one number worth keeping from the field
/// is written to the log as well: how long a click on a chat took to put its words on screen, as
/// `journey open`, which `log stream --predicate 'category == "performance"'` reads without a
/// debugger.
enum Pace {
    static let signposter = OSSignposter(
        subsystem: "com.guitaripod.tailscode", category: "performance")
    static let log = Logger(subsystem: "com.guitaripod.tailscode", category: "performance")

    /// `TAILSCODE_TRACE=1` writes the length of each named stage to the log, for a run that has to
    /// say where a window's opening time went rather than be sampled through Instruments.
    static let traces = ProcessInfo.processInfo.environment["TAILSCODE_TRACE"] != nil

    static func traceStart() -> CFTimeInterval? {
        traces ? CACurrentMediaTime() : nil
    }

    static func traceEnd(_ name: String, _ start: CFTimeInterval?) {
        guard let start else { return }
        let milliseconds = (CACurrentMediaTime() - start) * 1000
        let line = "trace \(name): \(Int(milliseconds.rounded())) ms"
        MidgarLog.notice(line, category: .performance)
        if let data = (line + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
