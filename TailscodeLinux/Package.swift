// swift-tools-version:6.0
import Foundation
import PackageDescription

/// The GTK4 build of VTE is what makes the terminal pane a real terminal rather than a
/// one-command-at-a-time runner. It is an optional dependency on purpose: the app has to build and
/// run on a machine that does not have it, and say so, rather than fail to compile.
let hasVte = FileManager.default.fileExists(
    atPath: "/usr/include/vte-2.91-gtk4/vte/vte.h")

/// libmpv is what makes the video slot a pane rather than a window: mpv renders into the pane's
/// own GL area instead of a toplevel Wayland surface. Optional on the same terms as VTE — a
/// machine without it builds an app that says the slot is unavailable rather than failing to
/// compile.
let hasMpv = FileManager.default.fileExists(atPath: "/usr/include/mpv/render_gl.h")

/// WebKitGTK is what makes the browser slot a pane rather than another window: the web view is a
/// GtkWidget the tiling owns. Optional on the same terms as the rest — a machine without it builds
/// an app whose slot says so.
/// Found the way the linker will find it: the system header, or a prefix already on
/// `PKG_CONFIG_PATH`. Anything else would compile here and fail to link in the install script.
let hasWebKit =
    FileManager.default.fileExists(atPath: "/usr/include/webkitgtk-6.0/webkit/webkit.h")
    || (ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] ?? "")
        .split(separator: ":")
        .contains { FileManager.default.fileExists(atPath: "\($0)/webkitgtk-6.0.pc") }

var appDependencies: [Target.Dependency] = [
    "CAdw",
    "CGtkShim",
    .product(name: "CodingAgentKit", package: "CodingAgentKit"),
    .product(name: "CodingAgentKitApple", package: "CodingAgentKit"),
    .product(name: "TailscodeCore", package: "TailscodeCore"),
]
var appSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var shimDependencies: [Target.Dependency] = ["CAdw"]
var shimSettings: [CSetting] = []
var shimLinkerSettings: [LinkerSetting] = []
var targets: [Target] = []

if hasMpv {
    appSettings.append(.define("HAS_MPV"))
    shimDependencies.append("CMpv")
    shimSettings.append(.define("TAILSCODE_HAS_MPV", to: "1"))
    shimLinkerSettings.append(.linkedLibrary("epoxy"))
    targets.append(
        .systemLibrary(
            name: "CMpv", pkgConfig: "mpv",
            providers: [.apt(["libmpv-dev"]), .yum(["mpv-libs-devel"])]))
}

if hasVte {
    appDependencies.append("CVte")
    appSettings.append(.define("HAS_VTE"))
    targets.append(
        .systemLibrary(
            name: "CVte", pkgConfig: "vte-2.91-gtk4",
            providers: [.apt(["libvte-2.91-gtk4-dev"])]))
}

if hasWebKit {
    appSettings.append(.define("HAS_WEBKIT"))
    shimDependencies.append("CWebKit")
    shimSettings.append(.define("TAILSCODE_HAS_WEBKIT", to: "1"))
    targets.append(
        .systemLibrary(
            name: "CWebKit", pkgConfig: "webkitgtk-6.0",
            providers: [.apt(["libwebkitgtk-6.0-dev"]), .yum(["webkitgtk6.0-devel"])]))
}

targets += [
    .systemLibrary(
        name: "CAdw",
        pkgConfig: "libadwaita-1",
        providers: [.apt(["libadwaita-1-dev"]), .yum(["libadwaita-devel"])]
    ),
    .target(
        name: "CGtkShim", dependencies: shimDependencies, cSettings: shimSettings,
        linkerSettings: shimLinkerSettings),
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
