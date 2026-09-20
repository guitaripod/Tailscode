import Foundation

/// Where a window lands on KDE.
///
/// A Wayland client cannot place its own window: it names a size and the compositor decides where
/// that size goes. KWin centres a transient on the window that opened it and then clamps it to the
/// screen, so a feature surface sized to the display less a margin lands wherever the main window
/// happened to be, pushed into whichever corner the clamp left — a window eighty pixels short of
/// the screen anchored to its bottom-right edge. The one lever KDE offers is a window rule, and
/// this is the same rule the person already keeps for their other apps: placement forced to
/// Centered for every window with this app's id. It is written once, checked on every launch,
/// and never touches a rule that is not its own.
enum KWinPlacement {
    private static let ruleID = "tailscode-centered"
    private static let file = "kwinrulesrc"
    private static let centered = "5"

    static func ensure() {
        guard isKDE, !DesktopGuard.isDevelopmentBuild else { return }
        guard let write = tool("kwriteconfig6"), let read = tool("kreadconfig6") else { return }
        let placement = run(read, ["--file", file, "--group", ruleID, "--key", "placement"])
        let policy = run(read, ["--file", file, "--group", ruleID, "--key", "placementrule"])
        let wmclass = run(read, ["--file", file, "--group", ruleID, "--key", "wmclass"])
        if placement == centered, policy == "2", wmclass == DesktopIntegration.appID { return }

        let entries: [(String, String)] = [
            ("Description", "Tailscode windows open centered"),
            ("placement", centered),
            ("placementrule", "2"),
            ("wmclass", DesktopIntegration.appID),
            ("wmclassmatch", "1"),
            ("wmclasscomplete", "false"),
        ]
        for (key, value) in entries {
            _ = run(write, ["--file", file, "--group", ruleID, "--key", key, value])
        }
        let listed = run(read, ["--file", file, "--group", "General", "--key", "rules"])
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if !listed.contains(ruleID) {
            let rules = (listed + [ruleID]).joined(separator: ",")
            _ = run(write, ["--file", file, "--group", "General", "--key", "rules", rules])
            _ = run(
                write, ["--file", file, "--group", "General", "--key", "count", "\(listed.count + 1)"])
        }
        if let bus = tool("qdbus6") ?? tool("qdbus") {
            _ = run(bus, ["org.kde.KWin", "/KWin", "reconfigure"])
        }
    }

    private static var isKDE: Bool {
        let desktop = ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? ""
        if desktop.uppercased().contains("KDE") { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "\(home)/.config/kwinrc")
    }

    private static func tool(_ name: String) -> String? {
        for prefix in ["/usr/bin", "/usr/local/bin"] {
            let path = "\(prefix)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
