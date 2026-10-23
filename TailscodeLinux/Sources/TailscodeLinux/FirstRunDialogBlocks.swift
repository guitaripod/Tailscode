import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension FirstRunDialog {
    func syncOffer(_ offer: FirstRunPlan.Offer?) {
        gtk_widget_set_visible(offerBox, offer == nil ? 0 : 1)
        guard let offer else { return }
        gtk_button_set_label(ptr(offerButton), offer.title)
        gtk_label_set_text(op(offerDetail), offer.detail)
    }

    func refill(_ box: UnsafeMutablePointer<GtkWidget>, with blocks: [FirstRunPlan.Block]) {
        let slot = UInt(bitPattern: box)
        guard slotContents[slot] != blocks else { return }
        slotContents[slot] = blocks
        Gtk.removeChildren(of: box)
        gtk_widget_set_visible(box, blocks.isEmpty ? 0 : 1)
        for block in blocks { append(block, to: box) }
    }

    func append(_ block: FirstRunPlan.Block, to box: UnsafeMutablePointer<GtkWidget>) {
        switch block {
        case .ways(let ways):
            for way in ways { gtk_box_append(ptr(box), wayButton(way)) }
        case .agents(let choices):
            gtk_box_append(ptr(box), agentRow(choices))
        case .command(let card):
            appendCommand(card, to: box)
        case .waiting(let text):
            gtk_box_append(ptr(box), FirstRunDialog.wrapped(text, css: "row-detail"))
        case .link(let card):
            appendLink(card, to: box)
        case .diagnosis(let diagnosis):
            appendDiagnosis(diagnosis, to: box)
        case .note(let text):
            gtk_box_append(ptr(box), FirstRunDialog.wrapped(text, css: "row-detail"))
        case .paste, .password, .signIn, .remedy:
            break
        }
    }

    func wayButton(_ way: FirstRunPlan.Way) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), Gtk.label(way.title, css: "row-title", selectable: false))
        gtk_box_append(
            ptr(column), FirstRunDialog.wrapped(way.detail, css: "row-detail"))
        gtk_button_set_child(ptr(button), column)
        gtk_widget_set_halign(button, GTK_ALIGN_FILL)
        let kind = way.kind
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [self] in
            Gtk.onMain { [self] in chose(kind) }
        }
        return button
    }

    func chose(_ kind: FirstRunPlan.Way.Kind) {
        switch kind {
        case .scan:
            break
        case .link:
            send { await $0.choose(.link) }
            gtk_widget_grab_focus(pasteEntry)
        case .install:
            send { await $0.choose(.install) }
        case .tailnet:
            discoveryRequested = true
            gtk_widget_set_visible(discoveryBox, 1)
            discovery?.scan()
        }
    }

    func agentRow(_ choices: [FirstRunPlan.AgentChoice]) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        for choice in choices {
            let button = Gtk.button(
                choice.title, css: choice.isSelected ? ["suggested-action"] : ["flat"]
            ) { [self] in
                send { await $0.selectAgent(choice.agent) }
            }
            gtk_widget_set_tooltip_text(button, choice.detail)
            gtk_box_append(ptr(row), button)
        }
        return row
    }

    func appendCommand(
        _ card: FirstRunPlan.CommandCard, to box: UnsafeMutablePointer<GtkWidget>
    ) {
        gtk_box_append(ptr(box), Gtk.label(card.title, css: "row-title", selectable: false))
        gtk_box_append(ptr(box), FirstRunDialog.wrapped(card.detail, css: "row-detail"))
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let text = Gtk.label(card.command, css: "tool-line", selectable: true)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(text, 1)
        gtk_box_append(ptr(line), text)
        let command = card.command
        gtk_box_append(
            ptr(line),
            Gtk.button(card.copyTitle, css: ["flat"]) { [self] in
                Gtk.copyToClipboard(command)
                send { await $0.handedOver() }
            })
        gtk_box_append(ptr(box), line)
        if let note = card.note {
            gtk_box_append(ptr(box), FirstRunDialog.wrapped(note, css: "row-detail"))
        }
    }

    func appendLink(_ card: FirstRunPlan.LinkCard, to box: UnsafeMutablePointer<GtkWidget>) {
        gtk_box_append(ptr(box), Gtk.label(card.headline, css: "row-title", selectable: false))
        for line in card.lines {
            gtk_box_append(ptr(box), FirstRunDialog.wrapped(line, css: "row-detail"))
        }
        if let title = card.connectAnywayTitle {
            let button = Gtk.button(title) { [self] in send { await $0.confirmOffTailnet() } }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(box), button)
        }
    }

    func appendDiagnosis(
        _ diagnosis: ConnectDiagnosis, to box: UnsafeMutablePointer<GtkWidget>
    ) {
        gtk_box_append(
            ptr(box),
            FirstRunDialog.wrapped("\(diagnosis.title)\n\(diagnosis.detail)", css: "row-detail"))
        guard let title = diagnosis.actionTitle else { return }
        let button: UnsafeMutablePointer<GtkWidget>?
        switch diagnosis.fix {
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            let address = url.absoluteString
            button = Gtk.button(title) { [self] in
                send { await $0.typeAddress(address) }
                send { await $0.retry() }
            }
        case .retry:
            button = Gtk.button(title) { [self] in send { await $0.retry() } }
        case .openTailscale:
            button = Gtk.button(title) { [self] in Gtk.onMain { [self] in performRemedy() } }
        case .revealPassword:
            button = Gtk.button(title) { [self] in send { await $0.revealPassword() } }
        case .copyCommand(let command):
            button = Gtk.button(title) { Gtk.copyToClipboard(command) }
        case .none, .openAppSettings, .seePro:
            button = nil
        }
        if let button {
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(box), button)
        }
    }

    func appendSignIn(_ card: FirstRunPlan.SignInCard, to box: UnsafeMutablePointer<GtkWidget>) {
        gtk_box_append(ptr(box), Gtk.label(card.title, css: "row-title", selectable: false))
    }

    func presentSignIn() {
        let flow = flow
        Task {
            guard let saved = await flow.saved,
                let backend = await ServerDirectory.shared.backend(for: saved.profile)
                    as? any AuthenticatingBackend
            else {
                await flow.skipSignIn()
                return
            }
            let name = saved.profile.name
            Gtk.onMain {
                SignInDialog.present(parent: nil, serverName: name, backend: backend) {
                    Task {
                        let auth = try? await backend.authStatus()
                        await flow.signInFinished(account: auth?.accountLabel)
                    }
                }
            }
        }
    }

    func syncPaste(_ paste: FirstRunPlan.Paste?) {
        gtk_widget_set_visible(pasteBox, paste == nil ? 0 : 1)
        guard let paste else { return }
        gtk_entry_set_placeholder_text(ptr(pasteEntry), paste.placeholder)
        if Dialogs.entryText(pasteEntry) != paste.text {
            syncing = true
            gtk_editable_set_text(op(pasteEntry), paste.text)
            gtk_editable_set_position(op(pasteEntry), -1)
            syncing = false
        }
        gtk_label_set_text(op(pasteReading), paste.reading ?? "")
        gtk_widget_set_visible(pasteReading, paste.reading == nil || paste.message != nil ? 0 : 1)
        let message = paste.message.map { "\($0.title)\n\($0.detail)" } ?? ""
        gtk_label_set_text(op(pasteMessage), message)
        gtk_widget_set_visible(pasteMessage, paste.message == nil ? 0 : 1)
    }

    func syncPassword(_ password: FirstRunPlan.PasswordField?) {
        gtk_widget_set_visible(passwordBox, password == nil ? 0 : 1)
        guard let password else { return }
        gtk_label_set_text(op(passwordNote), password.note ?? "")
        gtk_widget_set_visible(passwordNote, password.note == nil ? 0 : 1)
        if Dialogs.entryText(passwordEntry) != password.text {
            syncing = true
            gtk_editable_set_text(op(passwordEntry), password.text)
            syncing = false
        }
    }

    func syncDiscovery(installing: Bool) {
        let visible = discoveryRequested || installing
        gtk_widget_set_visible(discoveryBox, visible ? 1 : 0)
        guard installing != watching else { return }
        watching = installing
        guard installing else { return }
        watchRounds = 0
        tailnetKeys = []
        discovery?.scan()
        scheduleWatch()
    }

    func scheduleWatch() {
        Gtk.after(8000) { [self] in
            guard !closed, watching else { return }
            if tailscale?.isUp ?? false { discovery?.scan() }
            scheduleWatch()
        }
    }

    func sighted(_ suggestion: TailnetScanner.Suggestion) {
        guard watching else { return }
        if watchRounds == 0 {
            tailnetKeys.insert(suggestion.dedupeKey)
            return
        }
        guard !tailnetKeys.contains(suggestion.dedupeKey) else { return }
        tailnetKeys.insert(suggestion.dedupeKey)
        watching = false
        send { await $0.adopt(suggestion) }
    }

    func scanFinished() {
        watchRounds += 1
    }

    func addFromScan(_ suggestion: TailnetScanner.Suggestion) {
        let flow = flow
        Task {
            await flow.adopt(suggestion)
            if case .found = await flow.snapshot.machine { await flow.connect() }
        }
    }

    func readClipboard() {
        guard !closed else { return }
        let box = Unmanaged.passRetained(ClipboardBox { [weak self] text in
            guard let self else { return }
            self.send { await $0.clipboard(text) }
        }).toOpaque()
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            text, raw in
            guard let raw else { return }
            let box = Unmanaged<ClipboardBox>.fromOpaque(raw).takeRetainedValue()
            box.handler(text.map { String(cString: $0) })
        }
        tailscode_clipboard_read_text(callback, box)
    }

    final class ClipboardBox {
        let handler: (String?) -> Void
        init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    }

    func pollTailnet() {
        Task.detached { [self] in
            while !closed {
                let reading = TailnetStatusLinux.read().reading
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    tailscale = reading
                }
                await flow.tailscale(reading)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func finish() {
        let flow = flow
        Task {
            let saved = await flow.saved
            let landing = await flow.landing
            Gtk.onMain { [self] in self.landing = landing }
            onSaved()
            await checkPermissions(saved?.profile)
        }
    }
}
