import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension FirstRunDialog {
    /// The Mac just reached may need a grant its agents can't give themselves — asked once the
    /// account step has nothing left, so the checklist never stalls on two questions at once.
    /// A server that isn't a Claude Code Mac, or one too old for the route, closes as before.
    func checkPermissions(_ profile: ConnectionProfile?) async {
        guard let profile, profile.backend == .claudeCode,
            let backend = await ServerDirectory.shared.backend(for: profile)
                as? any PermissionReportingBackend,
            let permissions = await Self.within(15, { try? await backend.machinePermissions() }),
            MachinePermissionReading.needsAttention(permissions)
        else {
            Gtk.onMain { [self] in close() }
            return
        }
        permissionsBackend = backend
        Gtk.onMain { [self] in
            guard !closed else { return }
            gtk_label_set_text(op(permissionsStepTitle), MachinePermissionReading.setupTitle)
            gtk_label_set_text(op(permissionsDetailLabel), MachinePermissionReading.setupDetail(permissions))
            permissionsBox.apply(permissions)
            gtk_widget_set_visible(permissionsStepArea, 1)
            schedulePermissionsPoll(waiting: MachinePermissionReading.isWaiting(permissions))
        }
    }

    func requestPermission(_ kind: MachinePermissions.Grant.Kind) {
        guard let backend = permissionsBackend else { return }
        Task { [self] in
            guard
                let permissions = await Self.within(
                    15, { try? await backend.requestMachinePermission(kind) })
            else {
                Gtk.onMain { [self] in permissionsBox.showRequestFailed() }
                return
            }
            Gtk.onMain { [self] in
                guard !closed else { return }
                permissionsBox.apply(permissions)
                schedulePermissionsPoll(waiting: MachinePermissionReading.isWaiting(permissions))
            }
        }
    }

    func schedulePermissionsPoll(waiting: Bool) {
        guard waiting, !closed, !permissionsPollPending else { return }
        permissionsPollPending = true
        Gtk.after(Gtk.milliseconds(MachinePermissionReading.pollInterval)) { [self] in
            permissionsPollPending = false
            guard !closed, let backend = permissionsBackend else { return }
            Task { [self] in
                guard
                    let permissions = await Self.within(15, { try? await backend.machinePermissions() })
                else { return }
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    permissionsBox.apply(permissions)
                    if permissions.isComplete {
                        closeAfterGrant()
                    } else {
                        schedulePermissionsPoll(waiting: MachinePermissionReading.isWaiting(permissions))
                    }
                }
            }
        }
    }

    func closeAfterGrant() {
        Gtk.after(Gtk.milliseconds(MachinePermissionReading.doneLinger)) { [self] in
            guard !closed else { return }
            close()
        }
    }

    static func within<T: Sendable>(
        _ seconds: Int, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func performRemedy() {
        guard let reading = tailscale else { return }
        TailnetRemedyRunner.perform(reading, narrate: narrate)
    }

    func appendRemedy(_ reading: TailscaleReading, to box: UnsafeMutablePointer<GtkWidget>) {
        gtk_label_set_text(op(remedyOutput), "")
        gtk_widget_set_visible(remedyOutput, 0)
        guard let title = reading.actionTitle else { return }
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        switch reading.remedy {
        case .install(let url):
            gtk_box_append(ptr(actions), Gtk.button(title) { SignInDialog.openInBrowser(url) })
        case .signIn(let command), .start(let command):
            gtk_box_append(
                ptr(actions),
                Gtk.button(title) { [self] in Gtk.onMain { [self] in run(command) } })
            gtk_box_append(
                ptr(actions),
                Gtk.button(Localized.text("Copy"), css: ["flat"]) { Gtk.copyToClipboard(command) })
        case .grantHostAccess(let command):
            gtk_box_append(
                ptr(actions),
                Gtk.button(Localized.text("Copy"), css: ["flat"]) { Gtk.copyToClipboard(command) })
        case .none:
            break
        }
        gtk_box_append(ptr(box), actions)
        gtk_box_append(ptr(box), remedyOutput)
    }

    func run(_ command: String) {
        TailnetRemedyRunner.run(command, narrate: narrate)
    }

    /// What a remedy prints, shown under the Tailscale step for as long as the dialog is there.
    var narrate: @Sendable (String) -> Void {
        { [self] text in
            Gtk.onMain { [self] in
                guard !closed else { return }
                gtk_label_set_text(op(remedyOutput), text)
                gtk_widget_set_visible(remedyOutput, 1)
            }
        }
    }

    func driven(_ verb: String, _ argument: String) {
        switch verb {
        case "frpaste": send { await $0.paste(argument) }
        case "frchoose":
            if let kind = FirstRunPlan.Way.Kind(rawValue: argument) { chose(kind) }
        case "frback": send { await $0.back() }
        case "frconfirm": send { await $0.confirmOffTailnet() }
        case "frconnect": send { await $0.connect() }
        case "fragent":
            let agent: AgentType? =
                argument == "opencode" ? .openCode : argument == "omp" ? .omp : argument == "claude" ? .claudeCode : nil
            if let agent { send { await $0.selectAgent(agent) } }
        case "frhanded": send { await $0.handedOver() }
        case "frpassword": send { await $0.setPassword(argument) }
        case "frretry": send { await $0.retry() }
        case "frlater": Gtk.onMain { [self] in laterPressed() }
        default: break
        }
    }
}
