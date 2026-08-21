import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// What this Mac can see of its own tailnet, asked of Tailscale itself.
///
/// The phone has to mint an API token before it can list anything, because iOS gives an app no way
/// to ask the daemon. A Mac is the Linux desk's situation rather than the phone's: `tailscale
/// status --json` is right there, it answers who is on the tailnet and who is awake, and it costs
/// nothing to run — so discovery here needs no credential at all. Where the command cannot be
/// found the scan says that, in those words, rather than reporting an empty tailnet.
struct DiscoverySurvey: Sendable {
    /// Which of the ways this machine can be off a tailnet it is — Core's reading, so the words
    /// are the same ones the first-run checklist uses.
    let reading: TailscaleReading
    /// Whether the CLI could be run at all. A machine with no `tailscale` command and one that is
    /// signed out both list no peers and mean entirely different things.
    let foundCLI: Bool
    /// The peers that are awake. A sleeping machine holds its port open and answers nothing, so
    /// probing one costs the scan a full timeout for a result that was never coming.
    let peers: [TailscaleDevice]

    /// The peers worth asking, in the scanner's own shape — which also drops the phones and TVs
    /// that could never run an agent.
    var scannable: [TailscaleDevice] { TailnetScanner.scannableDevices(peers) }

    static func read() -> DiscoverySurvey {
        #if TAILSCODE_MAS
            return DiscoverySurvey(reading: .sandboxed, foundCLI: false, peers: [])
        #else
            return survey()
        #endif
    }

    #if !TAILSCODE_MAS
        private static func survey() -> DiscoverySurvey {
            guard let binary = executable() else {
                return DiscoverySurvey(reading: .notInstalled, foundCLI: false, peers: [])
            }
            guard let data = run(binary),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return DiscoverySurvey(
                    reading: TailscaleReading.read(
                        found: true, sandboxed: false, backendState: nil, address: nil),
                    foundCLI: true, peers: [])
            }
            let node = root["Self"] as? [String: Any]
            let address = (node?["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
            let reading = TailscaleReading.read(
                found: true, sandboxed: false, backendState: root["BackendState"] as? String,
                address: address)
            let raw = Array((root["Peer"] as? [String: Any] ?? [:]).values)
            let peers: [TailscaleDevice] = raw.compactMap { value in
                guard let peer = value as? [String: Any],
                    (peer["Online"] as? Bool) == true,
                    let name = (peer["HostName"] as? String) ?? (peer["DNSName"] as? String),
                    let ip = (peer["TailscaleIPs"] as? [String])?
                        .first(where: { !$0.contains(":") })
                else { return nil }
                var dns = (peer["DNSName"] as? String) ?? ""
                while dns.hasSuffix(".") { dns.removeLast() }
                return TailscaleDevice(
                    id: ip, name: dns.isEmpty ? nil : dns, hostname: name, addresses: [ip],
                    os: (peer["OS"] as? String) ?? "", lastSeen: nil)
            }
            return DiscoverySurvey(
                reading: reading, foundCLI: true, peers: peers.sorted { $0.hostname < $1.hostname })
        }
    #endif

    /// A scan that never comes back is a spinner with extra steps: a peer that has gone to sleep
    /// mid-sweep neither accepts nor refuses, so the whole sweep is given a deadline and reports
    /// what it did find by then.
    static func within<T: Sendable>(
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

    #if !TAILSCODE_MAS
        /// Tailscale lands in four places on a Mac depending on how it was installed, and the App
        /// Store build ships its command line inside the app bundle rather than on the PATH.
        private static func executable() -> String? {
            [
                "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale",
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            ].first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// The exit status is deliberately not consulted: a signed-out daemon answers with JSON
        /// *and* a non-zero status, and that JSON is the only place `BackendState` says which state
        /// it is.
        private static func run(_ binary: String) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? nil : data
        }
    #endif
}

/// The dial, rasterised. Every number in it is Core's — where the arm is, how bright each machine
/// sits — so this Mac draws the same scan at the same speed as the GTK desk rather than an
/// animation that merely resembles it.
///
/// The clock is the display's own, and it stops the moment Core says the frame is settled: a scan
/// that has finished is a result, and repainting a result sixty times a second is a fan spinning
/// for nothing. Angle zero is straight up and the sweep turns the way a clock does, because that
/// is the only radar anybody has ever seen.
@MainActor
final class TailnetRadarView: NSView {
    private var link: CADisplayLink?
    private var blips: [RadarBlip] = []
    private var scanning = false
    private var current = TailnetRadar.frame(at: 0, blips: [], scanning: false)

    static var now: TimeInterval { CACurrentMediaTime() }

    static var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 168) }

    /// What the dial knows. Called as each machine answers, so the picture is the progress rather
    /// than a bar that fills beside it.
    func show(blips: [RadarBlip], scanning: Bool) {
        self.blips = blips
        self.scanning = scanning
        if scanning, Self.motionAllowed {
            start()
        } else {
            stop()
        }
        render(at: Self.now)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard scanning, Self.motionAllowed else { return }
        window == nil ? stop() : start()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A desk that asks for less motion mid-scan is honoured at once: the same dial is drawn at
    /// rest with everything it has already found on it, and nothing is hidden by taking the
    /// movement away.
    @objc private func motionPreferenceChanged() {
        show(blips: blips, scanning: scanning)
    }

    private func start() {
        guard link == nil, window != nil else { return }
        let made = displayLink(target: self, selector: #selector(step))
        made.add(to: .current, forMode: .common)
        link = made
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        render(at: link.timestamp)
    }

    private func render(at time: TimeInterval) {
        current = TailnetRadar.frame(
            at: time, blips: blips, scanning: scanning, reducedMotion: !Self.motionAllowed)
        needsDisplay = true
        if current.settled { stop() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let reach = min(bounds.width, bounds.height) / 2 - 3
        guard reach > 4 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        drawGrid(center: center, reach: reach)
        drawSweep(center: center, reach: reach)
        drawPing(center: center, reach: reach)
        drawSparks(center: center, reach: reach)
    }

    /// Rings at the distances Core named, and a faint cross, so an empty tailnet still looks like
    /// an instrument rather than a blank circle.
    private func drawGrid(center: NSPoint, reach: CGFloat) {
        let ink = MacTheme.Color.tertiaryLabel
        ink.withAlphaComponent(0.22).setStroke()
        for ring in TailnetRadar.rings {
            let radius = reach * CGFloat(ring)
            guard radius > 0.5 else { continue }
            let path = NSBezierPath(ovalIn: Self.square(around: center, radius: radius))
            path.lineWidth = 1
            path.stroke()
        }
        let spokes = NSBezierPath()
        for spoke in 0..<4 {
            spokes.move(to: center)
            spokes.line(to: place(center, reach, Double(spoke) * .pi / 2, 0.98))
        }
        spokes.lineWidth = 1
        ink.withAlphaComponent(0.13).setStroke()
        spokes.stroke()
    }

    /// The arm and the light it drags behind it. A gradient cannot run along an arc, so the wake
    /// is laid down as narrow wedges whose alpha falls off the way Core's blip light does — the
    /// same curve, so the arm and the machines it crosses agree about where it has been.
    private func drawSweep(center: NSPoint, reach: CGFloat) {
        guard current.sweepLight > 0 else { return }
        let ink = MacTheme.Color.accent
        let span = TailnetRadar.wake
        let wedges = 48
        for wedge in 0..<wedges {
            let from = Double(wedge) / Double(wedges) * span
            let to = Double(wedge + 1) / Double(wedges) * span
            let alpha = exp(-from / 0.62) * 0.20 * current.sweepLight
            guard alpha >= 0.002 else { break }
            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(
                withCenter: center, radius: reach * 0.98,
                startAngle: Self.degrees(current.sweep - from),
                endAngle: Self.degrees(current.sweep - to), clockwise: false)
            path.close()
            ink.withAlphaComponent(CGFloat(alpha)).setFill()
            path.fill()
        }
        let arm = NSBezierPath()
        arm.move(to: center)
        arm.line(to: place(center, reach, current.sweep, 0.98))
        arm.lineWidth = 1.4
        arm.lineCapStyle = .round
        ink.withAlphaComponent(CGFloat(0.85 * current.sweepLight)).setStroke()
        arm.stroke()
    }

    private func drawPing(center: NSPoint, reach: CGFloat) {
        guard current.pingLight > 0 else { return }
        let radius = reach * CGFloat(current.ping)
        guard radius > 0.5 else { return }
        let path = NSBezierPath(ovalIn: Self.square(around: center, radius: radius))
        path.lineWidth = 1.2
        MacTheme.Color.accent.withAlphaComponent(CGFloat(current.pingLight)).setStroke()
        path.stroke()
    }

    /// One machine: a filled dot inside its own soft halo, in the ink its state earns.
    private func drawSparks(center: NSPoint, reach: CGFloat) {
        for spark in current.sparks {
            let ink = Self.ink(for: spark.tone)
            let size = CGFloat(3.2 * spark.scale)
            let at = place(center, reach, spark.angle, spark.radius)
            ink.withAlphaComponent(CGFloat(0.18 * spark.light)).setFill()
            NSBezierPath(ovalIn: Self.square(around: at, radius: size * 2.8)).fill()
            ink.withAlphaComponent(CGFloat(spark.light)).setFill()
            NSBezierPath(ovalIn: Self.square(around: at, radius: size)).fill()
        }
    }

    /// The three tones, in this window's palette: an agent that will connect wears affirmation, one
    /// that wants a password wears attention, and a machine still being asked keeps identity.
    private static func ink(for tone: RadarTone) -> NSColor {
        switch tone {
        case .ready: return MacTheme.Color.success
        case .locked: return MacTheme.Color.warning
        case .pending: return MacTheme.Color.info
        }
    }

    private func place(_ center: NSPoint, _ reach: CGFloat, _ angle: Double, _ radius: Double)
        -> NSPoint
    {
        NSPoint(
            x: center.x + CGFloat(sin(angle)) * reach * CGFloat(radius),
            y: center.y + CGFloat(cos(angle)) * reach * CGFloat(radius))
    }

    /// The dial's own angle in the degrees `NSBezierPath` measures, which run counter-clockwise
    /// from due east while the dial runs clockwise from due north.
    private static func degrees(_ angle: Double) -> CGFloat {
        CGFloat((Double.pi / 2 - angle) * 180 / .pi)
    }

    private static func square(around center: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Setting a machine up is a scan, not a form.
///
/// Everything this app talks to is already on the tailnet, so the address a person would type is
/// one this Mac can go and find: every awake peer is asked on both agent ports through the shared
/// `TailnetScanner`, and anything that answers becomes a row that adds itself. A machine already
/// configured says so instead of offering itself a second time, and a scan that finds nothing says
/// which peers it asked and why they came to nothing — an empty list is not an answer.
///
/// The wait is drawn rather than spun: `TailnetRadar` is the arithmetic and `TailnetRadarView` only
/// rasterises it, so a machine takes the place its own name gives it and a second scan puts it back
/// where the reader last saw it.
@MainActor
final class DiscoveryPanel {
    private static var active: [DiscoveryPanel] = []

    private let sheet: NSWindow
    private let onAdd: @MainActor (TailnetScanner.Suggestion) -> Void
    private let column = FillingStack()
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let radar = TailnetRadarView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let actionsRow = NSStackView()
    private let resultsColumn = FillingStack()
    private let resultsScroll: NSScrollView
    private let resultsHeight: NSLayoutConstraint

    private var blips: [RadarBlip] = []
    private var found: [TailnetScanner.Suggestion] = []
    private var configured: Set<String> = []
    private var scanning = false
    private var scanID = 0
    private var peerCount = 0
    private var startedAt = 0.0

    @discardableResult
    static func present(
        on host: NSWindow, configured: [ConnectionProfile],
        onAdd: @escaping @MainActor (TailnetScanner.Suggestion) -> Void
    ) -> DiscoveryPanel {
        let panel = DiscoveryPanel(onAdd: onAdd)
        panel.setConfigured(configured)
        active.append(panel)
        host.beginSheet(panel.sheet) { _ in
            active.removeAll { $0 === panel }
        }
        panel.scan()
        return panel
    }

    private init(onAdd: @escaping @MainActor (TailnetScanner.Suggestion) -> Void) {
        self.onAdd = onAdd
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("Find my machines")

        resultsColumn.spacing = MacTheme.Spacing.m
        resultsScroll = MacDialogs.scrollColumn(holding: resultsColumn)
        resultsHeight = resultsScroll.heightAnchor.constraint(equalToConstant: 0)
        resultsHeight.isActive = true

        heading.stringValue = Localized.text("Find my machines")
        subtitle.stringValue = Localized.text(
            "Every machine on your tailnet, asked on both agent ports.")
        statusDetail.isSelectable = true

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(radar)
        NSLayoutConstraint.activate([
            radar.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            radar.topAnchor.constraint(equalTo: holder.topAnchor),
            radar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            radar.widthAnchor.constraint(equalToConstant: 168),
            radar.heightAnchor.constraint(equalToConstant: 168),
        ])

        actionsRow.orientation = .horizontal
        actionsRow.spacing = MacTheme.Spacing.s

        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.close()
        }
        done.keyEquivalent = "\u{1B}"
        let footer = NSStackView(views: [RowKit.spacer(), done])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s

        for view in [
            heading, subtitle, holder, statusTitle, statusDetail, actionsRow, resultsScroll, footer,
        ] as [NSView] {
            column.addArrangedSubview(view)
        }
        column.spacing = MacTheme.Spacing.m
        column.setCustomSpacing(MacTheme.Spacing.xs, after: heading)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: statusTitle)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        sheet.contentView = column
        column.widthAnchor.constraint(equalToConstant: 560).isActive = true

        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        rest()
    }

    /// Which servers are already saved, so a machine the app already has offers a fact rather than
    /// a second copy of itself.
    func setConfigured(_ profiles: [ConnectionProfile]) {
        configured = Set(
            profiles.map { Self.key(host: $0.baseURL.host ?? "", port: $0.baseURL.port ?? 0) })
        renderResults()
    }

    /// Nothing outside the main window is reached by its restyle pass, and every colour and size
    /// here was resolved once at construction.
    @objc private func repaint() {
        applyTheme()
        renderResults()
        radar.needsDisplay = true
    }

    private func applyTheme() {
        heading.font = MacTheme.Ramp.font(.panelTitle)
        heading.textColor = MacTheme.Color.label
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        subtitle.textColor = MacTheme.Color.secondaryLabel
        statusTitle.font = MacTheme.Ramp.font(.cardTitle)
        statusTitle.textColor = MacTheme.Color.label
        statusDetail.font = MacTheme.Ramp.font(.panelFootnote)
        statusDetail.textColor = MacTheme.Color.secondaryLabel
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    private func rest() {
        setStatus(
            Localized.text("Nothing scanned yet"),
            detail: Localized.text("Ask every machine on your tailnet which agent it runs."),
            actions: [
                RowKit.ActionButton(title: Localized.text("Scan my tailnet")) { [weak self] in
                    self?.scan()
                }
            ])
        radar.show(blips: blips, scanning: false)
    }

    func scan() {
        guard !scanning else { return }
        scanID += 1
        let id = scanID
        scanning = true
        blips = []
        found = []
        peerCount = 0
        startedAt = TailnetRadarView.now
        renderResults()
        setStatus(Localized.text("Reading your tailnet…"), detail: "", actions: [])
        radar.show(blips: blips, scanning: true)

        Task { [weak self] in
            let survey = await Task.detached(priority: .userInitiated) {
                DiscoverySurvey.read()
            }.value
            guard let self, self.scanID == id else { return }
            let devices = survey.scannable
            self.peerCount = devices.count
            guard !devices.isEmpty else {
                let blocked = Self.blocked(survey)
                self.finish(id: id, blocked: blocked)
                return
            }
            self.setStatus(Self.asking(devices.count), detail: "", actions: [])

            let scanner = TailnetScanner()
            let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.scanID == id else { return }
                    self.setStatus(
                        Self.asking(self.peerCount),
                        detail: Localized.text("Asked %@ of %@ ports.", "\(done)", "\(total)"),
                        actions: [])
                }
            }
            let sighted: @Sendable (TailnetScanner.Suggestion) -> Void = { [weak self] suggestion in
                Task { @MainActor in
                    guard let self, self.scanID == id else { return }
                    self.light(suggestion)
                }
            }
            let complete = await DiscoverySurvey.within(30) {
                await scanner.scan(devices: devices, onProgress: report, onFound: sighted)
            }
            guard self.scanID == id else { return }
            guard let complete else {
                self.finish(
                    id: id,
                    stalled: Localized.text(
                        "Some machines never answered — a peer that is asleep holds the port open and says nothing."
                    ))
                return
            }
            self.found = complete
            self.blips = complete.map { self.blip(for: $0, bornAt: self.startedAt) }
            self.finish(id: id)
        }
    }

    /// A machine takes its place on the dial the moment it answers rather than when the whole sweep
    /// is over — the picture is the progress, so it has to move while the scan runs. A better
    /// address for a machine already on the dial replaces it in place, keeping the spot its name
    /// earned rather than lighting the same server twice.
    private func light(_ suggestion: TailnetScanner.Suggestion) {
        if let index = found.firstIndex(where: { $0.dedupeKey == suggestion.dedupeKey }) {
            guard TailnetScanner.preferred(suggestion, over: found[index]) else { return }
            found[index] = suggestion
            blips[index] = blip(for: suggestion, bornAt: blips[index].bornAt)
        } else {
            found.append(suggestion)
            blips.append(blip(for: suggestion, bornAt: TailnetRadarView.now))
        }
        radar.show(blips: blips, scanning: scanning)
        renderResults()
    }

    private func blip(for suggestion: TailnetScanner.Suggestion, bornAt: Double) -> RadarBlip {
        RadarBlip(
            key: suggestion.dedupeKey, tone: suggestion.requiresAuth ? .locked : .ready,
            bornAt: bornAt)
    }

    /// Every way a scan can end, said in words. Finding nothing is an outcome with a cause, and the
    /// cause is what a person acts on — never an empty list under a heading.
    private func finish(
        id: Int, blocked: (title: String, detail: String)? = nil, stalled: String? = nil
    ) {
        guard scanID == id else { return }
        scanning = false
        renderResults()
        radar.show(blips: blips, scanning: false)
        let again = RowKit.ActionButton(title: Localized.text("Scan again")) { [weak self] in
            self?.scan()
        }
        if let blocked {
            setStatus(blocked.title, detail: blocked.detail, actions: [again])
        } else if let stalled, !found.isEmpty {
            setStatus(Self.count(found.count), detail: stalled, actions: [again])
        } else if let stalled {
            setStatus(Localized.text("Nothing answered in time"), detail: stalled, actions: [again])
        } else if found.isEmpty {
            let copy = RowKit.ActionButton(title: Localized.text("Copy the install command")) {
                [weak self] in
                RowKit.copyToClipboard(BridgeInstall.installCommand)
                self?.setStatus(
                    Localized.text("Install command copied"),
                    detail: Localized.text(
                        "Run it on the machine you code on, then scan again."),
                    actions: [
                        RowKit.ActionButton(title: Localized.text("Scan again")) { [weak self] in
                            self?.scan()
                        }
                    ])
            }
            setStatus(
                Localized.text("No agents answered"), detail: Self.askedNothingAnswered(peerCount),
                actions: [copy, again])
        } else {
            setStatus(Self.count(found.count), detail: Self.across(peerCount), actions: [again])
        }
    }

    /// Why there was nothing to ask. Four different states share an empty peer list and only one of
    /// them is "your tailnet is quiet", so each says which it is in Core's own words.
    private static func blocked(_ survey: DiscoverySurvey) -> (title: String, detail: String) {
        guard survey.foundCLI else {
            return (
                Localized.text("Tailscale's command line isn't on this Mac"),
                Localized.text(
                    "Discovery asks Tailscale itself which machines are on your tailnet. Install Tailscale, or type the address by hand — the field behind this sheet needs nothing installed."
                )
            )
        }
        guard survey.reading.isUp else {
            return (
                survey.reading.title,
                survey.reading.detail
                    ?? Localized.text(
                        "This Mac is not on a tailnet, so there is nothing to look at.")
            )
        }
        guard survey.peers.isEmpty else {
            return (
                Localized.text("Nothing to ask"),
                Localized.text(
                    "Everything awake on your tailnet is a phone or a tablet, and neither can run an agent."
                )
            )
        }
        return (
            Localized.text("Nothing to add"),
            Localized.text("No other machine on your tailnet is awake right now.")
        )
    }

    /// One is a machine, two are machines. A count spliced into a sentence has to carry its own
    /// grammar or the app reads like a log line.
    private static func asking(_ value: Int) -> String {
        value == 1
            ? Localized.text("Asking 1 machine…") : Localized.text("Asking %@ machines…", "\(value)")
    }

    private static func count(_ value: Int) -> String {
        value == 1 ? Localized.text("1 found") : Localized.text("%@ found", "\(value)")
    }

    private static func across(_ value: Int) -> String {
        value == 1
            ? Localized.text("Across 1 machine on your tailnet.")
            : Localized.text("Across %@ machines on your tailnet.", "\(value)")
    }

    private static func askedNothingAnswered(_ value: Int) -> String {
        value == 1
            ? Localized.text(
                "Asked 1 machine on both ports. Run the install command on the machine you code on, then scan again."
            )
            : Localized.text(
                "Asked %@ machines on both ports. Run the install command on the machine you code on, then scan again.",
                "\(value)")
    }

    private static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    private func setStatus(_ title: String, detail: String, actions: [NSButton]) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusDetail.isHidden = detail.isEmpty
        actionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions { actionsRow.addArrangedSubview(action) }
        actionsRow.addArrangedSubview(RowKit.spacer())
        actionsRow.isHidden = actions.isEmpty
        resize()
    }

    private func renderResults() {
        resultsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in found {
            resultsColumn.addArrangedSubview(makeRow(suggestion))
        }
        resultsScroll.isHidden = found.isEmpty
        resize()
    }

    private func resize() {
        resultsColumn.layoutSubtreeIfNeeded()
        resultsHeight.constant = found.isEmpty ? 0 : min(resultsColumn.fittingSize.height, 320)
        sheet.setContentSize(column.fittingSize)
    }

    private func makeRow(_ suggestion: TailnetScanner.Suggestion) -> NSView {
        let badge = NSImageView()
        badge.image = NSImage(
            systemSymbolName: suggestion.requiresAuth ? "lock.fill" : "checkmark.circle.fill",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 12 * MacTheme.UIScale.factor, weight: .semibold))
        badge.contentTintColor =
            suggestion.requiresAuth ? MacTheme.Color.warning : MacTheme.Color.success
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setAccessibilityElement(false)

        let title = RowKit.label(
            suggestion.recommendedProfileName, font: MacTheme.Ramp.font(.rowTitle),
            color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = MacDialogs.detailLabel(Self.detail(suggestion))
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2

        let trailing: NSView
        if configured.contains(
            Self.key(host: suggestion.baseURL.host ?? "", port: suggestion.baseURL.port ?? 0))
        {
            trailing = MacDialogs.detailLabel(Localized.text("Already added"))
        } else {
            trailing = RowKit.ActionButton(title: Localized.text("Add")) { [weak self] in
                self?.onAdd(suggestion)
            }
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [badge, lines, RowKit.spacer(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        return row
    }

    private static func detail(_ suggestion: TailnetScanner.Suggestion) -> String {
        var parts = [ServerLabel.agent(suggestion.backend)]
        if let host = suggestion.baseURL.host, let port = suggestion.baseURL.port {
            parts.append("\(host):\(port)")
        }
        if let version = suggestion.version, !version.isEmpty { parts.append(version) }
        if suggestion.requiresAuth { parts.append(Localized.text("wants a password")) }
        return parts.joined(separator: " · ")
    }
}
