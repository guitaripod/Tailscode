import Foundation
import Testing

@testable import TailscodeCore

@Suite("Preview target")
struct PreviewTargetTests {

    @Test("An address reads back to exactly the target that wrote it")
    func roundTrip() throws {
        let target = PreviewTarget(
            host: "studio", port: 4300, project: "/Users/me/Dev/Notes", deviceType: "iPhone 17",
            screen: "settings")
        #expect(PreviewTarget.read(target.address) == target)
    }

    @Test("Spaces and slashes in the project path survive the trip")
    func awkwardPaths() throws {
        let target = PreviewTarget(
            host: "mac-mini.tail1234.ts.net", port: 4301,
            project: "/Users/me/My Apps/Cool App/Cool App.xcodeproj")
        let read = try #require(PreviewTarget.read(target.address))
        #expect(read.project == "/Users/me/My Apps/Cool App/Cool App.xcodeproj")
        #expect(read.host == "mac-mini.tail1234.ts.net")
        #expect(read.port == 4301)
        #expect(read.deviceType == nil)
        #expect(read.screen == nil)
    }

    @Test("A missing port reads as the preview host's own")
    func defaultPort() throws {
        let read = try #require(PreviewTarget.read("preview://studio/?project=/tmp/App"))
        #expect(read.port == 4300)
    }

    @Test("An address that names no app is no target")
    func missingProject() {
        #expect(PreviewTarget.read("preview://studio:4300/") == nil)
        #expect(PreviewTarget.read("preview://studio:4300/?project=") == nil)
        #expect(PreviewTarget.read("preview://studio:4300/?device=iPhone") == nil)
    }

    @Test("An address that names no machine is no target")
    func missingHost() {
        #expect(PreviewTarget.read("preview:///?project=/tmp/App") == nil)
    }

    @Test("Another scheme is no target")
    func wrongScheme() {
        #expect(PreviewTarget.read("https://studio:4300/?project=/tmp/App") == nil)
        #expect(PreviewTarget.read("video://studio:4300/?project=/tmp/App") == nil)
        #expect(PreviewTarget.read("") == nil)
        #expect(PreviewTarget.read("not an address") == nil)
    }

    @Test("A person calls an app by its folder")
    func names() {
        let target = PreviewTarget(host: "studio", project: "/Users/me/Dev/Notes")
        #expect(target.appName == "Notes")
        #expect(target.label == "Notes on studio")
        #expect(PreviewTarget(host: "studio", project: "Notes").appName == "Notes")
    }

    @Test("The access a target implies is its host and port")
    func access() {
        let target = PreviewTarget(host: "studio", port: 4311, project: "/tmp/App")
        #expect(target.access.host == "studio")
        #expect(target.access.port == 4311)
    }
}
