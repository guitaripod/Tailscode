import Foundation
import TailscodeCore

/// What to do about an engine this binary was built without.
///
/// WebKitGTK and libmpv are found when `Package.swift` is evaluated, so a machine that lacked one
/// at build time has a binary that lacks it for good — and a surface that only says "no engine"
/// leaves the person to work out which package, on which distribution, and that the app then has
/// to be rebuilt rather than merely relaunched. The remedy names all three: the package for the
/// manager actually on the box, the checkout the install stamp recorded, and the script that
/// rebuilds from it.
enum MissingEngine {
    case webKit

    var packageNames: (pacman: String, apt: String, dnf: String) {
        switch self {
        case .webKit: return ("webkitgtk-6.0", "libwebkitgtk-6.0-dev", "webkitgtk6.0-devel")
        }
    }

    /// The one command that puts the engine on this machine, for the manager that is here.
    var installCommand: String? {
        let exists = { FileManager.default.isExecutableFile(atPath: $0) }
        let names = packageNames
        if exists("/usr/bin/pacman") { return "sudo pacman -S --needed \(names.pacman)" }
        if exists("/usr/bin/apt") { return "sudo apt install \(names.apt)" }
        if exists("/usr/bin/dnf") { return "sudo dnf install \(names.dnf)" }
        return nil
    }

    /// The whole road: install the engine, then rebuild from the checkout this binary came from.
    /// A packaged copy never lacks an engine — its package depends on them — so the sentence is
    /// written for the person who built this copy themselves.
    var remedy: String {
        let install = LinuxAppInstall.read()
        let rebuild: String
        if let source = install.source {
            rebuild = "\(source)/scripts/install-linuxapp.sh"
        } else {
            rebuild = "scripts/install-linuxapp.sh"
        }
        guard let installCommand else {
            return Localized.text(
                "Install WebKitGTK 6.0 with this machine's package manager, then rebuild and "
                    + "reinstall with  %@", rebuild)
        }
        return Localized.text(
            "Install it and rebuild:  %@  then  %@", installCommand, rebuild)
    }

    /// Everything a person would paste, on one line, for a copy button.
    var command: String {
        let install = LinuxAppInstall.read()
        let rebuild = install.source.map { "\($0)/scripts/install-linuxapp.sh" }
            ?? "scripts/install-linuxapp.sh"
        guard let installCommand else { return rebuild }
        return "\(installCommand) && \(rebuild)"
    }
}
