import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// Pointing at the renderer, held to the standard adding a server is held to.
///
/// The renderer used to be one free-text field in a prompt dialog: typed blind, saved unchecked,
/// forgotten on the next reinstall. A server on this desk is none of those things — it states what
/// this machine's own tailnet address is, sweeps the tailnet rather than demanding a hostname,
/// probes what it is given before saving it, explains a failure in a sentence that names the fix,
/// and remembers what worked. This is that flow for the machine with the card, and every word and
/// every rule in it is `ForgeSetup`'s: the window owns a text field, three lists, a dial and some
/// buttons, and decides nothing.
///
/// A window presented from a local variable is a window whose buttons do nothing — GTK owns the
/// widgets and nothing owns the Swift object behind them — so this one holds itself for exactly as
/// long as its window is open and lets go on `close-request`.
final class ForgeSetupWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ForgeSetupWindow?

    /// The window, raised rather than made twice — and handed the caller that asked for it. A modal
    /// this one is opened from can be closed and opened again while it stands, and the caller that
    /// arrives with the second press is the live one: keeping the first would tell a surface that
    /// no longer exists which renderer somebody chose, and tell nobody else at all.
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        if let open {
            open.onSaved = onSaved
            gtk_window_present(ptr(open.window))
            return
        }
        open = ForgeSetupWindow(parent: parent, onSaved: onSaved)
    }

    private var onSaved: @Sendable () -> Void
    private let window: UnsafeMutablePointer<GtkWidget>
    private var setup: ForgeSetup
    private var sweep = ForgeSweepReading()

    private let introGroup = adw_preferences_group_new()!
    private let knownGroup = adw_preferences_group_new()!
    private let sweepGroup = adw_preferences_group_new()!
    private let addGroup = adw_preferences_group_new()!
    private let radar = RadarView()
    /// The dial's own row, shown only while a scan is out or has answered. A dial nobody has spun
    /// is dead space above the form, and the rest state already says what spinning it would do.
    private var radarRow: UnsafeMutablePointer<GtkWidget>?
    private let addressEntry = gtk_entry_new()!
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let nameRow = adw_entry_row_new()!
    private let statusRow = adw_action_row_new()!
    private let statusActions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let sweepRow = adw_action_row_new()!
    private let sweepActions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let buttonRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let secondaryNote: UnsafeMutablePointer<GtkWidget>
    private var knownRows: [UnsafeMutablePointer<GtkWidget>] = []
    private var candidateRows: [UnsafeMutablePointer<GtkWidget>] = []

    /// Every machine the tailnet last reported, kept from the reading so a second scan does not
    /// shell out to `tailscale` again for a list that has not changed under it.
    private var devices: [TailscaleDevice] = []
    /// The sweep in flight, held so it can be stopped. It is a fan-out of probes against every
    /// machine on the tailnet, and a window nobody is looking at any more has no business holding
    /// them open to Core's deadline — or leaving the next window to scan on top of them.
    private var sweepTask: Task<Void, Never>?
    private var scanID = 0
    private var checking = false
    private var typing = false

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        self.onSaved = onSaved
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            deviceName: Localized.text("This machine"))
        hintLabel = Gtk.label("", css: "dim", wrap: true, selectable: false)
        secondaryNote = Gtk.label("", css: "row-detail", wrap: true, selectable: false)

        window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), ForgeSetup.title)
        gtk_window_set_default_size(ptr(window), 620, 760)
        gtk_window_set_modal(ptr(window), 1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))
        adw_preferences_page_add(ptr(page), ptr(introGroup))
        adw_preferences_page_add(ptr(page), ptr(sweepGroup))
        adw_preferences_page_add(ptr(page), ptr(knownGroup))
        adw_preferences_page_add(ptr(page), ptr(addGroup))

        buildKnownGroup()
        buildSweepGroup()
        buildAddGroup()

        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { [weak self] in
            self?.dismissed()
        }
        readTailnet()
        render()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(addressEntry)
    }

    private func buildKnownGroup() {
        adw_preferences_group_set_title(ptr(knownGroup), ForgeSetup.knownTitle)
    }

    /// The dial, its status line, and whatever answered — the same three parts, in the same order,
    /// that finding a server has, because it is the same question asked of the same tailnet.
    private func buildSweepGroup() {
        adw_preferences_group_set_title(ptr(sweepGroup), setup.discovery.title)
        let dial = radar.preferencesRow()
        radarRow = dial
        adw_preferences_group_add(ptr(sweepGroup), ptr(dial))
        adw_preferences_row_set_use_markup(ptr(sweepRow), 0)
        adw_action_row_set_subtitle_lines(ptr(sweepRow), 0)
        gtk_widget_set_valign(sweepActions, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(sweepRow), sweepActions)
        adw_preferences_group_add(ptr(sweepGroup), ptr(sweepRow))
    }

    private func buildAddGroup() {
        adw_preferences_group_set_title(ptr(addGroup), ForgeSetup.addressLabel)
        adw_preferences_group_set_description(ptr(addGroup), ForgeSetup.addressHelp)

        gtk_entry_set_placeholder_text(ptr(addressEntry), ForgeSetup.addressPlaceholder)
        gtk_widget_set_tooltip_text(addressEntry, ForgeSetup.addressHelp)
        gtk_widget_set_hexpand(addressEntry, 1)
        Gtk.connect(UnsafeMutableRawPointer(addressEntry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.typed() }
        }
        Gtk.connect(UnsafeMutableRawPointer(addressEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressPrimary() }
        }
        adw_preferences_group_add(ptr(addGroup), ptr(addressRow()))

        adw_preferences_row_set_use_markup(ptr(nameRow), 0)
        adw_preferences_row_set_title(ptr(nameRow), ForgeSetup.nameLabel)
        Gtk.connect(UnsafeMutableRawPointer(nameRow), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.renamed() }
        }
        adw_preferences_group_add(ptr(addGroup), ptr(nameRow))

        adw_preferences_row_set_use_markup(ptr(statusRow), 0)
        adw_action_row_set_subtitle_lines(ptr(statusRow), 0)
        adw_action_row_set_subtitle_selectable(ptr(statusRow), 1)
        gtk_widget_set_valign(statusActions, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(statusRow), statusActions)
        adw_preferences_group_add(ptr(addGroup), ptr(statusRow))

        gtk_widget_set_halign(buttonRow, GTK_ALIGN_END)
        Gtk.margins(buttonRow, top: 6)
        gtk_label_set_max_width_chars(op(secondaryNote), 64)
        Gtk.margins(secondaryNote, top: 6)
        adw_preferences_group_add(ptr(addGroup), ptr(secondaryNote))
        adw_preferences_group_add(ptr(addGroup), ptr(buttonRow))
    }

    /// The address, its label and the line that says what the typed text will actually be used as.
    /// A plain entry rather than an `AdwEntryRow`, because the row's floating title has nowhere to
    /// put a placeholder — and the placeholder is the whole of the answer to "what do I type here".
    private func addressRow() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.margins(column, top: 10, bottom: 10, leading: 12, trailing: 12)
        gtk_box_append(
            ptr(column), Gtk.label(ForgeSetup.addressLabel, css: "row-title", selectable: false))
        gtk_box_append(ptr(column), addressEntry)
        gtk_label_set_max_width_chars(op(hintLabel), 64)
        gtk_box_append(ptr(column), hintLabel)
        let row = adw_preferences_row_new()!
        gtk_list_box_row_set_child(ptr(row), column)
        gtk_list_box_row_set_activatable(ptr(row), 0)
        gtk_list_box_row_set_selectable(ptr(row), 0)
        return row
    }

    /// The first look, taken as the window opens so the surface leads with a fact rather than a
    /// blank. Every look after this one belongs to a press — see `scan`.
    private func readTailnet() {
        Task { [weak self] in
            let reading = Self.readings()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.took(reading)
                self.render()
            }
        }
    }

    /// What this machine is on the tailnet, and every machine it can see. Both come out of one
    /// reading: the sentence the surface leads with, and the peer list a sweep would ask. Blocking
    /// work, so it is never taken on the loop that has to keep the dial turning.
    private static func readings() -> (tailnet: TailscaleReading, devices: [TailscaleDevice]) {
        let status = TailnetStatusLinux.read()
        return (status.reading, status.scannableDevices(includingThisMachine: true))
    }

    /// A reading taken into the window: the line about this machine, the machines a sweep would
    /// ask, and whichever fact stops a sweep before it starts. A tailnet that has since come up
    /// clears the refusal the dial was wearing, because a refusal left standing over a fact that
    /// stopped being true is the whole of the bug this exists to close.
    private func took(_ reading: (tailnet: TailscaleReading, devices: [TailscaleDevice])) {
        devices = reading.devices
        setup.tailnet = reading.tailnet
        sweep =
            reading.tailnet.isUp
            ? ForgeSweepReading() : ForgeSweepReading(blocked: reading.tailnet)
    }

    /// The window is going away. Everything it started goes with it, and the static lets go of it
    /// now rather than on an idle — for the length of that gap `present` would raise a window that
    /// is already closing and hand it a caller nothing would ever tell.
    private func dismissed() {
        scanID += 1
        sweepTask?.cancel()
        sweepTask = nil
        if ForgeSetupWindow.open === self { ForgeSetupWindow.open = nil }
    }

    private func typed() {
        guard !typing else { return }
        setup.type(Dialogs.entryText(addressEntry))
        render()
    }

    private func renamed() {
        guard !typing else { return }
        setup.rename(Dialogs.entryText(nameRow))
        render()
    }

    private func pressPrimary() {
        perform(setup.primary)
    }

    private func perform(_ button: ForgeSetupButton) {
        guard button.isEnabled else { return }
        perform(button.action)
    }

    /// Every button on this window hands back one of these, and the window runs it. Nothing here
    /// decides anything: which action a press carries is `ForgeSetup`'s answer, and so is the word
    /// on the button that carried it.
    private func perform(_ action: ForgeSetupAction) {
        switch action {
        case .nothing:
            return
        case .check(let endpoint):
            check(endpoint)
        case .save(let renderer):
            save(renderer)
        case .scan:
            scan()
        case .fix(let fix):
            apply(fix)
        }
    }

    private func check(_ endpoint: ForgeEndpoint) {
        guard !checking else { return }
        checking = true
        setup.checking()
        render()
        Task { [weak self] in
            let verdict = await endpoint.reach()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.checking = false
                self.setup.reached(verdict)
                self.render()
            }
        }
    }

    /// The one write this window makes. `ForgeStore` files the machine among the ones this device
    /// has used and points renders at it in the same breath, so nothing else here has to know what
    /// "remembered" means.
    private func save(_ renderer: ForgeRenderer) {
        ForgeStore.remember(renderer)
        SettingsFile.capture()
        onSaved()
        gtk_window_close(ptr(window))
    }

    private func apply(_ fix: ConnectDiagnosis.Fix) {
        switch fix {
        case .copyCommand(let command):
            Gtk.copyToClipboard(command)
            toast(Localized.text("Copied — run it in a terminal."))
        case .openTailscale:
            guard let tailnet = setup.tailnet else { return }
            offer(tailnet.remedy)
        case .retry:
            guard let endpoint = setup.endpoint else { return }
            check(endpoint)
        case .none, .openAppSettings, .retryOtherPort, .usePlainHTTP, .revealPassword, .seePro:
            return
        }
    }

    /// The tailnet, re-read and then asked which machine answers on the forge's port.
    ///
    /// The reading is taken again on every press. Whether this machine is on a tailnet at all is a
    /// live fact — somebody signs in, starts the daemon, comes back — so a surface whose whole
    /// remedy is "go fix that, then scan" has to be able to see that it worked. Read once when the
    /// window opened, it would refuse forever for a state that stopped being true, sweep a peer
    /// list assembled before the tunnel came up, and go on blaming a later timeout on a tailnet
    /// this machine has since joined.
    private func scan() {
        guard sweepTask == nil, !sweep.isScanning else { return }
        scanID += 1
        let id = scanID
        sweepTask = Task { [weak self] in
            let reading = Self.readings()
            guard !Task.isCancelled else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                self.took(reading)
                self.render()
                guard reading.tailnet.isUp else {
                    self.sweepTask = nil
                    self.offer(reading.tailnet.remedy)
                    return
                }
                self.sweepTailnet(id)
            }
        }
    }

    /// Every machine on the tailnet, asked at once. Raced against Core's own deadline, because a
    /// peer that has gone to sleep holds its port open and says nothing — the sweep reports what it
    /// did find rather than spinning until the window closes.
    private func sweepTailnet(_ id: Int) {
        let targets = ForgeSweep.targets(devices)
        sweep.began(targets, at: RadarView.now)
        radar.scanning = true
        render()
        radar.startClock()

        let progressed: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                self.sweep.advanced(checked: done, total: total)
                self.render()
            }
        }
        let sighted: @Sendable (ForgeCandidate) -> Void = { [weak self] candidate in
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                self.sweep.found(candidate, at: RadarView.now)
                self.render()
            }
        }
        sweepTask = Task { [weak self] in
            _ = await Self.within(ForgeSweep.deadline) {
                await ForgeSweep.run(
                    targets: targets, onProgress: progressed, onFound: sighted)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.scanID == id else { return }
                self.sweepTask = nil
                self.sweep.finished()
                self.radar.scanning = false
                self.render()
                self.radar.draw()
            }
        }
    }

    /// A scan that never comes back is a spinner with extra steps, so the whole sweep is given
    /// Core's deadline and reports what it has.
    private static func within<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A machine already used, or one a scan just found, taken into the form. A found machine has
    /// already answered the question the button asks, so `adopt` leaves it checked; one out of the
    /// list has not been asked since whenever it was last used, so it is put in the field and
    /// checked again rather than trusted.
    private func adopt(_ candidate: ForgeCandidate) {
        setup.adopt(candidate)
        writeForm()
        render()
    }

    private func recall(_ renderer: ForgeRenderer) {
        setup.type(renderer.endpoint.displayHost)
        setup.rename(renderer.name ?? "")
        writeForm()
        render()
        if let endpoint = setup.endpoint { check(endpoint) }
    }

    /// Puts the boxes back in step with the form after something else filled it in. The writes are
    /// not edits, so they must not be read back as ones.
    private func writeForm() {
        typing = true
        gtk_editable_set_text(op(addressEntry), setup.typed)
        gtk_editable_set_text(op(nameRow), setup.name)
        typing = false
    }

    private func render() {
        renderIntro()
        renderSweep()
        renderKnown()
        renderAdd()
    }

    /// Two facts, in the order they matter: what a renderer is, and whether this machine is on the
    /// tailnet at all — because a probe from a machine that is not fails identically however right
    /// the address is. Both sentences are Core's; only the line between them is this window's.
    private func renderIntro() {
        let line = setup.tailnetLine
        adw_preferences_group_set_description(
            ptr(introGroup),
            line.isEmpty ? ForgeSetup.detail : "\(ForgeSetup.detail)\n\(line)")
    }

    private func renderKnown() {
        for row in knownRows { adw_preferences_group_remove(ptr(knownGroup), ptr(row)) }
        knownRows = []
        adw_preferences_group_set_description(
            ptr(knownGroup), setup.known.isEmpty ? ForgeSetup.knownEmpty : "")
        for renderer in setup.known {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_preferences_row_set_title(ptr(row), renderer.title)
            adw_action_row_set_subtitle(ptr(row), renderer.detail)
            gtk_list_box_row_set_activatable(ptr(row), 1)
            if let badge = ForgeRenderer.badge(current: setup.isCurrent(renderer)) {
                let pill = Gtk.label(badge, css: "pill", selectable: false)
                Gtk.addClass(pill, "pill-live")
                gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(row), pill)
            }
            let forget = Self.button("✕") { [weak self] in
                Gtk.onMain { [weak self] in self?.confirmForget(renderer) }
            }
            gtk_widget_set_tooltip_text(forget, ForgeSetup.forgetTitle)
            adw_action_row_add_suffix(ptr(row), forget)
            Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
                Gtk.onMain { [weak self] in self?.recall(renderer) }
            }
            adw_preferences_group_add(ptr(knownGroup), ptr(row))
            knownRows.append(row)
        }
    }

    /// Forgetting the machine in force stops every screen in the app being able to render, and the
    /// press is a small unlabelled glyph beside the one that recalls it — so it is asked before it
    /// is done, the way removing a server on this desk is. The words are Core's.
    private func confirmForget(_ renderer: ForgeRenderer) {
        Dialogs.confirm(
            title: ForgeSetup.forgetTitle, body: renderer.detail,
            confirmLabel: ForgeSetup.forgetTitle, parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.forget(renderer) }
        }
    }

    private func forget(_ renderer: ForgeRenderer) {
        ForgeStore.forgetRenderer(renderer.id)
        SettingsFile.capture()
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            tailnet: setup.tailnet, deviceName: Localized.text("This machine"))
        writeForm()
        onSaved()
        render()
    }

    private func renderSweep() {
        for row in candidateRows { adw_preferences_group_remove(ptr(sweepGroup), ptr(row)) }
        candidateRows = []
        radar.blips = sweep.blips
        if let radarRow {
            let spinning = sweep.isScanning || !sweep.blips.isEmpty
            gtk_widget_set_visible(radarRow, spinning ? 1 : 0)
        }
        if case .rest = sweep.stage {
            adw_preferences_row_set_title(ptr(sweepRow), sweep.detail)
            adw_action_row_set_subtitle(ptr(sweepRow), "")
        } else {
            adw_preferences_row_set_title(ptr(sweepRow), sweep.title)
            adw_action_row_set_subtitle(ptr(sweepRow), sweep.detail)
        }
        Gtk.setTone(sweepRow, Self.tone(sweep.tone), from: Self.tones)
        Gtk.removeChildren(of: sweepActions)
        if let title = sweep.actionTitle {
            gtk_box_append(
                ptr(sweepActions),
                Self.button(title) { [weak self] in
                    Gtk.onMain { [weak self] in self?.pressSweep() }
                })
        }
        gtk_widget_set_visible(sweepActions, sweep.actionTitle == nil ? 0 : 1)
        for candidate in sweep.found {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_preferences_row_set_title(ptr(row), candidate.title)
            adw_action_row_set_subtitle(ptr(row), candidate.detail)
            gtk_list_box_row_set_activatable(ptr(row), 1)
            let glyph = Gtk.label("●", css: "glyph-done", selectable: false)
            gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
            adw_action_row_add_prefix(ptr(row), glyph)
            let chevron = Gtk.label("›", css: "dim", selectable: false)
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), chevron)
            Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
                Gtk.onMain { [weak self] in self?.adopt(candidate) }
            }
            adw_preferences_group_add(ptr(sweepGroup), ptr(row))
            candidateRows.append(row)
        }
    }

    /// What the dial's own button does, which is always the scan — and the scan re-reads Tailscale
    /// before it sweeps, so one press is both "find out whether I can" and "do it". A machine with
    /// no tailnet is sent through the door its reading names instead of sweeping a tailnet it is
    /// not on, and the press that follows the fix finds that it worked.
    private func pressSweep() {
        scan()
    }

    /// The tailnet's own way out, which is a different act in each of the four states it can be in:
    /// a download page for a machine that never had Tailscale, a sign-in for one that is signed
    /// out, a service to start, a sandbox permission to grant. `TailscaleReading` exists precisely
    /// so that a client stops sending everybody to a terminal to run the one command that helps one
    /// of them, so the remedy it names is the one offered wherever this door is opened.
    private func offer(_ remedy: TailscaleReading.Remedy) {
        switch remedy {
        case .install(let url):
            SignInDialog.openInBrowser(url)
        case .signIn(let command), .start(let command), .grantHostAccess(let command):
            Gtk.copyToClipboard(command)
            toast(Localized.text("Copied — run it in a terminal."))
        case .none:
            return
        }
    }

    private func renderAdd() {
        let status = setup.status
        let hint = Self.hint(setup.hint, beside: status)
        gtk_label_set_text(op(hintLabel), hint ?? "")
        gtk_widget_set_visible(hintLabel, hint == nil ? 0 : 1)

        adw_preferences_row_set_title(ptr(statusRow), status.title)
        adw_action_row_set_subtitle(ptr(statusRow), status.detail)
        Gtk.setTone(statusRow, Self.tone(status.tone), from: Self.tones)
        gtk_widget_set_visible(statusRow, status.title.isEmpty ? 0 : 1)
        Gtk.removeChildren(of: statusActions)
        if let button = remedy(for: status) { gtk_box_append(ptr(statusActions), button) }
        gtk_widget_set_visible(statusActions, gtk_widget_get_first_child(statusActions) == nil ? 0 : 1)

        let note = setup.secondaryNote
        gtk_label_set_text(op(secondaryNote), note ?? "")
        gtk_widget_set_visible(secondaryNote, note == nil ? 0 : 1)

        Gtk.removeChildren(of: buttonRow)
        if let secondary = setup.secondary {
            gtk_box_append(
                ptr(buttonRow),
                Gtk.button(secondary.title) { [weak self] in
                    Gtk.onMain { [weak self] in self?.perform(secondary) }
                })
        }
        let primary = setup.primary
        let button = Gtk.button(primary.title, css: ["suggested-action", "pill"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.pressPrimary() }
        }
        gtk_widget_set_sensitive(button, primary.isEnabled ? 1 : 0)
        gtk_box_append(ptr(buttonRow), button)
    }

    /// The one press a failure offers, which is `ConnectDiagnosis`'s own — the sentence and the
    /// action are two halves of one value, so a status with no diagnosis has no button by
    /// construction rather than by a check here.
    ///
    /// The row does not repeat the dock. Where a failure's remedy is the press the button row at
    /// the foot already carries, the row states what is wrong and lets that button carry the act:
    /// `.timedOut` and `.nameNotResolved` both answer "Try again", which is the primary's own word,
    /// and the commonest failure on this window would otherwise print it twice forty pixels apart.
    private func remedy(for status: ForgeSetupReading) -> UnsafeMutablePointer<GtkWidget>? {
        guard let diagnosis = status.diagnosis,
            let title = Self.title(for: diagnosis, on: setup.tailnet),
            title != setup.primary.title
        else { return nil }
        return Self.button(title) { [weak self] in
            Gtk.onMain { [weak self] in self?.perform(.fix(diagnosis.fix)) }
        }
    }

    /// What the status row's button says. `ConnectDiagnosis` can only tell that this machine is
    /// not on a tailnet; `TailscaleReading` knows which of the four reasons it is, and each of them
    /// is a different door with a different word on it — so the reading names the button it is
    /// about to open, and a machine with no door left offers nothing to press rather than a button
    /// that does nothing.
    private static func title(for diagnosis: ConnectDiagnosis, on tailnet: TailscaleReading?)
        -> String?
    {
        guard case .openTailscale = diagnosis.fix else { return diagnosis.actionTitle }
        return tailnet?.actionTitle
    }

    /// The line under the field, unless the status row is already saying it. A refusal is both the
    /// hint and the whole of the status, and the same sentence printed twice reads as two problems.
    private static func hint(_ hint: String?, beside status: ForgeSetupReading) -> String? {
        guard let hint, hint != status.detail else { return nil }
        return hint
    }

    private func toast(_ text: String) {
        guard let toast = adw_toast_new(text) else { return }
        adw_preferences_window_add_toast(ptr(window), toast)
    }

    private static let tones = ["fact-good", "fact-warn", "fact-bad", "row-detail"]

    private static func tone(_ tone: ActivityTone) -> String? {
        switch tone {
        case .live: return "fact-good"
        case .attention: return "fact-warn"
        case .danger: return "fact-bad"
        case .quiet: return nil
        }
    }

    private static func button(
        _ title: String, css: [String] = ["flat"], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }
}
