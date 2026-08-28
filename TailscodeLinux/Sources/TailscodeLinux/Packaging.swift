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
        /// The one line that updates it on this computer, or nothing when no line here would.
        let command: String?
        /// The whole of what to do, in one sentence a person can follow without opening anything
        /// else: where this copy came from, the line to run, and the relaunch that no package
        /// manager performs for a program that is still running.
        let instructions: String
    }

    static let flatpakID = "io.github.guitaripod.Tailscode"

    static var isFlatpak: Bool {
        ProcessInfo.processInfo.environment["FLATPAK_ID"] != nil
            || FileManager.default.fileExists(atPath: "/.flatpak-info")
    }

    static func current(executable: String = DesktopGuard.executablePath) -> Reading? {
        if isFlatpak {
            return Reading(
                name: "Flatpak", command: "flatpak update \(flatpakID)",
                instructions: Localized.text(
                    "Installed as a Flatpak. In a terminal, run  %@  — then quit and reopen "
                        + "Tailscode.", "flatpak update \(flatpakID)"))
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
    /// `/etc/os-release`, which names a distribution and not the tool that owns this file. The only
    /// repository the app is published in is the AUR, so only Arch gets a line: an AUR helper where
    /// one exists, `makepkg` where there is none (bare `pacman -Syu` cannot see the AUR at all), and
    /// any other system prefix is a tarball or a package Tailscode does not know about, which gets
    /// the release page rather than a command that would fail.
    private static func distribution() -> Reading {
        let exists = { FileManager.default.isExecutableFile(atPath: $0) }
        for helper in ["/usr/bin/paru", "/usr/bin/yay"] where exists(helper) {
            let name = (helper as NSString).lastPathComponent
            let command = "\(name) -Syu tailscode"
            return Reading(
                name: Localized.text("the AUR (%@)", name), command: command,
                instructions: Localized.text(
                    "Installed from the AUR. In a terminal, run  %@  — then quit and reopen "
                        + "Tailscode.", command))
        }
        if exists("/usr/bin/pacman") {
            let command =
                "git clone https://aur.archlinux.org/tailscode.git && cd tailscode && makepkg -si"
            return Reading(
                name: Localized.text("the AUR"), command: command,
                instructions: Localized.text(
                    "Installed from the AUR, and no AUR helper is on this machine. In a terminal, "
                        + "run  %@  — then quit and reopen Tailscode.", command))
        }
        return Reading(
            name: Localized.text("a tarball or a package manager Tailscode does not know"),
            command: nil,
            instructions: Localized.text(
                "Tailscode does not know what installed this copy. Download the new tarball from "
                    + "the release page, unpack it over the old one the same way, then quit and "
                    + "reopen Tailscode."))
    }
}
