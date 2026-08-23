import AppKit
import CodingAgentKit
import Foundation
import TailscodeCore

/// Pointing at the renderer, held to the standard adding a server is held to.
///
/// The renderer used to be one free-text field in an `NSAlert`: typed blind, saved unchecked,
/// forgotten on the next reinstall. A server on this Mac is none of those things — it states what
/// this machine's own tailnet address is, sweeps the tailnet rather than demanding a hostname,
/// probes what it is given before saving it, explains a failure in a sentence that names the fix,
/// and remembers what worked. This is that flow for the machine with the card, and every word and
/// every rule in it is `ForgeSetup`'s: the sheet owns a text field, three lists, a dial and some
/// buttons, and decides nothing.
///
/// A sheet presented from a local is a sheet whose buttons do nothing — AppKit holds the window and
/// nothing holds the controller behind it — so this one is retained for exactly as long as it is on
/// screen, the way `DiscoveryPanel` is.
@MainActor
final class ForgeSetupSheet: NSObject {
    private static var active: [ForgeSetupSheet] = []

    private let sheet: NSWindow
    private let onSaved: @MainActor () -> Void

    private var setup: ForgeSetup
    private var sweep = ForgeSweepReading()

    private let column = FillingStack()
    /// The sheet's own surface. It hangs off the forge, which paints the theme's canvas edge to
    /// edge, and a form standing on AppKit's window background instead would be a different colour
    /// the moment a palette is in force.
    private let ground = RowKit.Ground(frame: .zero)
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let tailnetLine = NSTextField(wrappingLabelWithString: "")
    private let tailnetRemedy = TailnetRemedyView()

    private let knownHeader = MacDialogs.sectionHeader("")
    private let knownColumn = FillingStack()

    private let sweepHeader = MacDialogs.sectionHeader("")
    private let radar = TailnetRadarView()
    private let sweepTitle = NSTextField(labelWithString: "")
    private let sweepDetail = NSTextField(wrappingLabelWithString: "")
    private let sweepActions = NSStackView()
    private let foundColumn = FillingStack()

    private let addressHeader = MacDialogs.sectionHeader("")
    private let addressField = NSTextField()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let nameField = NSTextField()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let statusActions = NSStackView()
    private let copiedLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()

    /// Every machine the tailnet last reported, kept from the survey so a second scan does not shell
    /// out to `tailscale` again for a list that has not changed under it.
    private var peers: [TailscaleDevice] = []
    private var scanID = 0
    /// The sweep in flight. `scanID` only makes a late answer harmless; the probes themselves are a
    /// fan-out at every machine on the tailnet, and a sheet that is gone must not leave thirty of
    /// them running to Core's deadline — nor have a second sheet's scan land on top of the first.
    private var sweepTask: Task<Void, Never>?
    /// Why a sweep cannot run, when it cannot. Held rather than derived, because it is read off two
    /// separate questions about Tailscale and the answer decides both what the dial says and where
    /// its button goes.
    private var sweepBlock: TailscaleReading?
    /// The command a copy put on the clipboard, kept beside the failure that offered it. A copy that
    /// leaves nothing on screen is indistinguishable from a button that did nothing.
    private var copied: (command: String, of: ConnectDiagnosis)?
    private var checking = false
    private var writing = false

    /// As wide as the servers window, because this is the servers window's job done for a different
    /// kind of machine: an address, a dial and a list of machines, none of them wrapping.
    private static let width: CGFloat = 560

    @discardableResult
    static func present(on host: NSWindow, onSaved: @escaping @MainActor () -> Void)
        -> ForgeSetupSheet
    {
        let made = ForgeSetupSheet(onSaved: onSaved)
        active.append(made)
        host.beginSheet(made.sheet) { _ in
            made.release()
            active.removeAll { $0 === made }
        }
        made.sheet.makeFirstResponder(made.addressField)
        made.readTailnet()
        made.render()
        return made
    }

    private init(onSaved: @escaping @MainActor () -> Void) {
        self.onSaved = onSaved
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            deviceName: Localized.text("This Mac"))

        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.isReleasedWhenClosed = false
        sheet.title = ForgeSetup.title

        build()
        applyTheme()
        writing = true
        addressField.stringValue = setup.typed
        nameField.stringValue = setup.name
        writing = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        render()
    }

    private func build() {
        addressField.placeholderString = ForgeSetup.addressPlaceholder
        addressField.toolTip = ForgeSetup.addressHelp
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.delegate = self
        nameField.placeholderString = ForgeSetup.nameLabel
        nameField.delegate = self

        statusDetail.isSelectable = true
        copiedLabel.isSelectable = true
        noteLabel.isSelectable = true

        for row in [sweepActions, statusActions, buttonRow] {
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
        }
        knownColumn.spacing = MacTheme.Spacing.s
        foundColumn.spacing = MacTheme.Spacing.s

        column.spacing = MacTheme.Spacing.m
        for view in [
            heading, subtitle, tailnetLine, tailnetRemedy,
            sweepHeader, dialHolder(), sweepTitle, sweepDetail, sweepActions, foundColumn,
            knownHeader, knownColumn,
            addressHeader, addressField, hintLabel, nameField,
            statusTitle, statusDetail, statusActions, copiedLabel, noteLabel, buttonRow,
        ] as [NSView] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(MacTheme.Spacing.xs, after: heading)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: subtitle)
        column.setCustomSpacing(MacTheme.Spacing.xl, after: tailnetRemedy)
        column.setCustomSpacing(MacTheme.Spacing.xl, after: knownColumn)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: sweepTitle)
        column.setCustomSpacing(MacTheme.Spacing.xl, after: foundColumn)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: addressField)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: statusTitle)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let scroll = MacDialogs.scrollColumn(holding: column)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(ground)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        sheet.contentView = content
    }

    private func dialHolder() -> NSView {
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
        return holder
    }

    /// Nothing outside the main window is reached by its restyle pass, and every colour and size here
    /// was resolved once at construction.
    @objc private func repaint() {
        applyTheme()
        render()
        radar.needsDisplay = true
    }

    private func applyTheme() {
        ground.fill = MacTheme.Color.canvas
        ground.needsDisplay = true
        heading.font = MacTheme.Ramp.font(.panelTitle)
        heading.textColor = MacTheme.Color.label
        for label in [subtitle, tailnetLine, sweepDetail, statusDetail, hintLabel, noteLabel] {
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.secondaryLabel
        }
        copiedLabel.font = MacTheme.Ramp.font(.code)
        copiedLabel.textColor = MacTheme.Color.secondaryLabel
        for label in [sweepTitle, statusTitle] {
            label.font = MacTheme.Ramp.font(.cardTitle)
        }
        addressField.font = MacTheme.Ramp.font(.code)
        for header in [knownHeader, sweepHeader, addressHeader] {
            header.font = MacTheme.Ramp.font(.sectionLabel)
            header.textColor = MacTheme.Color.secondaryLabel
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    /// The sheet is gone, so the tailnet stops being asked about it. Dropping the last reference is
    /// not enough: a weakly captured `self` makes the callbacks no-ops while every probe carries on
    /// to its own timeout, which is the cost this cancels.
    private func release() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// The first look, taken as the sheet opens so the surface leads with a fact rather than a
    /// blank. Every look after this one belongs to a press — see `scan`.
    private func readTailnet() {
        Task { [weak self] in
            let reading = await Self.readings()
            guard let self else { return }
            self.took(reading)
            self.render()
        }
    }

    /// Two readings, because they are two questions. The interface walk underneath
    /// `TailnetStatusMac` still proves a tunnel on a Mac whose Tailscale cannot be run from here,
    /// while the survey is the machine list a sweep would ask — the same one the server scan asks,
    /// so a renderer scan and an agent scan look at one tailnet.
    private static func readings() async -> (tailnet: TailscaleReading, survey: DiscoverySurvey) {
        let status = await Task.detached(priority: .utility) { TailnetStatusMac.read() }.value
        let survey = await Task.detached(priority: .utility) { DiscoverySurvey.read() }.value
        return (status.reading, survey)
    }

    /// A reading taken into the sheet: the line about this Mac, the machines a sweep would ask, and
    /// whichever fact stops a sweep before it starts.
    ///
    /// This Mac is one of the machines asked. The desk somebody codes at is the likeliest box on the
    /// whole tailnet to be holding the graphics card, and a sweep that only asked peers could never
    /// find the renderer it is running on.
    private func took(_ reading: (tailnet: TailscaleReading, survey: DiscoverySurvey)) {
        peers = reading.survey.scannable(includingThisMachine: true)
        setup.tailnet = reading.tailnet
        sweepBlock = Self.blocker(reading.tailnet, reading.survey)
        sweep = sweepBlock.map(ForgeSweepReading.init(blocked:)) ?? ForgeSweepReading()
    }

    /// Which reading stops a sweep before it starts, if either does. A Mac off the tailnet has
    /// nothing to ask; a Mac whose Tailscale left no command line here is on the tailnet and still
    /// has no way of being told what else is on it. Two states, two doors — and neither of them is
    /// "start ComfyUI on the machine with the card", which is what a machine list that came back
    /// empty would otherwise be reported as.
    private static func blocker(_ tailnet: TailscaleReading, _ survey: DiscoverySurvey)
        -> TailscaleReading?
    {
        guard tailnet.isUp else { return tailnet }
        guard survey.foundCLI else { return survey.reading }
        return nil
    }

    @objc private func addressSubmitted() {
        perform(setup.primary)
    }

    private func perform(_ button: ForgeSetupButton) {
        guard button.isEnabled else { return }
        perform(button.action)
    }

    /// Every button on this sheet hands back one of these, and the sheet runs it. Nothing here
    /// decides anything: which action a press carries is `ForgeSetup`'s answer, and so is the word on
    /// the button that carried it.
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
            guard let self else { return }
            self.checking = false
            self.setup.reached(verdict)
            self.render()
        }
    }

    /// The one write this sheet makes. `ForgeStore` files the machine among the ones this device has
    /// used and points renders at it in the same breath, so nothing else here has to know what
    /// "remembered" means.
    private func save(_ renderer: ForgeRenderer) {
        ForgeStore.remember(renderer)
        onSaved()
        close()
    }

    /// The failure's own remedy, wired the way every other `ConnectDiagnosis` on this Mac is. The
    /// line that starts ComfyUI is put on the clipboard and then shown, because a command copied
    /// silently is indistinguishable from a button that did nothing.
    private func apply(_ fix: ConnectDiagnosis.Fix) {
        switch fix {
        case .copyCommand(let command):
            RowKit.copyToClipboard(command)
            copied = setup.status.diagnosis.map { (command, $0) }
            render()
        case .openTailscale:
            tailnetRemedy.enterDoor()
        case .retry:
            perform(setup.primary.action)
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            write(address: url.absoluteString, name: setup.name)
            perform(setup.primary.action)
        case .none, .openAppSettings, .revealPassword, .seePro:
            return
        }
    }

    /// The tailnet, re-read and then asked which machine answers on the forge's port.
    ///
    /// The reading is taken again on every press. Whether this Mac is on a tailnet at all, and
    /// whether Tailscale left a command line here to ask, are both live facts — somebody signs in,
    /// installs the app, comes back — so a surface whose whole remedy is "go fix that, then scan"
    /// has to be able to see that it worked. Read once when the sheet opened, it would refuse
    /// forever for a state that stopped being true, and go on blaming a later timeout on a tailnet
    /// this Mac has since joined.
    private func scan() {
        guard sweepTask == nil, !sweep.isScanning else { return }
        scanID += 1
        let id = scanID
        sweepTask = Task { [weak self] in
            let reading = await Self.readings()
            guard !Task.isCancelled, let self, self.scanID == id else { return }
            self.took(reading)
            guard let blocked = self.sweepBlock else {
                await self.sweepTailnet(id)
                return
            }
            self.sweepTask = nil
            self.render()
            self.enterSweepDoor(blocked)
        }
    }

    /// Every machine on the tailnet, asked at once. Raced against Core's own deadline, because a
    /// peer that has gone to sleep holds its port open and says nothing — the sweep reports what it
    /// did find rather than spinning until the sheet closes.
    private func sweepTailnet(_ id: Int) async {
        let targets = ForgeSweep.targets(peers)
        sweep.began(targets, at: TailnetRadarView.now)
        render()

        let progressed: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.scanID == id else { return }
                self.sweep.advanced(checked: done, total: total)
                self.render()
            }
        }
        let sighted: @Sendable (ForgeCandidate) -> Void = { [weak self] candidate in
            Task { @MainActor in
                guard let self, self.scanID == id else { return }
                self.sweep.found(candidate, at: TailnetRadarView.now)
                self.render()
            }
        }
        _ = await Self.within(ForgeSweep.deadline) {
            await ForgeSweep.run(targets: targets, onProgress: progressed, onFound: sighted)
        }
        guard !Task.isCancelled, scanID == id else { return }
        sweepTask = nil
        sweep.finished()
        render()
    }

    /// The door the reading that blocks the sweep offers, which is not always the one the tailnet
    /// line above it is offering: a Mac whose tunnel is up but whose Tailscale left no command line
    /// behind is on the tailnet, so the line above states that truthfully and has no door of its own
    /// to open. The walker is the same one either way — a remedy is one press on every surface.
    private func enterSweepDoor(_ reading: TailscaleReading) {
        guard reading != setup.tailnet, let door = TailnetStatusMac.door(for: reading) else {
            tailnetRemedy.enterDoor()
            return
        }
        tailnetRemedy.enter(door)
    }

    /// A scan that never comes back is a spinner with extra steps, so the whole sweep is given Core's
    /// deadline and reports what it has.
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

    /// What the dial's own button does, which is always the scan — and the scan re-reads Tailscale
    /// before it sweeps, so one press is both "find out whether I can" and "do it". A Mac that
    /// cannot sweep is sent through the door its reading names instead of sweeping a tailnet it is
    /// not on, and the press that follows the fix finds that it worked.
    private func pressSweep() {
        scan()
    }

    /// A machine a scan just found, taken into the form. It has already answered the question the
    /// button asks, so `adopt` leaves it checked rather than buying the same wait twice.
    private func adopt(_ candidate: ForgeCandidate) {
        setup.adopt(candidate)
        writeForm()
        render()
    }

    /// A machine already used, put back in the form and asked again. It has not been probed since
    /// whenever it was last rendered on, so it is checked rather than trusted.
    private func recall(_ renderer: ForgeRenderer) {
        write(address: renderer.endpoint.displayHost, name: renderer.name ?? "")
        render()
        guard let endpoint = setup.endpoint else { return }
        check(endpoint)
    }

    /// Forgetting the machine in force stops every screen in the app being able to render, and the
    /// press is a small unlabelled glyph beside the one that recalls it — so it is asked before it
    /// is done, the way removing a server on this Mac is. The words are Core's.
    private func confirmForget(_ renderer: ForgeRenderer) {
        MacDialogs.confirm(
            on: sheet, title: ForgeSetup.forgetTitle, body: renderer.detail,
            confirmLabel: ForgeSetup.forgetTitle
        ) { [weak self] in
            self?.forget(renderer)
        }
    }

    private func forget(_ renderer: ForgeRenderer) {
        ForgeStore.forgetRenderer(renderer.id)
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            tailnet: setup.tailnet, deviceName: Localized.text("This Mac"))
        writeForm()
        onSaved()
        render()
    }

    private func write(address: String, name: String) {
        setup.type(address)
        setup.rename(name)
        writeForm()
    }

    /// Puts the boxes back in step with the form after something else filled it in. The writes are
    /// not edits, so they must not be read back as ones.
    private func writeForm() {
        writing = true
        addressField.stringValue = setup.typed
        nameField.stringValue = setup.name
        writing = false
    }

    private func render() {
        renderIntro()
        renderKnown()
        renderSweep()
        renderForm()
        resize()
    }

    private func renderIntro() {
        heading.stringValue = ForgeSetup.title
        subtitle.stringValue = ForgeSetup.detail
        let line = setup.tailnetLine
        tailnetLine.stringValue = line
        tailnetLine.isHidden = line.isEmpty
        guard let reading = setup.tailnet else {
            tailnetRemedy.isHidden = true
            return
        }
        tailnetRemedy.write(reading)
    }

    private func renderKnown() {
        knownHeader.stringValue = ForgeSetup.knownTitle.uppercased()
        knownColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !setup.known.isEmpty else {
            knownColumn.addArrangedSubview(
                MacDialogs.detailLabel(ForgeSetup.knownEmpty, wraps: true))
            return
        }
        for renderer in setup.known {
            knownColumn.addArrangedSubview(makeKnownRow(renderer))
        }
    }

    /// A machine this device has used. The row is the press — the same shape the phone gives it —
    /// with the word for the one in force beside it and the one destructive verb spelled out.
    private func makeKnownRow(_ renderer: ForgeRenderer) -> NSView {
        var trailing: [NSView] = [lines(renderer.title, renderer.detail), RowKit.spacer()]
        if let badge = ForgeRenderer.badge(current: setup.isCurrent(renderer)) {
            let pill = MacDialogs.detailLabel(badge)
            pill.textColor = MacTheme.Color.success
            pill.setContentHuggingPriority(.required, for: .horizontal)
            trailing.append(pill)
        }
        trailing.append(chevron())
        let drop = RowKit.ActionButton(title: "") { [weak self] in
            self?.confirmForget(renderer)
        }
        drop.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: ForgeSetup.forgetTitle)
        drop.bezelStyle = .inline
        drop.toolTip = ForgeSetup.forgetTitle
        drop.setAccessibilityLabel(ForgeSetup.forgetTitle)
        drop.setContentHuggingPriority(.required, for: .horizontal)
        trailing.append(drop)

        let row = NSStackView(views: trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.addGestureRecognizer(RowKit.PressGesture { [weak self] in self?.recall(renderer) })
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel("\(renderer.title), \(renderer.detail)")
        return row
    }

    private func renderSweep() {
        sweepHeader.stringValue = setup.discovery.title.uppercased()
        radar.show(blips: sweep.blips, scanning: sweep.isScanning)
        sweepTitle.stringValue = sweep.title
        sweepTitle.textColor = sweep.tone.color
        sweepDetail.stringValue = sweep.detail
        sweepDetail.isHidden = sweep.detail.isEmpty

        fill(sweepActions, with: sweep.actionTitle.map { title in
            RowKit.ActionButton(title: title) { [weak self] in self?.pressSweep() }
        })

        foundColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for candidate in sweep.found {
            foundColumn.addArrangedSubview(makeCandidateRow(candidate))
        }
        foundColumn.isHidden = sweep.found.isEmpty
    }

    private func makeCandidateRow(_ candidate: ForgeCandidate) -> NSView {
        let badge = NSImageView()
        badge.image = NSImage(
            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 12 * MacTheme.UIScale.factor, weight: .semibold))
        badge.contentTintColor = MacTheme.Color.success
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setAccessibilityElement(false)

        let row = NSStackView(views: [
            badge, lines(candidate.title, candidate.detail), RowKit.spacer(), chevron(),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.addGestureRecognizer(RowKit.PressGesture { [weak self] in self?.adopt(candidate) })
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel("\(candidate.title), \(candidate.detail)")
        return row
    }

    private func lines(_ title: String, _ detail: String) -> NSView {
        let name = RowKit.label(
            title, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [name, MacDialogs.detailLabel(detail)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func chevron() -> NSView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 10 * MacTheme.UIScale.factor, weight: .semibold))
        view.contentTintColor = MacTheme.Color.tertiaryLabel
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setAccessibilityElement(false)
        return view
    }

    private func renderForm() {
        addressHeader.stringValue = ForgeSetup.addressLabel.uppercased()
        let status = setup.status
        let hint = Self.hint(setup.hint, beside: status)
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil

        statusTitle.stringValue = status.title
        statusTitle.textColor = status.tone.color
        statusTitle.isHidden = status.title.isEmpty
        statusDetail.stringValue = status.detail
        statusDetail.isHidden = status.detail.isEmpty

        fill(statusActions, with: remedy(for: status))

        let command = Self.copied(copied, beside: status.diagnosis)
        copiedLabel.stringValue = command ?? ""
        copiedLabel.isHidden = command == nil

        let note = setup.secondaryNote
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.addArrangedSubview(RowKit.spacer())
        if let secondary = setup.secondary {
            buttonRow.addArrangedSubview(
                RowKit.ActionButton(title: secondary.title) { [weak self] in
                    self?.perform(secondary)
                })
        }
        let done = RowKit.ActionButton(title: ForgeSurface.dismissTitle) { [weak self] in
            self?.close()
        }
        done.keyEquivalent = "\u{1B}"
        buttonRow.addArrangedSubview(done)
        let primary = setup.primary
        let go = RowKit.ActionButton(title: primary.title) { [weak self] in self?.perform(primary) }
        go.isEnabled = primary.isEnabled
        go.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(go)
    }

    /// The one press a failure offers, which is `ConnectDiagnosis`'s own — the sentence and the
    /// action are two halves of one value, so a status with no diagnosis has no button by
    /// construction rather than by a check here.
    ///
    /// The card does not repeat the dock. Where a failure's remedy is the press the button row at
    /// the foot already carries, the card states what is wrong and lets that button carry the act:
    /// `.timedOut` and `.nameNotResolved` both answer "Try again", which is the primary's own word,
    /// and the commonest failure on this sheet would otherwise print it twice forty pixels apart.
    private func remedy(for status: ForgeSetupReading) -> NSButton? {
        guard let diagnosis = status.diagnosis, let title = diagnosis.actionTitle,
            title != setup.primary.title
        else { return nil }
        return RowKit.ActionButton(title: title) { [weak self] in
            self?.perform(.fix(diagnosis.fix))
        }
    }

    /// The copied command stands for as long as the failure that offered it does. A different
    /// diagnosis is a different problem, and a line left over from the last one reads as advice
    /// about this one.
    private static func copied(
        _ copy: (command: String, of: ConnectDiagnosis)?, beside diagnosis: ConnectDiagnosis?
    ) -> String? {
        guard let copy, copy.of == diagnosis else { return nil }
        return copy.command
    }

    /// A row that holds one button and pushes it left, or nothing at all. The spacer goes in only
    /// beside a button: a hidden stack holding a lone view with no intrinsic size of its own is a
    /// height Auto Layout cannot settle, and it reports the whole sheet ambiguous for it.
    private func fill(_ row: NSStackView, with button: NSButton?) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        row.isHidden = button == nil
        guard let button else { return }
        row.addArrangedSubview(button)
        row.addArrangedSubview(RowKit.spacer())
    }

    /// The line under the field, unless the status is already saying it. A refusal is both the hint
    /// and the whole of the status, and the same sentence printed twice reads as two problems.
    private static func hint(_ hint: String?, beside status: ForgeSetupReading) -> String? {
        guard let hint, hint != status.detail else { return nil }
        return hint
    }

    /// The sheet is as tall as it needs to be and never taller than what it hangs from, because a
    /// sheet whose primary button is below the bottom of the screen is a sheet with no way out.
    private func resize() {
        column.layoutSubtreeIfNeeded()
        let wanted = column.fittingSize.height
        let available =
            sheet.sheetParent?.frame.height ?? NSScreen.main?.visibleFrame.height ?? wanted
        sheet.setContentSize(
            NSSize(width: Self.width, height: min(wanted, max(360, available - 60))))
    }
}

extension ForgeSetupSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard !writing else { return }
        switch notification.object as? NSTextField {
        case addressField:
            setup.type(addressField.stringValue)
        case nameField:
            setup.rename(nameField.stringValue)
        default:
            return
        }
        render()
    }
}
