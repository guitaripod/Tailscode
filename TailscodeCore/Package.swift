// swift-tools-version:6.0
import Foundation
import PackageDescription

let package = Package(
    name: "TailscodeCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TailscodeCore", targets: ["TailscodeCore"])
    ],
    dependencies: [
        Kit.dependency
    ],
    targets: [
        .target(
            name: "TailscodeCore",
            dependencies: [
                .product(name: "CodingAgentKit", package: "CodingAgentKit"),
                .product(name: "CodingAgentKitApple", package: "CodingAgentKit"),
                .product(name: "AgentTestSupport", package: "CodingAgentKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TailscodeCoreTests",
            dependencies: ["TailscodeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

/// Where CodingAgentKit is read from, which is a different answer for the two kinds of tree this
/// package lives in. The one on the author's machine has the Kit as a sibling working copy, so a
/// change that spans both lands in one edit; a staged copy for the build VM has it vendored beside
/// the manifest; and every other tree — a packager's clone, a CI runner's, a Flatpak build's — has
/// neither and resolves the published tag over the network. Trying them in that order is what lets
/// a stranger run `swift build` in a fresh clone without changing anything the release path does.
/// `TAILSCODE_KIT_REMOTE=1` skips straight to the tag, which packaging scripts set so a release can
/// never be built from an unpublished working copy.
enum Kit {
    static let remote = "https://github.com/guitaripod/CodingAgentKit.git"
    static let version = Version(0, 16, 0)

    static var dependency: Package.Dependency {
        let forced = ProcessInfo.processInfo.environment["TAILSCODE_KIT_REMOTE"] ?? ""
        guard forced.isEmpty || forced == "0" else {
            return .package(url: remote, from: version)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for candidate in ["../../../swift/CodingAgentKit", "../vendor/CodingAgentKit"] {
            let path = root.appendingPathComponent(candidate).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: path + "/Package.swift") {
                return .package(path: candidate)
            }
        }
        return .package(url: remote, from: version)
    }
}
