import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private final class TestClock: HostClock, @unchecked Sendable {
    private let start = Date()

    func now() -> TimeInterval { Date().timeIntervalSince(start) }

    func requestDrain() {}
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PREVIEWD_URL"] != nil))
struct PreviewRunnerLiveTests {
    private func runner() throws -> PreviewRunner {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["PREVIEWD_URL"] ?? ""))
        let host = try #require(url.host)
        let project = ProcessInfo.processInfo.environment["PREVIEWD_PROJECT"] ?? "/Users/marcus/pvtest/PhotoNotes"
        let target = PreviewTarget(host: host, port: url.port ?? 4300, project: project)
        let config = try #require(target.access.config(password: nil))
        return PreviewRunner(target: target, config: config, clock: TestClock())
    }

    @Test func aPaneComesUpAndShowsAPictureThenFollowsARebuild() async throws {
        let runner = try runner()
        runner.start()
        defer { runner.stop() }
        var firstPicture: PreviewPicture?
        let deadline = ContinuousClock.now + .seconds(150)
        while ContinuousClock.now < deadline {
            if let picture = runner.pictures.take() { firstPicture = picture }
            if runner.snapshot.phase == .live, firstPicture != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let picture = try #require(firstPicture)
        #expect(picture.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(runner.snapshot.phase == .live)
        #expect(runner.snapshot.light == .live)
        #expect(runner.snapshot.session?.app?.name == "PhotoNotes")
        #expect(runner.snapshot.frame != nil)

        runner.rebuild()
        var building = false
        var landed = false
        let end = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < end {
            let state = runner.snapshot
            if state.light == .updating { building = true }
            if state.recent.contains(where: { $0.kind == "build.done" && $0.message?.contains("Shown") == true }), building || state.lastBuild?.trigger == "asked" {
                landed = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(landed)
        #expect(runner.snapshot.lastBuild?.ok == true)
    }

    @Test func aMissingHostIsAStateNotACrash() async throws {
        let target = PreviewTarget(host: "127.0.0.1", port: 9, project: "/nowhere")
        let config = try #require(target.access.config(password: nil))
        let runner = PreviewRunner(target: target, config: config, clock: TestClock())
        runner.start()
        defer { runner.stop() }
        try await Task.sleep(for: .seconds(3))
        if case .failed = runner.snapshot.phase {} else { Issue.record("expected failed, got \(runner.snapshot.phase)") }
        #expect(runner.snapshot.light == .offline)
    }
}
