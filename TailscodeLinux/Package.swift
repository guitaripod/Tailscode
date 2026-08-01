// swift-tools-version:6.0
import Foundation
import PackageDescription

/// The GTK4 build of VTE is what makes the terminal pane a real terminal rather than a
/// one-command-at-a-time runner. It is an optional dependency on purpose: the app has to build and
/// run on a machine that does not have it, and say so, rather than fail to compile.
let hasVte = FileManager.default.fileExists(
    atPath: "/usr/include/vte-2.91-gtk4/vte/vte.h")

var appDependencies: [Target.Dependency] = [
    "CAdw",
    "CGtkShim",
    .product(name: "CodingAgentKit", package: "CodingAgentKit"),
    .product(name: "CodingAgentKitApple", package: "CodingAgentKit"),
    .product(name: "TailscodeCore", package: "TailscodeCore"),
]
var appSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var targets: [Target] = []

if hasVte {
    appDependencies.append("CVte")
    appSettings.append(.define("HAS_VTE"))
    targets.append(
        .systemLibrary(
            name: "CVte", pkgConfig: "vte-2.91-gtk4",
            providers: [.apt(["libvte-2.91-gtk4-dev"])]))
}

targets += [
    .systemLibrary(
        name: "CAdw",
        pkgConfig: "libadwaita-1",
        providers: [.apt(["libadwaita-1-dev"]), .yum(["libadwaita-devel"])]
    ),
    .target(name: "CGtkShim", dependencies: ["CAdw"]),
    .executableTarget(
        name: "TailscodeLinux",
        dependencies: appDependencies,
        swiftSettings: appSettings
    ),
]

let package = Package(
    name: "TailscodeLinux",
    products: [
        .executable(name: "tailscode", targets: ["TailscodeLinux"])
    ],
    dependencies: [
        .package(path: "../../../swift/CodingAgentKit"),
        .package(path: "../TailscodeCore"),
    ],
    targets: targets
)
