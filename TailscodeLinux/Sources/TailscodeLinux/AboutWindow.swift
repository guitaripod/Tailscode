import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What this copy is, in the terms a bug report needs.
///
/// The version was only reachable by running the binary with `--version` from a terminal, which
/// somebody who installed a Flatpak from a store has no reason to know how to do — so "what are you
/// running" had no answer, and neither did "why is there no browser pane", since the optional panes
/// are decided at build time and an install that lost one gives no sign of it.
///
/// Everything here is a fact with provenance, the way every other version surface in this app is
/// required to be: what it is, who installed it, what it was linked against, which panes it has,
/// and where its log lives. Copy diagnostics puts all of it plus the tail of the log on the
/// clipboard, so a report can be pasted rather than interviewed out of somebody.
enum AboutWindow {
    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let dialog = adw_about_dialog_new()!
        adw_about_dialog_set_application_name(op(dialog), "Tailscode")
        adw_about_dialog_set_application_icon(op(dialog), DesktopIntegration.appID)
        adw_about_dialog_set_version(op(dialog), TailscodeVersion.current)
        adw_about_dialog_set_developer_name(op(dialog), "Marcus Ordoñez")
        adw_about_dialog_set_license_type(op(dialog), GTK_LICENSE_GPL_3_0)
        adw_about_dialog_set_website(op(dialog), "https://github.com/guitaripod/Tailscode")
        adw_about_dialog_set_issue_url(op(dialog), "https://github.com/guitaripod/Tailscode/issues")
        adw_about_dialog_set_comments(op(dialog), Localized.text("Coding agents over Tailscale."))
        adw_about_dialog_set_debug_info(op(dialog), diagnostics())
        adw_about_dialog_set_debug_info_filename(op(dialog), "tailscode-diagnostics.txt")
        adw_dialog_present(ptr(UnsafeMutableRawPointer(dialog)), parent)
    }

    /// The block that goes in a bug report. Deliberately boring and deliberately complete: the
    /// panes line is here because a person cannot otherwise tell a feature they do not have from
    /// one that is broken, and the install line is here because "installed by pacman" and "built
    /// from a checkout" fail in different ways.
    static func diagnostics() -> String {
        let install = LinuxAppInstall.read()
        var lines = [
            "tailscode \(TailscodeVersion.current)",
            "install: \(install.kind.sentence)\(install.packager.map { " (\($0))" } ?? "")",
            "binary: \(DesktopGuard.executablePath)",
            "gtk: \(gtk_get_major_version()).\(gtk_get_minor_version()).\(gtk_get_micro_version())",
            "libadwaita: \(adw_get_major_version()).\(adw_get_minor_version()).\(adw_get_micro_version())",
            "panes: \(panes())",
            "session: \(sessionKind())",
            "log: \(AppLog.current.path)",
        ]
        let tail = AppLog.tail()
        if !tail.isEmpty {
            lines.append("")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }

    private static func panes() -> String {
        var present: [String] = []
        #if HAS_VTE
            present.append("terminal")
        #endif
        #if HAS_MPV
            present.append("video")
        #endif
        #if HAS_WEBKIT
            present.append("browser")
        #endif
        return present.isEmpty ? "none of the optional panes" : present.joined(separator: ", ")
    }

    private static func sessionKind() -> String {
        let environment = ProcessInfo.processInfo.environment
        let type = environment["XDG_SESSION_TYPE"] ?? "unknown"
        let desktop = environment["XDG_CURRENT_DESKTOP"] ?? "unknown"
        return "\(type) · \(desktop)"
    }
}
