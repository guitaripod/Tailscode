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

/// Looking for the machine with the card, the way the server flow looks for machines running an
/// agent — same peer list, same radar, same wording shape — but asked with the only question a
/// renderer can answer cheaply.
///
/// `TailnetScanner` cannot be reused whole here: it ranks `ConnectionProbe` outcomes and drops
/// anything that is not an agent, which is every ComfyUI there has ever been. What *is* reused is
/// everything above the probe — `TailnetScanner.scannableDevices` to skip the phones and the peers
/// nobody has seen in ten minutes, `PortReachability` to ask, `TailnetRadar` to draw the wait.
public enum ForgeSweep {
    public static let port = ForgeEndpoint.defaultPort
    /// Enough probes in flight that a tailnet of thirty machines is a wait rather than a coffee,
    /// and few enough that a laptop's DNS resolver is not the thing that times out. The same
    /// number the agent scan uses, for the same reason.
    public static let concurrency = 16
    /// Shorter than an interactive check: a sweep asks many machines and a sleeping one must not
    /// hold the whole dial. The machine that is actually there answers in milliseconds.
    public static let probeTimeout: Duration = .seconds(2)
    /// When the scan gives up saying anything more. A tailnet with a dozen asleep peers can hold
    /// probes far longer than a person will watch a radar.
    public static let deadline: Duration = .seconds(30)

    /// One machine worth asking, and the addresses worth asking it at, best first.
    public struct Target: Sendable, Hashable, Identifiable {
        public let machine: String
        /// The MagicDNS name first and the IPv4 behind it. A name is what a person wants saved,
        /// and a tailnet with MagicDNS off simply fails to resolve it, which is the one verdict
        /// that means "ask the other address" rather than "this machine is not it".
        public let hosts: [String]
        public let os: String?
        public let lastSeen: String?

        public init(machine: String, hosts: [String], os: String? = nil, lastSeen: String? = nil) {
            self.machine = machine
            self.hosts = hosts
            self.os = os
            self.lastSeen = lastSeen
        }

        public var id: String { machine }
    }

    public typealias Probe = @Sendable (String, Int) async -> PortReachability.Verdict

    /// The real question, asked the only way that tells a closed port from a sleeping machine.
    public static let liveProbe: Probe = { host, port in
        await PortReachability.check(
            host: host, port: UInt16(clamping: port), timeout: probeTimeout)
    }

    /// The machines worth asking, in the order the scan will ask them. The filtering is
    /// `TailnetScanner`'s — offline peers blackhole every probe into a full timeout, and a phone or
    /// a TV can never hold a graphics card — so a renderer scan and an agent scan look at exactly
    /// the same tailnet.
    public static func targets(_ devices: [TailscaleDevice], now: Date = Date()) -> [Target] {
        TailnetScanner.scannableDevices(devices, now: now).compactMap { device in
            let hosts = probeHosts(for: device)
            guard !hosts.isEmpty else { return nil }
            let label = device.hostname.isEmpty ? (device.name ?? hosts[0]) : device.hostname
            return Target(machine: label, hosts: hosts, os: device.os, lastSeen: device.lastSeen)
        }
    }

    /// The name first, then one IPv4. One address per family is waste — the tailnet's IPv6 reaches
    /// the same node the IPv4 does — and the name is the thing worth remembering, so it leads.
    private static func probeHosts(for device: TailscaleDevice) -> [String] {
        var hosts: [String] = []
        if let name = device.name, !name.isEmpty { hosts.append(name) }
        if let v4 = device.addresses.first(where: { !$0.contains(":") }) {
            hosts.append(v4)
        } else if let any = device.addresses.first {
            hosts.append(any)
        }
        return hosts
    }

    public static func run(
        devices: [TailscaleDevice], now: Date = Date(), probe: @escaping Probe = liveProbe,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onFound: (@Sendable (ForgeCandidate) -> Void)? = nil
    ) async -> [ForgeCandidate] {
        await run(targets: targets(devices, now: now), probe: probe, onProgress: onProgress, onFound: onFound)
    }

    /// Asks every machine, `concurrency` at a time, and reports each answer as it lands so the dial
    /// lights while the scan is still out. The returned list is the same findings in the order the
    /// targets were given, which is the order the tailnet last saw them.
    public static func run(
        targets: [Target], probe: @escaping Probe = liveProbe,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onFound: (@Sendable (ForgeCandidate) -> Void)? = nil
    ) async -> [ForgeCandidate] {
        guard !targets.isEmpty else { return [] }
        var found: [(order: Int, candidate: ForgeCandidate)] = []
        var checked = 0
        await withTaskGroup(of: (Int, ForgeCandidate?).self) { group in
            var iterator = targets.enumerated().makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let (order, target) = iterator.next() else { return false }
                group.addTask { (order, await ask(target, probe: probe)) }
                return true
            }
            var launched = 0
            while launched < concurrency, addNext() { launched += 1 }
            for await (order, candidate) in group {
                if let candidate {
                    found.append((order, candidate))
                    onFound?(candidate)
                }
                checked += 1
                onProgress?(checked, targets.count)
                _ = addNext()
            }
        }
        return found.sorted { $0.order < $1.order }.map(\.candidate)
    }

    /// What one address's verdict means to the walk down a machine's addresses. A name that does
    /// not resolve is the only answer worth trying another address on — MagicDNS being off says
    /// nothing whatever about the machine — while a refusal or a silence is that machine's answer
    /// however it was addressed, and asking it again by its number only spends the timeout twice.
    public enum Step: Sendable, Equatable {
        case found
        case notIt
        case tryNext
    }

    public static func step(for verdict: PortReachability.Verdict) -> Step {
        switch verdict {
        case .listening: return .found
        case .nameNotResolved: return .tryNext
        case .refused, .timedOut: return .notIt
        }
    }

    private static func ask(_ target: Target, probe: Probe) async -> ForgeCandidate? {
        for host in target.hosts {
            switch step(for: await probe(host, port)) {
            case .found:
                return ForgeCandidate(
                    machine: target.machine, host: host, port: port, os: target.os,
                    lastSeen: target.lastSeen)
            case .tryNext:
                continue
            case .notIt:
                return nil
            }
        }
        return nil
    }
}

/// The scan as something to draw: what it is doing, what it has found, and where every machine sits
/// on the dial. The radar is `TailnetRadar`'s arithmetic unchanged, so a renderer scan and a server
/// scan are the same picture at the same speed with the same constellation.
public struct ForgeSweepReading: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case rest
        /// This machine cannot scan, because it is not on a tailnet to scan. The reading carries
        /// the reason and the remedy rather than an empty result that would read as "nothing here".
        case blocked(TailscaleReading)
        case scanning(checked: Int, total: Int)
        case done
    }

    public private(set) var stage: Stage
    public private(set) var machines: Int
    public private(set) var found: [ForgeCandidate]
    public private(set) var blips: [RadarBlip]

    public init() {
        stage = .rest
        machines = 0
        found = []
        blips = []
    }

    public init(blocked reading: TailscaleReading) {
        self.init()
        stage = .blocked(reading)
    }

    public var isScanning: Bool {
        if case .scanning = stage { return true }
        return false
    }

    /// Every machine about to be asked takes its place on the dial before a single probe lands, so
    /// the reader watches a known sky light up rather than watching one appear.
    public mutating func began(_ targets: [ForgeSweep.Target], at time: TimeInterval) {
        machines = targets.count
        found = []
        blips = targets.map { RadarBlip(key: $0.machine, tone: .pending, bornAt: time) }
        stage = .scanning(checked: 0, total: targets.count)
    }

    public mutating func advanced(checked: Int, total: Int) {
        guard isScanning else { return }
        stage = .scanning(checked: checked, total: total)
    }

    public mutating func found(_ candidate: ForgeCandidate, at time: TimeInterval) {
        if !found.contains(where: { $0.id == candidate.id }) { found.append(candidate) }
        guard let index = blips.firstIndex(where: { $0.key == candidate.machine }) else {
            blips.append(RadarBlip(key: candidate.machine, tone: .ready, bornAt: time))
            return
        }
        blips[index] = RadarBlip(key: candidate.machine, tone: .ready, bornAt: blips[index].bornAt)
    }

    /// The end of the scan, which keeps only what answered. A pending blip that never lit is a
    /// machine that is not the renderer, and leaving it on the dial would read as a maybe.
    public mutating func finished() {
        blips = blips.filter { $0.tone == .ready }
        stage = .done
    }

    public var title: String {
        switch stage {
        case .rest:
            return Localized.text("Find my renderer")
        case .blocked(let reading):
            return reading.title
        case .scanning:
            return Localized.text("Asking %@ machines…", "\(machines)")
        case .done:
            return found.isEmpty
                ? Localized.text("No renderer answered")
                : Localized.text("%@ found", "\(found.count)")
        }
    }

    public var detail: String {
        switch stage {
        case .rest:
            return Localized.text(
                "Ask every machine on your tailnet which one answers on %@.", "\(ForgeSweep.port)")
        case .blocked(let reading):
            return reading.detail
                ?? Localized.text("There is no tailnet to scan from this machine yet.")
        case .scanning(let checked, let total):
            return Localized.text("Asked %@ of %@.", "\(checked)", "\(total)")
        case .done:
            return found.isEmpty
                ? Localized.text(
                    "Asked %@ machines on port %@. Start ComfyUI on the machine with the card, then scan again.",
                    "\(machines)", "\(ForgeSweep.port)")
                : Localized.text("Across %@ machines on your tailnet.", "\(machines)")
        }
    }

    public var actionTitle: String? {
        switch stage {
        case .rest: return Localized.text("Scan my tailnet")
        case .blocked(let reading): return reading.actionTitle
        case .scanning: return nil
        case .done: return Localized.text("Scan again")
        }
    }

    public var tone: ActivityTone {
        switch stage {
        case .rest: return .quiet
        case .blocked: return .attention
        case .scanning: return .live
        case .done: return found.isEmpty ? .attention : .live
        }
    }
}

/// What a scan needs before it can run at all on a device with no `tailscale` binary to ask.
///
/// A desk asks its own Tailscale for the list of machines. A phone cannot — Tailscale there is
/// another app inside another sandbox — so the machines come from the Tailscale API and a key is the
/// price of the list. That makes the key a precondition of the whole screen rather than a button
/// that appears unexplained once the dial has already been drawn; and a key that was refused is
/// replaced, never scanned again with, which is the difference between the two readings here.
public struct ForgeSweepKey: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let tone: ActivityTone

    /// Nothing has been given yet, which is where a phone that has only ever typed addresses is.
    public static var missing: ForgeSweepKey {
        ForgeSweepKey(
            title: Localized.text("A tailnet key first"),
            detail: Localized.text(
                "This device cannot ask Tailscale which machines are on your tailnet, so a scan reads the list from the Tailscale API. A key with Devices read access is the whole of what it needs."
            ),
            actionTitle: Localized.text("Set up tailnet access"),
            tone: .attention)
    }

    /// The key this device holds was not accepted, which no number of scans will change.
    public static var rejected: ForgeSweepKey {
        ForgeSweepKey(
            title: Localized.text("That key was refused"),
            detail: Localized.text(
                "Tailscale would not accept the key this device holds. Keys expire and can be revoked — replace it and the scan runs."
            ),
            actionTitle: Localized.text("Update the key"),
            tone: .danger)
    }
}

/// What the setup knows about the address in the field: whether it reads, whether it was asked, and
/// what it said. One value so a client draws one status line and branches on nothing except a
/// failure, which carries its own fix.
public struct ForgeSetupReading: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case blank
        case unreadable
        /// A parseable address nobody has asked yet.
        case ready
        case checking
        case listening
        case failed
    }

    public let stage: Stage
    public let title: String
    public let detail: String
    public let tone: ActivityTone
    /// Present exactly when the stage is `failed`, carrying the sentence and the one action that
    /// would fix it — the same value the server flow's failures carry.
    public let diagnosis: ConnectDiagnosis?

    init(
        stage: Stage, title: String, detail: String, tone: ActivityTone,
        diagnosis: ConnectDiagnosis? = nil
    ) {
        self.stage = stage
        self.title = title
        self.detail = detail
        self.tone = tone
        self.diagnosis = diagnosis
    }
}

/// What pressing something in the setup means to the client. Nothing here is a sentence — every
/// word is already on the button — and nothing here is a decision: a client runs the action and
/// hands the answer back.
public enum ForgeSetupAction: Sendable, Equatable {
    case nothing
    /// Ask the port. The client calls `checking()`, awaits `ForgeEndpoint.reach()`, then `reached(_:)`.
    case check(ForgeEndpoint)
    /// File it and use it: `ForgeStore.remember(renderer)`.
    case save(ForgeRenderer)
    /// Sweep the tailnet. The client supplies the peer list its platform can get.
    case scan
    /// The failure's own remedy, wired the same way every other `ConnectDiagnosis` is.
    case fix(ConnectDiagnosis.Fix)
}

public struct ForgeSetupButton: Sendable, Equatable {
    public let title: String
    public let action: ForgeSetupAction
    public let isEnabled: Bool

    init(_ title: String, _ action: ForgeSetupAction, isEnabled: Bool = true) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// The setup surface's own shape: which parts it has and the order a reader meets them in.
///
/// Three clients drew the same five parts in three different orders — the Mac put the machines
/// already used above the scan, the Linux window led with an empty list and buried the form below
/// the fold — so the walk a person takes was a different walk on every desk. The order is therefore
/// a fact of Core's, in the order the decision is actually made: what this surface is and whether
/// this machine can even ask (intro), the way in that is not typing (find), the machines that have
/// already answered (known), the address as typed (address), and what became of it with the one
/// press that settles it (outcome).
public enum ForgeSetupArea: String, Sendable, Equatable, CaseIterable {
    case intro
    case find
    case known
    case address
    case outcome
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

    /// What starts the thing being looked for, handed over the way the server flow hands over its
    /// install command — a line to copy and run on the other machine, never an instruction to go
    /// and read a manual. `--listen` is the whole point: a ComfyUI bound to localhost is invisible
    /// from every other machine on the tailnet, which is the commonest way this fails.
    public static var startCommand: String {
        "python main.py --listen 0.0.0.0 --port \(ForgeSweep.port)"
    }

    public static var startCommandTitle: String { Localized.text("Copy the start command") }

    public private(set) var typed: String
    public private(set) var name: String
    public private(set) var stage: ForgeSetupReading.Stage
    /// What the port last said, kept because it decides whether saving an unanswered address is
    /// worth offering: a machine asleep may be the right one, a name that does not resolve is not.
    public private(set) var verdict: PortReachability.Verdict?
    public private(set) var diagnosis: ConnectDiagnosis?
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

/// The control that opens the forge, and what it says on each of the three desks.
///
/// Video generation was reachable through a settings menu on one client and a menu-bar item on
/// another, which is where a preference lives rather than where an action does. It is an action —
/// the same weight as starting a chat — so it gets a control of its own beside the app's other
/// primary ones, wearing one title, one symbol and one glyph everywhere.
public enum ForgeEntryPoint {
    public static var title: String { ForgeBoard.heading }

    /// The title on a menu row, where the ellipsis is the convention for "this opens something".
    public static var menuTitle: String { Localized.text("Video…") }

    /// SF Symbols for the Apple clients; the text clients map it to `glyph`, the way every other
    /// toolkit-free icon in this package is carried.
    public static var symbol: String { "film.stack" }

    public static var glyph: String { "▶" }

    /// What the control promises, which is a different promise before a renderer exists: one opens
    /// a box you describe a video in, the other opens the setup that makes that possible.
    public static func tooltip(configured: Bool) -> String {
        configured
            ? Localized.text("Describe a video and watch it be made")
            : Localized.text("Set up the machine that makes videos")
    }

    public static func accessibilityLabel(rendering: Bool) -> String {
        rendering ? Localized.text("Video — rendering") : title
    }

    /// The mark the control wears while a render is out, so a person who closed the surface can
    /// still see that the other machine is working. Nil when nothing is running — a badge on an
    /// idle control is a decoration, and this vocabulary has none.
    public static func activity(rendering: Bool) -> ActivityKind? {
        rendering ? .working : nil
    }
}

/// How the forge is presented, which is the thing every desktop had wrong.
///
/// A render is a task you start, watch and collect. It is not a place you work, so it does not earn
/// half of a window the way a second conversation does — tiling it beside a chat spends the
/// transcript's width on a surface nobody types into for four minutes, and leaves the pane behind
/// afterwards. So it opens over the window and closes back to it, on every desk: a modal on the
/// desktops, a presented screen on the phone.
///
/// The one thing dismissal must not do is stop the render. The job lives above the surface — the
/// way `ForgeRunner` already holds it on iOS — so closing is closing a window, not cancelling four
/// minutes of somebody else's card, and the surface says so while a render is out.
public enum ForgeSurface {
    public static var title: String { ForgeEntryPoint.title }

    public static var subtitle: String { ForgeBoard.notice }

    public static var dismissTitle: String { Localized.text("Done") }

    /// What closing means while something is rendering. Nil when nothing is — there is nothing to
    /// reassure anybody about.
    public static func dismissNote(rendering: Bool) -> String? {
        guard rendering else { return nil }
        return Localized.text(
            "Closing this leaves the render running on the machine with the card. Come back and it will still be here."
        )
    }

    /// The size the modal opens at on a desktop, so a Mac sheet and a GTK window are the same
    /// surface rather than two shapes that happen to share a name. Tall enough for the renderer,
    /// the render, seven settings and the first clips without scrolling.
    public static let preferredWidth: Double = 680
    public static let preferredHeight: Double = 820
    public static let minimumWidth: Double = 480
    public static let minimumHeight: Double = 560
}

/// The setup's rules, checked headlessly — the parser, the sweep, every sentence a failure can
/// produce, and the one rule that is the renderer's own rather than the server flow's. Run from
/// `ForgeBoardCheck` so both desktops' `--selftest` carry it without a third call site.
public enum ForgeSetupCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let arch = ForgeEndpoint(host: "arch")
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        expect(setup.status.stage == .blank, "a setup with nothing typed is blank")
        expect(!setup.primary.isEnabled, "and its button does nothing")
        expect(setup.primary.action == .nothing, "which it says by offering no action")
        expect(setup.commit == nil, "nothing is filed from an empty field")
        expect(setup.tailnetLine.contains("100.64.0.9"), "the surface states this machine's own address")

        setup.type("0.0.0.0:8188")
        expect(setup.status.stage == .unreadable, "the address a server binds to is not one to reach")
        expect(setup.status.detail == ForgeEndpoint.complaint(.bindAll), "and the refusal is Core's own sentence")
        expect(!setup.primary.isEnabled, "which nothing can be checked from")

        setup.type("arch")
        expect(setup.status.stage == .ready, "a bare machine name reads")
        expect(setup.endpoint == arch, "as the machine and the port it answers on")
        expect(setup.hint == Localized.text("→ %@ (port added)", "arch:8188"), "and the supplied port is said out loud")
        expect(setup.primary.action == .check(arch), "the button asks the port")
        expect(setup.commit == nil, "and nothing is filed before it answers")

        setup.checking()
        expect(setup.status.stage == .checking, "asking is a state with its own words")
        expect(!setup.primary.isEnabled, "and nothing is pressed twice")

        setup.reached(.listening)
        expect(setup.status.stage == .listening, "a port that answered settles it")
        expect(setup.commit?.endpoint == arch, "and the renderer is ready to file")
        expect(setup.secondary == nil, "with nothing else to offer")
        expect(setup.status.diagnosis == nil, "and nothing to explain")

        setup.reached(.timedOut)
        expect(setup.status.stage == .failed, "silence is a failure")
        expect(setup.status.diagnosis != nil, "that explains itself")
        expect(setup.commit == nil, "and files nothing")
        expect(
            setup.secondary?.action == .save(ForgeRenderer(endpoint: arch, name: setup.name)),
            "but a renderer that sleeps may still be the right machine")
        expect(setup.secondaryNote != nil, "and saving it anyway says why")
        expect(setup.primary.action == .check(arch), "while the ordinary press asks again")

        setup.reached(.refused)
        expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand),
            "a machine that is up with nothing listening is handed the line that starts it")
        expect(setup.secondary != nil, "and can still be saved for later")

        setup.reached(.nameNotResolved)
        expect(setup.secondary == nil, "a name this machine cannot resolve is never filed")

        var offline = ForgeSetup(tailnet: .loggedOut)
        offline.type("arch")
        offline.reached(.timedOut)
        expect(offline.status.diagnosis?.fix == .openTailscale,
            "a probe from a machine with no tailnet blames the tailnet rather than the renderer")
        expect(!offline.discovery.isEnabled, "and there is nothing to scan from here")
        expect(offline.discoveryBlock?.fix == .openTailscale,
            "so the scan that cannot run says why and offers the one door out rather than greying out")
        expect(ForgeSetup(tailnet: .up(address: "100.64.0.9")).discovery.action == .scan, "while a connected one can sweep")
        expect(ForgeSetup(tailnet: .up(address: "100.64.0.9")).discoveryBlock == nil, "with nothing in its way to explain")

        let candidate = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        var adopted = ForgeSetup()
        adopted.adopt(candidate)
        expect(adopted.status.stage == .listening, "a machine a scan found has already answered")
        expect(adopted.commit?.name == "arch", "and it brings the name the tailnet gave it")
        expect(adopted.commit?.endpoint == candidate.endpoint, "at the address it answered on")

        let devices = [
            TailscaleDevice(
                name: "arch.tail1234.ts.net", hostname: "arch", addresses: ["100.64.0.3", "fd7a::3"],
                os: "linux", lastSeen: nil),
            TailscaleDevice(
                name: "phone.tail1234.ts.net", hostname: "phone", addresses: ["100.64.0.4"],
                os: "iOS", lastSeen: nil),
            TailscaleDevice(
                name: "mac.tail1234.ts.net", hostname: "macbook", addresses: ["100.64.0.5"],
                os: "macOS", lastSeen: nil),
        ]
        let targets = ForgeSweep.targets(devices)
        expect(targets.map(\.machine) == ["arch", "macbook"], "a phone can never hold a card, so it is not asked")
        expect(targets[0].hosts == ["arch.tail1234.ts.net", "100.64.0.3"],
            "each machine is asked by name first and by one address behind it")

        expect(ForgeSweep.step(for: .listening) == .found, "a port that answered is the machine")
        expect(
            ForgeSweep.step(for: .nameNotResolved) == .tryNext,
            "MagicDNS being off says nothing about the machine, so its number is tried next")
        expect(ForgeSweep.step(for: .refused) == .notIt, "a machine that refused is not it")
        expect(
            ForgeSweep.step(for: .timedOut) == .notIt,
            "and one that said nothing is not asked twice — the second address would only spend the timeout again")

        let candidate2 = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        expect(candidate2.detail.contains("100.64.0.3:8188"), "a found machine says where it answered")
        expect(candidate2.renderer.name == "arch", "and carries the name the tailnet gave it")

        var sweep = ForgeSweepReading()
        expect(sweep.actionTitle == Localized.text("Scan my tailnet"), "a dial nobody has spun offers to spin")
        expect(!sweep.isScanning, "and is not scanning")
        sweep.began(targets, at: 0)
        expect(sweep.blips.count == 2, "every machine takes its place before a probe lands")
        expect(sweep.blips.allSatisfy { $0.tone == .pending }, "unlit until it answers")
        expect(sweep.isScanning, "and the dial is turning")
        sweep.advanced(checked: 1, total: 2)
        expect(sweep.detail == Localized.text("Asked %@ of %@.", "1", "2"), "the wait counts itself")
        sweep.found(candidate2, at: 0.4)
        expect(sweep.blips.first { $0.key == "arch" }?.tone == .ready, "a machine that answers lights")
        sweep.finished()
        expect(sweep.blips.count == 1, "and one that never did leaves the dial rather than reading as a maybe")
        expect(sweep.title == Localized.text("%@ found", "1"), "the result is a count")
        expect(sweep.actionTitle == Localized.text("Scan again"), "and the dial can be spun again")

        var empty = ForgeSweepReading()
        empty.began(targets, at: 0)
        empty.finished()
        expect(empty.title == Localized.text("No renderer answered"), "a sweep that found nothing says so")
        expect(empty.detail.contains("\(ForgeSweep.port)"), "and names the port it asked on")

        let blocked = ForgeSweepReading(blocked: .notInstalled)
        expect(blocked.title == TailscaleReading.notInstalled.title, "a machine with no tailnet cannot scan one")
        expect(blocked.actionTitle == TailscaleReading.notInstalled.actionTitle, "and is offered the fix rather than a result")

        expect(ForgeSweepKey.missing.actionTitle != ForgeSweepKey.rejected.actionTitle,
            "a key never given and a key refused are fixed by different presses")
        expect(ForgeSweepKey.rejected.tone == .danger, "a key the tailnet would not accept is a failure")
        expect(ForgeSweepKey.missing.tone == .attention, "while one that was never given is only a step not taken")

        let renderer = ForgeRenderer(endpoint: arch, name: "  arch  ")
        expect(renderer.name == "arch", "a name is trimmed before it is kept")
        expect(ForgeRenderer(endpoint: arch, name: "   ").name == nil, "and whitespace is no name at all")
        expect(renderer.title == "arch" && renderer.detail == "arch:8188", "a row says the machine and the address")
        expect(ForgeRenderer(endpoint: arch).title == "arch", "an address typed blind still names itself")
        expect(ForgeRenderer.badge(current: true) != nil, "the machine in use wears a word")
        expect(ForgeRenderer.badge(current: false) == nil, "and the others do not")

        expect(ForgeEntryPoint.tooltip(configured: true) != ForgeEntryPoint.tooltip(configured: false),
            "the control promises something different before a renderer exists")
        expect(ForgeEntryPoint.activity(rendering: true) == .working, "and wears a live mark while one is out")
        expect(ForgeEntryPoint.activity(rendering: false) == nil, "but never an idle decoration")
        expect(ForgeSurface.dismissNote(rendering: true) != nil, "closing over a render says what it does not do")
        expect(ForgeSurface.dismissNote(rendering: false) == nil, "and says nothing when there is nothing to say")
        expect(ForgeSurface.title == ForgeBoard.heading, "the control, the modal and the surface share one name")
        expect(ForgeSurface.subtitle == ForgeBoard.notice, "and the modal carries the board's own line about where rendering happens")
        expect(ForgeSweep.deadline > ForgeSweep.probeTimeout, "a scan outlives any one probe in it")
        expect(ForgeSurface.preferredWidth >= ForgeSurface.minimumWidth, "the modal's sizes are consistent")
        expect(ForgeSurface.preferredHeight >= ForgeSurface.minimumHeight, "in both directions")
        expect(ForgeSetup.startCommand.contains("--listen"), "the command handed over binds where the tailnet can reach it")
        expect(ForgeSetup.startCommand.contains("\(ForgeSweep.port)"), "on the port everything else asks")

        expect(
            ForgeSetup.order == [.intro, .find, .known, .address, .outcome],
            "the setup is met in one order on every desk: what this is, the way in that is not typing, the machines that already answered, the address as typed, and what became of it")
        expect(ForgeSetup.order == ForgeSetupArea.allCases, "and no area is left undrawn")

        for field in ForgeField.allCases {
            expect(
                field.isCyclable
                    ? (field.affordanceGlyph == "⇅" && field.affordanceSymbol == "chevron.up.chevron.down")
                    : (field.affordanceGlyph == "›" && field.affordanceSymbol == "chevron.right"),
                "a row that cycles and a row that opens wear different marks (\(field.rawValue))")
        }

        expect(ForgeJobPhase.running(0.5).activity == .working, "a render that is working breathes")
        expect(ForgeJobPhase.queued(2).activity == .queued(2), "a queued one waits with its count")
        expect(ForgeJobPhase.done(ForgeAsset(filename: "x.mp4")).activity == nil, "and a settled one holds still")
        expect(ForgeJobPhase.failed("x").tone == .danger, "a failure wears the danger slot")
        expect(ForgeJobPhase.failed("x").stageGlyph == "✕", "and its stage says so in one column")
        expect(
            ForgeJobPhase.done(ForgeAsset(filename: "x.mp4")).stageSymbol == "play.rectangle",
            "a finished stage offers the play it promises")
        return failures
    }
}
