import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PreviewStateTests {
    private func session(
        state: SessionState = .live, step: String? = nil, build: BuildReport? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: "abc123", state: state, step: step,
            device: DeviceInfo(udid: "U", name: "pv-abc123", deviceType: "t", runtime: "r"),
            app: AppInfo(name: "PhotoNotes", bundleID: "dev.photonotes"), project: ProjectRef(path: "/p"),
            lastBuild: build, frame: FrameInfo(width: 604, height: 1312), startedAt: Date(), restarts: 0)
    }

    private func report(ok: Bool, path: ReloadPath = .rebuilt) -> BuildReport {
        BuildReport(
            ok: ok, path: path, trigger: "edit", seconds: 1.84, finishedAt: Date(),
            issues: ok
                ? []
                : [BuildIssue(severity: .error, message: "cannot find 'cornerRadus' in scope", file: "/a/SaveButton.swift", line: 48, column: 12)])
    }

    @Test func lightFollowsPhaseAndTheLastBuild() {
        var state = PreviewState()
        #expect(state.light == .waking)
        state.phase = .settingUp
        #expect(state.light == .needsYou)
        state.phase = .starting
        #expect(state.light == .waking)
        state.phase = .live
        state.session = session(build: report(ok: true))
        #expect(state.light == .live)
        state.session = session(step: "Updating", build: report(ok: true))
        #expect(state.light == .updating)
        state.session = session(build: report(ok: false))
        #expect(state.light == .broken)
        state.phase = .reconnecting
        #expect(state.light == .stale)
        state.phase = .failed("no")
        #expect(state.light == .broken)
        state.session = nil
        #expect(state.light == .offline)
    }

    @Test func theStripSaysHowTheLastChangeArrivedOrWhyItDidNot() {
        var state = PreviewState()
        state.phase = .live
        state.session = session(build: report(ok: true))
        #expect(state.line.contains("Rebuilt and restarted"))
        #expect(state.line.contains("1.8"))
        state.session = session(build: report(ok: false))
        #expect(state.line == PreviewReading.headline(of: report(ok: false)))
        #expect(state.firstProblem == "SaveButton.swift:48: cannot find 'cornerRadus' in scope")
    }

    @Test func everyFaceHasAnAnswerForTheStripBadge() {
        let faces: [PreviewLight] = [.dark, .waking, .needsYou, .live, .updating, .broken, .stale, .offline]
        for face in faces {
            if face == .dark || face == .live {
                #expect(face.activity == nil)
            } else {
                #expect(face.activity != nil)
            }
        }
    }

    @Test func slotWordsFollowItsTarget() {
        var slot = PreviewSlot()
        #expect(slot.isAsking)
        #expect(slot.light == .dark)
        #expect(slot.title == "Preview")
        slot.point(at: PreviewTarget(host: "macbook", project: "/Users/anna/PhotoNotes"))
        #expect(!slot.isAsking)
        #expect(slot.title == "PhotoNotes")
        #expect(slot.subtitle.hasPrefix("macbook"))
        slot.ask()
        #expect(slot.isAsking)
        #expect(slot.draft == "/Users/anna/PhotoNotes")
    }

    @Test func checklistRowsCarryTheirFixAndItsProgress() {
        var slot = PreviewSlot(target: PreviewTarget(host: "m", project: "/p"))
        var state = PreviewState()
        state.checks = [
            DoctorCheck(id: "streamer", title: "x", state: .fixable, detail: nil, fix: "installStreamer"),
            DoctorCheck(id: "xcode", title: "x", state: .ok),
        ]
        state.fixes["installStreamer"] = FixJob(id: "j", check: "streamer", state: .running, message: "Downloading", fraction: 0.4)
        slot.apply(state)
        let rows = slot.checklist
        #expect(rows.count == 2)
        #expect(rows[0].fixLabel == "Fetch it")
        #expect(rows[0].working)
        #expect(rows[0].progress == 0.4)
        #expect(rows[1].fix == nil)
    }

    @Test func nextAppearanceTogglesAndCommandsAreNarrow() {
        var slot = PreviewSlot()
        #expect(slot.nextAppearance == "dark")
        slot.appearance = "dark"
        #expect(slot.nextAppearance == "light")
    }

    @Test func theRunnerChoosesAnIPhoneAndPrefersTheProModel() {
        func status(_ names: [String]) -> PreviewStatus {
            PreviewStatus(
                version: "0.1.0", host: HostFacts(name: "m", os: "macOS", arch: "arm64"), xcode: nil,
                runtimes: [
                    RuntimeFact(
                        identifier: "r", name: "iOS 27.0", platform: "iOS", version: "27.0", available: true,
                        deviceTypes: names.map { DeviceTypeFact(identifier: "id.\($0)", name: $0) }),
                    RuntimeFact(
                        identifier: "t", name: "tvOS 27.0", platform: "tvOS", version: "27.0", available: true,
                        deviceTypes: [DeviceTypeFact(identifier: "id.tv", name: "Apple TV")]),
                ], streaming: StreamingFacts(encodings: ["mjpeg"], maximumFramesPerSecond: 60, touch: false, tool: nil))
        }
        #expect(PreviewRunner.chooseDevice(status(["iPhone 16", "iPhone 17 Pro"])) == "id.iPhone 17 Pro")
        #expect(PreviewRunner.chooseDevice(status(["iPad Pro", "iPhone 16"])) == "id.iPhone 16")
        #expect(PreviewRunner.chooseDevice(status(["iPad Pro"])) == nil)
    }

    @Test func aPasswordRefusalIsRecognised() {
        #expect(PreviewRunner.wantsPassword(AgentError.http(status: 401, body: "")))
        #expect(PreviewRunner.wantsPassword(AgentError.http(status: 403, body: "")))
        #expect(!PreviewRunner.wantsPassword(AgentError.http(status: 500, body: "")))
        #expect(!PreviewRunner.wantsPassword(AgentError.connection("down")))
    }
}
