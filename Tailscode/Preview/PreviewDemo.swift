import MidgarCore
#if DEBUG
    import CodingAgentKit
    import TailscodeCore
    import UIKit

    /// Hand-built states for the viewer, so every face it can wear is looked at without a Mac that
    /// runs a host: `--preview <state>` presents these through the viewer's own test entry rather
    /// than a second code path, and `--preview-live HOST:PORT:/folder` presents it against a real
    /// host.
    @MainActor
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

        static func target(_ address: String) -> PreviewTarget? {
            let parts = address.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3, let port = Int(parts[1]), !parts[0].isEmpty, !parts[2].isEmpty else {
                return nil
            }
            return PreviewTarget(host: parts[0], port: port, project: parts[2])
        }

        /// The viewer for a fixture name, already holding that state, or nil for a name that is not
        /// one. The pictures are drawn rather than streamed, in the size the host sends.
        static func viewer(_ name: String) -> PreviewViewController? {
            guard names.contains(name) else { return nil }
            if name == "asking" {
                let viewer = PreviewViewController(target: nil, runs: false, secrets: PreviewMemorySecrets())
                viewer.loadViewIfNeeded()
                return viewer
            }
            let target = PreviewTarget(host: host, port: 4300, project: project)
            let viewer = PreviewViewController(target: target, runs: false, secrets: PreviewMemorySecrets())
            guard let state = state(name) else { return nil }
            let showsPicture = ["live", "reconnecting", "broken"].contains(name)
            viewer.applyForTest(state, jpeg: showsPicture ? picture : nil)
            return viewer
        }

        /// A phone's worth of screen drawn from nothing, so a fixture face has a picture to sit
        /// over: the size the host streams, a title, and a few rows of notes.
        static var picture: Data {
            if let path = ProcessInfo.processInfo.environment["TAILSCODE_PREVIEW_PICTURE"],
                let data = FileManager.default.contents(atPath: path)
            {
                return data
            }
            return drawn
        }

        private static let drawn: Data = {
            let size = CGSize(width: 604, height: 1312)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(white: 0.96, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                NSAttributedString(
                    string: "PhotoNotes",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: UIColor.black,
                    ]
                ).draw(at: CGPoint(x: 48, y: 150))
                let rows = ["Harbour at dusk", "Trip to Porvoo", "Sauna schedule", "Bike service", "Ideas"]
                for (index, row) in rows.enumerated() {
                    let top = 260 + CGFloat(index) * 170
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: CGRect(x: 36, y: top, width: 532, height: 140), cornerRadius: 28).fill()
                    UIColor(red: 0.35 + CGFloat(index) * 0.1, green: 0.55, blue: 0.85, alpha: 1).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 60, y: top + 24, width: 92, height: 92), cornerRadius: 18).fill()
                    NSAttributedString(
                        string: row,
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                            .foregroundColor: UIColor.black,
                        ]
                    ).draw(at: CGPoint(x: 176, y: top + 48))
                }
            }
            return image.jpegData(compressionQuality: 0.8) ?? Data()
        }()

        /// Presents a fixture or a live host over `presenter`, for `--preview <state>` and
        /// `--preview-live HOST:PORT:/folder`.
        static func presentIfAsked(from presenter: UIViewController) {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(where: { $0 == "--preview" || $0 == "--preview-live" }),
                arguments.indices.contains(index + 1)
            else { return }
            let value = arguments[index + 1]
            let viewer: PreviewViewController?
            if arguments[index] == "--preview-live" {
                viewer = target(value).map { PreviewViewController(target: $0) }
            } else {
                viewer = Self.viewer(value)
            }
            guard let viewer else {
                MidgarLog.error("preview: no fixture or host named \(value)", category: .ui)
                return
            }
            viewer.onAskAgent = { words in MidgarLog.info(
                "preview: asked the agent: \(words)",
                category: .ui
            ) }
            presenter.present(viewer, animated: false)
        }

        /// What the pure parts of the viewer promise, checked in the running app because the iOS
        /// target has no test bundle: the entry gate, the fixture faces, the controls only over a
        /// picture, the dim and the failure card, and a viewer that has been closed owning no clock
        /// and no runner.
        static func selfCheck() -> [String] {
            var failures: [String] = []
            func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
            let known = PreviewAccess(host: "mac.local", port: 4300)
            let lookup: (String) -> PreviewAccess? = { $0 == "mac.local" ? known : nil }
            expect(
                PreviewEntry.target(host: "mac.local", directory: "/p/App", access: lookup)?.project == "/p/App",
                "known host and folder offer a target")
            expect(PreviewEntry.target(host: "other", directory: "/p/App", access: lookup) == nil, "unknown host offers none")
            expect(PreviewEntry.target(host: "mac.local", directory: nil, access: lookup) == nil, "no folder offers none")
            expect(PreviewEntry.target(host: "mac.local", directory: "  ", access: lookup) == nil, "blank folder offers none")
            expect(PreviewEntry.target(host: nil, directory: "/p", access: lookup) == nil, "no host offers none")

            let summaries = Dictionary(
                uniqueKeysWithValues: names.compactMap { name in viewer(name).map { (name, $0) } })
            expect(summaries["asking"]?.summary == "asking", "asking face")
            expect(summaries["setup"]?.summary == "settingUp rows=6", "setup shows the six checks")
            expect(summaries["starting"]?.summary.hasPrefix("starting") == true, "starting has no picture yet")
            expect(summaries["live"]?.summary == "live 604x1312", "live face holds the picture")
            expect(summaries["live"]?.controlsVisible == true, "live shows the controls")
            expect(summaries["setup"]?.controlsVisible == false, "setup hides the controls")
            expect(summaries["live"]?.shownPictureAlpha == 1, "live picture is undimmed")
            expect(abs((summaries["reconnecting"]?.shownPictureAlpha ?? 1) - 0.55) < 0.001, "reconnecting dims the picture")
            expect(summaries["reconnecting"]?.shownChipWords == PreviewLight.stale.line, "reconnecting says so")
            expect(summaries["broken"]?.summary.hasPrefix("broken 604x1312 banner=NoteView.swift:42") == true, "broken keeps the picture under the first problem")
            for viewer in summaries.values {
                viewer.shutdown()
                expect(!viewer.hasLink && !viewer.isRunning, "a closed viewer owns no clock and no runner")
            }
            return failures
        }
    }

    /// Secrets held in memory only, so a viewer built by a check or a fixture never reaches for the
    /// Keychain.
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
#endif
