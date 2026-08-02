import Foundation

/// `TAILSCODE_TRACE=1` prints millisecond-stamped marks for the paths worth watching — the same
/// stdout a `TAILSCODE_DRIVE` run records, so a headless timing session reads as one log.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["TAILSCODE_TRACE"] != nil
    private static let epoch = ContinuousClock.now

    static func mark(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        let elapsed = (ContinuousClock.now - epoch).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        FileHandle.standardOutput.write(Data("TRACE +\(ms)ms \(label())\n".utf8))
    }
}
