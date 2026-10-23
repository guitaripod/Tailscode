import CodingAgentKit
import Foundation

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
