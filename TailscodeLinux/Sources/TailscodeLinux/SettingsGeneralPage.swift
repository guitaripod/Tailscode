import CAdw
import CGtkShim
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// General: which machines the app talks to, how to change that, and what this copy is.
enum SettingsGeneralPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        if DemoMode.isActive { addDemo(page, context) }
        addServers(page, context)
        addAbout(page, context)
    }

    private static func addDemo(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let demo = SettingsRows.group(Localized.text("Demo"), on: page)
        let windowHold = context.window
        let onLayoutChanged = context.onLayoutChanged
        SettingsRows.add(
            SettingsRows.buttonRow(Localized.text("Leave the demo world")) {
                DemoMode.leave()
                Task {
                    await ServerDirectory.shared.reload()
                    Gtk.onMain {
                        onLayoutChanged()
                        if let held = windowHold.widget {
                            gtk_window_close(ptr(held))
                        }
                    }
                }
            }, to: demo)
    }

    private static func addServers(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let servers = SettingsRows.group(Localized.text("Servers"), on: page)
        let groupHold = Gtk.WeakWidget(servers)
        Task {
            let lines = await serverLines()
            Gtk.onMain {
                guard let held = groupHold.widget else { return }
                fillServers(lines, into: held)
            }
        }

        let onOpenServers = context.onOpenServers
        let manage = SettingsRows.group(nil, on: page)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Your machines"),
                subtitle: Localized.text("Add a machine, change an address or a password, or remove one"),
                label: Localized.text("Manage…")
            ) { onOpenServers() }, to: manage)
    }

    private static func addAbout(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let about = SettingsRows.group(Localized.text("About"), on: page)
        SettingsRows.add(
            SettingsRows.infoRow(Localized.text("Version"), value: TailscodeVersion.current),
            to: about)
        let onOpenUpdates = context.onOpenUpdates
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Update Center"),
                subtitle: Localized.text(
                    "This app and every server it talks to: what each runs and what it could run"),
                label: Localized.text("Open")
            ) { onOpenUpdates() }, to: about)
    }

    /// One machine as the page says it: the name, and its address with when it last answered.
    private struct ServerLine: Sendable {
        let name: String
        let detail: String
    }

    private static func serverLines() async -> [ServerLine] {
        let profiles = await ServerDirectory.shared.profiles()
        let heard = await ServerDirectory.shared.lastHeard
        return profiles.map { profile in
            ServerLine(
                name: ServerLabel.display(profile),
                detail: "\(ServerLabel.address(profile)) · \(state(of: profile, heard: heard))")
        }
    }

    private static func state(of profile: ConnectionProfile, heard: [String: Date]) -> String {
        guard !profile.id.hasPrefix(DemoWorld.profilePrefix) else { return Localized.text("Demo") }
        guard let last = heard[ServerLabel.display(profile)] else {
            return Localized.text("Not heard from yet")
        }
        return Localized.text("Answered %@ ago", SessionRowModel.age(of: last))
    }

    private static func fillServers(_ lines: [ServerLine], into group: UnsafeMutablePointer<GtkWidget>) {
        guard !lines.isEmpty else {
            SettingsRows.add(
                SettingsRows.noteRow(
                    Localized.text("No servers yet. Add the machine your agents run on.")),
                to: group)
            return
        }
        for line in lines {
            let row = SettingsRows.infoRow(line.name, value: "", subtitle: line.detail)
            SettingsRows.add(row, to: group)
        }
    }
}

extension SettingsRows {
    /// A sentence in a group where there is nothing to press and nothing to read off.
    static func noteRow(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), text)
        gtk_widget_add_css_class(row, "dim-label")
        gtk_list_box_row_set_activatable(ptr(UnsafeMutableRawPointer(row)), 0)
        return row
    }
}
