import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// First run as a window that draws a `FirstRunPlan`. The plan is Core's: the rows, the words and
/// the one press that moves on are the same on all three clients, and this file decides only how a
/// row is painted and what each intent reaches for on a Linux desktop. Shown when there is no
/// server yet, and again — as a question, not a form — when a link arrives for another machine.
final class FirstRunDialog: @unchecked Sendable {
    nonisolated(unsafe) private static var current: FirstRunDialog?

    static func presentIfNeeded(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        let parentBits = parent.map { UInt(bitPattern: $0) } ?? 0
        Task {
            await ServerDirectory.shared.reload()
            guard await ServerDirectory.shared.profiles().isEmpty else { return }
            Gtk.onMain {
                guard current == nil else { return }
                begin(mode: .firstRun, parentBits: parentBits, link: nil, onSaved: onSaved)
            }
        }
    }

    /// A link that reached the app from outside: the dialog already open takes it, and otherwise
    /// one opens — the first-run checklist when there is no server yet, the question when there is.
    static func open(
        link: String, parent: UnsafeMutablePointer<GtkWidget>?,
        onSaved: @escaping @Sendable () -> Void
    ) {
        if let existing = current {
            existing.raise()
            existing.send { await $0.paste(link) }
            return
        }
        let parentBits = parent.map { UInt(bitPattern: $0) } ?? 0
        Task {
            await ServerDirectory.shared.reload()
            let empty = await ServerDirectory.shared.profiles().isEmpty
            Gtk.onMain {
                guard current == nil else {
                    current?.raise()
                    current?.send { await $0.paste(link) }
                    return
                }
                begin(
                    mode: empty ? .firstRun : .addition, parentBits: parentBits, link: link,
                    onSaved: onSaved)
            }
        }
    }

    static func forTesting(mode: FirstRunState.Mode) -> FirstRunDialog {
        let dialog = FirstRunDialog(mode: mode, onSaved: {})
        dialog.build(parent: nil)
        return dialog
    }

    func applyForTesting(_ plan: FirstRunPlan) {
        render(plan)
    }

    func renderedTexts() -> [String] {
        guard let window else { return [] }
        var texts: [String] = []
        if let child = gtk_window_get_child(ptr(window)) { collect(from: child, into: &texts) }
        return texts
    }

    private func collect(from widget: UnsafeMutablePointer<GtkWidget>, into texts: inout [String]) {
        guard gtk_widget_get_visible(widget) != 0 else { return }
        let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
            let raw = gtk_label_get_text(op(widget))
        {
            texts.append(String(cString: raw))
        } else if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0,
            let raw = gtk_button_get_label(ptr(widget))
        {
            texts.append(String(cString: raw))
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            collect(from: current, into: &texts)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    func isShowingPassword() -> Bool {
        gtk_widget_get_visible(passwordBox) != 0
    }

    static func drive(_ verb: String, _ argument: String) {
        current?.driven(verb, argument)
    }

    private static func begin(
        mode: FirstRunState.Mode, parentBits: UInt, link: String?,
        onSaved: @escaping @Sendable () -> Void
    ) {
        let parent = UnsafeMutableRawPointer(bitPattern: parentBits).map {
            raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
        }
        let dialog = FirstRunDialog(mode: mode, onSaved: onSaved)
        current = dialog
        dialog.present(parent: parent, link: link)
    }

    private let flow: FirstRunFlow
    private let mode: FirstRunState.Mode
    private let onSaved: @Sendable () -> Void
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var rows: [FirstRunPlan.Row.ID: RowWidgets] = [:]
    private var plan: FirstRunPlan?
    private var closed = false
    private var finishing = false
    private var streamTask: Task<Void, Never>?
    private var blocksShown: [FirstRunPlan.Row.ID: [FirstRunPlan.Block]] = [:]
    private var tailscale: TailscaleReading?
    private var tailnetKeys: Set<String> = []
    private var discoveryRequested = false
    private var watching = false
    private var watchRounds = 0
    private var syncing = false

    private let intro = FirstRunDialog.wrapped("", css: "row-detail")
    private let demoButton = gtk_button_new_with_label("")!
    private let laterButton = gtk_button_new_with_label("")!
    private let primaryButton = gtk_button_new_with_label("")!
    private let backButton = gtk_button_new_with_label("")!
    private let remedyOutput: UnsafeMutablePointer<GtkWidget> = {
        let label = FirstRunDialog.wrapped("", css: "row-detail")
        g_object_ref_sink(UnsafeMutableRawPointer(label))
        return label
    }()
    private let permissionsStepArea = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let permissionsStepTitle = Gtk.label("", css: "row-title", selectable: false)
    private let permissionsDetailLabel = FirstRunDialog.wrapped("", css: "row-detail")
    private let permissionsBox = MachinePermissionsBox(local: false)
    private var permissionsBackend: (any PermissionReportingBackend)?
    private var permissionsPollPending = false

    private let waysBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let pasteBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let pasteEntry = gtk_entry_new()!
    private let offerButton = gtk_button_new_with_label("")!
    private let pasteReading = FirstRunDialog.wrapped("", css: "row-detail")
    private let pasteMessage = FirstRunDialog.wrapped("", css: "row-detail")
    private let installBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let linkBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let statusBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let passwordBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let passwordNote = FirstRunDialog.wrapped("", css: "row-detail")
    private let passwordEntry = gtk_password_entry_new()!
    private let discoveryBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private var discovery: DiscoveryPanel?

    private struct RowWidgets {
        let container: UnsafeMutablePointer<GtkWidget>
        let number: UnsafeMutablePointer<GtkWidget>
        let title: UnsafeMutablePointer<GtkWidget>
        let pill: UnsafeMutablePointer<GtkWidget>
        let detail: UnsafeMutablePointer<GtkWidget>
        let body: UnsafeMutablePointer<GtkWidget>
    }

    private init(mode: FirstRunState.Mode, onSaved: @escaping @Sendable () -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        flow = FirstRunFlow(
            platform: .linux, mode: mode,
            environment: FirstRunEnvironment(
                offersTailnetScan: true,
                profiles: { await ServerDirectory.shared.profiles() },
                save: { profile, password in
                    do {
                        try await ServerDirectory.shared.save(profile, password: password)
                        return .saved
                    } catch {
                        return .failed(String(describing: error))
                    }
                },
                log: { AppLog.write(.connection, $0) }))
    }

    private static func wrapped(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: css, wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(label), 78)
        return label
    }

    private func send(_ work: @escaping @Sendable (FirstRunFlow) async -> Void) {
        let flow = flow
        Task { await work(flow) }
    }

    private func raise() {
        if let window { gtk_window_present(ptr(window)) }
    }

    private func present(parent: UnsafeMutablePointer<GtkWidget>?, link: String?) {
        build(parent: parent)
        guard let window else { return }
        streamTask = Task { [self] in
            for await next in await flow.plans() {
                Gtk.onMain { [self] in render(next) }
            }
        }
        pollTailnet()
        render(FirstRunPlan.make(FirstRunState(platform: .linux, mode: mode)))
        gtk_window_present(ptr(window))
        readClipboard()
        if let link { send { await $0.paste(link) } }
    }

    private func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        let title =
            mode == .addition ? ConnectLinkReading.addQuestion : Localized.text("Welcome")
        let (window, content, actions) = Dialogs.windowWithActions(
            title: title, parent: parent, width: 660)
        self.window = window
        gtk_window_set_default_size(ptr(window), 680, 640)

        gtk_box_append(ptr(content), intro)
        for id in FirstRunPlan.Row.ID.allCases { gtk_box_append(ptr(content), makeRow(id)) }
        buildMachineSlots()
        buildPermissionsStep(in: content)

        gtk_box_append(ptr(actions), demoButton)
        gtk_box_append(ptr(actions), laterButton)
        gtk_box_append(ptr(actions), primaryButton)
        Gtk.addClass(primaryButton, "suggested-action")
        Gtk.addClass(laterButton, "flat")
        Gtk.connect(UnsafeMutableRawPointer(demoButton), "clicked") { [self] in
            Gtk.onMain { [self] in enterDemo() }
        }
        Gtk.connect(UnsafeMutableRawPointer(laterButton), "clicked") { [self] in
            Gtk.onMain { [self] in laterPressed() }
        }
        Gtk.connect(UnsafeMutableRawPointer(primaryButton), "clicked") { [self] in
            Gtk.onMain { [self] in primaryPressed() }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [self] in
            Gtk.onMain { [self] in tearDown() }
        }
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "is-active") { [self] in
            Gtk.onMain { [self] in readClipboard() }
        }
    }

    private func tearDown() {
        closed = true
        streamTask?.cancel()
        if Self.current === self { Self.current = nil }
    }

    private func close() {
        if let window { Dialogs.close(window) }
    }

    private func enterDemo() {
        Task {
            await ServerDirectory.shared.enterDemoMode()
            Gtk.onMain { [self] in
                close()
                onSaved()
            }
        }
    }

    private func laterPressed() {
        guard let plan else {
            close()
            return
        }
        if plan.later != nil {
            send { await $0.skipSignIn() }
        } else {
            close()
        }
    }

    private func primaryPressed() {
        guard let intent = plan?.primary?.intent else { return }
        switch intent {
        case .connect: send { await $0.connect() }
        case .openTailscale: performRemedy()
        case .signIn: presentSignIn()
        }
    }

    private func makeRow(_ id: FirstRunPlan.Row.ID) -> UnsafeMutablePointer<GtkWidget> {
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

    private func buildPermissionsStep(in content: UnsafeMutablePointer<GtkWidget>) {
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

    private func buildMachineSlots() {
        guard let machine = rows[.machine] else { return }
        for slot in [
            waysBox, pasteBox, installBox, linkBox, statusBox, passwordBox, discoveryBox,
        ] {
            gtk_box_append(ptr(machine.body), slot)
        }

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
        gtk_box_append(ptr(pasteBox), offerButton)
        Gtk.addClass(offerButton, "suggested-action")
        gtk_widget_set_halign(offerButton, GTK_ALIGN_START)
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
        for slot in [waysBox, pasteBox, installBox, linkBox, statusBox, passwordBox, discoveryBox, backButton]
        {
            gtk_widget_set_visible(slot, 0)
        }
    }

    private func render(_ next: FirstRunPlan) {
        guard !closed else { return }
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
        if next.isFinished, !finishing {
            finishing = true
            finish()
        }
    }

    private func renderRow(_ row: FirstRunPlan.Row, _ widgets: RowWidgets) {
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

    private static func pillStyle(_ glyph: FirstRunPlan.Row.Glyph) -> String {
        switch glyph {
        case .proven: return "glyph-running"
        case .attention: return "glyph-error"
        case .working, .current, .waiting: return "dim"
        }
    }

    private func renderGeneric(_ row: FirstRunPlan.Row, _ widgets: RowWidgets) {
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

    private func renderActions(_ next: FirstRunPlan) {
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

    private func renderMachine(_ blocks: [FirstRunPlan.Block]) {
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
        syncPaste(paste)
        syncPassword(password)
        syncDiscovery(installing: installContext)
    }

    private func refill(_ box: UnsafeMutablePointer<GtkWidget>, with blocks: [FirstRunPlan.Block]) {
        let slot = UInt(bitPattern: box)
        guard slotContents[slot] != blocks else { return }
        slotContents[slot] = blocks
        Gtk.removeChildren(of: box)
        gtk_widget_set_visible(box, blocks.isEmpty ? 0 : 1)
        for block in blocks { append(block, to: box) }
    }

    private var slotContents: [UInt: [FirstRunPlan.Block]] = [:]

    private func append(_ block: FirstRunPlan.Block, to box: UnsafeMutablePointer<GtkWidget>) {
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

    private func wayButton(_ way: FirstRunPlan.Way) -> UnsafeMutablePointer<GtkWidget> {
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

    private func chose(_ kind: FirstRunPlan.Way.Kind) {
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

    private func agentRow(_ choices: [FirstRunPlan.AgentChoice]) -> UnsafeMutablePointer<GtkWidget> {
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

    private func appendCommand(
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

    private func appendLink(_ card: FirstRunPlan.LinkCard, to box: UnsafeMutablePointer<GtkWidget>) {
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

    private func appendDiagnosis(
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

    private func appendSignIn(_ card: FirstRunPlan.SignInCard, to box: UnsafeMutablePointer<GtkWidget>) {
        let button = Gtk.button(card.action, css: ["suggested-action"]) { [self] in
            Gtk.onMain { [self] in presentSignIn() }
        }
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_box_append(ptr(box), button)
    }

    private func presentSignIn() {
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

    private func syncPaste(_ paste: FirstRunPlan.Paste?) {
        gtk_widget_set_visible(pasteBox, paste == nil ? 0 : 1)
        guard let paste else { return }
        gtk_entry_set_placeholder_text(ptr(pasteEntry), paste.placeholder)
        if Dialogs.entryText(pasteEntry) != paste.text {
            syncing = true
            gtk_editable_set_text(op(pasteEntry), paste.text)
            gtk_editable_set_position(op(pasteEntry), -1)
            syncing = false
        }
        gtk_widget_set_visible(offerButton, paste.offer == nil ? 0 : 1)
        if let offer = paste.offer { gtk_button_set_label(ptr(offerButton), offer) }
        gtk_label_set_text(op(pasteReading), paste.reading ?? "")
        gtk_widget_set_visible(pasteReading, paste.reading == nil || paste.message != nil ? 0 : 1)
        let message = paste.message.map { "\($0.title)\n\($0.detail)" } ?? ""
        gtk_label_set_text(op(pasteMessage), message)
        gtk_widget_set_visible(pasteMessage, paste.message == nil ? 0 : 1)
    }

    private func syncPassword(_ password: FirstRunPlan.PasswordField?) {
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

    private func syncDiscovery(installing: Bool) {
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

    private func scheduleWatch() {
        Gtk.after(8000) { [self] in
            guard !closed, watching else { return }
            if tailscale?.isUp ?? false { discovery?.scan() }
            scheduleWatch()
        }
    }

    private func sighted(_ suggestion: TailnetScanner.Suggestion) {
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

    private func scanFinished() {
        watchRounds += 1
    }

    private func addFromScan(_ suggestion: TailnetScanner.Suggestion) {
        let flow = flow
        Task {
            await flow.adopt(suggestion)
            if case .found = await flow.snapshot.machine { await flow.connect() }
        }
    }

    private func readClipboard() {
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

    private final class ClipboardBox {
        let handler: (String?) -> Void
        init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    }

    private func pollTailnet() {
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

    private func finish() {
        let flow = flow
        Task {
            let saved = await flow.saved
            onSaved()
            await checkPermissions(saved?.profile)
        }
    }

    /// The Mac just reached may need a grant its agents can't give themselves — asked once the
    /// account step has nothing left, so the checklist never stalls on two questions at once.
    /// A server that isn't a Claude Code Mac, or one too old for the route, closes as before.
    private func checkPermissions(_ profile: ConnectionProfile?) async {
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

    private func requestPermission(_ kind: MachinePermissions.Grant.Kind) {
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

    private func schedulePermissionsPoll(waiting: Bool) {
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

    private func closeAfterGrant() {
        Gtk.after(Gtk.milliseconds(MachinePermissionReading.doneLinger)) { [self] in
            guard !closed else { return }
            close()
        }
    }

    private static func within<T: Sendable>(
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

    private func performRemedy() {
        guard let reading = tailscale else { return }
        switch reading.remedy {
        case .install(let url): SignInDialog.openInBrowser(url)
        case .signIn(let command), .start(let command): run(command)
        case .grantHostAccess(let command): Gtk.copyToClipboard(command)
        case .none: break
        }
    }

    private func appendRemedy(_ reading: TailscaleReading, to box: UnsafeMutablePointer<GtkWidget>) {
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

    /// A command that has to run on *this* machine is run from here, with its output on the same
    /// screen, rather than handed over with "run it in a terminal" — which is the one thing the
    /// first-run doctrine forbids and is also useless advice to somebody who has never opened one.
    ///
    /// `tailscale up` answers by printing a login URL and waiting, so the URL is watched for and
    /// opened as it appears; anything needing root is raised through pkexec, which asks with the
    /// desktop's own dialog. A command that cannot run says so and leaves the copyable line.
    private func run(_ command: String) {
        let elevated = command.hasPrefix("sudo ")
        let bare = elevated ? String(command.dropFirst(5)) : command
        let usePolkit = elevated && FileManager.default.isExecutableFile(atPath: "/usr/bin/pkexec")
        gtk_label_set_text(op(remedyOutput), Localized.text("Running %@…", bare))
        gtk_widget_set_visible(remedyOutput, 1)

        Task.detached { [self] in
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
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    gtk_label_set_text(
                        op(remedyOutput),
                        Localized.text(
                            "This machine would not run %@. Copy it and run it yourself, then this "
                                + "step turns green on its own.", bare))
                }
                return
            }
            var seen = ""
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                seen += String(decoding: chunk, as: UTF8.self)
                let text = seen
                if let url = Self.loginURL(in: text) {
                    Gtk.onMain { SignInDialog.openInBrowser(url) }
                    seen = ""
                }
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    gtk_label_set_text(op(remedyOutput), text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
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

    private func driven(_ verb: String, _ argument: String) {
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
        default: break
        }
    }
}
