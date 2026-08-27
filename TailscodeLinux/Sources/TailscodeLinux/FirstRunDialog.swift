import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// First run is a checklist the app verifies, not a form: it states each requirement and proves
/// what it can — this machine's tailnet presence, polled live, and which agent answers the typed
/// address via the full `probeCandidates()` sweep — before asking for anything. A failed probe
/// names its cause; a password is asked for only once a server says it wants one. Shown only
/// when no server is configured yet.
final class FirstRunDialog: @unchecked Sendable {
    static func presentIfNeeded(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        let parentBits = parent.map { UInt(bitPattern: $0) } ?? 0
        Task {
            await ServerDirectory.shared.reload()
            guard await ServerDirectory.shared.profiles().isEmpty else { return }
            Gtk.onMain {
                let parent = UnsafeMutableRawPointer(bitPattern: parentBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                FirstRunDialog(onSaved: onSaved).present(parent: parent)
            }
        }
    }

    private let onSaved: @Sendable () -> Void
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let tailnetPill = Gtk.label("", css: "row-detail", selectable: false)
    private let tailnetDetail = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
    private let tailnetActions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let agentPill = Gtk.label("", css: "row-detail", selectable: false)
    private let addressEntry = gtk_entry_new()!
    private let passwordEntry = gtk_password_entry_new()!
    private let readingLabel = Gtk.label("", css: "row-detail", selectable: false)
    private let diagnosisLabel = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
    private let diagnosisActions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let connectButton = gtk_button_new_with_label("")!
    private var chosenBackend: AgentType = .claudeCode
    private var passwordShown = false
    private var tailnetAddress: String?
    private var tailscale: TailscaleReading = .daemonDown
    private var closed = false
    private var probeGeneration = 0
    private var verified: (url: URL, agent: AgentType, version: String?)?
    private var scan: DiscoveryPanel?

    /// Minted before the command is shown, so the line a person copies onto the other machine and
    /// the password this app will send are the same string. iOS has always done this; Linux handed
    /// over the bare installer and then asked the user to go and find what it had generated.
    private let mintedPassword = BridgeInstall.makePassword()

    private init(onSaved: @escaping @Sendable () -> Void) {
        self.onSaved = onSaved
    }

    private func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (window, content, actions) = Dialogs.windowWithActions(
            title: Localized.text("Welcome"), parent: parent, width: 620)
        self.window = window

        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Tailscode drives coding agents on your other machines. Three things have to be true first — each one is checked for you."),
                css: "row-detail", wrap: true, selectable: false))

        appendStep(
            to: content, number: "1", title: Localized.text("Tailscale on this machine"),
            pill: tailnetPill)
        setPill(tailnetPill, text: Localized.text("Checking…"), css: "dim")
        Gtk.margins(tailnetDetail, leading: 22)
        gtk_widget_set_visible(tailnetDetail, 0)
        gtk_box_append(ptr(content), tailnetDetail)
        Gtk.margins(tailnetActions, leading: 22)
        gtk_widget_set_visible(tailnetActions, 0)
        gtk_box_append(ptr(content), tailnetActions)

        appendStep(
            to: content, number: "2",
            title: Localized.text("Run an agent on the machine with your code"),
            pill: agentPill)
        appendCommand(
            to: content, label: "claude-bridge",
            command: BridgeInstall.command(for: .claudeCode, password: mintedPassword),
            note: Localized.text("Needs git and a Swift 6 toolchain on that machine."))
        appendCommand(
            to: content, label: "opencode",
            command: BridgeInstall.command(for: .openCode, password: mintedPassword),
            note: Localized.text(
                "Installs opencode if it is missing, serves it on port 4096, and keeps its model list current."
            ))
        appendCommand(
            to: content, label: "omp-bridge",
            command: BridgeInstall.command(for: .omp, password: mintedPassword),
            note: Localized.text(
                "Drives oh-my-pi (install it first) on port 4099. Needs git and a Swift 6 toolchain."
            ))

        appendStep(to: content, number: "3", title: Localized.text("Connect this machine"), pill: nil)

        // The scan is the road with no typing on it, and on Linux the tailnet is free to read, so
        // it leads rather than hiding in a preferences window the person has not found yet.
        let panel = DiscoveryPanel(
            onAdd: { [weak self] suggestion in self?.adopt(suggestion) },
            onChanged: {})
        scan = panel
        gtk_box_append(ptr(content), panel.group)
        gtk_entry_set_placeholder_text(
            ptr(addressEntry),
            Localized.text("Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port"))
        gtk_box_append(ptr(content), addressEntry)

        let kindRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let claudeButton = gtk_toggle_button_new_with_label("claude-bridge · 4098")!
        let opencodeButton = gtk_toggle_button_new_with_label("opencode · 4096")!
        let ompButton = gtk_toggle_button_new_with_label("oh-my-pi · 4099")!
        gtk_toggle_button_set_active(ptr(claudeButton), 1)
        gtk_toggle_button_set_group(ptr(opencodeButton), ptr(claudeButton))
        gtk_toggle_button_set_group(ptr(ompButton), ptr(claudeButton))
        let claudeBits = UInt(bitPattern: claudeButton)
        let opencodeBits = UInt(bitPattern: opencodeButton)
        Gtk.connect(UnsafeMutableRawPointer(claudeButton), "toggled") { [self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: claudeBits),
                gtk_toggle_button_get_active(ptr(raw)) != 0
            else { return }
            chosenBackend = .claudeCode
            Gtk.onMain { [self] in scheduleProbe(afterMilliseconds: 100) }
        }
        Gtk.connect(UnsafeMutableRawPointer(opencodeButton), "toggled") { [self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: opencodeBits),
                gtk_toggle_button_get_active(ptr(raw)) != 0
            else { return }
            chosenBackend = .openCode
            Gtk.onMain { [self] in scheduleProbe(afterMilliseconds: 100) }
        }
        let ompBits = UInt(bitPattern: ompButton)
        Gtk.connect(UnsafeMutableRawPointer(ompButton), "toggled") { [self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: ompBits),
                gtk_toggle_button_get_active(ptr(raw)) != 0
            else { return }
            chosenBackend = .omp
            Gtk.onMain { [self] in scheduleProbe(afterMilliseconds: 100) }
        }
        gtk_box_append(ptr(kindRow), claudeButton)
        gtk_box_append(ptr(kindRow), opencodeButton)
        gtk_box_append(ptr(kindRow), ompButton)
        gtk_box_append(ptr(content), kindRow)

        gtk_box_append(ptr(content), readingLabel)
        gtk_widget_set_visible(passwordEntry, 0)
        gtk_box_append(ptr(content), passwordEntry)
        gtk_box_append(ptr(content), diagnosisLabel)
        gtk_widget_set_visible(diagnosisActions, 0)
        gtk_box_append(ptr(content), diagnosisActions)

        // The demo is the only thing that works with no infrastructure at all, so it reads as an
        // offer rather than as a consolation: somebody who cannot finish setup tonight still gets
        // to see the app instead of closing an empty window.
        let demo = Gtk.button(Localized.text("Try the demo")) { [self] in
            Gtk.onMain { [self] in self.enterDemo() }
        }
        gtk_widget_set_tooltip_text(demo, Localized.text("Two sample servers. Nothing real."))
        gtk_box_append(ptr(actions), demo)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Later"), css: ["flat"]) { [self] in
                Gtk.onMain { [self] in
                    if let window = self.window { Dialogs.close(window) }
                }
            })
        gtk_button_set_label(ptr(connectButton), Localized.text("Connect"))
        Gtk.addClass(connectButton, "suggested-action")
        Gtk.connect(UnsafeMutableRawPointer(connectButton), "clicked") { [self] in
            Gtk.onMain { [self] in probe(userInitiated: true) }
        }
        gtk_box_append(ptr(actions), connectButton)

        Gtk.connect(UnsafeMutableRawPointer(addressEntry), "changed") { [self] in
            Gtk.onMain { [self] in
                verified = nil
                updateReading()
                scheduleProbe(afterMilliseconds: 900)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [self] in
            Gtk.onMain { [self] in closed = true }
        }

        pollTailnet()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(addressEntry)
    }

    private func enterDemo() {
        Task {
            await ServerDirectory.shared.enterDemoMode()
            Gtk.onMain { [self] in
                if let window = self.window { Dialogs.close(window) }
                onSaved()
            }
        }
    }

    private func appendStep(
        to content: UnsafeMutablePointer<GtkWidget>, number: String, title: String,
        pill: UnsafeMutablePointer<GtkWidget>?
    ) {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 8)
        gtk_box_append(ptr(row), Gtk.label("\(number) ·", css: "dim", selectable: false))
        gtk_box_append(ptr(row), Gtk.label(title, css: "row-title", selectable: false))
        if let pill {
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(row), spacer)
            gtk_box_append(ptr(row), pill)
        }
        gtk_box_append(ptr(content), row)
    }

    private func appendCommand(
        to content: UnsafeMutablePointer<GtkWidget>, label: String, command: String,
        note: String? = nil
    ) {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, leading: 22)
        let text = Gtk.label(command, css: "tool-line", selectable: true)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(text, 1)
        gtk_box_append(ptr(row), Gtk.label(label, css: "row-detail", selectable: false))
        gtk_box_append(ptr(row), text)
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Copy"), css: ["flat"]) {
                Gtk.copyToClipboard(command)
            })
        gtk_box_append(ptr(content), row)
        // What that machine needs before the line can work. Silence here is what makes step 2 fail
        // invisibly on somebody else's laptop half an hour later.
        if let note {
            let hint = Gtk.label(note, css: "dim", wrap: true, selectable: false)
            Gtk.margins(hint, leading: 22)
            gtk_box_append(ptr(content), hint)
        }
    }

    /// A machine the scan found, taken as it stands — the whole point of the radar is that nothing
    /// has to be typed. One that wants a password fills the form in and asks only for that.
    private func adopt(_ suggestion: TailnetScanner.Suggestion) {
        guard !suggestion.requiresAuth else {
            gtk_editable_set_text(op(addressEntry), suggestion.baseURL.absoluteString)
            chosenBackend = suggestion.backend
            revealPassword()
            gtk_label_set_text(
                op(diagnosisLabel),
                Localized.text(
                    "%@ answered, so the address is right — it wants the password it was started with.",
                    suggestion.recommendedProfileName))
            return
        }
        let profile = ConnectionProfile(
            id: UUID().uuidString, name: suggestion.recommendedProfileName,
            backend: suggestion.backend, baseURL: suggestion.baseURL,
            username: ProbeSweep.username(for: suggestion.backend))
        Task { [self] in
            do {
                try await ServerDirectory.shared.save(profile, password: nil)
                await finish(profile: profile)
            } catch {
                let text = Localized.text("Could not save: %@", String(describing: error))
                Gtk.onMain { [self] in gtk_label_set_text(op(diagnosisLabel), text) }
            }
        }
    }

    private func revealPassword() {
        guard !passwordShown else { return }
        passwordShown = true
        gtk_widget_set_visible(passwordEntry, 1)
        // The password this app minted is the one the copied command sets, so it is already the
        // best guess — filled in rather than demanded, and still editable for a bridge that was
        // installed before today and kept its old one.
        if Dialogs.entryText(addressEntry).isEmpty || chosenBackend != .openCode {
            gtk_editable_set_text(op(passwordEntry), mintedPassword)
        }
        gtk_widget_grab_focus(passwordEntry)
    }

    private func setPill(_ label: UnsafeMutablePointer<GtkWidget>, text: String, css: String) {
        gtk_label_set_text(op(label), text)
        for name in ["dim", "glyph-running", "glyph-error", "glyph-pending"] {
            gtk_widget_remove_css_class(label, name)
        }
        Gtk.addClass(label, css)
    }

    /// This machine's tailnet presence, re-proved every few seconds while the window is open —
    /// someone starting Tailscale mid-setup watches the step go green by itself.
    private func pollTailnet() {
        Task.detached { [self] in
            var scanned = false
            while !closed {
                let status = TailnetStatusLinux.read()
                let address = status.address
                let reading = status.reading
                let start = address != nil && !scanned
                if start { scanned = true }
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    tailnetAddress = address
                    tailscale = reading
                    show(reading)
                    // The radar can only ask peers once this machine has a tailnet of its own, so
                    // the sweep starts the moment step 1 goes green rather than on a press.
                    if start { scan?.scan() }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Step 1 as one of four states, each with the one thing that fixes it. "Not connected — run
    /// `tailscale up`" used to stand for all four, and it is the right advice for exactly one of
    /// them — and it is advice, which first run is not supposed to give.
    private func show(_ reading: TailscaleReading) {
        setPill(
            tailnetPill, text: reading.title,
            css: reading.isUp ? "glyph-running" : (reading.tone == .quiet ? "dim" : "glyph-error"))

        let detail = reading.detail
        gtk_label_set_text(op(tailnetDetail), detail ?? "")
        gtk_widget_set_visible(tailnetDetail, detail == nil ? 0 : 1)

        Gtk.removeChildren(of: tailnetActions)
        guard let title = reading.actionTitle else {
            gtk_widget_set_visible(tailnetActions, 0)
            return
        }
        gtk_widget_set_visible(tailnetActions, 1)
        switch reading.remedy {
        case .install(let url):
            gtk_box_append(ptr(tailnetActions), Gtk.button(title) { SignInDialog.openInBrowser(url) })
        case .signIn(let command), .start(let command):
            gtk_box_append(
                ptr(tailnetActions),
                Gtk.button(title) { [self] in
                    Gtk.onMain { [self] in run(command) }
                })
            gtk_box_append(
                ptr(tailnetActions),
                Gtk.button(Localized.text("Copy"), css: ["flat"]) {
                    Gtk.copyToClipboard(command)
                })
        case .grantHostAccess(let command):
            gtk_box_append(
                ptr(tailnetActions),
                Gtk.button(Localized.text("Copy"), css: ["flat"]) {
                    Gtk.copyToClipboard(command)
                })
        case .none:
            gtk_widget_set_visible(tailnetActions, 0)
        }
    }

    /// A command that has to run on *this* machine is run from here, with its output on the same
    /// screen, rather than handed over with "run it in a terminal" — which is the one thing the
    /// first-run doctrine forbids and is also useless advice to somebody who has never opened one.
    ///
    /// `tailscale up` answers by printing a login URL and waiting, so the URL is watched for and
    /// opened as it appears; anything needing root is raised through pkexec, which asks with the
    /// desktop's own dialog. A command that cannot run says so and leaves the copyable line, which
    /// is the honest floor rather than a silent failure.
    private func run(_ command: String) {
        let elevated = command.hasPrefix("sudo ")
        let bare = elevated ? String(command.dropFirst(5)) : command
        let usePolkit = elevated && FileManager.default.isExecutableFile(atPath: "/usr/bin/pkexec")
        gtk_label_set_text(op(tailnetDetail), Localized.text("Running %@…", bare))
        gtk_widget_set_visible(tailnetDetail, 1)

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
                        op(tailnetDetail),
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
                    gtk_label_set_text(op(tailnetDetail), text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            process.waitUntilExit()
        }
    }

    /// Tailscale's own sign-in link, which is the whole point of watching the output: a person who
    /// never sees it has no way to finish signing in.
    private static func loginURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace })
        where token.hasPrefix("https://login.tailscale.com/") {
            return String(token)
        }
        return nil
    }

    private func updateReading() {
        let raw = Dialogs.entryText(addressEntry)
        guard !raw.isEmpty else {
            gtk_label_set_text(op(readingLabel), "")
            return
        }
        let backend: AgentType = chosenBackend
        switch HostAddress.read(raw, defaultPort: HostAddress.port(for: backend)) {
        case .address(let address):
            gtk_label_set_text(op(readingLabel), "→ \(address.url.absoluteString)")
        case .bindAll:
            gtk_label_set_text(
                op(readingLabel),
                Localized.text("0.0.0.0 is what a server binds to, never where it lives."))
        case .unsupportedScheme(let scheme):
            gtk_label_set_text(op(readingLabel), Localized.text("%@:// cannot work here.", scheme))
        case .invalid:
            gtk_label_set_text(op(readingLabel), Localized.text("Doesn't read as an address yet."))
        case .empty:
            gtk_label_set_text(op(readingLabel), "")
        }
    }

    private func scheduleProbe(afterMilliseconds: UInt32) {
        probeGeneration += 1
        let generation = probeGeneration
        Gtk.after(afterMilliseconds) { [self] in
            guard !closed, generation == probeGeneration else { return }
            probe(userInitiated: false)
        }
    }

    private func probe(userInitiated: Bool) {
        let raw = Dialogs.entryText(addressEntry)
        let backend: AgentType = chosenBackend
        guard case .address(let address) = HostAddress.read(
            raw, defaultPort: HostAddress.port(for: backend))
        else {
            if userInitiated { updateReading() }
            return
        }
        guard let passwordRaw = gtk_editable_get_text(op(passwordEntry)) else { return }
        let password = String(cString: passwordRaw)
        gtk_label_set_text(
            op(diagnosisLabel), Localized.text("Probing %@…", address.displayHost))
        probeGeneration += 1
        let generation = probeGeneration
        let tailnetUp = tailnetAddress != nil
        Task { [self] in
            let verdict = await ProbeSweep.best(
                address: address, password: password.isEmpty ? nil : password,
                preferring: backend,
                policy: userInitiated ? ProbeSweep.interactivePolicy : ProbeSweep.typingPolicy,
                retryUnreachable: userInitiated)
            var reachability: PortReachability.Verdict?
            if case .unreachable = verdict.outcome, let host = verdict.url.host,
                let port = verdict.url.port
            {
                reachability = await PortReachability.check(host: host, port: UInt16(port))
            }
            let settled = reachability
            Gtk.onMain { [self] in
                guard !closed, generation == probeGeneration else { return }
                consume(
                    verdict, address: address, password: password, tailnetUp: tailnetUp,
                    reachability: settled, userInitiated: userInitiated)
            }
        }
    }

    private func consume(
        _ verdict: ProbeSweep.Verdict, address: HostAddress, password: String,
        tailnetUp: Bool, reachability: PortReachability.Verdict?, userInitiated: Bool
    ) {
        switch verdict.outcome {
        case .ok(let agent, let version):
            verified = (verdict.url, agent, version)
            let name = Self.bridgeName(for: agent)
            setPill(agentPill, text: Localized.text("Answering"), css: "glyph-running")
            gtk_label_set_text(
                op(diagnosisLabel),
                Localized.text("%@ %@ answered at %@.", name, version ?? "", verdict.url.absoluteString))
            gtk_button_set_label(
                ptr(connectButton), Localized.text("Connect to %@", address.displayHost))
            if userInitiated { save(password: password) }
        case .authFailed, .notAnAgentServer, .unreachable:
            verified = nil
            if case .authFailed = verdict.outcome { revealPassword() }
            // The shared diagnosis, with the same words and the same one fix the Servers window
            // gives. First run used to hand-roll eight sentences and offer no action at all, so the
            // one screen a stranger meets was the one screen that could only dead-end.
            let diagnosis = ConnectDiagnosis.make(
                outcome: verdict.outcome, address: address, tailnetAddress: tailnetAddress,
                alternatePort: Self.otherAgentPort(for: verdict.url),
                sentPassword: !password.isEmpty, reachability: reachability,
                deviceName: Localized.text("This machine"))
            show(diagnosis, for: address)
        }
    }

    private func show(_ diagnosis: ConnectDiagnosis?, for address: HostAddress) {
        Gtk.removeChildren(of: diagnosisActions)
        guard let diagnosis else {
            gtk_label_set_text(op(diagnosisLabel), "")
            gtk_widget_set_visible(diagnosisActions, 0)
            return
        }
        gtk_label_set_text(op(diagnosisLabel), "\(diagnosis.title)\n\(diagnosis.detail)")
        guard let title = diagnosis.actionTitle else {
            gtk_widget_set_visible(diagnosisActions, 0)
            return
        }
        gtk_widget_set_visible(diagnosisActions, 1)
        switch diagnosis.fix {
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(title) { [self] in
                    Gtk.onMain { [self] in
                        gtk_editable_set_text(op(addressEntry), url.absoluteString)
                        probe(userInitiated: true)
                    }
                })
        case .retry:
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(title) { [self] in
                    Gtk.onMain { [self] in probe(userInitiated: true) }
                })
        case .openTailscale:
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(title) { [self] in
                    Gtk.onMain { [self] in show(tailscale) }
                })
        case .revealPassword:
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(title) { [self] in Gtk.onMain { [self] in revealPassword() } })
        case .copyCommand(let command):
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(title) { Gtk.copyToClipboard(command) })
        case .none, .openAppSettings, .seePro:
            gtk_widget_set_visible(diagnosisActions, 0)
        }
    }

    /// Saves the profile as what actually answered: the detected agent and the URL that spoke,
    /// which quietly corrects a guessed port or a wrong toggle.
    private func save(password: String) {
        guard let verified else { return }
        let profile = ConnectionProfile(
            id: UUID().uuidString,
            name: verified.url.host ?? verified.url.absoluteString,
            backend: verified.agent,
            baseURL: verified.url,
            username: ProbeSweep.username(for: verified.agent))
        AppLog.write(
            .connection,
            "first run saving \(verified.agent.rawValue) at \(verified.url.absoluteString) "
                + "password \(AppLog.redacted(password.isEmpty ? nil : password))")
        Task { [self] in
            do {
                try await ServerDirectory.shared.save(
                    profile, password: password.isEmpty ? nil : password)
                await finish(profile: profile)
            } catch {
                Gtk.onMain { [self] in
                    gtk_label_set_text(
                        op(diagnosisLabel),
                        Localized.text("Could not save: %@", String(describing: error)))
                }
            }
        }
    }

    /// The third requirement, which the checklist never named: the CLI on that machine has to be
    /// signed in, or every turn comes back "Not logged in · Please run /login" and the conversation
    /// looks broken rather than signed out. Asked here, while the person is still on the screen that
    /// promised to check things, instead of being met as a banner half an hour later.
    ///
    /// A server that cannot answer the question — opencode, which has no such account, or a bridge
    /// too old for the route — closes the dialog as before. "Cannot say" is not "signed out".
    private static func otherAgentPort(for url: URL) -> URL? {
        guard let port = url.port else { return nil }
        let alternate: Int
        switch port {
        case HostAddress.openCodePort: alternate = HostAddress.claudeCodePort
        case HostAddress.claudeCodePort: alternate = HostAddress.ompPort
        case HostAddress.ompPort: alternate = HostAddress.openCodePort
        default: return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.port = alternate
        return components.url
    }

    /// What the process on the far machine is actually called, for the sentence that names what
    /// answered: the agent label is Core's, but only opencode serves under its own name — the
    /// other two agents answer through their bridges.
    private static func bridgeName(for agent: AgentType) -> String {
        switch agent {
        case .openCode: return "opencode"
        case .claudeCode: return "claude-bridge"
        case .omp: return "omp-bridge"
        }
    }

    private func finish(profile: ConnectionProfile) async {
        let backend = await Self.signedOutBackend(profile)
        onSaved()
        Gtk.onMain { [self] in
            guard !closed else { return }
            guard let backend else {
                if let window { Dialogs.close(window) }
                return
            }
            gtk_label_set_text(
                op(diagnosisLabel),
                Localized.text(
                    "%@ is connected, but Claude is signed out there — every turn will refuse until "
                        + "it signs in.", profile.name))
            Gtk.removeChildren(of: diagnosisActions)
            gtk_widget_set_visible(diagnosisActions, 1)
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(Localized.text("Sign in to Claude")) { [self] in
                    Gtk.onMain { [self] in
                        if let window { Dialogs.close(window) }
                        SignInDialog.present(
                            parent: nil, serverName: profile.name, backend: backend) {}
                    }
                })
            gtk_box_append(
                ptr(diagnosisActions),
                Gtk.button(Localized.text("Later"), css: ["flat"]) { [self] in
                    Gtk.onMain { [self] in
                        if let window { Dialogs.close(window) }
                    }
                })
        }
    }

    /// The backend to sign in, when there is a question to ask and the answer was "signed out".
    /// Nil covers three different things on purpose — a backend with no account, a server too old
    /// for the route, and a machine that did not answer — because none of them is "signed out", and
    /// only "signed out" earns a step.
    private static func signedOutBackend(_ profile: ConnectionProfile) async
        -> (any AuthenticatingBackend)?
    {
        guard profile.backend == .claudeCode else { return nil }
        guard
            let backend = await ServerDirectory.shared.backend(for: profile)
                as? any AuthenticatingBackend
        else { return nil }
        guard let status = try? await backend.authStatus(), !status.loggedIn else { return nil }
        return backend
    }
}
