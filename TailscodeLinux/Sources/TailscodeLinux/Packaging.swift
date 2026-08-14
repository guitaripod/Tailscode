import Foundation
import TailscodeCore

/// Whether something other than the person owns this copy of the binary, and what to say to it.
///
/// A build installed by a package manager cannot replace itself and must not offer to: `/app` and
/// `/usr` are read-only to the process, there is no checkout to build from and no toolchain to
/// build with, and a rebuild script that reached either would be writing over files the manager
/// believes it owns. The update doctrine already requires a press to say beforehand when it cannot
/// finish the job, so the reading this produces is what turns "Update" into the one line that
/// actually does it on this machine.
///
/// Two kinds of evidence, in the order they deserve. A Flatpak announces itself — the sandbox sets
/// `FLATPAK_ID` and mounts `/.flatpak-info`, and neither can be faked by a path. Otherwise it is a
/// question of where the binary lives: a system prefix is a place only a package manager and a root
/// shell can write, so a binary in `/usr/bin` was put there by one of them, while anything under a
/// home directory is the person's own and stays the app's business.
enum Packaging {
    struct Reading: Sendable, Equatable {
        /// What owns it, in the words a person would use to talk to it.
        let name: String
        /// The one line that updates it here, or nothing when the manager updates it unasked.
        let command: String?
    }

    static let flatpakID = "io.github.guitaripod.Tailscode"

    static var isFlatpak: Bool {
        ProcessInfo.processInfo.environment["FLATPAK_ID"] != nil
            || FileManager.default.fileExists(atPath: "/.flatpak-info")
    }

    static func current(executable: String = DesktopGuard.executablePath) -> Reading? {
        if isFlatpak {
            return Reading(name: "Flatpak", command: "flatpak update \(flatpakID)")
        }
        guard isSystemPrefix(executable) else { return nil }
        return distribution()
    }

    /// A prefix the person's own build never lands in. `~/.local/bin` is deliberately absent: that
    /// is where `scripts/install-linuxapp.sh` puts a build somebody made themselves, and that copy
    /// really can replace itself.
    private static func isSystemPrefix(_ executable: String) -> Bool {
        ["/usr/bin/", "/usr/local/bin/", "/bin/", "/opt/", "/app/bin/", "/nix/store/"]
            .contains { executable.hasPrefix($0) }
    }

    /// Which manager this distribution uses, read from what is on the box rather than from
    /// `/etc/os-release`, which names a distribution and not the tool that owns this file. An AUR
    /// helper is preferred over bare pacman where one exists, because the package is in the AUR and
    /// `pacman -Syu` would not see it.
    private static func distribution() -> Reading {
        let exists = { FileManager.default.isExecutableFile(atPath: $0) }
        for helper in ["/usr/bin/paru", "/usr/bin/yay"] where exists(helper) {
            let name = (helper as NSString).lastPathComponent
            return Reading(name: name, command: "\(name) -Syu tailscode")
        }
        if exists("/usr/bin/pacman") {
            return Reading(name: "pacman", command: "sudo pacman -Syu tailscode")
        }
        if exists("/usr/bin/apt") {
            return Reading(name: "apt", command: "sudo apt update && sudo apt install tailscode")
        }
        if exists("/usr/bin/dnf") {
            return Reading(name: "dnf", command: "sudo dnf upgrade tailscode")
        }
        if exists("/usr/bin/zypper") {
            return Reading(name: "zypper", command: "sudo zypper update tailscode")
        }
        return Reading(name: Localized.text("this system's package manager"), command: nil)
    }
}
