import CGtkShim
import Foundation
import TailscodeCore

/// What a Tailscale remedy does on this desktop, for every surface that offers one. A command that
/// has to run on *this* machine is run from here, with its output narrated back to where the person
/// is looking, rather than handed over with "run it in a terminal" — the one thing the first-run
/// doctrine forbids, and useless advice to somebody who has never opened one.
enum TailnetRemedyRunner {
    /// - Returns: whether the reading has a remedy this runner could act on.
    @discardableResult
    static func perform(
        _ reading: TailscaleReading, narrate: @escaping @Sendable (String) -> Void
    ) -> Bool {
        switch reading.remedy {
        case .install(let url):
            SignInDialog.openInBrowser(url)
        case .signIn(let command), .start(let command):
            run(command, narrate: narrate)
        case .grantHostAccess(let command):
            Gtk.copyToClipboard(command)
        case .none:
            return false
        }
        return true
    }

    /// `tailscale up` answers by printing a login URL and waiting, so the URL is watched for and
    /// opened as it appears; anything needing root is raised through pkexec, which asks with the
    /// desktop's own dialog. A command that cannot run says so and leaves the copyable line.
    static func run(_ command: String, narrate: @escaping @Sendable (String) -> Void) {
        let elevated = command.hasPrefix("sudo ")
        let bare = elevated ? String(command.dropFirst(5)) : command
        let usePolkit = elevated && FileManager.default.isExecutableFile(atPath: "/usr/bin/pkexec")
        narrate(Localized.text("Running %@…", bare))

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var arguments = bare.split(separator: " ").map(String.init)
            if usePolkit { arguments.insert("pkexec", at: 0) }
            if Packaging.isFlatpak { arguments.insert(contentsOf: ["flatpak-spawn", "--host"], at: 0) }
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else {
                narrate(
                    Localized.text(
                        "This machine would not run %@. Copy it and run it yourself, then this "
                            + "step turns green on its own.", bare))
                return
            }
            var seen = ""
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                seen += String(decoding: chunk, as: UTF8.self)
                let text = seen
                if let url = loginURL(in: text) {
                    Gtk.onMain { SignInDialog.openInBrowser(url) }
                    seen = ""
                }
                narrate(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            process.waitUntilExit()
        }
    }

    private static func loginURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace })
        where token.hasPrefix("https://login.tailscale.com/") {
            return String(token)
        }
        return nil
    }
}
