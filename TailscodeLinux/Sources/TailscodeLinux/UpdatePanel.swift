import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Every machine in the picture and what it is running: this app, and each server it talks to.
///
/// One expander per machine, each carrying the one line that leads it, the honest sentence under
/// that line, both version numbers with who said them, what an update would bring in, and the single
/// press that machine has earned — which says before it is pressed whether this app can actually
/// finish the job. Nothing here invents a verdict: every word comes off the ``UpdateReading`` Core
/// built, so this screen and the server screen cannot disagree.
///
/// Not modal, deliberately. An update takes minutes on somebody else's machine and the person is
/// not meant to sit and watch it — the window is a place to come back to, and the chat list stays
/// live behind it. A window presented from a local variable is a window whose buttons do nothing,
/// so this one holds itself for exactly as long as its window is open, like ``ServerManager``.
final class UpdatePanel: @unchecked Sendable {
    private var token: UInt = 0
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var machines: UnsafeMutablePointer<GtkWidget>?
    private var everythingRow: UnsafeMutablePointer<GtkWidget>?
    private var everythingActions: UnsafeMutablePointer<GtkWidget>?
    private var listed: [UnsafeMutablePointer<GtkWidget>] = []
    private var rows: [String: UpdateRow] = [:]
    private var profiles: [ConnectionProfile] = []
    private var watching: UInt = 0
    /// The machine whose expander was open when the list was last rebuilt. A reading that arrives
    /// while somebody is reading a row must not collapse it back to the top.
    private var expandAfterReload: String?

    func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Software"))
        gtk_window_set_default_size(ptr(window), 620, 720)
        gtk_window_set_modal(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        self.window = window

        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))
        machines = makeMachinesGroup(on: page)
        makeActionsGroup(on: page)

        token = Self.hold(self)
        let token = self.token
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { Self.release(token) }
        observeLedger()

        reload()
        loadProfiles()
        gtk_window_present(ptr(window))
    }

    private func makeMachinesGroup(on page: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Machines"))
        adw_preferences_page_add(ptr(page), ptr(group))
        return group
    }

    private func makeActionsGroup(on page: UnsafeMutablePointer<GtkWidget>) {
        let group = adw_preferences_group_new()!
        adw_preferences_page_add(ptr(page), ptr(group))

        let (everything, everythingActions) = Self.factRow(title: Localized.text("Everything"))
        self.everythingRow = everything
        self.everythingActions = everythingActions
        gtk_widget_set_visible(everything, 0)
        adw_preferences_group_add(ptr(group), ptr(everything))

        let (recheck, recheckActions) = Self.factRow(title: Localized.text("Check again"))
        adw_action_row_set_subtitle(
            ptr(recheck),
            Localized.text(
                "Asks every machine what it is running and what it could run. It costs each server a "
                    + "fetch, so it happens on its own every few hours rather than every time this "
                    + "window opens."))
        Gtk.removeChildren(of: recheckActions)
        gtk_box_append(
            ptr(recheckActions),
            Self.inlineButton(Localized.text("Check again")) { [weak self] in
                UpdateWatch.refresh()
                self?.toast(Localized.text("Asking every machine…"))
            })
        gtk_widget_set_visible(recheckActions, 1)
        adw_preferences_group_add(ptr(group), ptr(recheck))
    }

    /// Every answer that lands rewrites this screen, and rewrites it in place: rows are rebuilt only
    /// when the *set* of machines changes, because a rebuild under somebody's hand closes the row
    /// they opened and moves the button they were reaching for.
    private func observeLedger() {
        guard watching == 0 else { return }
        watching = 1
        NotificationCenter.default.addObserver(
            forName: UpdateLedger.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.apply() }
        }
    }

    private func apply() {
        guard window != nil else { return }
        let rollup = UpdateLedger.rollup()
        guard Set(rollup.readings.map(\.id)) == Set(rows.keys) else {
            reload()
            return
        }
        for reading in rollup.readings {
            rows[reading.id]?.write(
                reading, acknowledged: rollup.isAcknowledged(reading), panel: self)
        }
        renderEverything(rollup)
    }

    private func reload() {
        guard let group = machines else { return }
        let expanding = expandAfterReload
        expandAfterReload = nil
        for row in listed { adw_preferences_group_remove(ptr(group), ptr(row)) }
        listed = []
        rows = [:]

        let rollup = UpdateLedger.rollup()
        guard !rollup.readings.isEmpty else {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_preferences_row_set_title(ptr(row), Localized.text("Nothing has been asked yet"))
            adw_action_row_set_subtitle(
                ptr(row),
                Localized.text("The first check runs on its own — or press Check again."))
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            adw_preferences_group_add(ptr(group), ptr(row))
            listed.append(row)
            renderEverything(rollup)
            return
        }
        for reading in rollup.readings {
            let holder = UpdateRow(reading: reading)
            rows[reading.id] = holder
            holder.write(reading, acknowledged: rollup.isAcknowledged(reading), panel: self)
            if reading.id == expanding { adw_expander_row_set_expanded(ptr(holder.row), 1) }
            adw_preferences_group_add(ptr(group), ptr(holder.row))
            listed.append(holder.row)
        }
        renderEverything(rollup)
    }

    /// One press for the servers this app can drive, walked one at a time — a bridge serialises its
    /// own fetch, and two updates started together queue behind each other anyway while both
    /// surfaces claim to be working. This app is never in the walk: on a desktop it would replace
    /// the process doing the watching.
    private func renderEverything(_ rollup: UpdateRollup) {
        guard let row = everythingRow, let actions = everythingActions else { return }
        guard rollup.canUpdateEverything else {
            gtk_widget_set_visible(row, 0)
            return
        }
        let order = rollup.installableServers
        adw_action_row_set_subtitle(
            ptr(row),
            Localized.text(
                "%@ servers can install their own update: %@. They are taken one at a time.",
                String(order.count), order.map(\.title).joined(separator: ", ")))
        Gtk.removeChildren(of: actions)
        let components = order.map(\.component)
        gtk_box_append(
            ptr(actions),
            Self.inlineButton(Localized.text("Update everything"), css: ["suggested-action"]) {
                [weak self] in
                self?.updateEverything(components)
            })
        gtk_widget_set_visible(actions, 1)
        gtk_widget_set_visible(row, 1)
    }

    private func updateEverything(_ components: [UpdateComponent]) {
        toast(Localized.text("Updating %@ servers, one at a time…", String(components.count)))
        Task { [weak self] in
            for component in components {
                guard case .server(let profileID) = component else { continue }
                await self?.updateAndWait(profileID)
            }
        }
    }

    /// One server taken to its end before the next is asked. `updateServer` reports through a
    /// callback rather than returning, so the walk waits on the reading that settles it.
    private func updateAndWait(_ profileID: String) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate()
            UpdateWatch.updateServer(profile) { reading in
                guard !reading.verdict.isBusy, gate.close() else { return }
                continuation.resume()
            }
        }
    }

    /// A continuation may be resumed exactly once, and a settled reading can arrive twice — the
    /// server's own answer, then the fresh comparison that follows it.
    private final class Gate: @unchecked Sendable {
        private var open = true

        func close() -> Bool {
            guard open else { return false }
            open = false
            return true
        }
    }

    fileprivate func act(on reading: UpdateReading) {
        guard let invitation = reading.invitation else { return }
        switch invitation {
        case .installHere:
            install(reading)
        case .restartHere:
            restart(reading, promise: invitation.promise)
        case .openStore(let url), .openPage(let url):
            SignInDialog.openInBrowser(url)
            toast(Localized.text("Opened in your browser"))
        case .copyCommand(let command):
            Gtk.copyToClipboard(command)
            toast(Localized.text("Install command copied"))
        case .recheck:
            UpdateWatch.recheck(reading.component)
            toast(Localized.text("Asking %@…", reading.title))
        }
    }

    private func install(_ reading: UpdateReading) {
        expandAfterReload = reading.id
        switch reading.component {
        case .app:
            guard let refusal = UpdateWatch.beginSelfUpdate() else {
                toast(
                    Localized.text(
                        "Building. Nothing closes until it is ready to restart — a build that fails "
                            + "leaves you exactly here."))
                return
            }
            toast(refusal)
        case .server(let profileID):
            guard let profile = profiles.first(where: { $0.id == profileID }) else {
                toast(Localized.text("That server is not configured any more."))
                return
            }
            toast(Localized.text("%@ is fetching and building…", profile.name))
            UpdateWatch.updateServer(profile) { _ in }
        }
    }

    /// A build already on that machine, loaded. It goes down the same walk an update does — the
    /// bridge stops answering partway through and that is the supervisor doing its job, not a
    /// failure — and the press repeats the promise it was offered under, because what it costs
    /// depends on whether a turn is running at the moment it is taken.
    private func restart(_ reading: UpdateReading, promise: String?) {
        expandAfterReload = reading.id
        guard case .server(let profileID) = reading.component,
            let profile = profiles.first(where: { $0.id == profileID })
        else {
            toast(Localized.text("That server is not configured any more."))
            return
        }
        toast(promise ?? reading.headline)
        UpdateWatch.restartServer(profile) { _ in }
    }

    fileprivate func setAside(_ reading: UpdateReading) {
        UpdateLedger.acknowledge(reading)
        rows[reading.id].map { adw_expander_row_set_expanded(ptr($0.row), 0) }
        toast(
            Localized.text(
                "Set aside. It comes back the moment there is something different to act on."))
    }

    /// A machine the ledger has never heard of is asked once, here, because somebody opened this
    /// screen — a configured server with no row at all would otherwise read as a machine that does
    /// not exist rather than one nobody has got round to asking.
    private func loadProfiles() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
                .filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
            Gtk.onMain { [weak self] in self?.profiles = profiles }
            for profile in profiles
            where UpdateLedger.remembered(.server(profileID: profile.id)) == nil {
                await UpdateWatch.ask(profile, checkingRemote: true)
            }
        }
    }

    private func toast(_ text: String) {
        guard let window, let toast = adw_toast_new(text) else { return }
        adw_preferences_window_add_toast(ptr(window), toast)
    }

    fileprivate enum Tone {
        case good, warn, bad, quiet

        var css: String? {
            switch self {
            case .good: return "fact-good"
            case .warn: return "fact-warn"
            case .bad: return "fact-bad"
            case .quiet: return nil
            }
        }

        /// The four meanings the rest of the app answers to, resolved into this screen's own tones.
        /// A reading that is merely unknown is quiet on purpose: doubt is not an alarm.
        static func of(_ reading: UpdateReading) -> Tone {
            switch reading.verdict {
            case .behind(let offer): return offer.canInstallHere ? .warn : .quiet
            case .failed: return .bad
            case .current: return .good
            case .ahead, .working, .blocked, .unverified: return .quiet
            }
        }
    }

    fileprivate static let factTones = ["fact-good", "fact-warn", "fact-bad"]
    fileprivate static let glyphTones = ActivityTone.allCases.map(\.glyphCSS)

    fileprivate static func setFact(
        _ row: UnsafeMutablePointer<GtkWidget>?, _ actionBox: UnsafeMutablePointer<GtkWidget>?,
        _ text: String, tone: Tone, actions: [UnsafeMutablePointer<GtkWidget>],
        title: String? = nil
    ) {
        guard let row else { return }
        if let title { adw_preferences_row_set_title(ptr(row), title) }
        adw_action_row_set_subtitle(ptr(row), text)
        Gtk.setTone(row, tone.css, from: factTones)
        guard let actionBox else { return }
        Gtk.removeChildren(of: actionBox)
        for action in actions { gtk_box_append(ptr(actionBox), action) }
        gtk_widget_set_visible(actionBox, actions.isEmpty ? 0 : 1)
    }

    /// A row that states one fact about a machine and carries whatever buttons that fact earns. The
    /// subtitle is where the sentence goes — it wraps to as many lines as it needs, because these
    /// sentences are paragraphs and truncating one puts the surface back to a bare number.
    fileprivate static func factRow(title: String)
        -> (UnsafeMutablePointer<GtkWidget>, UnsafeMutablePointer<GtkWidget>)
    {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        adw_action_row_set_subtitle_selectable(ptr(row), 1)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(actions, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(actions, 0)
        adw_action_row_add_suffix(ptr(row), actions)
        return (row, actions)
    }

    fileprivate static func inlineButton(
        _ title: String, css: [String] = ["flat"], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }

    private final class Registry: @unchecked Sendable {
        var panels: [UInt: UpdatePanel] = [:]
        var next: UInt = 1
    }

    private static let registry = Registry()

    private static func hold(_ panel: UpdatePanel) -> UInt {
        let token = registry.next
        registry.next += 1
        registry.panels[token] = panel
        return token
    }

    private static func release(_ token: UInt) {
        registry.panels[token]?.forgetWidgets()
        registry.panels[token] = nil
    }

    /// Every pointer here belongs to a window GTK has destroyed. The panel itself outlives it — the
    /// app holds one so a second ask raises rather than rebuilds — and an update still in flight will
    /// come back to write into a row. Nothing may be touched again, and a reopened window builds a
    /// fresh set rather than taking back the group it used to remove rows from.
    private func forgetWidgets() {
        window = nil
        machines = nil
        everythingRow = nil
        everythingActions = nil
        listed = []
        rows = [:]
        expandAfterReload = nil
    }
}

/// The widgets one machine's expander owns, so an answer that lands a minute later writes into
/// exactly its own row rather than rebuilding the list under whoever is reading it.
private final class UpdateRow {
    let row: UnsafeMutablePointer<GtkWidget>
    private let glyph: UnsafeMutablePointer<GtkWidget>
    private let state: UnsafeMutablePointer<GtkWidget>
    private let stateActions: UnsafeMutablePointer<GtkWidget>
    private let installed: UnsafeMutablePointer<GtkWidget>
    private let available: UnsafeMutablePointer<GtkWidget>
    private let changes: UnsafeMutablePointer<GtkWidget>
    private let obstacle: UnsafeMutablePointer<GtkWidget>

    init(reading: UpdateReading) {
        row = adw_expander_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), reading.title)
        if let subtitle = reading.subtitle {
            adw_expander_row_set_subtitle(ptr(row), subtitle)
        }

        glyph = Gtk.label(reading.icon.glyph, css: reading.icon.glyphCSS, selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        adw_expander_row_add_prefix(ptr(row), glyph)

        (state, stateActions) = UpdatePanel.factRow(title: reading.headline)
        adw_expander_row_add_row(ptr(row), state)

        installed = UpdatePanel.factRow(title: Localized.text("Running")).0
        adw_expander_row_add_row(ptr(row), installed)

        available = UpdatePanel.factRow(title: Localized.text("Available")).0
        adw_expander_row_add_row(ptr(row), available)

        changes = UpdatePanel.factRow(title: Localized.text("What it would bring")).0
        adw_expander_row_add_row(ptr(row), changes)

        obstacle = UpdatePanel.factRow(title: Localized.text("What is in the way")).0
        adw_expander_row_add_row(ptr(row), obstacle)
    }

    /// One reading painted into the row it belongs to. The expander's own subtitle carries the
    /// headline as well as the machine's address, so a collapsed row still says what is true about
    /// it — the whole point of a standing fact is that it does not need opening.
    func write(_ reading: UpdateReading, acknowledged: Bool, panel: UpdatePanel) {
        adw_preferences_row_set_title(ptr(row), reading.title)
        adw_expander_row_set_subtitle(
            ptr(row),
            reading.subtitle.map { "\(reading.headline) · \($0)" } ?? reading.headline)
        gtk_label_set_text(op(glyph), reading.icon.glyph)
        Gtk.setTone(glyph, reading.icon.glyphCSS, from: UpdatePanel.glyphTones)
        ActivityPulse.apply(reading.icon, to: glyph)

        UpdatePanel.setFact(
            state, stateActions, reading.detail(), tone: UpdatePanel.Tone.of(reading),
            actions: buttons(for: reading, acknowledged: acknowledged, panel: panel),
            title: reading.headline)

        UpdatePanel.setFact(
            installed, nil, reading.installed.line, tone: .quiet, actions: [],
            title: Localized.text("Running"))
        gtk_widget_set_visible(installed, reading.installed.isKnown ? 1 : 0)

        UpdatePanel.setFact(
            available, nil, reading.available.line, tone: .quiet, actions: [],
            title: Localized.text("Available"))
        gtk_widget_set_visible(available, reading.available.isKnown ? 1 : 0)

        let subjects = reading.verdict.offer?.changes ?? []
        UpdatePanel.setFact(
            changes, nil, subjects.prefix(8).map { "· \($0)" }.joined(separator: "\n"),
            tone: .quiet, actions: [], title: Localized.text("What it would bring"))
        gtk_widget_set_visible(changes, subjects.isEmpty ? 0 : 1)

        let named = reading.verdict.offer?.detailLines ?? []
        UpdatePanel.setFact(
            obstacle, nil, named.prefix(8).map { "· \($0)" }.joined(separator: "\n"),
            tone: .quiet, actions: [], title: Localized.text("What is in the way"))
        gtk_widget_set_visible(obstacle, named.isEmpty ? 0 : 1)
    }

    /// The one press, and what it promises. A promise is printed as its own button-height sentence
    /// beside the button rather than after it: an offer that ends in another app's hands has to say
    /// so before it is taken, not once it is too late to choose differently.
    ///
    /// "Not now" is offered on exactly the rows that are holding the mark up, which is Core's
    /// judgement rather than this screen's — a failure a person has read and decided to live with
    /// is as much a standing mark as an offer they are not taking, and one they could not set aside
    /// would keep the sidebar lit over a build that is never coming back.
    private func buttons(for reading: UpdateReading, acknowledged: Bool, panel: UpdatePanel)
        -> [UnsafeMutablePointer<GtkWidget>]
    {
        var made: [UnsafeMutablePointer<GtkWidget>] = []
        if let invitation = reading.invitation {
            if let promise = invitation.promise {
                let note = Gtk.label(promise, css: "row-detail", wrap: true, selectable: false)
                gtk_label_set_max_width_chars(op(note), 34)
                gtk_widget_set_valign(note, GTK_ALIGN_CENTER)
                made.append(note)
            }
            let suggested = invitation.isOneClickInstall ? ["suggested-action"] : ["flat"]
            made.append(
                UpdatePanel.inlineButton(invitation.label, css: suggested) { [weak panel] in
                    Gtk.onMain { [weak panel] in panel?.act(on: reading) }
                })
        }
        guard reading.stands(acknowledged: acknowledged) else { return made }
        made.append(
            UpdatePanel.inlineButton(Localized.text("Not now")) { [weak panel] in
                Gtk.onMain { [weak panel] in panel?.setAside(reading) }
            })
        return made
    }
}
