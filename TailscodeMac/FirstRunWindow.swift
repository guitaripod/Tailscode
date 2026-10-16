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
/// already read, and with servers it asks whether to add the machine the link names.
@MainActor
final class FirstRunWindow: NSObject, NSWindowDelegate {
    struct Hooks {
        var saved: () -> Void
        var seePro: () -> Void
        var openServer: (String) -> Void
    }

    static var hooks = Hooks(saved: {}, seePro: {}, openServer: { _ in })
    private static var open: FirstRunWindow?

    static func presentIfNeeded() {
        ServerDirectory.shared.reload()
        guard realProfiles.isEmpty else { return }
        let checklist = FirstRunWindow(mode: .firstRun)
        open = checklist
        checklist.begin(pasting: nil)
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
        let window = FirstRunWindow(mode: realProfiles.isEmpty ? .firstRun : .addition)
        open = window
        window.begin(pasting: text)
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
        signIn: { [weak self] in self?.signIn() },
        fix: { [weak self] in self?.fix($0) },
        back: { [weak self] in
            guard let flow = self?.flow else { return }
            Task { await flow.back() }
        })
    }

    private init(mode: FirstRunState.Mode) {
        self.mode = mode
        environment = Self.environment()
        flow = FirstRunFlow(platform: .mac, mode: mode, environment: environment)
        window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.addArrangedSubview(intro)
        column.addArrangedSubview(footer())

        window.title = mode == .addition ? ConnectLinkReading.addQuestion : Localized.text("Welcome")
        window.minSize = NSSize(width: 620, height: 320)
        window.contentView = MacDialogs.scrollColumn(holding: column)
        window.delegate = self
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
        let actions = NSStackView(views: [
            RowKit.spacer(), demoButton, notNowButton, laterButton, busy, primaryButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.translatesAutoresizingMaskIntoConstraints = false
        return actions
    }

    private func begin(pasting text: String?) {
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
            if let text { await flow.paste(text) }
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
            drawn.update(row, back: row.id == .machine ? plan.back : nil)
        }
        showFooter(plan)
        watchForInstall(plan)
        if plan.isFinished { finish() }
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
        notNowButton.isHidden = plan.later != nil
        notNowButton.title = plan.dismiss
        laterButton.isHidden = plan.later == nil
        laterButton.title = plan.later ?? ""
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

    private func primaryPressed() {
        guard let primary else { return }
        let flow = self.flow
        switch primary.intent {
        case .connect:
            window.makeFirstResponder(nil)
            Task { await flow.connect() }
        case .openTailscale:
            openTailscale()
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
        switch fix {
        case .none:
            return
        case .openTailscale:
            openTailscale()
        case .openAppSettings:
            if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
        case .retry:
            Task { await flow.retry() }
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            Task { await flow.typeAddress(url.absoluteString) }
        case .revealPassword:
            Task { await flow.revealPassword() }
        case .seePro:
            Self.hooks.seePro()
        case .copyCommand(let command):
            RowKit.copyToClipboard(command)
        }
    }

    /// The door Tailscale offers for what this Mac reads, or the Tailscale app, or its download
    /// page when the reading is a healthy one and the diagnosis still names Tailscale (a machine
    /// signed into another account says so from an `up` reading).
    private func openTailscale() {
        if let reading = latestTailscale, TailnetStatusMac.door(for: reading) != nil {
            remedy.write(reading)
            remedy.enterDoor()
            return
        }
        if let app = TailnetStatusMac.appURL {
            NSWorkspace.shared.open(app)
        } else if let page = URL(string: TailnetStatusMac.downloadPage) {
            NSWorkspace.shared.open(page)
        }
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
        ServerDirectory.shared.enterDemoMode()
        Self.hooks.saved()
        window.close()
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
        Self.hooks.saved()
        window.close()
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
