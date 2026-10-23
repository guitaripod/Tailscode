import CodingAgentKit
import Foundation

/// A renderer this device has used, kept so the second time costs nothing.
///
/// Pointing at a machine is a one-line decision that people nevertheless make twice — once on the
/// laptop and once on the phone, and again after a reinstall — so the answer is filed the way a
/// server is: with the name the tailnet gave it, so a list of addresses reads as a list of
/// machines. The address is the whole configuration and none of it is a secret.
public struct ForgeRenderer: Sendable, Codable, Hashable, Identifiable {
    public let endpoint: ForgeEndpoint
    /// What the tailnet calls the machine, when a scan found it or somebody typed it. Nil is not a
    /// failure — an address typed blind is still a renderer — so the row falls back to the host.
    public let name: String?
    public let usedAt: Date

    public init(endpoint: ForgeEndpoint, name: String? = nil, usedAt: Date = Date()) {
        self.endpoint = endpoint
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.usedAt = usedAt
    }

    public var id: String { endpoint.displayHost }

    /// When it was last used is bookkeeping rather than identity: two records of the same machine
    /// under the same name are the same renderer, and a client comparing what it is holding against
    /// what it was offered must not be told they differ because a clock moved between them.
    public static func == (lhs: ForgeRenderer, rhs: ForgeRenderer) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(endpoint)
        hasher.combine(name)
    }

    public var title: String { name ?? endpoint.host }

    public var detail: String { endpoint.displayHost }

    /// The word the row wears when this is the machine renders currently go to. Every other row is
    /// a machine that would work, which is a different thing from the one in force.
    public static func badge(current: Bool) -> String? {
        current ? Localized.text("in use") : nil
    }
}

/// A machine on the tailnet that answered on the forge port.
///
/// Deliberately not a `TailnetScanner.Suggestion`: that value is an *agent* server's, and its probe
/// discards everything that is not opencode or claude-bridge — a ComfyUI comes back as
/// `notAnAgentServer` and is dropped. What is being looked for here is a port answering, which is
/// the only question a renderer can be asked cheaply, so this carries the verdict rather than a
/// backend and a version.
public struct ForgeCandidate: Sendable, Hashable, Identifiable {
    public let machine: String
    public let host: String
    public let port: Int
    public let os: String?
    public let lastSeen: String?

    public init(machine: String, host: String, port: Int, os: String? = nil, lastSeen: String? = nil) {
        self.machine = machine
        self.host = host
        self.port = port
        self.os = os
        self.lastSeen = lastSeen
    }

    public var id: String { "\(host):\(port)" }

    public var endpoint: ForgeEndpoint { ForgeEndpoint(host: host, port: port) }

    public var renderer: ForgeRenderer { ForgeRenderer(endpoint: endpoint, name: machine) }

    public var title: String { machine }

    /// The address it answered on, and that it answered at all. A scan that merely lists machines
    /// says nothing a person could not have guessed; the fact worth carrying is the port.
    public var detail: String {
        [endpoint.displayHost, Localized.text("answering")].joined(separator: " · ")
    }
}

/// Setting up the renderer, held to the standard adding a server is held to.
///
/// A server is not typed blind: the flow states what this machine's own tailnet address is, offers
/// to sweep the tailnet rather than demanding a hostname, checks what was given before saving it,
/// explains a failure in a sentence that names the fix, and remembers the answer. A renderer is the
/// same shape of decision — one machine, one address, no account — and had none of it. This is that
/// flow, written once: the clients own a text field, a list and a button, and not one word.
///
/// The one rule that differs from a server, and it is the renderer's own: a machine that did not
/// answer may still be the right machine. ComfyUI is socket-activated and stops itself after
/// fifteen idle minutes, so silence from a box that is genuinely the renderer is the ordinary case
/// rather than a mistake — the setup therefore offers to save it anyway, and says why.
public struct ForgeSetup: Sendable, Equatable {
    /// The parts of the surface in the order a reader meets them, which no client may reorder.
    public static var order: [ForgeSetupArea] { ForgeSetupArea.allCases }

    public static var title: String { Localized.text("Set up the renderer") }

    public static var detail: String {
        Localized.text(
            "Video is made on one machine on your tailnet — the one with the graphics card, running ComfyUI. Point this at it once and every screen uses it."
        )
    }

    public static var addressLabel: String { ForgeField.endpoint.label }

    public static var addressPlaceholder: String {
        Localized.text("Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:%@", "\(ForgeSweep.port)")
    }

    public static var addressHelp: String {
        Localized.text(
            "100.x.y.z, a MagicDNS name, host:port — or a whole line pasted out of ComfyUI's terminal. Port %@ is added when you don't name one.",
            "\(ForgeSweep.port)")
    }

    public static var nameLabel: String { Localized.text("Name (optional)") }

    public static var knownTitle: String { Localized.text("Renderers you have used") }

    public static var knownEmpty: String {
        Localized.text("None yet. Scan your tailnet, or type the address below.")
    }

    public static var forgetTitle: String { Localized.text("Forget this renderer") }

    /// What starts the thing being looked for, handed over the way the server flow's install
    /// command is, a line to copy and run on the other machine and never an instruction to go and
    /// read a manual. A ComfyUI bound to localhost is invisible from every other machine on the
    /// tailnet, which is the commonest way this fails, and a ComfyUI bound to every interface is an
    /// unauthenticated render queue on every network the machine is on. So it binds loopback and the
    /// Tailscale address and nothing else, and it fails safe: ComfyUI reads `--listen` as a list
    /// split on commas, and an empty entry (what `$(tailscale ip -4)` becomes on a machine without
    /// Tailscale) is a bind to every interface, so the address is read first and nothing is started
    /// without one.
    public static var startCommand: String {
        "ts=$(tailscale ip -4 | head -n 1); if [ -n \"$ts\" ]; then python main.py --listen \"127.0.0.1,$ts\" --port \(ForgeSweep.port); else echo \"Tailscale gave no address, so ComfyUI was not started\"; fi"
    }

    public static var startCommandTitle: String { Localized.text("Copy the start command") }

    public private(set) var typed: String
    public private(set) var name: String
    public private(set) var stage: ForgeSetupReading.Stage
    /// What the port last said, kept because it decides whether saving an unanswered address is
    /// worth offering: a machine asleep may be the right one, a name that does not resolve is not.
    public private(set) var verdict: PortReachability.Verdict?
    public private(set) var diagnosis: ConnectDiagnosis?
    public private(set) var media: MediaVerdict?
    public private(set) var current: ForgeEndpoint?
    public private(set) var known: [ForgeRenderer]
    /// What this machine's own Tailscale says, so the surface can state the one condition that
    /// makes every probe fail identically before a person spends a minute on the address.
    public var tailnet: TailscaleReading?
    public var deviceName: String

    public init(
        current: ForgeEndpoint? = nil, known: [ForgeRenderer] = [],
        tailnet: TailscaleReading? = nil, deviceName: String = Localized.text("This device")
    ) {
        self.current = current
        self.known = known
        self.tailnet = tailnet
        self.deviceName = deviceName
        typed = current?.displayHost ?? ""
        name = known.first { $0.endpoint == current }?.name ?? ""
        stage = typed.isEmpty ? .blank : .ready
        verdict = nil
        diagnosis = nil
    }

    public var reading: ForgeEndpoint.Reading { ForgeEndpoint.read(typed) }

    public var endpoint: ForgeEndpoint? {
        guard case .endpoint(let endpoint) = reading else { return nil }
        return endpoint
    }

    public var renderer: ForgeRenderer? {
        endpoint.map { ForgeRenderer(endpoint: $0, name: name) }
    }

    /// The renderer to file, non-nil exactly once a machine has answered. A client saves this and
    /// closes; nothing else in the flow writes to the store.
    public var commit: ForgeRenderer? {
        guard stage == .listening else { return nil }
        return renderer
    }

    /// What the typed line will actually be used as, said while it is being typed — the port this
    /// supplied, or the reason the line cannot be used. Nil when there is nothing to add.
    public var hint: String? {
        switch HostAddress.read(typed, defaultPort: ForgeSweep.port) {
        case .address(let address):
            guard address.portWasInferred else { return nil }
            return Localized.text("→ %@ (port added)", address.displayHost)
        case .empty, .bindAll, .invalid, .unsupportedScheme:
            return ForgeEndpoint.complaint(reading)
        }
    }

    /// What this machine is on the tailnet, or the reason it is on none. The same fact the server
    /// flow leads with, because a probe from a machine with no tailnet address fails identically
    /// however right the address is.
    public var tailnetLine: String {
        guard let tailnet else { return "" }
        guard let address = tailnet.address else {
            return Localized.text(
                "Tailscale isn't reporting an address here — nothing will answer until it is connected."
            )
        }
        return Localized.text("This machine is %@ on your tailnet.", address)
    }

    public mutating func type(_ text: String) {
        guard text != typed else { return }
        typed = text
        verdict = nil
        diagnosis = nil
        media = nil
        stage = settledStage()
    }

    public mutating func rename(_ text: String) {
        name = text
    }

    public mutating func checking() {
        guard endpoint != nil else { return }
        stage = .checking
        verdict = nil
        diagnosis = nil
    }

    /// What the port said, turned into the one thing that is wrong and the one press that fixes it.
    public mutating func reached(_ verdict: PortReachability.Verdict) {
        guard let endpoint else { return }
        self.verdict = verdict
        guard
            let diagnosis = ConnectDiagnosis.forge(
                verdict: verdict, endpoint: endpoint, tailnet: tailnet, deviceName: deviceName)
        else {
            self.diagnosis = nil
            stage = .listening
            return
        }
        self.diagnosis = diagnosis
        stage = .failed
    }

    /// Takes a scan result into the form, already checked. A machine that answered a sweep answered
    /// the same question the button asks, so asking it twice is a wait bought for nothing.
    /// The doctor's answer in place of the port's: what became of the address, and what the
    /// machine at it can make. A running ComfyUI that lacks files is still the right machine, so
    /// it files like any other and the shortfall is said under it rather than in its way.
    public mutating func assessed(_ found: MediaVerdict) {
        guard let endpoint, found.endpoint == endpoint else { return }
        media = found
        switch found.comfy {
        case .answering, .starting:
            verdict = .listening
            diagnosis = nil
            stage = .listening
        case .timedOut:
            reached(.timedOut)
        case .unresolved:
            reached(.nameNotResolved)
        case .refused, .loopbackOnly, .notComfy:
            verdict = found.comfy == .notComfy ? .listening : .refused
            diagnosis = ConnectDiagnosis.forge(comfy: found.comfy, endpoint: endpoint)
            stage = .failed
        }
    }

    public mutating func adopt(_ candidate: ForgeCandidate) {
        typed = candidate.endpoint.displayHost
        name = candidate.machine
        verdict = .listening
        diagnosis = nil
        stage = .listening
    }

    private func settledStage() -> ForgeSetupReading.Stage {
        switch reading {
        case .empty: return .blank
        case .endpoint: return .ready
        case .bindAll, .invalid, .unsupportedScheme: return .unreadable
        }
    }

    public var status: ForgeSetupReading {
        switch stage {
        case .blank:
            return ForgeSetupReading(
                stage: .blank, title: Localized.text("Nothing typed yet"),
                detail: Localized.text(
                    "Paste the address of the machine with the card — 100.x.y.z, a MagicDNS name, or the whole line ComfyUI printed when it started."
                ),
                tone: .quiet)
        case .unreadable:
            return ForgeSetupReading(
                stage: .unreadable, title: Localized.text("That does not read as an address"),
                detail: ForgeEndpoint.complaint(reading)
                    ?? Localized.text("That does not read as a machine on the tailnet"),
                tone: .attention)
        case .ready:
            return ForgeSetupReading(
                stage: .ready, title: endpoint?.displayHost ?? "",
                detail: Localized.text("Not checked yet"), tone: .quiet)
        case .checking:
            return ForgeSetupReading(
                stage: .checking, title: Localized.text("Checking %@…", endpoint?.host ?? ""),
                detail: Localized.text("Asking whether anything is listening before saving it."),
                tone: .live)
        case .listening:
            if let media, let check = media.check("media.comfy"), let endpoint {
                if media.isStarting {
                    return ForgeSetupReading(
                        stage: .listening, title: Localized.text("%@ is starting", endpoint.host),
                        detail: MediaReading.comfyDetail(check, endpoint: endpoint), tone: .live)
                }
                if let blocker = media.video {
                    return ForgeSetupReading(
                        stage: .listening, title: Localized.text("%@ answered", endpoint.host),
                        detail: blocker.sentence, tone: .attention)
                }
            }
            return ForgeSetupReading(
                stage: .listening, title: Localized.text("%@ answered", endpoint?.host ?? ""),
                detail: Localized.text(
                    "Answering on %@. The first render still waits while it loads the model.",
                    "\(endpoint?.port ?? ForgeSweep.port)"),
                tone: .live)
        case .failed:
            guard let diagnosis else {
                return ForgeSetupReading(
                    stage: .failed, title: Localized.text("No answer"),
                    detail: Localized.text("Nothing came back from that address."), tone: .danger)
            }
            return ForgeSetupReading(
                stage: .failed, title: diagnosis.title, detail: diagnosis.detail, tone: .danger,
                diagnosis: diagnosis)
        }
    }

    /// The one button that does the work, in the words of what it would do next.
    public var primary: ForgeSetupButton {
        switch stage {
        case .blank, .unreadable:
            return ForgeSetupButton(
                Localized.text("Check and save"), .nothing, isEnabled: false)
        case .ready:
            guard let endpoint else {
                return ForgeSetupButton(Localized.text("Check and save"), .nothing, isEnabled: false)
            }
            return ForgeSetupButton(Localized.text("Check and save"), .check(endpoint))
        case .checking:
            return ForgeSetupButton(Localized.text("Checking…"), .nothing, isEnabled: false)
        case .listening:
            guard let renderer else {
                return ForgeSetupButton(Localized.text("Save"), .nothing, isEnabled: false)
            }
            return ForgeSetupButton(Localized.text("Save"), .save(renderer))
        case .failed:
            guard let endpoint else {
                return ForgeSetupButton(Localized.text("Try again"), .nothing, isEnabled: false)
            }
            return ForgeSetupButton(Localized.text("Try again"), .check(endpoint))
        }
    }

    /// The renderer's own second answer: save a machine that said nothing. Offered only where
    /// silence is plausibly the right machine — a box asleep, or one whose ComfyUI is not up yet —
    /// and never for a name this device could not resolve, which would file an address that can
    /// never work.
    public var secondary: ForgeSetupButton? {
        guard stage == .failed, let renderer else { return nil }
        switch verdict {
        case .timedOut, .refused:
            return ForgeSetupButton(Localized.text("Use it anyway"), .save(renderer))
        case .listening, .nameNotResolved, .none:
            return nil
        }
    }

    /// The sentence under that second answer, because saving something that did not answer needs a
    /// reason rather than a shrug.
    public var secondaryNote: String? {
        guard secondary != nil else { return nil }
        return Localized.text(
            "A renderer nothing has asked for a while stops itself. Save it anyway and the first render wakes it."
        )
    }

    /// The way in that is not typing. Disabled only when this machine has no tailnet to sweep,
    /// which is a fact the surface has already stated rather than a button that fails silently.
    public var discovery: ForgeSetupButton {
        ForgeSetupButton(
            Localized.text("Find my renderer"), .scan, isEnabled: tailnet?.isUp ?? true)
    }

    /// Why the scan cannot run, when it cannot. `discovery.isEnabled` says only that it cannot, and
    /// a greyed-out button under a sentence about what scanning does states neither the reason nor a
    /// way out. The desks have a fourfold answer of their own in `ForgeSweepReading(blocked:)`, read
    /// off a Tailscale they can interrogate; this is the answer every device can make, and the only
    /// one a phone — which can see whether it has an address and nothing else — is in a position to.
    public var discoveryBlock: ConnectDiagnosis? {
        guard let tailnet, !tailnet.isUp else { return nil }
        return .offTailnet(deviceName: deviceName)
    }

    /// Whether a row in the known list is the machine renders currently go to.
    public func isCurrent(_ renderer: ForgeRenderer) -> Bool {
        renderer.endpoint == current
    }
}
