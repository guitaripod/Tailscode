import AppKit
import CodingAgentKit
import CodingAgentKitApple
import ImageIO
import TailscodeCore

/// A running iOS app living inside the split tree: a Mac's simulator, streamed picture by picture
/// by a preview host and drawn in the pane the way a page or a stream is. The pane is a skin over
/// ``PreviewSlot`` and ``PreviewRunner``; every word on it is Core's and every fact comes from the
/// runner's two latest-wins mailboxes, which one display-link tick drains.
///
/// The link exists only while there is something to drain. The runner wakes it when a picture or a
/// state lands, it decodes the newest picture and no more than one per tick, and it comes off the
/// display again the moment both mailboxes are clean, so a pane showing a still screen owns no
/// clock at all, and a parked or shut-down pane owns neither a clock nor a stream.
///
/// The picture and the checklist are content on the opaque canvas. The only glass over this pane
/// is the identity strip the pane already floats at its top edge.
@MainActor
final class PreviewSlotView: NSView {
    private enum Face {
        case ask, setup, status, live
    }

    private(set) var slot: PreviewSlot
    let fixedHost: String?

    var onChange: (() -> Void)?
    var onAskAgent: ((String) -> Void)?

    /// Where the pane's own floating strip ends, so the faces centre in the room that is left.
    var topClearance: CGFloat = 0 {
        didSet {
            guard topClearance != oldValue else { return }
            stageTop.constant = topClearance
        }
    }

    private let secrets: any SecretStore
    private let lifetime = PaneLifetime()
    private let clock = PreviewClock()
    private var runner: PreviewRunner?
    private var runsRunner = true
    private var probeTask: Task<Void, Never>?
    private var link: CADisplayLink?
    private var lastDecodedAt: CFTimeInterval = 0
    private var isParked = false
    private var isShutDown = false
    private var announced = ""
    private var shownFace: Face = .ask
    private var copiedReset: Task<Void, Never>?

    private(set) var lastPictureJPEG: Data?
    private(set) var pictureSize: (width: Int, height: Int)?

    private let stage = NSView()
    private lazy var stageTop = stage.topAnchor.constraint(equalTo: topAnchor)

    private let askFace = NSView()
    private let askStack = NSStackView()
    private let headingLabel = NSTextField(labelWithString: Localized.text("Preview"))
    private let hostLabel = NSTextField(labelWithString: "")
    private let hostField = NSTextField()
    private let folderField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    private let setupScroll = NSScrollView()
    private let setupHeading = NSTextField(wrappingLabelWithString: "")
    private let checklistStack = FillingStack(topDown: true)
    private var drawnChecklist: [PreviewChecklistRow] = []

    private let statusFace = NSView()
    private let statusBadge = ActivityBadgeView(pointSize: 26)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryPassword = NSSecureTextField()
    private let statusBanner = PreviewBannerView()

    private let liveFace = PreviewLiveView()
    private let lightChip = SymbolChip(kind: .control)
    private let darkChip = SymbolChip(kind: .control)
    private let rebuildChip = SymbolChip(kind: .control)
    private let copyChip = SymbolChip(kind: .control)

    private static let columnWidth: CGFloat = 460
    private static let decodeInterval: CFTimeInterval = 0.015

    init(
        target: PreviewTarget?, fixedHost: String? = nil, runs: Bool = true,
        secrets: (any SecretStore)? = nil
    ) {
        slot = PreviewSlot(target: target)
        self.fixedHost = fixedHost
        self.secrets = secrets ?? KeychainSecretStore()
        super.init(frame: .zero)
        clock.view = self
        build()
        applyGround()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        if let target {
            runsRunner = runs
            if runs { startRunner(for: target) }
        }
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var target: PreviewTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }
    var hasLink: Bool { link != nil }
    var lifetimeCount: Int { lifetime.count }
    var isRunning: Bool { runner != nil && !isParked && !isShutDown }

    private func build() {
        wantsLayer = true

        stage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)
        NSLayoutConstraint.activate([
            stageTop,
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for face in [askFace, setupScroll, statusFace, liveFace] as [NSView] {
            face.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(face)
            NSLayoutConstraint.activate([
                face.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                face.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                face.topAnchor.constraint(equalTo: stage.topAnchor),
                face.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
        buildAsk()
        buildSetup()
        buildStatus()
        buildLive()
    }

    private func style(_ label: NSTextField, role: TypeRole, color: NSColor, centered: Bool = true) {
        label.font = MacTheme.Ramp.font(role)
        label.textColor = color
        label.alignment = centered ? .center : .natural
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func centre(_ content: NSView, in face: NSView) {
        let width = content.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        width.priority = .defaultLow
        let middle = content.centerYAnchor.constraint(equalTo: face.centerYAnchor)
        middle.priority = .defaultLow
        let top = content.topAnchor.constraint(
            greaterThanOrEqualTo: face.topAnchor, constant: MacTheme.Spacing.l)
        top.priority = .init(999)
        let bottom = content.bottomAnchor.constraint(
            lessThanOrEqualTo: face.bottomAnchor, constant: -MacTheme.Spacing.l)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: face.leadingAnchor, constant: MacTheme.Spacing.l),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: face.trailingAnchor, constant: -MacTheme.Spacing.l),
            width, middle, top, bottom,
        ])
    }

    private func buildAsk() {
        style(headingLabel, role: .cardTitle, color: MacTheme.Color.label)
        headingLabel.maximumNumberOfLines = 1
        style(hostLabel, role: .panelLabel, color: MacTheme.Color.secondaryLabel)
        style(reasonLabel, role: .panelFootnote, color: MacTheme.Color.secondaryLabel)
        reasonLabel.isHidden = true
        style(hintLabel, role: .panelFootnote, color: MacTheme.Color.secondaryLabel)
        hintLabel.stringValue = slot.hint

        hostField.placeholderString = Localized.text("Address of the Mac")
        folderField.placeholderString = slot.prompt
        passwordField.placeholderString = Localized.text("Password")
        passwordField.isHidden = true
        for field in [hostField, folderField, passwordField] {
            field.font = MacTheme.Ramp.font(.panelLabel)
            field.target = self
            field.action = #selector(submit)
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        if let fixedHost {
            hostLabel.stringValue = PreviewAccessStore.access(host: fixedHost)?.label ?? fixedHost
            hostField.isHidden = true
        } else {
            hostLabel.isHidden = true
            let known = PreviewAccessStore.all()
            if known.count == 1, let only = known.first { hostField.stringValue = only.host }
        }

        askStack.orientation = .vertical
        askStack.alignment = .centerX
        askStack.spacing = MacTheme.Spacing.m
        askStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [headingLabel, hostLabel, hostField, folderField, passwordField, reasonLabel, hintLabel] {
            askStack.addArrangedSubview(view)
        }
        for view in [hostField, folderField, passwordField, reasonLabel, hintLabel] as [NSView] {
            view.widthAnchor.constraint(equalTo: askStack.widthAnchor).isActive = true
        }
        askFace.addSubview(askStack)
        centre(askStack, in: askFace)
    }

    private func buildSetup() {
        style(setupHeading, role: .cardTitle, color: MacTheme.Color.label)
        checklistStack.spacing = MacTheme.Spacing.m
        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.l
        column.addArrangedSubview(setupHeading)
        column.addArrangedSubview(checklistStack)

        let document = FlippedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        setupScroll.drawsBackground = false
        setupScroll.hasVerticalScroller = true
        setupScroll.autohidesScrollers = true
        setupScroll.borderType = .noBorder
        setupScroll.documentView = document

        let clip = setupScroll.contentView
        let small = document.heightAnchor.constraint(equalToConstant: 0)
        small.priority = .init(1)
        let preferred = column.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        preferred.priority = .defaultLow
        let middle = column.centerYAnchor.constraint(equalTo: document.centerYAnchor)
        middle.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            small,
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
            column.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor, constant: MacTheme.Spacing.l),
            column.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor, constant: -MacTheme.Spacing.l),
            column.topAnchor.constraint(
                greaterThanOrEqualTo: document.topAnchor, constant: MacTheme.Spacing.l),
            column.bottomAnchor.constraint(
                lessThanOrEqualTo: document.bottomAnchor, constant: -MacTheme.Spacing.l),
            preferred, middle,
        ])
    }

    private func buildStatus() {
        style(statusLabel, role: .panelLabel, color: MacTheme.Color.label)
        retryPassword.placeholderString = Localized.text("Password")
        retryPassword.font = MacTheme.Ramp.font(.panelLabel)
        retryPassword.target = self
        retryPassword.action = #selector(retryWithPassword)
        retryPassword.translatesAutoresizingMaskIntoConstraints = false
        retryPassword.isHidden = true
        statusBanner.isHidden = true
        statusBanner.onAsk = { [weak self] in self?.askAgent() }

        let column = NSStackView(views: [statusBadge, statusLabel, retryPassword, statusBanner])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MacTheme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusLabel, retryPassword, statusBanner] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        statusFace.addSubview(column)
        centre(column, in: statusFace)
    }

    private func buildLive() {
        lightChip.text = Localized.text("Light")
        darkChip.text = Localized.text("Dark")
        rebuildChip.text = Localized.text("Rebuild")
        copyChip.text = Localized.text("Copy picture")
        lightChip.onTap = { [weak self] in self?.choose(appearance: "light") }
        darkChip.onTap = { [weak self] in self?.choose(appearance: "dark") }
        rebuildChip.onTap = { [weak self] in self?.rebuild() }
        copyChip.onTap = { [weak self] in self?.copyPicture() }
        liveFace.install(chips: [lightChip, darkChip, rebuildChip, copyChip])
        liveFace.banner.onAsk = { [weak self] in self?.askAgent() }
    }

    private func applyGround() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGround()
    }

    @objc private func themeChanged() {
        applyGround()
        drawnChecklist = []
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            liftLink()
        } else if let runner, runner.pictures.isDirty || runner.states.isDirty {
            arm()
        }
    }

    func focusPrompt() {
        guard slot.isAsking else { return }
        window?.makeFirstResponder(fixedHost == nil ? hostField : folderField)
    }

    var summary: String {
        let size = pictureSize.map { " \($0.width)x\($0.height)" } ?? ""
        guard !slot.isAsking else { return "asking" }
        let state = slot.state
        switch face {
        case .ask: return "asking"
        case .setup: return "settingUp rows=\(slot.checklist.count)"
        case .status:
            if state.light == .broken { return "broken banner=\(statusBanner.problem)" }
            return "\(phaseWord(state.phase)) [\(state.line)]"
        case .live:
            if state.light == .broken { return "broken\(size) banner=\(liveFace.banner.problem)" }
            return "\(phaseWord(state.phase))\(size)"
        }
    }

    private func phaseWord(_ phase: PreviewPhase) -> String {
        switch phase {
        case .connecting: return "connecting"
        case .settingUp: return "settingUp"
        case .starting: return "starting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }

    private var face: Face {
        if slot.isAsking { return .ask }
        let state = slot.state
        switch state.phase {
        case .settingUp: return .setup
        case .connecting: return .status
        case .starting, .live, .reconnecting: return pictureSize == nil ? .status : .live
        case .failed: return pictureSize != nil && state.session != nil ? .live : .status
        }
    }

    private func render() {
        let showing = face
        shownFace = showing
        askFace.isHidden = showing != .ask
        setupScroll.isHidden = showing != .setup
        statusFace.isHidden = showing != .status
        liveFace.isHidden = showing != .live
        switch showing {
        case .ask: break
        case .setup: renderSetup()
        case .status: renderStatus()
        case .live: renderLive()
        }
        announceIfChanged()
    }

    private func announceIfChanged() {
        let line = "\(slot.title)|\(slot.subtitle)|\(slot.light)|\(slot.target?.address ?? "")"
        guard line != announced else { return }
        announced = line
        onChange?()
    }

    private func renderSetup() {
        setupHeading.stringValue = slot.state.line
        let rows = slot.checklist
        guard rows != drawnChecklist else { return }
        drawnChecklist = rows
        for view in checklistStack.arrangedSubviews {
            checklistStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows { checklistStack.addArrangedSubview(rowView(row)) }
    }

    private func rowView(_ row: PreviewChecklistRow) -> NSView {
        let glyph = NSImageView()
        glyph.imageScaling = .scaleNone
        let size = MacTheme.Ramp.font(.rowTitleStrong).pointSize
        glyph.image = NSImage(systemSymbolName: Self.symbol(for: row.state), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        glyph.contentTintColor = Self.tint(for: row.state)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)

        let title = NSTextField(wrappingLabelWithString: row.title)
        style(title, role: .rowTitleStrong, color: MacTheme.Color.label, centered: false)
        var words: [NSView] = [title]
        if let detail = row.detail {
            let label = NSTextField(wrappingLabelWithString: detail)
            style(label, role: .rowDetail, color: MacTheme.Color.secondaryLabel, centered: false)
            label.isSelectable = true
            words.append(label)
        }
        if row.working || row.state == .working, let progress = row.progress {
            let bar = PreviewProgressBar()
            bar.fraction = min(1, max(0, progress))
            words.append(bar)
        }
        if row.state == .fixable, !row.working, let fix = row.fix {
            let chip = SymbolChip(kind: .control)
            chip.text = row.fixLabel ?? Localized.text("Fix it")
            chip.onTap = { [weak self] in self?.runner?.runFix(fix) }
            let holder = NSStackView(views: [chip])
            holder.orientation = .horizontal
            words.append(holder)
        }
        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.xs
        for view in words { column.addArrangedSubview(view) }
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let parts: [NSView] = [glyph, column]
        let line = NSStackView(views: parts)
        line.orientation = .horizontal
        line.alignment = .top
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.m
        line.setAccessibilityLabel(row.title)
        return line
    }

    private static func symbol(for state: DoctorCheck.State) -> String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle"
        case .needsYou: return "exclamationmark.circle.fill"
        case .fixable: return "arrow.down.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private static func tint(for state: DoctorCheck.State) -> NSColor {
        switch state {
        case .ok: return MacTheme.Color.success
        case .working, .fixable: return MacTheme.Color.secondaryLabel
        case .needsYou: return MacTheme.Color.warning
        case .failed: return MacTheme.Color.danger
        }
    }

    private func renderStatus() {
        let state = slot.state
        statusLabel.stringValue = state.line
        statusBadge.activity = slot.light.activity
        if slot.light.activity == nil { statusBadge.isHidden = true }
        retryPassword.isHidden = !state.needsPassword
        let broken = state.light == .broken
        statusBanner.isHidden = !broken
        if broken { statusBanner.show(headline: headline(of: state), problem: state.firstProblem) }
    }

    private func renderLive() {
        let state = slot.state
        let stale = state.phase == .reconnecting
        let changing = state.phase == .starting
        liveFace.setDimmed(stale || changing, words: stale ? PreviewLight.stale.line : state.line)
        let broken = state.light == .broken
        liveFace.banner.isHidden = !broken
        if broken { liveFace.banner.show(headline: headline(of: state), problem: state.firstProblem) }
        liveFace.setAccessibility(slot.light.spoken ?? slot.title)
        renderAppearance()
    }

    private func renderAppearance() {
        let dark = slot.appearance == "dark"
        lightChip.accented = !dark
        darkChip.accented = dark
    }

    private func headline(of state: PreviewState) -> String {
        state.lastBuild.map(PreviewReading.headline(of:)) ?? state.line
    }

    func handle(_ command: PreviewCommand) {
        guard !slot.isAsking else { return }
        switch command {
        case .toggleAppearance: choose(appearance: slot.nextAppearance)
        case .rebuild: rebuild()
        case .copyPicture: copyPicture()
        }
    }

    private func choose(appearance: String) {
        guard appearance != slot.appearance else { return }
        slot.appearance = appearance
        runner?.setAppearance(appearance)
        renderAppearance()
    }

    private func rebuild() {
        runner?.rebuild()
    }

    private func copyPicture() {
        guard let lastPictureJPEG, let image = NSImage(data: lastPictureJPEG) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
        copyChip.text = Localized.text("Copied")
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copyChip.text = Localized.text("Copy picture")
        }
    }

    private func askAgent() {
        let problem = slot.state.firstProblem ?? slot.state.line
        let words = Localized.text(
            "The preview of %@ would not build. The first problem is: %@. Please fix it.",
            slot.target?.appName ?? slot.title, problem)
        onAskAgent?(words)
    }

    @objc private func submit() {
        let typedHost = fixedHost ?? hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedHost.isEmpty else {
            window?.makeFirstResponder(hostField)
            return
        }
        guard !folder.isEmpty else {
            window?.makeFirstResponder(folderField)
            return
        }
        let (host, typedPort) = Self.split(typedHost)
        let remembered = PreviewAccessStore.access(host: host)
        let access = PreviewAccess(
            host: host, port: typedPort ?? remembered?.port ?? PreviewAccess(host: host).port,
            name: remembered?.name)
        let typedPassword = passwordField.stringValue
        let stored = (try? secrets.value(for: access.secretKey)) ?? nil
        let password = typedPassword.isEmpty ? stored : typedPassword
        show(reason: PreviewReach.checking.line)
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let reach = await PreviewProbe.probe(access, password: password)
            guard !Task.isCancelled else { return }
            self?.probed(reach, access: access, folder: folder, typedPassword: typedPassword)
        }
    }

    nonisolated static func split(_ address: String) -> (host: String, port: Int?) {
        let parts = address.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return (address.trimmingCharacters(in: CharacterSet(charactersIn: ":")), nil)
        }
        return (parts[0], port)
    }

    private func probed(_ reach: PreviewReach, access: PreviewAccess, folder: String, typedPassword: String) {
        guard !isShutDown, slot.isAsking else { return }
        guard reach.isAnswering else {
            show(reason: reach.line)
            if reach.asksForPassword {
                passwordField.isHidden = false
                window?.makeFirstResponder(passwordField)
            }
            return
        }
        PreviewAccessStore.remember(access)
        if !typedPassword.isEmpty { try? secrets.setValue(typedPassword, for: access.secretKey) }
        show(reason: nil)
        point(at: PreviewTarget(host: access.host, port: access.port, project: folder))
    }

    private func show(reason: String?) {
        reasonLabel.isHidden = reason == nil
        reasonLabel.stringValue = reason ?? ""
    }

    @objc private func retryWithPassword() {
        guard let target = slot.target else { return }
        let typed = retryPassword.stringValue
        guard !typed.isEmpty else { return }
        try? secrets.setValue(typed, for: target.access.secretKey)
        retryPassword.stringValue = ""
        point(at: target)
    }

    func point(at target: PreviewTarget) {
        endRun()
        slot.point(at: target)
        resetPicture()
        startRunner(for: target)
        render()
    }

    func ask() {
        endRun()
        slot.ask()
        resetPicture()
        folderField.stringValue = slot.draft
        render()
        focusPrompt()
    }

    private func startRunner(for target: PreviewTarget) {
        guard runsRunner else { return }
        let password = (try? secrets.value(for: target.access.secretKey)) ?? nil
        guard let config = target.access.config(password: password) else {
            var failed = PreviewState()
            failed.phase = .failed(PreviewReach.unreachable(target.access.address).line)
            slot.apply(failed)
            return
        }
        let runner = PreviewRunner(target: target, config: config, clock: clock)
        self.runner = runner
        guard !isParked, !isShutDown else { return }
        begin(runner)
    }

    private func begin(_ runner: PreviewRunner) {
        runner.start()
        lifetime.add { runner.stop() }
        arm()
    }

    private func endRun() {
        lifetime.cancelAll()
        liftLink()
        runner = nil
    }

    func park() {
        guard !isParked else { return }
        isParked = true
        lifetime.cancelAll()
        liftLink()
        probeTask?.cancel()
    }

    func unpark() {
        guard isParked else { return }
        isParked = false
        guard !isShutDown, let runner else { return }
        begin(runner)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        probeTask?.cancel()
        probeTask = nil
        copiedReset?.cancel()
        lifetime.cancelAll()
        liftLink()
        runner = nil
        clock.view = nil
        NotificationCenter.default.removeObserver(self)
    }

    func freeze() {
        endRun()
    }

    fileprivate func wake() {
        guard runner != nil else { return }
        arm()
    }

    private func arm() {
        guard link == nil, runner != nil, !isParked, !isShutDown, window != nil else { return }
        let fresh = displayLink(target: self, selector: #selector(step(_:)))
        fresh.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        fresh.add(to: .main, forMode: .common)
        link = fresh
    }

    private func liftLink() {
        link?.invalidate()
        link = nil
    }

    /// One frame of the pane's whole work: the newest state, then the newest picture if the last
    /// decode is old enough, then the clock off the display again once nothing is waiting.
    @objc private func step(_ link: CADisplayLink) {
        guard let runner else {
            liftLink()
            return
        }
        if let state = runner.states.take() { apply(state) }
        if runner.pictures.isDirty, link.timestamp - lastDecodedAt >= Self.decodeInterval,
            let newest = runner.pictures.take()
        {
            lastDecodedAt = link.timestamp
            adopt(newest.jpeg)
        }
        if !runner.states.isDirty, !runner.pictures.isDirty { liftLink() }
    }

    private func apply(_ state: PreviewState) {
        slot.apply(state)
        render()
    }

    nonisolated static func decode(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Decodes a JPEG into the picture the pane shows. A bad frame keeps the last good one, which
    /// is the whole point of a preview that outlives a broken build.
    @discardableResult
    private func adopt(_ bytes: Data) -> Bool {
        guard let image = Self.decode(bytes) else { return false }
        liveFace.show(image)
        lastPictureJPEG = bytes
        let size = (width: image.width, height: image.height)
        let changed = pictureSize?.width != size.width || pictureSize?.height != size.height
        pictureSize = size
        if changed || shownFace != face { render() }
        return true
    }

    private func resetPicture() {
        liveFace.clear()
        lastPictureJPEG = nil
        pictureSize = nil
    }

    func discardPicture() {
        resetPicture()
        render()
    }

    func applyForTest(_ state: PreviewState, jpeg bytes: Data? = nil) {
        if let bytes { adopt(bytes) }
        apply(state)
    }

    var checklistRowCount: Int { checklistStack.arrangedSubviews.count }

    var visibleButtonTitles: [String] {
        var found: [String] = []
        collectButtons(in: stage, into: &found)
        return found
    }

    private func collectButtons(in view: NSView, into found: inout [String]) {
        guard !view.isHidden else { return }
        if let chip = view as? SymbolChip, !chip.text.isEmpty { found.append(chip.text) }
        for child in view.subviews { collectButtons(in: child, into: &found) }
    }

    var bannerShown: Bool { !(liveFace.isHidden ? statusBanner.isHidden : liveFace.banner.isHidden) }
    var pictureDrawn: CGImage? { liveFace.image }
    var pictureAlpha: CGFloat { liveFace.pictureAlpha }
    var reconnectWords: String? { liveFace.chipWords }
    var progressBarCount: Int { Self.count(of: PreviewProgressBar.self, in: stage) }

    private static func count<T: NSView>(of type: T.Type, in view: NSView) -> Int {
        guard !view.isHidden else { return 0 }
        return (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(of: type, in: $1) }
    }

    func renderedPicture(size: NSSize) -> (rep: NSBitmapImageRep, frame: NSRect)? {
        setFrameSize(size)
        layoutSubtreeIfNeeded()
        return liveFace.snapshot()
    }

    var passwordShown: Bool { !passwordField.isHidden }
    var hostFieldShown: Bool { !hostField.isHidden }
    var statusBadgeActivity: ActivityKind? { statusBadge.activity }

    func pressAskAgent() {
        askAgent()
    }
}

/// The wake-up the runner is given: a drain request from any thread becomes one tick of the
/// display link on the main loop, and nothing else. It holds the pane weakly, so a runner
/// outliving its pane for a moment wakes nothing.
private final class PreviewClock: HostClock, @unchecked Sendable {
    nonisolated(unsafe) weak var view: PreviewSlotView?

    func now() -> TimeInterval { CACurrentMediaTime() }

    func requestDrain() {
        DispatchQueue.main.async { [weak self] in
            MainThread.call { self?.view?.wake() }
        }
    }
}

/// A scroll view's document is read from its top, so the checklist starts at the head of a pane
/// too short to hold it.
private final class FlippedDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// The live face: the newest picture aspect-fitted above a quiet row of chips. It is placed by
/// frame rather than by constraint because the picture's shape arrives with its first frame and
/// changes with the device, and a layout pass per frame is not something a stream should cost.
@MainActor
final class PreviewLiveView: NSView {
    let banner = PreviewBannerView()
    private let host = NSView()
    private let picture = PreviewPictureView()
    private let chipLabel = PreviewChipLabel()
    private let chips = NSStackView()

    var image: CGImage? { picture.image }
    var pictureAlpha: CGFloat { picture.alphaValue }
    var chipWords: String? { chipLabel.isHidden ? nil : chipLabel.text }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.addSubview(picture)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.isHidden = true
        host.addSubview(banner)
        host.addSubview(chipLabel)
        addSubview(host)
        chips.orientation = .horizontal
        chips.spacing = MacTheme.Spacing.s
        chips.alignment = .centerY
        addSubview(chips)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: MacTheme.Spacing.s),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -MacTheme.Spacing.s),
            banner.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -MacTheme.Spacing.s),
            chipLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            chipLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: MacTheme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func install(chips views: [NSView]) {
        for view in views { chips.addArrangedSubview(view) }
        needsLayout = true
    }

    func show(_ image: CGImage) {
        let reshaped = picture.image.map { $0.width != image.width || $0.height != image.height } ?? true
        picture.show(image)
        if reshaped { needsLayout = true }
    }

    func clear() {
        picture.clear()
        needsLayout = true
    }

    func setDimmed(_ dimmed: Bool, words: String) {
        picture.alphaValue = dimmed ? 0.55 : 1
        chipLabel.isHidden = !dimmed
        chipLabel.text = words
    }

    func setAccessibility(_ label: String) {
        picture.setAccessibilityLabel(label)
    }

    func snapshot() -> (rep: NSBitmapImageRep, frame: NSRect)? {
        layoutSubtreeIfNeeded()
        let area = picture.bounds
        guard area.width > 0, area.height > 0, let rep = picture.bitmapImageRepForCachingDisplay(in: area)
        else { return nil }
        picture.cacheDisplay(in: area, to: rep)
        return (rep, host.frame)
    }

    override func layout() {
        super.layout()
        let side = MacTheme.Spacing.l
        let below = chips.fittingSize
        let chipsFrame = NSRect(
            x: ((bounds.width - below.width) / 2).rounded(), y: MacTheme.Spacing.m,
            width: below.width, height: below.height)
        chips.frame = chipsFrame
        let room = NSRect(
            x: side, y: chipsFrame.maxY + MacTheme.Spacing.m, width: max(0, bounds.width - side * 2),
            height: max(0, bounds.height - chipsFrame.maxY - MacTheme.Spacing.m - side))
        guard let image = picture.image, room.width > 0, room.height > 0 else {
            host.frame = .zero
            return
        }
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        var fitted = NSSize(width: room.height * ratio, height: room.height)
        if fitted.width > room.width { fitted = NSSize(width: room.width, height: room.width / ratio) }
        host.frame = NSRect(
            x: room.midX - fitted.width / 2, y: room.midY - fitted.height / 2, width: fitted.width.rounded(),
            height: fitted.height.rounded())
        picture.frame = host.bounds
    }
}

/// The newest picture, drawn by handing the layer the decoded image rather than by drawing it
/// again: the compositor scales it, and a stream of 60 pictures a second costs one assignment each.
@MainActor
final class PreviewPictureView: NSView {
    private(set) var image: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.masksToBounds = true
        setAccessibilityRole(.image)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ next: CGImage) {
        image = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.contents = next
        CATransaction.commit()
    }

    func clear() {
        image = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let clip = CGPath(
            roundedRect: bounds, cornerWidth: MacTheme.Radius.card, cornerHeight: MacTheme.Radius.card,
            transform: nil)
        context.addPath(clip)
        context.clip()
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// A short word over the top of a dimmed picture, in a capsule on the opaque canvas.
@MainActor
final class PreviewChipLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let capsule = CapsuleView()

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTheme.Ramp.font(ChatChrome.chipRole)
        label.textColor = MacTheme.Color.label
        addSubview(capsule)
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: MacTheme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -MacTheme.Spacing.m),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: MacTheme.Spacing.xs),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layer = capsule.layer else { return }
        capsule.effectiveAppearance.performAsCurrentDrawingAppearance {
            ChipGround.paint(layer, kind: .fact, height: bounds.height)
        }
    }
}

/// What a failed build looks like over a picture: the headline, the first problem in mono ink, and
/// the one button that hands it to the agent. A card on the opaque canvas, never glass.
@MainActor
final class PreviewBannerView: NSView {
    var onAsk: (() -> Void)?
    private(set) var problem = ""
    private let glyph = NSImageView()
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let ask = SymbolChip(kind: .control)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.borderWidth = 1

        glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: MacTheme.Ramp.font(.rowTitleStrong).pointSize, weight: .medium))
        glyph.contentTintColor = MacTheme.Color.danger
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)
        headline.font = MacTheme.Ramp.font(.rowTitleStrong)
        headline.textColor = MacTheme.Color.label
        headline.isSelectable = false
        headline.maximumNumberOfLines = 0
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problemLabel.font = MacTheme.Ramp.font(.toolOutput)
        problemLabel.textColor = MacTheme.Color.secondaryLabel
        problemLabel.isSelectable = true
        problemLabel.maximumNumberOfLines = 0
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ask.text = Localized.text("Ask the agent to fix it")
        ask.accented = true
        ask.onTap = { [weak self] in self?.onAsk?() }

        let top = NSStackView(views: [glyph, headline])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = MacTheme.Spacing.s
        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(top)
        column.addArrangedSubview(problemLabel)
        let row = NSStackView(views: [ask])
        row.orientation = .horizontal
        column.addArrangedSubview(row)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(headline text: String, problem line: String?) {
        headline.stringValue = text
        problem = line ?? ""
        problemLabel.stringValue = problem
        problemLabel.isHidden = problem.isEmpty
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.blended(
                withFraction: 0.07, of: MacTheme.Color.label)?.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

/// A bar for a job whose progress the host reports: a track and a fill, drawn from layers so a
/// step in the number is a change of width and nothing is re-laid-out.
@MainActor
final class PreviewProgressBar: NSView {
    var fraction: Double = 0 {
        didSet { needsLayout = true }
    }
    private let fill = NSView()

    private static let thickness: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.wantsLayer = true
        addSubview(fill)
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    override func layout() {
        super.layout()
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
        layer?.cornerRadius = bounds.height / 2
        fill.layer?.cornerRadius = bounds.height / 2
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.separator.cgColor
            fill.layer?.backgroundColor = MacTheme.Color.accent.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}
