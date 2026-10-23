import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension FirstRunDialog {
    func makeRow(_ id: FirstRunPlan.Row.ID) -> UnsafeMutablePointer<GtkWidget> {
        let container = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.margins(container, top: 8)
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let number = Gtk.label("", css: "dim", selectable: false)
        let title = Gtk.label("", css: "row-title", selectable: false)
        let pill = Gtk.label("", css: "row-detail", selectable: false)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        for part in [number, title, spacer, pill] { gtk_box_append(ptr(header), part) }
        let detail = FirstRunDialog.wrapped("", css: "row-detail")
        Gtk.margins(detail, leading: 22)
        let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.margins(body, leading: 22)
        for part in [header, detail, body] { gtk_box_append(ptr(container), part) }
        rows[id] = RowWidgets(
            container: container, number: number, title: title, pill: pill, detail: detail,
            body: body)
        return container
    }

    func buildPermissionsStep(in content: UnsafeMutablePointer<GtkWidget>) {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(header), Gtk.label("4 ·", css: "dim", selectable: false))
        gtk_box_append(ptr(header), permissionsStepTitle)
        gtk_box_append(ptr(permissionsStepArea), header)
        Gtk.margins(permissionsDetailLabel, leading: 22)
        gtk_box_append(ptr(permissionsStepArea), permissionsDetailLabel)
        let wrapper = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(wrapper, top: 6, leading: 22)
        gtk_box_append(ptr(wrapper), permissionsBox.widget)
        gtk_box_append(ptr(permissionsStepArea), wrapper)
        let skip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.margins(skip, top: 6, leading: 22)
        gtk_box_append(
            ptr(skip),
            Gtk.button(MachinePermissionReading.skip, css: ["flat"]) { [self] in
                Gtk.onMain { [self] in close() }
            })
        gtk_box_append(ptr(permissionsStepArea), skip)
        Gtk.margins(permissionsStepArea, top: 8)
        gtk_widget_set_visible(permissionsStepArea, 0)
        gtk_box_append(ptr(content), permissionsStepArea)
        permissionsBox.onRequest = { [self] kind in requestPermission(kind) }
    }

    func buildMachineSlots() {
        guard let machine = rows[.machine] else { return }
        for slot in [
            offerBox, waysBox, pasteBox, installBox, linkBox, statusBox, passwordBox, discoveryBox,
        ] {
            gtk_box_append(ptr(machine.body), slot)
        }
        gtk_box_append(ptr(offerBox), offerButton)
        gtk_box_append(ptr(offerBox), offerDetail)
        gtk_widget_set_halign(offerButton, GTK_ALIGN_START)

        gtk_button_set_label(ptr(backButton), "")
        Gtk.addClass(backButton, "flat")
        gtk_widget_set_halign(backButton, GTK_ALIGN_START)
        Gtk.connect(UnsafeMutableRawPointer(backButton), "clicked") { [self] in
            Gtk.onMain { [self] in
                discoveryRequested = false
                send { await $0.back() }
            }
        }
        gtk_box_prepend(ptr(machine.body), backButton)

        gtk_entry_set_activates_default(ptr(pasteEntry), 0)
        gtk_widget_set_hexpand(pasteEntry, 1)
        gtk_box_append(ptr(pasteBox), pasteEntry)
        gtk_box_append(ptr(pasteBox), pasteReading)
        gtk_box_append(ptr(pasteBox), pasteMessage)
        Gtk.connect(UnsafeMutableRawPointer(pasteEntry), "changed") { [self] in
            Gtk.onMain { [self] in
                guard !syncing else { return }
                let text = Dialogs.entryText(pasteEntry)
                send { await $0.paste(text) }
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(offerButton), "clicked") { [self] in
            send { await $0.useClipboardLink() }
        }

        gtk_box_append(ptr(passwordBox), passwordNote)
        gtk_box_append(ptr(passwordBox), passwordEntry)
        gtk_editable_set_text(op(passwordEntry), "")
        Gtk.connect(UnsafeMutableRawPointer(passwordEntry), "changed") { [self] in
            Gtk.onMain { [self] in
                guard !syncing else { return }
                let text = Dialogs.entryText(passwordEntry)
                send { await $0.setPassword(text) }
            }
        }

        let panel = DiscoveryPanel(
            onAdd: { [weak self] suggestion in self?.addFromScan(suggestion) }, onChanged: {})
        panel.onSighted = { [weak self] suggestion in self?.sighted(suggestion) }
        panel.onFinished = { [weak self] in self?.scanFinished() }
        discovery = panel
        gtk_box_append(ptr(discoveryBox), panel.group)
        for slot in [
            offerBox, waysBox, pasteBox, installBox, linkBox, statusBox, passwordBox, discoveryBox,
            backButton,
        ] {
            gtk_widget_set_visible(slot, 0)
        }
    }

    func render(_ next: FirstRunPlan, fixture: Bool = false) {
        guard !closed, fixture || !fixed else { return }
        plan = next
        gtk_label_set_text(op(intro), mode == .firstRun ? next.intro : "")
        gtk_widget_set_visible(intro, mode == .firstRun ? 1 : 0)
        for id in FirstRunPlan.Row.ID.allCases {
            guard let widgets = rows[id] else { continue }
            let row = next.row(id)
            gtk_widget_set_visible(widgets.container, row == nil ? 0 : 1)
            if let row { renderRow(row, widgets) }
        }
        renderActions(next)
        if next.outcome != nil {
            send { await $0.acknowledgeOutcome() }
            close()
            mainWindow?.raise()
            return
        }
        if next.isFinished, !finishing, !fixed {
            finishing = true
            finish()
        }
    }

    func renderRow(_ row: FirstRunPlan.Row, _ widgets: RowWidgets) {
        gtk_label_set_text(op(widgets.number), "\(row.number) ·")
        gtk_label_set_text(op(widgets.title), row.title)
        gtk_label_set_text(op(widgets.pill), row.pill ?? "")
        for name in ["dim", "glyph-running", "glyph-error", "glyph-needs", "glyph-pending"] {
            gtk_widget_remove_css_class(widgets.pill, name)
        }
        Gtk.addClass(widgets.pill, Self.pillStyle(row.glyph))
        gtk_label_set_text(op(widgets.detail), row.detail ?? "")
        gtk_widget_set_visible(widgets.detail, row.detail == nil ? 0 : 1)
        switch row.id {
        case .machine: renderMachine(row.blocks)
        case .tailscale, .connected: renderGeneric(row, widgets)
        }
    }

    static func pillStyle(_ glyph: FirstRunPlan.Row.Glyph) -> String {
        switch glyph {
        case .proven: return "glyph-running"
        case .attention: return "glyph-error"
        case .working, .current, .waiting: return "dim"
        }
    }

    func renderGeneric(_ row: FirstRunPlan.Row, _ widgets: RowWidgets) {
        guard blocksShown[row.id] != row.blocks else { return }
        blocksShown[row.id] = row.blocks
        Gtk.removeChildren(of: widgets.body)
        for block in row.blocks {
            switch block {
            case .remedy(let reading):
                tailscale = reading
                appendRemedy(reading, to: widgets.body)
            case .diagnosis(let diagnosis):
                appendDiagnosis(diagnosis, to: widgets.body)
            case .signIn(let card):
                appendSignIn(card, to: widgets.body)
            case .note(let text):
                gtk_box_append(ptr(widgets.body), FirstRunDialog.wrapped(text, css: "row-detail"))
            default:
                break
            }
        }
    }

    func renderActions(_ next: FirstRunPlan) {
        let demo = next.demo
        gtk_widget_set_visible(demoButton, demo == nil ? 0 : 1)
        if let demo {
            gtk_button_set_label(ptr(demoButton), demo.title)
            gtk_widget_set_tooltip_text(demoButton, demo.detail)
        }
        gtk_button_set_label(ptr(laterButton), next.dismiss)
        if let primary = next.primary {
            gtk_widget_set_visible(primaryButton, 1)
            gtk_button_set_label(ptr(primaryButton), primary.title)
            gtk_widget_set_sensitive(primaryButton, primary.isEnabled ? 1 : 0)
        } else {
            gtk_widget_set_visible(primaryButton, 0)
        }
        gtk_button_set_label(ptr(backButton), next.back ?? "")
        gtk_widget_set_visible(backButton, next.back == nil ? 0 : 1)
    }

    func renderMachine(_ blocks: [FirstRunPlan.Block]) {
        var ways: [FirstRunPlan.Block] = []
        var paste: FirstRunPlan.Paste?
        var install: [FirstRunPlan.Block] = []
        var link: [FirstRunPlan.Block] = []
        var status: [FirstRunPlan.Block] = []
        var password: FirstRunPlan.PasswordField?
        var installContext = false
        var sawInstallWays = false
        for block in blocks {
            switch block {
            case .ways:
                if installContext {
                    install.append(block)
                    sawInstallWays = true
                } else {
                    ways.append(block)
                }
            case .paste(let value): paste = value
            case .agents, .command:
                installContext = true
                install.append(block)
            case .waiting:
                if installContext && !sawInstallWays { install.append(block) } else { status.append(block) }
            case .link: link.append(block)
            case .diagnosis: status.append(block)
            case .password(let value): password = value
            case .note, .signIn, .remedy: break
            }
        }
        refill(waysBox, with: ways)
        refill(installBox, with: install)
        refill(linkBox, with: link)
        refill(statusBox, with: status)
        syncOffer(plan?.offer)
        syncPaste(paste)
        syncPassword(password)
        syncDiscovery(installing: installContext)
    }
}
