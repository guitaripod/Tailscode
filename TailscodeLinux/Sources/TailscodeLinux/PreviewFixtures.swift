import CodingAgentKit
import Foundation
import TailscodeCore

/// Hand-built states for a preview pane, so every face it can wear is looked at and asserted on
/// without a Mac: the harness driver and the selftest both draw these, through the pane's own
/// test entry rather than a second code path.
enum PreviewFixtures {
    static let project = "/Users/marcus/pvtest/PhotoNotes"

    static let tinyJPEG = Data(
        base64Encoded:
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAaAAwDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDNijq0sfFEUdWVj4redc58NU0FijqysfFMiq0vSvInUZx4aTsf/9k="
    ) ?? Data()

    private static let device = DeviceInfo(
        udid: "FIXTURE", name: "iPhone 17 Pro", deviceType: "iPhone 17 Pro", runtime: "iOS 26.0")

    static func session(
        _ state: SessionState, step: String? = nil, build: BuildReport? = nil,
        frame: FrameInfo? = FrameInfo(width: 12, height: 26)
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
            state.session = session(.building, step: "Building", frame: nil)
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
}

extension ChatPane {
    /// Draws one of the fixture faces in this pane. A live runner is ended first, so a real host
    /// cannot repaint over the face being looked at; the last real picture is kept for the faces
    /// that sit over one.
    func drivePreviewFixture(_ name: String) {
        guard name != "asking" else {
            showPreview(nil)
            return
        }
        guard let state = PreviewFixtures.state(name) else { return }
        if preview == nil {
            showPreview(
                PreviewTarget(host: "mac.local", project: PreviewFixtures.project), runs: false)
        }
        guard let preview else { return }
        preview.freeze()
        if name == "starting" || name == "setup" { preview.discardPicture() }
        let wantsPicture = name == "live" || name == "reconnecting" || name == "broken"
        preview.applyForTest(
            state, jpeg: wantsPicture ? preview.lastPictureJPEG ?? PreviewFixtures.tinyJPEG : nil)
    }
}
