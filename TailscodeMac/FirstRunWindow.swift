import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// First run as a window that only draws. `FirstRunFlow` (Core) owns the checklist, the probe, the
/// save and Claude's sign-in, and publishes a `FirstRunPlan` after each change; this window draws
/// that plan, tells the flow what the person did, and does the three things only a Mac can: read
/// its own tailnet, scan the tailnet for the machine being installed, and ask for the grants a
/// machine needs once it is saved.
///
/// It is also the door for a pairing link: with no server it is the first run with the link
/// already read, and with servers it asks whether to add the machine the link names. And it is the
/// one place a machine is added from: the Servers window and the empty window both open it, in the
/// addition mode when a machine is already there, so the link way, the install command and the
/// tailnet scan exist here and nowhere else.
@MainActor
final class FirstRunWindow: NSObject, NSWindowDelegate {
    struct Hooks {
        var saved: () -> Void
        var landed: (FirstRunLanding?) -> Void
        var seePro: () -> Void
        var openServer: (String) -> Void
    }

    static var hooks = Hooks(saved: {}, landed: { _ in }, seePro: {}, openServer: { _ in })
    private static var open: FirstRunWindow?

    static func presentIfNeeded() {
        ServerDirectory.shared.reload()
        guard realProfiles.isEmpty else { return }
        present(way: nil)
    }

    /// The checklist, for whoever asks for a machine to be added: the first run when no real
    /// server exists, the addition mode when one does, which has no Tailscale row to wrongly claim
    /// anything is missing. A window already open is raised, and moved to the way asked for.
    static func present(way: FirstRunPlan.Way.Kind?) {
        ServerDirectory.shared.reload()
        if let existing = open {
            existing.raise()
            if let way { existing.choose(way) }
            return
        }
        let mode: FirstRunState.Mode = realProfiles.isEmpty ? .firstRun : .addition
        let checklist = FirstRunWindow(mode: mode, fixture: nil, linked: false)
        open = checklist
        checklist.begin(pasting: nil, way: way)
    }

    /// One state of the checklist from `FirstRunFixtures`, drawn through the ordinary plan and
    /// left alone: no tailnet is read, no clipboard is looked at and nothing is probed, so a
    /// picture of "the machine refused" needs no machine.
    /// - Parameter ordersFront: false draws the plan into a window nobody sees, which is how the
    ///   selftest reads every state without a screen.
    @discardableResult
    static func presentFixture(named name: String, ordersFront: Bool = true) -> FirstRunWindow? {
        guard let state = FirstRunFixtures.state(named: name, platform: .mac) else { return nil }
        if ordersFront { open?.window.close() }
        let checklist = FirstRunWindow(mode: state.mode, fixture: state, linked: false)
        if ordersFront { open = checklist }
        checklist.show(fixture: state, ordersFront: ordersFront)
        return checklist
    }

    /// Another state in the same window: a picture of each state needs one window, not one each.
    /// A state of the other mode is a different checklist and is refused.
    @discardableResult
    func redraw(fixtureNamed name: String) -> Bool {
        guard fixture != nil, let state = FirstRunFixtures.state(named: name, platform: .mac),
            state.mode == mode
        else { return false }
        show(fixture: state, ordersFront: false)
        return true
    }

    var drawnTexts: [String] { Self.texts(in: window.contentView) }

    var windowTitle: String { window.title }

    /// The button Return presses, when there is one on screen, and whether it can be pressed.
    var returnButton: (title: String, isEnabled: Bool)? {
        guard !primaryButton.isHidden, primaryButton.keyEquivalent == "\r" else { return nil }
        return (primaryButton.title, primaryButton.isEnabled)
    }

    /// Every visible button Escape presses: exactly one, Later or Not now, whichever the step has.
    var escapeButtons: [String] {
        [notNowButton, laterButton].filter { !$0.isHidden && $0.keyEquivalent == Self.escape }
            .map(\.title)
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view, !view.isHidden else { return [] }
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            found.append(field.stringValue)
        }
        if let button = view as? NSButton, !button.title.isEmpty { found.append(button.title) }
        for child in view.subviews { found += texts(in: child) }
        return found
    }

    func closeFixture() {
        window.close()
    }

    /// The demo's two servers, taken from the checklist or from the empty window, with the window
    /// closed behind them.
    static func enterDemoMode() {
        ServerDirectory.shared.enterDemoMode()
        hooks.saved()
        open?.window.close()
    }

    /// A pairing link that arrived from outside: pasted into the window that is already open, or
    /// into a new one that is shown only if the link is not for a server this Mac already has.
    static func receive(link text: String) {
        ServerDirectory.shared.reload()
        if let existing = open {
            existing.raise()
            existing.paste(text)
            return
        }
        let window = FirstRunWindow(
            mode: realProfiles.isEmpty ? .firstRun : .addition, fixture: nil, linked: true)
        open = window
        window.begin(pasting: text, way: nil)
    }

    private static var realProfiles: [ConnectionProfile] {
        ServerDirectory.shared.profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
    }

    private static var offersTailnetScan: Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return true
        #endif
    }

    private static func environment() -> FirstRunEnvironment {
        FirstRunEnvironment(
            offersTailnetScan: offersTailnetScan,
            profiles: { await MainActor.run { realProfiles } },
            save: { profile, password in await MainActor.run { save(profile, password: password) } },
            log: { AppLogger.connection.info($0) })
    }

    private static func save(_ profile: ConnectionProfile, password: String?) -> FirstRunSave {
        do {
            try ServerDirectory.shared.save(profile, password: password)
            return .saved
        } catch is ServerDirectory.ProRequired {
            return .needsPro
        } catch {
            return .failed(AgentErrorText.readable(error))
        }
    }

    private let flow: FirstRunFlow
    private let environment: FirstRunEnvironment
    private let mode: FirstRunState.Mode
    private let fixture: FirstRunState?
    private let window: FloatingWindow
    private let column = FillingStack(topDown: true)
    private let intro = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private let remedy = TailnetRemedyView()
    private let demoButton = RowKit.ActionButton(title: "") {}
    private let notNowButton = RowKit.ActionButton(title: "") {}
    private let laterButton = RowKit.ActionButton(title: "") {}
    private let primaryButton = RowKit.ActionButton(title: "") {}
    private let busy = NSProgressIndicator()
    private var rows: [FirstRunPlan.Row.ID: FirstRunRow] = [:]
    private var primary: FirstRunPlan.Primary?
    private var latestTailscale: TailscaleReading?
    private var planTask: Task<Void, Never>?
    private var tailnetTask: Task<Void, Never>?
    private var installWatch: Task<Void, Never>?
    private var finishing = false
    private var completed = false
    private var isClosed = false

    private func makeIntents() -> FirstRunIntents {
        FirstRunIntents(
        choose: { [weak self] in self?.choose($0) },
        paste: { [weak self] in self?.paste($0) },
        useClipboard: { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.useClipboardLink() }
        },
        selectAgent: { [weak self] agent in
            guard let flow = self?.flow else { return }
            Task { await flow.selectAgent(agent) }
        },
        copied: { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.handedOver() }
        },
        setPassword: { [weak self] text in
            guard let flow = self?.flow else { return }
            Task { await flow.setPassword(text) }
        },
        confirmOffTailnet: { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.confirmOffTailnet() }
        },
        fix: { [weak self] in self?.fix($0) },
        back: { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.back() }
        })
    }

    private init(mode: FirstRunState.Mode, fixture: FirstRunState?, linked: Bool) {
        self.mode = mode
        self.fixture = fixture
        environment = Self.environment()
        flow = FirstRunFlow(platform: .mac, mode: mode, environment: environment)
        window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        build(linked: linked)
    }

    private func build(linked: Bool) {
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.addArrangedSubview(intro)
        column.addArrangedSubview(footer())

        window.title = Self.title(for: mode, linked: linked)
        window.minSize = NSSize(width: 620, height: 320)
        window.contentView = MacDialogs.scrollColumn(holding: column)
        window.delegate = self
    }

    private static func title(for mode: FirstRunState.Mode, linked: Bool) -> String {
        switch mode {
        case .firstRun: return Localized.text("Welcome")
        case .addition: return linked ? ConnectLinkReading.addQuestion : ConnectLinkReading.addMachine
        }
    }

    private func footer() -> NSView {
        busy.style = .spinning
        busy.controlSize = .small
        busy.isIndeterminate = true
        busy.isDisplayedWhenStopped = false
        busy.translatesAutoresizingMaskIntoConstraints = false
        demoButton.setAction { [weak self] in self?.enterDemo() }
        notNowButton.setAction { [weak self] in self?.window.close() }
        laterButton.setAction { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.skipSignIn() }
        }
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAction { [weak self] in self?.primaryPressed() }
        primaryButton.setAccessibilityIdentifier("firstrun.primary")
        let actions = NSStackView(views: [
            RowKit.spacer(), demoButton, notNowButton, laterButton, busy, primaryButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.translatesAutoresizingMaskIntoConstraints = false
        return actions
    }

    private func show(fixture state: FirstRunState, ordersFront: Bool) {
        latestTailscale = state.tailscale
        render(FirstRunPlan.make(state))
        if ordersFront { show() }
    }

    private func begin(pasting text: String?, way: FirstRunPlan.Way.Kind?) {
        let flow = self.flow
        planTask = Task { [weak self] in
            let plans = await flow.plans()
            for await plan in plans {
                guard let self, !Task.isCancelled else { return }
                self.render(plan)
            }
        }
        pollTailnet()
        Task { [weak self] in
            if let text {
                await flow.paste(text)
            } else if let way {
                await flow.choose(way)
            }
            let plan = await flow.plan
            guard let self, !self.isClosed, plan.outcome == nil else { return }
            self.show()
        }
    }

    private func show() {
        if !window.isVisible { window.center() }
        raise()
    }

    private func raise() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func paste(_ text: String) {
        let flow = self.flow
        Task { await flow.paste(text) }
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        planTask?.cancel()
        tailnetTask?.cancel()
        installWatch?.cancel()
        if Self.open === self { Self.open = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard fixture == nil else { return }
        let text = NSPasteboard.general.string(forType: .string)
        let flow = self.flow
        Task { await flow.clipboard(text) }
    }

    private func render(_ plan: FirstRunPlan) {
        guard !finishing, !completed, !isClosed else { return }
        if let outcome = plan.outcome {
            handle(outcome)
            return
        }
        intro.stringValue = plan.intro
        intro.isHidden = plan.mode == .addition
        for (index, row) in plan.rows.enumerated() {
            let drawn = rowView(row.id, at: index)
            drawn.update(
                row, back: row.id == .machine ? plan.back : nil,
                offer: row.id == .machine ? plan.offer : nil)
        }
        showFooter(plan)
        watchForInstall(plan)
        if plan.isFinished, fixture == nil { finish() }
    }

    private func rowView(_ id: FirstRunPlan.Row.ID, at index: Int) -> FirstRunRow {
        if let existing = rows[id] { return existing }
        let made = FirstRunRow(intents: makeIntents(), remedy: remedy)
        rows[id] = made
        column.insertArrangedSubview(made.view, at: 1 + index)
        return made
    }

    private func showFooter(_ plan: FirstRunPlan) {
        demoButton.isHidden = plan.demo == nil
        demoButton.title = plan.demo?.title ?? ""
        demoButton.toolTip = plan.demo?.detail
        demoButton.setAccessibilityHelp(plan.demo?.detail)
        notNowButton.isHidden = plan.later != nil
        notNowButton.title = plan.dismiss
        notNowButton.keyEquivalent = plan.later == nil ? Self.escape : ""
        laterButton.isHidden = plan.later == nil
        laterButton.title = plan.later ?? ""
        laterButton.keyEquivalent = plan.later == nil ? "" : Self.escape
        primary = plan.primary
        primaryButton.isHidden = plan.primary == nil
        primaryButton.title = plan.primary?.title ?? ""
        primaryButton.isEnabled = plan.primary?.isEnabled ?? false
        if plan.primary?.isLoading == true {
            busy.startAnimation(nil)
        } else {
            busy.stopAnimation(nil)
        }
    }

    private static let escape = "\u{1b}"

    private func primaryPressed() {
        guard let primary else { return }
        let flow = self.flow
        switch primary.intent {
        case .connect:
            window.makeFirstResponder(nil)
            Task { await flow.connect() }
        case .openTailscale:
            fix(.openTailscale)
        case .signIn:
            signIn()
        }
    }

    private func choose(_ kind: FirstRunPlan.Way.Kind) {
        switch kind {
        case .tailnet:
            findOnTailnet()
        case .scan:
            return
        case .link, .install:
            let flow = self.flow
            Task { await flow.choose(kind) }
        }
    }

    private func fix(_ fix: ConnectDiagnosis.Fix) {
        window.makeFirstResponder(nil)
        let flow = self.flow
        MacConnectFix(
            remedy: remedy, tailscale: { [weak self] in self?.latestTailscale },
            retry: { Task { await flow.retry() } },
            retarget: { url in Task { await flow.typeAddress(url.absoluteString) } },
            revealPassword: { Task { await flow.revealPassword() } },
            seePro: { Self.hooks.seePro() }
        ).perform(fix)
    }

    private func findOnTailnet() {
        #if !TAILSCODE_MAS
            let flow = self.flow
            DiscoveryPanel.present(on: window, configured: Self.realProfiles) { suggestion in
                Task { await flow.adopt(suggestion) }
            }
        #endif
    }

    /// While the person installs a machine, the tailnet is asked every few seconds and the first
    /// agent that was not there at the start is taken as the machine being installed.
    private func watchForInstall(_ plan: FirstRunPlan) {
        #if !TAILSCODE_MAS
            let installing = plan.row(.machine)?.blocks.contains {
                if case .command = $0 { return true }
                return false
            } ?? false
            guard installing else {
                installWatch?.cancel()
                installWatch = nil
                return
            }
            guard installWatch == nil else { return }
            let flow = self.flow
            installWatch = Task { [weak self] in
                var baseline: Set<String>?
                while !Task.isCancelled {
                    let found = await FirstRunMachineScan.once()
                    guard let self, !Task.isCancelled else { return }
                    if let known = baseline {
                        let saved = Self.realProfiles
                        let fresh = found.first {
                            !known.contains($0.dedupeKey)
                                && !ConfiguredServers.isConfigured(
                                    $0.baseURL, profiles: saved, devices: [])
                        }
                        if let fresh {
                            self.installWatch = nil
                            await flow.adopt(fresh)
                            return
                        }
                    } else {
                        baseline = Set(found.map(\.dedupeKey))
                    }
                    try? await Task.sleep(for: .seconds(6))
                }
            }
        #endif
    }

    /// This Mac's tailnet presence, re-proved every few seconds while the window is open, so
    /// someone starting Tailscale mid-setup watches the step turn green by itself. The CLI is
    /// asked off the main actor, because a step that polls must never be a step that stutters.
    private func pollTailnet() {
        guard fixture == nil else { return }
        let flow = self.flow
        tailnetTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = await Task.detached(priority: .utility) { TailnetStatusMac.read() }
                    .value
                guard let self, !Task.isCancelled else { return }
                self.latestTailscale = status.reading
                await flow.tailscale(status.reading)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func enterDemo() {
        completed = true
        Self.enterDemoMode()
    }

    private func handle(_ outcome: FirstRunState.Outcome) {
        guard !completed else { return }
        completed = true
        let flow = self.flow
        Task { await flow.acknowledgeOutcome() }
        window.close()
        switch outcome {
        case .openExisting(let id):
            Self.hooks.openServer(id)
        }
    }

    private func signIn() {
        let flow = self.flow
        Task { [weak self] in
            guard let saved = await flow.saved else { return }
            guard let self, !self.isClosed else { return }
            guard
                let backend = ServerDirectory.shared.backend(for: saved.profile)
                    as? any AuthenticatingBackend
            else {
                await flow.skipSignIn()
                return
            }
            SignInSheet.present(
                on: self.window, serverName: saved.profile.name, backend: backend
            ) { [weak self] in
                self?.signedIn(saved.profile, password: saved.password)
            }
        }
    }

    private func signedIn(_ profile: ConnectionProfile, password: String?) {
        let flow = self.flow
        let account = environment.account
        Task {
            let auth = await account(profile, password)
            await flow.signInFinished(account: auth?.accountLabel)
        }
    }

    private func finish() {
        guard !finishing, !completed else { return }
        finishing = true
        let flow = self.flow
        Task { [weak self] in
            let saved = await flow.saved
            guard let self, !self.isClosed else { return }
            guard let profile = saved?.profile else {
                self.complete()
                return
            }
            self.finishOrAskPermissions(profile: profile)
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        let flow = self.flow
        window.close()
        Task { Self.hooks.landed(await flow.landing) }
    }

    /// The machine just saved may be a Mac still missing a grant it needs to work anywhere in the
    /// person's files, so the checklist asks about that once, here, before first run calls itself
    /// finished. A server too old for the route, a non-Mac, or one that already has everything
    /// finishes exactly as it always did.
    private func finishOrAskPermissions(profile: ConnectionProfile) {
        guard
            let backend = ServerDirectory.shared.backend(for: profile)
                as? any PermissionReportingBackend
        else {
            complete()
            return
        }
        Task { [weak self] in
            let permissions = try? await backend.machinePermissions()
            guard let self, !self.isClosed else { return }
            guard MachinePermissionReading.needsAttention(permissions) else {
                self.complete()
                return
            }
            self.showPermissionsStep(backend: backend, permissions: permissions)
        }
    }

    /// First run's last step: the same checklist the servers window carries per server, with one
    /// way past it that never blocks, because nothing breaks without the grant, it only asks more.
    private func showPermissionsStep(
        backend: any PermissionReportingBackend, permissions: MachinePermissions?
    ) {
        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        column.addArrangedSubview(
            RowKit.label(
                MachinePermissionReading.setupTitle, font: MacTheme.Ramp.font(.panelTitle),
                color: MacTheme.Color.label))
        column.addArrangedSubview(
            RowKit.wrapping(
                permissions.map(MachinePermissionReading.setupDetail)
                    ?? MachinePermissionReading.setupTitle,
                font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel))

        let permissionsView = MachinePermissionsView(
            backend: backend, showsHeader: false, initial: permissions)
        permissionsView.onGranted = { [weak self] in
            Task { [weak self] in
                try? await Task.sleep(for: MachinePermissionReading.doneLinger)
                guard let self, !self.isClosed else { return }
                self.complete()
            }
        }
        column.addArrangedSubview(permissionsView)

        let skip = RowKit.ActionButton(title: MachinePermissionReading.skip) { [weak self] in
            self?.complete()
        }
        let actions = NSStackView(views: [RowKit.spacer(), skip])
        actions.orientation = .horizontal
        actions.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(actions)

        window.title = MachinePermissionReading.setupTitle
        window.contentView = MacDialogs.scrollColumn(holding: column)
        window.makeFirstResponder(nil)
    }
}
