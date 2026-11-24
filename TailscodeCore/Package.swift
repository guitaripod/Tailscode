// swift-tools-version:6.0
import Foundation
import PackageDescription

let package = Package(
    name: "TailscodeCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TailscodeCore", targets: ["TailscodeCore"]),
        .library(name: "CTerminalEngine", targets: ["CTerminalEngine"]),
    ],
    dependencies: [
        Kit.dependency
    ],
    targets: TerminalEngine.targets + [
        .target(
            name: "TailscodeCore",
            dependencies: [
                "CTerminalEngine",
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

/// The terminal emulator every client draws from: libghostty-vt (MIT), behind the small C door in
/// `CTerminalEngine` so no client holds an engine type.
///
/// Apple platforms take the release's own XCFramework, pinned by checksum. Linux has no prebuilt
/// library, so `scripts/ghostty-vt.sh` builds the same release from its signed source into
/// `Vendor/ghostty-vt` and this manifest links it when it is there. A tree without it still
/// builds: the door answers that there is no engine, and the terminal says so in words. The same
/// is true of the one slice the XCFramework does not carry, a simulator on an Intel Mac.
enum TerminalEngine {
    static let version = "1.0.1"
    static let checksum = "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"

    static var targets: [Target] {
        #if os(Linux)
            let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Vendor/ghostty-vt").path
            let library = vendor + "/lib/libghostty-vt.a"
            guard FileManager.default.fileExists(atPath: library) else {
                return [.target(name: "CTerminalEngine")]
            }
            return [
                .target(
                    name: "CTerminalEngine",
                    cSettings: [.define("TS_HAS_GHOSTTY"), .unsafeFlags(["-I", vendor + "/include"])],
                    linkerSettings: [.unsafeFlags([library])])
            ]
        #else
            return [
                .binaryTarget(
                    name: "GhosttyVt",
                    url: "https://release.files.ghostty.org/libghostty-vt/\(version)/ghostty-vt-\(version).xcframework.zip",
                    checksum: checksum),
                .target(
                    name: "CTerminalEngine", dependencies: ["GhosttyVt"],
                    cSettings: [.define("TS_HAS_GHOSTTY")]),
            ]
        #endif
    }
}

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
    /// 0.24.1 adds `contextWindow` to the omp bridge's `/models` rows; a pin below it leaves
    /// every omp session's context ring on the client's name guess. 0.24.2 corrects the
    /// claude-bridge table: fable, opus and sonnet run a million-token window. 0.25.0 carries
    /// the delegate daemon's class and mode policies and its auth mode on the capabilities. 0.27.2
    /// folds an answer a server hands back under a second name into the one already held. 0.28.0
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
    /// read and touched. 0.38.0 speaks a voice call, says what a machine cannot do yet and carries a
    /// pairing link. 0.39.0 learns how far a server's clock is from this device's from the Date
    /// header of the answers it already gives. 0.42.0 names how long a request's cache writes
    /// live, which is what tells a client whether the prompt cache is still held.
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
    /// queue and under its own id, so the phone can rewrite a message queued behind a running turn
    /// the way it already rewrites one a bridge holds.
    /// 0.64.0 speaks the masters a claude-bridge keeps (MachineExperts): standing roles whose tasks
    /// start fresh with a brief and end with a debrief, with their bench, guards, notebook and journal.
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
