import AppKit
import CodingAgentKit
import TailscodeCore

/// Hand-built states for a preview pane, so every face it can wear is looked at and asserted on
/// without a Mac that runs a host: `--open preview[:state]` and the selftest both draw these
/// through the pane's own test entry rather than a second code path.
enum PreviewDemo {
    static let project = "/Users/marcus/pvtest/PhotoNotes"
    static let host = "mac.local"
    static let names = ["asking", "setup", "starting", "live", "reconnecting", "broken"]

    private static let device = DeviceInfo(
        udid: "FIXTURE", name: "iPhone 17 Pro", deviceType: "iPhone 17 Pro", runtime: "iOS 26.0")

    static func session(
        _ state: SessionState, step: String? = nil, build: BuildReport? = nil,
        frame: FrameInfo? = FrameInfo(width: 604, height: 1312)
    ) -> SessionInfo {
        SessionInfo(
            id: "fixture", state: state, step: step, device: device,
            app: AppInfo(name: "PhotoNotes", bundleID: "com.example.PhotoNotes"),
            project: ProjectRef(path: project), lastBuild: build, frame: frame, startedAt: Date(),
            restarts: 0)
    }

    static let failedBuild = BuildReport(
        ok: false, path: .rebuilt, trigger: "NoteView.swift", seconds: 4.2, finishedAt: Date(),
        issues: [
            BuildIssue(
                severity: .error, message: "cannot find 'noteTitle' in scope",
                file: "\(project)/NoteView.swift", line: 42, column: 9)
        ])

    static func state(_ name: String) -> PreviewState? {
        var state = PreviewState()
        switch name {
        case "setup":
            state.phase = .settingUp
            state.checks = [
                DoctorCheck(id: "silicon", title: "silicon", state: .ok),
                DoctorCheck(id: "xcode", title: "xcode", state: .ok),
                DoctorCheck(id: "firstLaunch", title: "firstLaunch", state: .needsYou),
                DoctorCheck(id: "runtime", title: "runtime", state: .fixable, fix: "downloadIOSRuntime"),
                DoctorCheck(id: "streamer", title: "streamer", state: .working, fix: "installStreamer"),
                DoctorCheck(id: "disk", title: "disk", state: .failed),
            ]
            state.fixes["installStreamer"] = FixJob(
                id: "job", check: "streamer", state: .running, fraction: 0.4)
        case "starting":
            state.phase = .starting
            state.session = session(.building, step: "Building your app", frame: nil)
        case "live":
            state.phase = .live
            state.session = session(.live)
        case "reconnecting":
            state.phase = .reconnecting
            state.session = session(.live)
        case "broken":
            state.phase = .live
            state.session = session(.live, build: failedBuild)
        default:
            return nil
        }
        return state
    }

    /// A phone's worth of screen drawn from nothing, so a fixture face has a picture to sit over:
    /// the size the host streams, a title, and a few rows of notes.
    static var picture: Data {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["TAILSCODE_PREVIEW_PICTURE"],
                let data = FileManager.default.contents(atPath: path)
            {
                return data
            }
        #endif
        return drawn
    }

    private static let drawn: Data = {
        let width = 604
        let height = 1312
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let title = NSAttributedString(
            string: "PhotoNotes",
            attributes: [
                .font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.black,
            ])
        title.draw(at: NSPoint(x: 48, y: height - 220))
        let rows = ["Harbour at dusk", "Trip to Porvoo", "Sauna schedule", "Bike service", "Ideas"]
        for (index, row) in rows.enumerated() {
            let top = CGFloat(height) - 320 - CGFloat(index) * 170
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 36, y: top - 140, width: 532, height: 140), xRadius: 28, yRadius: 28)
                .fill()
            NSColor(calibratedRed: 0.35 + CGFloat(index) * 0.1, green: 0.55, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 60, y: top - 116, width: 92, height: 92), xRadius: 18, yRadius: 18)
                .fill()
            NSAttributedString(
                string: row,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: NSColor.black,
                ]
            ).draw(at: NSPoint(x: 176, y: top - 88))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
    }()

    static func target(_ address: String) -> PreviewTarget? {
        let parts = address.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3, let port = Int(parts[1]), !parts[0].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return PreviewTarget(host: parts[0], port: port, project: parts[2])
    }
}

/// Secrets held in memory only, so a pane built by a check or a fixture never reaches for the
/// Keychain and a headless run is never stopped by a prompt.
final class PreviewMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: String] = [:]

    func value(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return held[key]
    }

    func setValue(_ value: String, for key: String) throws {
        lock.lock()
        held[key] = value
        lock.unlock()
    }

    func removeValue(for key: String) throws {
        lock.lock()
        held[key] = nil
        lock.unlock()
    }
}
