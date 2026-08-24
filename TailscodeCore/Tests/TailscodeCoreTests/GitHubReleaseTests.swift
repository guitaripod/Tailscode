import Foundation
import Testing

@testable import TailscodeCore

/// The release feed is the one thing every install shares, so what it answers is the whole
/// comparison a package-installed desktop gets to make. The proofs here are about the parse
/// surviving what a real feed sends: a tag with the v, a body that is markdown, a date in the
/// format the API actually uses — and about refusing to claim a release where the response was
/// not one.
extension DeviceStores {
    @Suite struct GitHubReleaseTests {
        private static let now = Date(timeIntervalSince1970: 1_770_000_000)

        private static func payload(_ extra: [String: String] = [:]) -> Data {
            var fields: [String: String] = [
                "tag_name": "v1.24",
                "body": "Ask for a video and watch it being made.",
                "html_url": "https://github.com/guitaripod/Tailscode/releases/tag/v1.24",
                "published_at": "2026-08-20T04:18:33Z",
            ]
            for (key, value) in extra { fields[key] = value }
            let entries = fields.map { "\"\($0.key)\":\(Self.quoted($0.value))" }
            return Data(("{" + entries.joined(separator: ",") + "}").utf8)
        }

        private static func quoted(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }

        @Test func aTagReadsAsTheVersionItCarries() {
            let release = GitHubRelease.parse(Self.payload(), now: Self.now)
            #expect(release?.version == "1.24")
            #expect(release?.provenance == .gitHubRelease)
            #expect(release?.notes == "Ask for a video and watch it being made.")
            #expect(release?.url?.hasSuffix("/tag/v1.24") == true)
            #expect(release?.publishedAt == Date(timeIntervalSince1970: 1_787_199_513))
            #expect(release?.readAt == Self.now)
        }

        @Test func aTagWithoutTheVIsItsOwnVersion() {
            let release = GitHubRelease.parse(Self.payload(["tag_name": "1.23"]), now: Self.now)
            #expect(release?.version == "1.23")
        }

        @Test func aReleaseWithoutANoteIsStillARelease() {
            let release = GitHubRelease.parse(Self.payload(["body": ""]), now: Self.now)
            #expect(release?.version == "1.24")
            #expect(release?.notes == "")
        }

        @Test func aResponseWithoutATagIsNotARelease() {
            #expect(GitHubRelease.parse(Self.payload(["tag_name": ""]), now: Self.now) == nil)
            #expect(GitHubRelease.parse(Data("{}".utf8), now: Self.now) == nil)
        }

        @Test func aResponseThatIsNotJSONIsNotARelease() {
            #expect(GitHubRelease.parse(Data("<html>rate limited</html>".utf8), now: Self.now) == nil)
            #expect(GitHubRelease.parse(Data(), now: Self.now) == nil)
        }
    }
}
