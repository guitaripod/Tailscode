// swift-tools-version:6.0
import Foundation
import PackageDescription

/// libmpv is what makes the video slot a pane rather than a window: mpv renders into the pane's
/// own GL area instead of a toplevel Wayland surface. Optional on the same terms as VTE — a
/// machine without it builds an app that says the slot is unavailable rather than failing to
/// compile.
let hasMpv = FileManager.default.fileExists(atPath: "/usr/include/mpv/render_gl.h")

/// PulseAudio's simple API is what lets a call hear the microphone and speak through the desk's
/// speakers (PipeWire answers it too). Optional on the same terms as the rest — a machine without
/// it builds an app whose call answers that audio is unavailable rather than failing to compile.
let hasPulse = FileManager.default.fileExists(atPath: "/usr/include/pulse/simple.h")
/// The layer shell is what lets the quick ask stand where it was left and come back the size it
/// was made: a desktop window cannot place itself on Wayland, but an overlay surface can place
/// what it draws. Optional like the engines above; without it the quick ask is an ordinary window.
let hasLayerShell = FileManager.default.fileExists(
    atPath: "/usr/include/gtk4-layer-shell/gtk4-layer-shell.h")

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

/// The compositor's own word on input idle is what tells the phone the person is at this desk on
/// Wayland, where no D-Bus service will say. Optional like the rest; without it the desk falls back
/// to GNOME's idle monitor or the freedesktop screen saver, and says so when neither answers.
let hasWayland =
    FileManager.default.fileExists(atPath: "/usr/include/wayland-client.h")
    && FileManager.default.fileExists(atPath: "/usr/include/gtk-4.0/gdk/wayland/gdkwayland.h")

var appDependencies: [Target.Dependency] = [
    "CAdw",
    "CGtkShim",
    "CSherpa",
    .product(name: "CodingAgentKit", package: "CodingAgentKit"),
    .product(name: "CodingAgentKitApple", package: "CodingAgentKit"),
    .product(name: "TailscodeCore", package: "TailscodeCore"),
]
var appSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var shimDependencies: [Target.Dependency] = [
    "CAdw", "CGdkPixbuf", .product(name: "CTerminalEngine", package: "TailscodeCore"),
]
var shimSettings: [CSetting] = []
var shimLinkerSettings: [LinkerSetting] = [.linkedLibrary("epoxy")]
var targets: [Target] = []
var shimExcluded: [String] = []

if hasWayland {
    shimSettings.append(.define("TAILSCODE_HAS_WAYLAND", to: "1"))
    shimLinkerSettings.append(.linkedLibrary("wayland-client"))
} else {
    shimExcluded += ["ext-idle-notify-v1-protocol.c", "ext-idle-notify-v1-client-protocol.h"]
}

if hasMpv {
    appSettings.append(.define("HAS_MPV"))
    shimDependencies.append("CMpv")
    shimSettings.append(.define("TAILSCODE_HAS_MPV", to: "1"))
    targets.append(
        .systemLibrary(
            name: "CMpv", pkgConfig: "mpv",
            providers: [.apt(["libmpv-dev"]), .yum(["mpv-libs-devel"])]))
}

if hasPulse {
    appDependencies.append("CPulse")
    appSettings.append(.define("HAS_PULSE"))
    targets.append(
        .systemLibrary(
            name: "CPulse", pkgConfig: "libpulse-simple",
            providers: [.apt(["libpulse-dev"]), .yum(["pulseaudio-libs-devel"])]))
}

if hasLayerShell {
    appDependencies.append("CLayerShell")
    appSettings.append(.define("HAS_LAYER_SHELL"))
    targets.append(
        .systemLibrary(
            name: "CLayerShell", pkgConfig: "gtk4-layer-shell-0",
            providers: [.apt(["libgtk4-layer-shell-dev"])]))
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
    .systemLibrary(
        name: "CGdkPixbuf",
        pkgConfig: "gdk-pixbuf-2.0",
        providers: [.apt(["libgdk-pixbuf-2.0-dev"]), .yum(["gdk-pixbuf2-devel"])]
    ),
    .target(
        name: "CGtkShim", dependencies: shimDependencies, exclude: shimExcluded,
        cSettings: shimSettings, linkerSettings: shimLinkerSettings),
    .target(name: "CSherpa", linkerSettings: [.linkedLibrary("dl")]),
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
        Kit.dependency,
        .package(path: "../TailscodeCore"),
    ],
    targets: targets
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
    /// 0.24.2 corrects the claude-bridge model table (fable, opus and sonnet run a million-token
    /// window); 0.25.0 carries the delegate daemon's class and mode policies and its auth mode on
    /// the capabilities; 0.26.0 carries `BackgroundWork` — the work an agent's process holds
    /// between turns — on the session, the revision, the transcript and the conversation state;
    /// 0.27.0 reads the stored profile list an entry at a time, so one server whose backend a
    /// build has no case for costs only itself rather than every server on the machine. 0.28.0
    /// splits an omp model name into its door and id and gives omp its own fallback ladder. 0.29.0
    /// carries background work's age and stall and the person's own end of it. 0.30.1 speaks
    /// opencode 2 — the backend finds out which generation a server runs and answers in it.
    /// 0.31.0 reads an update as a job and a release — the step a bridge's update is on, how it
    /// ended and what the new version brings — and asks for the project to be fetched now. 0.31.1
    /// keeps an opencode 2 conversation whole: a sent prompt appears as it is delivered, a file
    /// attachment no longer breaks the transcript, a shell run beside the chat streams live, a
    /// stopped or declined step is not a failure, and absolute file paths read and list. 0.31.2
    /// re-reads a bridge transcript with If-None-Match, so an unchanged one answers 304, shares one
    /// connection pool per set of deadlines, and sends every refresh read at once.
    /// 0.32.0 draws what opencode 2 writes for the reader as transcript notes, names the provider
    /// wait a turn sits out, winds a conversation back to a message with the way back open, and
    /// lets opencode 2 report its own cut-off turns and session usage. 0.33.0 reads what a Mac
    /// server's agents are allowed to touch — Full Disk Access — and asks it to open the pane.
    /// 0.33.2 keeps an ad-hoc Mac build's secrets in a file only its user can read.
    /// 0.34.0 waits on a turn from another process: a side-effect-free request a background
    /// URLSession can hold until the turn ends, and whether a bridge can really push.
    /// 0.35.0 lets a delegated patch wait to be read: review, the patch, apply and discard.
    /// 0.35.1 stops a Linux binary trapping on a resource bundle it was never given.
    /// 0.36.1 writes a streaming answer's saved transcript at most every thirty seconds and not
    /// at all when nothing changed. 0.37.0 speaks to a preview host: a Mac's simulator watched,
    /// read and touched.
    /// 0.42.1 names a fresh opencode 2 conversation: the model a prompt sets is read back
    /// before the prompt goes out, and a session the server has not titled yet is not mistaken
    /// for one called by its id. 0.43.0 holds a message queued behind a running turn on the
    /// server, so every client of the conversation shows the same queue and can edit, cancel and
    /// resume it. 0.44.0 reads the end of a held conversation ahead of the whole of it, so coming
    /// back to a long chat shows what the agent said while the phone was away after one small read.
    /// 0.45.0 restarts a bridge on request, with or without a newer build waiting.
    /// 0.46.0 spaces the writes of a heavy transcript by what it weighs, so a long conversation
    /// stops rewriting tens of megabytes to the phone's flash every half minute.
    /// 0.47.0 speaks a machine's schedules and the ACP agents a claude-bridge hosts.
    /// 0.48.0 reads a conversation once per refresh, a list that has not moved as a header, and a
    /// bridge's provider wait.
    /// 0.48.1 reads a transcript held from before the sidecar again, and keeps opencode 2's cut-off
    /// card when liveness could not be read.
    /// 0.49.0 shares one event connection per opencode 2 server and asks a Claude conversation's
    /// agent what fills its window.
    /// 0.50.0 hands a bridge the device's notification rules and holds a wait until the work
    /// settles rather than the turn.
    /// 0.51.0 carries a conversation's chapters from the servers that keep them.
    /// 0.51.1 says a dropped connection in a sentence rather than an error dump.
    /// 0.52.0 reads a failed turn a bridge kept on its answer.
    /// 0.53.0 carries the workflow run each agent belongs to.
    /// 0.54.0 carries what a chat's last answer said, for a list row nobody has read.
    /// 0.55.0 carries the limiter's verdict on a usage window, so a refusal is told apart from a
    /// reading rounded up to 100 %.
    /// 0.56.0 lets a Live Activity's registration say what its server does when the turn ends.
    /// 0.57.0 lets a device hand a server what it needs to start its Live Activities.
    /// 0.58.0 says whether a listed conversation's own turn is open, and whether a bridge took the
    /// device's Live Activity start token.
    /// 0.59.0 says when a desk's person is at it, so a phone can stay quiet while they are.
    /// 0.60.0 lets a phone hand a held notice to its bridge and dates each look a desk reports.
    /// 0.61.0 reads a bridge's notice (work the agent left running coming back) into a note.
    /// 0.62.0 says which answers a person stopped by hand, and when a waited-on turn ended.
    /// 0.63.0 edits and cancels a prompt waiting in opencode 2's inbox, in its own place in the
    /// queue and under its own id, so a queued message can be rewritten on opencode too.
    /// 0.64.0 speaks the masters a claude-bridge keeps (MachineExperts).
    /// 0.65.0 speaks to a shell a server holds: the terminal's wire, link and mock. 0.65.1 makes
    /// the mock's shell bash.
    /// 0.66.0 holds a shell on opencode 2 too, in opencode's own pty.
    /// 0.67.0 seats an opencode workflow's agents on the call that started their run.
    static let version = Version(0, 67, 0)

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
