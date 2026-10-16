import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Preview reading")
struct PreviewReadingTests {

    private func check(
        _ id: String, _ state: DoctorCheck.State, title: String = "Raw", detail: String? = nil,
        fix: String? = nil, optional: Bool? = nil
    ) -> DoctorCheck {
        DoctorCheck(id: id, title: title, state: state, detail: detail, fix: fix, optional: optional)
    }

    private func report(
        ok: Bool = true, path: ReloadPath = .injected, seconds: Double = 1.25,
        issues: [BuildIssue] = []
    ) -> BuildReport {
        BuildReport(
            ok: ok, path: path, trigger: "save", seconds: seconds,
            finishedAt: Date(timeIntervalSince1970: 0), issues: issues)
    }

    @Test("A Mac is ready only when it has a checklist and every line is ok")
    func isReadyTable() {
        #expect(!PreviewReading.isReady([]))
        #expect(PreviewReading.isReady([check("xcode", .ok), check("disk", .ok)]))
        for state in [DoctorCheck.State.working, .fixable, .needsYou, .failed] {
            #expect(!PreviewReading.isReady([check("xcode", .ok), check("disk", state)]))
        }
    }

    @Test("An extra that is not on yet never holds the preview back, and an empty list of musts is not ready")
    func optionalChecksDoNotBlock() {
        let extras = [
            check("hotReload", .fixable, fix: "installHotReload", optional: true),
            check("inspector", .failed, optional: true),
        ]
        #expect(PreviewReading.isReady([check("xcode", .ok)] + extras))
        #expect(!PreviewReading.isReady([check("xcode", .needsYou)] + extras))
        #expect(!PreviewReading.isReady(extras))
    }

    @Test("The extras have words and a label for the button that turns them on")
    func extrasHaveWords() {
        #expect(PreviewReading.title(of: check("hotReload", .fixable)) == "Instant updates")
        #expect(PreviewReading.title(of: check("inspector", .fixable)) == "Screen inspector")
        #expect(PreviewReading.fixLabel("installHotReload") == "Turn it on")
        #expect(PreviewReading.fixLabel("installInspector") == "Build it")
        #expect(PreviewReading.detail(of: check("inspector", .fixable)) != nil)
    }

    @Test("Every check the host names has a title of its own")
    func titles() {
        let expected = [
            "silicon": "An Apple silicon Mac", "xcode": "Xcode installed",
            "firstLaunch": "Apple's license accepted", "runtime": "An iPhone to run it on",
            "streamer": "The screen streamer", "disk": "Room to build",
        ]
        for (id, title) in expected {
            #expect(PreviewReading.title(of: check(id, .ok)) == title)
        }
        #expect(PreviewReading.title(of: check("mystery", .ok, title: "Something new")) == "Something new")
    }

    @Test("Each check that needs a person says what to do about it")
    func details() {
        #expect(PreviewReading.detail(of: check("xcode", .needsYou))?.contains("App Store") == true)
        #expect(
            PreviewReading.detail(of: check("firstLaunch", .needsYou))?.contains(
                "sudo xcodebuild -runFirstLaunch") == true)
        #expect(PreviewReading.detail(of: check("runtime", .fixable))?.contains("downloaded") == true)
        #expect(PreviewReading.detail(of: check("streamer", .fixable))?.contains("fetched") == true)
        #expect(PreviewReading.detail(of: check("disk", .needsYou))?.contains("8 GB") == true)
        #expect(PreviewReading.detail(of: check("silicon", .failed))?.contains("Apple silicon") == true)
    }

    @Test("A line waiting on Xcode says so, and any other line keeps the host's own words")
    func detailFallbacks() {
        #expect(
            PreviewReading.detail(of: check("runtime", .working, detail: "Checked after Xcode"))
                == "Checked after Xcode")
        #expect(
            PreviewReading.detail(of: check("runtime", .working, detail: "Checked after Xcode is installed"))
                == "Checked after Xcode")
        #expect(PreviewReading.detail(of: check("xcode", .ok, detail: "26.1")) == "26.1")
        #expect(PreviewReading.detail(of: check("xcode", .ok)) == nil)
        #expect(PreviewReading.detail(of: check("mystery", .failed, detail: "raw")) == "raw")
    }

    @Test("Each fix the host offers is a button label, and an unknown one is still pressable")
    func fixLabels() {
        #expect(PreviewReading.fixLabel("showXcodeInAppStore") == "Show it on my Mac")
        #expect(PreviewReading.fixLabel("downloadIOSRuntime") == "Download it")
        #expect(PreviewReading.fixLabel("installStreamer") == "Fetch it")
        #expect(PreviewReading.fixLabel("somethingNew") == "Fix it")
    }

    @Test("A failure reads as one sentence with the detail kept apart")
    func headlineAndSummary() {
        #expect(
            PreviewReading.headline(of: report(ok: false))
                == "Your app stopped building after the last change.")
        #expect(PreviewReading.summary(of: report(path: .injected, seconds: 1.5)) == "Updated in place · 1.5 s")
        #expect(PreviewReading.words(for: .first) == "Built")
        #expect(PreviewReading.words(for: .injected) == "Updated in place")
        #expect(PreviewReading.words(for: .rebuilt) == "Rebuilt and restarted")
        #expect(PreviewReading.words(for: .scratch) == "Rebuilt from scratch")
        #expect(PreviewReading.summary(of: report(path: .scratch, seconds: 12)) == "Rebuilt from scratch · 12.0 s")
    }

    @Test("The first error is the first error, whatever warnings come before it")
    func firstError() {
        let warning = BuildIssue(severity: .warning, message: "unused")
        let first = BuildIssue(severity: .error, message: "first", file: "/a/B.swift", line: 3)
        let second = BuildIssue(severity: .error, message: "second")
        #expect(
            PreviewReading.firstError(of: report(ok: false, issues: [warning, first, second]))
                == first)
        #expect(PreviewReading.firstError(of: report(ok: false, issues: [warning])) == nil)
        #expect(PreviewReading.firstError(of: report()) == nil)
    }

    @Test("An issue names its file and line when it has them")
    func detailLine() {
        #expect(
            PreviewReading.detailLine(
                of: BuildIssue(severity: .error, message: "boom", file: "/a/b/View.swift", line: 12))
                == "View.swift:12: boom")
        #expect(
            PreviewReading.detailLine(of: BuildIssue(severity: .error, message: "boom", file: "/a/b/View.swift"))
                == "View.swift: boom")
        #expect(PreviewReading.detailLine(of: BuildIssue(severity: .error, message: "boom")) == "boom")
    }

    @Test("A session's step is said in the person's words, and a live one says nothing")
    func sessionLines() {
        func session(_ state: SessionState, step: String? = nil) -> SessionInfo {
            SessionInfo(
                id: "s", state: state, step: step,
                device: DeviceInfo(udid: "u", name: "iPhone", deviceType: "t", runtime: "r"),
                app: nil, project: ProjectRef(path: "/tmp/App"), lastBuild: nil, frame: nil,
                startedAt: Date(timeIntervalSince1970: 0), restarts: 0)
        }
        #expect(PreviewReading.line(for: session(.building, step: "Compiling")) == "Compiling")
        #expect(PreviewReading.line(for: session(.building)) == "Building your app")
        #expect(PreviewReading.line(for: session(.preparing)) == "Getting ready")
        #expect(PreviewReading.line(for: session(.installing)) == "Installing")
        #expect(PreviewReading.line(for: session(.launching)) == "Opening your app")
        #expect(PreviewReading.line(for: session(.live)) == nil)
        #expect(PreviewReading.line(for: session(.stopped)) == "Stopped")
        #expect(PreviewReading.line(for: session(.failed, step: "No scheme")) == "No scheme")
    }

    @Test("Events the host reports have words, and the ones that do not stay quiet")
    func events() {
        func event(_ kind: String, build: BuildReport? = nil) -> SessionEvent {
            SessionEvent(seq: 1, at: Date(timeIntervalSince1970: 0), kind: kind, build: build)
        }
        #expect(PreviewReading.eventLine(event("build.start")) == "Building…")
        #expect(PreviewReading.eventLine(event("build.done", build: report())) != nil)
        #expect(PreviewReading.eventLine(event("build.done")) == nil)
        #expect(
            PreviewReading.eventLine(event("build.failed", build: report(ok: false)))
                == "Your app stopped building after the last change.")
        #expect(PreviewReading.eventLine(event("app.crashed")) == "The app closed on its own")
        #expect(PreviewReading.eventLine(event("app.loop")) == "The app keeps closing")
        #expect(PreviewReading.eventLine(event("something.else")) == nil)
    }

    @Test("A reach failure names a password, a wrong address, or a silent Mac")
    func reachFailures() {
        #expect(
            PreviewReading.reachFailure(AgentError.http(status: 401, body: "")) == "The preview host wants its password")
        #expect(
            PreviewReading.reachFailure(AgentError.http(status: 403, body: "")) == "The preview host wants its password")
        #expect(
            PreviewReading.reachFailure(AgentError.http(status: 404, body: "")) == "That address is not a preview host")
        #expect(PreviewReading.reachFailure(URLError(.timedOut)) == "The Mac is not answering")
    }
}
