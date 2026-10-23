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
    nonisolated(unsafe) static var current: FirstRunDialog?
    nonisolated(unsafe) static var onLanded: @Sendable (FirstRunLanding) -> Void = { _ in }

    static func presentIfNeeded(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        let parentHold = parent.map { Gtk.WeakWidget($0) }
        Task {
            await ServerDirectory.shared.reload()
            guard await ServerDirectory.shared.profiles().isEmpty else { return }
            Gtk.onMain {
                guard current == nil else { return }
                begin(
                    mode: .firstRun, parentHold: parentHold, link: nil, way: nil, onSaved: onSaved)
            }
        }
    }

    /// The checklist for whoever asks for a machine to be added: first run when no server exists,
    /// its addition mode when one does, which has no Tailscale row to wrongly claim anything is
    /// missing. A dialog already open is raised and moved to the way asked for.
    static func present(
        way: FirstRunPlan.Way.Kind?, parent: UnsafeMutablePointer<GtkWidget>?,
        onSaved: @escaping @Sendable () -> Void
    ) {
        let parentHold = parent.map { Gtk.WeakWidget($0) }
        Task {
            await ServerDirectory.shared.reload()
            let real = !EmptyWelcome.holdsNoRealServer(await ServerDirectory.shared.profiles())
            Gtk.onMain {
                if let existing = current {
                    existing.raise()
                    if let way { existing.chose(way) }
                    return
                }
                begin(
                    mode: real ? .addition : .firstRun, parentHold: parentHold, link: nil,
                    way: way, onSaved: onSaved)
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
        let parentHold = parent.map { Gtk.WeakWidget($0) }
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
                    mode: empty ? .firstRun : .addition, parentHold: parentHold, link: link,
                    way: nil, onSaved: onSaved)
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
        if let child = gtk_window_get_child(ptr(window)) { Self.collect(from: child, into: &texts) }
        return texts
    }

    static func collect(from widget: UnsafeMutablePointer<GtkWidget>, into texts: inout [String]) {
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
            return
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            Self.collect(from: current, into: &texts)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    func isShowingPassword() -> Bool {
        gtk_widget_get_visible(passwordBox) != 0
    }

    static func drive(_ verb: String, _ argument: String) {
        guard verb == "frstate" else {
            current?.driven(verb, argument)
            return
        }
        stage(argument)
    }

    /// `frstate=<name>`: one state of the checklist from `FirstRunFixtures`, drawn through the
    /// ordinary plan and left alone — nothing is probed and the live plan no longer redraws it — so a
    /// picture of "the machine refused" needs no machine.
    static func stage(_ name: String) {
        guard let state = FirstRunFixtures.state(named: name, platform: .linux) else {
            FileHandle.standardError.write(Data("first-run: no state \(name)\n".utf8))
            return
        }
        if let existing = current, existing.mode != state.mode { existing.close() }
        let dialog: FirstRunDialog
        if let existing = current {
            dialog = existing
        } else {
            dialog = FirstRunDialog(mode: state.mode, onSaved: {})
            current = dialog
            dialog.present(parent: nil, link: nil)
        }
        dialog.fixed = true
        dialog.tailscale = state.tailscale
        dialog.render(FirstRunPlan.make(state), fixture: true)
    }

    static func begin(
        mode: FirstRunState.Mode, parentHold: Gtk.WeakWidget?, link: String?,
        way: FirstRunPlan.Way.Kind?, onSaved: @escaping @Sendable () -> Void
    ) {
        let parent = parentHold?.widget
        let dialog = FirstRunDialog(mode: mode, onSaved: onSaved)
        current = dialog
        dialog.present(parent: parent, link: link, way: way)
    }

    let flow: FirstRunFlow
    let mode: FirstRunState.Mode
    let onSaved: @Sendable () -> Void
    var window: UnsafeMutablePointer<GtkWidget>?
    var rows: [FirstRunPlan.Row.ID: RowWidgets] = [:]
    var plan: FirstRunPlan?
    var closed = false
    var finishing = false
    var streamTask: Task<Void, Never>?
    var blocksShown: [FirstRunPlan.Row.ID: [FirstRunPlan.Block]] = [:]
    var tailscale: TailscaleReading?
    var tailnetKeys: Set<String> = []
    var discoveryRequested = false
    var watching = false
    var watchRounds = 0
    var syncing = false

    let intro = FirstRunDialog.wrapped("", css: "row-detail")
    let demoButton = gtk_button_new_with_label("")!
    let laterButton = gtk_button_new_with_label("")!
    let primaryButton = gtk_button_new_with_label("")!
    let backButton = gtk_button_new_with_label("")!
    let remedyOutput: UnsafeMutablePointer<GtkWidget> = {
        let label = FirstRunDialog.wrapped("", css: "row-detail")
        g_object_ref_sink(UnsafeMutableRawPointer(label))
        return label
    }()
    let permissionsStepArea = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    let permissionsStepTitle = Gtk.label("", css: "row-title", selectable: false)
    let permissionsDetailLabel = FirstRunDialog.wrapped("", css: "row-detail")
    let permissionsBox = MachinePermissionsBox(local: false)
    var permissionsBackend: (any PermissionReportingBackend)?
    var permissionsPollPending = false

    let waysBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    let pasteBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    let pasteEntry = gtk_entry_new()!
    let offerBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    let offerButton = gtk_button_new_with_label("")!
    let offerDetail = FirstRunDialog.wrapped("", css: "row-detail")
    var landing: FirstRunLanding?
    var fixed = false
    let pasteReading = FirstRunDialog.wrapped("", css: "row-detail")
    let pasteMessage = FirstRunDialog.wrapped("", css: "row-detail")
    let installBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    let linkBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    let statusBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    let passwordBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    let passwordNote = FirstRunDialog.wrapped("", css: "row-detail")
    let passwordEntry = gtk_password_entry_new()!
    let discoveryBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    var discovery: DiscoveryPanel?

    struct RowWidgets {
        let container: UnsafeMutablePointer<GtkWidget>
        let number: UnsafeMutablePointer<GtkWidget>
        let title: UnsafeMutablePointer<GtkWidget>
        let pill: UnsafeMutablePointer<GtkWidget>
        let detail: UnsafeMutablePointer<GtkWidget>
        let body: UnsafeMutablePointer<GtkWidget>
    }

    init(mode: FirstRunState.Mode, onSaved: @escaping @Sendable () -> Void) {
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

    static func wrapped(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: css, wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(label), 78)
        return label
    }

    func send(_ work: @escaping @Sendable (FirstRunFlow) async -> Void) {
        let flow = flow
        Task { await work(flow) }
    }

    func raise() {
        if let window { gtk_window_present(ptr(window)) }
    }

    func present(
        parent: UnsafeMutablePointer<GtkWidget>?, link: String?, way: FirstRunPlan.Way.Kind? = nil
    ) {
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
        if let link {
            send { await $0.paste(link) }
        } else if let way {
            chose(way)
        }
    }

    func build(parent: UnsafeMutablePointer<GtkWidget>?) {
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
            tearDown()
        }
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "is-active") { [self] in
            Gtk.onMain { [self] in readClipboard() }
        }
    }

    func tearDown() {
        closed = true
        streamTask?.cancel()
        if Self.current === self { Self.current = nil }
        if let landing { Self.onLanded(landing) }
    }

    func close() {
        guard !closed, let window else { return }
        Dialogs.close(window)
    }

    func enterDemo() {
        Task {
            await ServerDirectory.shared.enterDemoMode()
            Gtk.onMain { [self] in
                close()
                onSaved()
            }
        }
    }

    func laterPressed() {
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

    func primaryPressed() {
        guard let intent = plan?.primary?.intent else { return }
        switch intent {
        case .connect: send { await $0.connect() }
        case .openTailscale: performRemedy()
        case .signIn: presentSignIn()
        }
    }

    var slotContents: [UInt: [FirstRunPlan.Block]] = [:]
}
