import AppKit
import TailscodeCore

/// What the strip has to say once a call is over, or never began: the face it wore, a title in the
/// call's words, the reason when there is one, and whether the way back is System Settings.
struct CallNotice: Equatable {
    let face: VoiceCallFace
    let title: String
    let line: String?
    let offersSettings: Bool
}

/// A chip that is a control of the call: the composer row's own shape, with the one that ends the
/// call filled in the danger tone and its ink on that fill.
@MainActor
final class CallControlButton: SymbolChip {
    var isDanger = false {
        didSet {
            guard isDanger != oldValue else { return }
            accented = isDanger
            needsDisplay = true
        }
    }

    override func updateLayer() {
        super.updateLayer()
        guard isDanger, let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = MacTheme.Color.danger.cgColor
            layer.borderWidth = 0
        }
    }
}

/// A live call, docked as a strip in the chat pane directly above the composer so the transcript
/// stays fully visible above it and the person watches the agent work while talking. It is a state
/// of the conversation rather than a window: the call's face with its word and a tabular timer, the
/// last thing the person said as it was heard, the agent's account wearing its own `ActivityKind`
/// face, mute, hang up, and the beta mark. The voice model never speaks, so the strip has no line
/// for it. Every word is Core's.
///
/// Every part has one fixed height for as long as the state lasts. The caption and the account are one
/// line each and always present, with a placeholder where nothing has been said yet, so no frame of
/// a call lays anything out; only a state change (live, ended) changes the strip's height, once.
/// The strip sits on the pane's glass layer, so its inks are the system's, which glass flips and
/// lends its vibrancy to.
@MainActor
final class CallStripView: NSView {
    var onHangUp: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var reportLines: () -> [String] = { [] }

    var level: () -> Double {
        get { face.level }
        set { face.level = newValue }
    }

    private let face = CallFaceView()
    private let word = NSTextField(labelWithString: "")
    private let timer = NSTextField(labelWithString: "")
    private let titles = NSStackView()
    private lazy var beta: BetaBadge = {
        let badge = BetaBadge(feature: .voiceCall, reportLines: { [weak self] in self?.reportLines() ?? [] })
        badge.preferredEdge = .maxY
        return badge
    }()
    private let mute = CallControlButton()
    private let hangUp = CallControlButton()
    private let settings = CallControlButton()
    private let youRole = NSTextField(labelWithString: VoiceCallReading.youLabel)
    private let youText = NSTextField(labelWithString: "")
    private let captions = NSStackView()
    private let agentBadge = ActivityBadgeView(pointSize: 11)
    private let agentText = NSTextField(labelWithString: SpokenDigest.idle)
    private let agentRow = NSStackView()
    private let noticeText = NSTextField(wrappingLabelWithString: "")
    private let header = NSStackView()
    private let column = NSStackView()
    private var startedAt: Date?
    private var clock: Task<Void, Never>?
    private var snapshot: VoiceCallSnapshot?
    private var shownMuted: Bool?
    private var captionSource: [VoiceCallLine] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildHeader()
        buildCaptions()
        buildAgentRow()
        buildNotice()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        column.translatesAutoresizingMaskIntoConstraints = false
        for part in [header, captions, agentRow, noticeText] {
            column.addArrangedSubview(part)
            part.widthAnchor.constraint(
                equalTo: column.widthAnchor,
                constant: -(MacTheme.Spacing.m + MacTheme.Spacing.s)
            ).isActive = true
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        clock?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopClock() : startClock()
    }

    override func layout() {
        let width = max(0, bounds.width - 2 * MacTheme.Spacing.m - MacTheme.Spacing.s)
        if abs(noticeText.preferredMaxLayoutWidth - width) > 0.5 {
            noticeText.preferredMaxLayoutWidth = width
        }
        super.layout()
    }

    func show(_ snapshot: VoiceCallSnapshot) {
        self.snapshot = snapshot
        startedAt = snapshot.startedAt
        for control in [mute, hangUp, beta, timer] { control.isHidden = false }
        for part in [captions, agentRow] { part.isHidden = false }
        for part in [noticeText, settings] { part.isHidden = true }
        face.show(snapshot.face)
        word.stringValue = snapshot.word
        titles.setAccessibilityLabel(snapshot.spoken)
        paintCaptions(snapshot.lines)
        paintMute(snapshot.muted)
        refreshTimer()
        startClock()
    }

    func show(_ notice: CallNotice) {
        stopClock()
        snapshot = nil
        for part in [captions, agentRow, mute, hangUp, beta, timer] { part.isHidden = true }
        noticeText.isHidden = notice.line == nil
        noticeText.stringValue = notice.line ?? ""
        settings.isHidden = !notice.offersSettings
        face.show(notice.face)
        word.stringValue = notice.title
        titles.setAccessibilityLabel([notice.title, notice.line].compactMap { $0 }.joined(separator: ". "))
        titles.setAccessibilityValue(nil)
    }

    func hide() {
        stopClock()
        snapshot = nil
    }

    func show(agent digest: String, activity: ActivityKind?) {
        if agentText.stringValue != digest { agentText.stringValue = digest }
        agentBadge.activity = activity
        agentRow.setAccessibilityLabel(
            [activity?.spoken, digest].compactMap { $0 }.joined(separator: ". "))
    }

    /// Every font and glyph size is asked for again rather than remembered: a type-scale step
    /// changes what a role is worth, and the disc follows it.
    func restyle() {
        word.font = MacTheme.Ramp.font(.control)
        timer.font = MacTheme.Ramp.font(.statusLine)
        youRole.font = MacTheme.Ramp.font(.panelFootnote)
        for text in [youText, agentText] { text.font = MacTheme.Ramp.font(.panelDetail) }
        noticeText.font = MacTheme.Ramp.font(.panelDetail)
        for chip in [mute, hangUp, settings] { chip.restyle() }
        face.restyle()
        paintCaptions(captionSource)
        shownMuted = nil
        paintMute(snapshot?.muted ?? false)
    }

    private func label(_ field: NSTextField, ink: NSColor, lines: Int = 1) {
        field.textColor = ink
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = lines
        field.setAccessibilityElement(false)
    }

    private func buildHeader() {
        label(word, ink: MacTheme.Color.onGlass)
        word.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label(timer, ink: MacTheme.Color.onGlassSecondary)
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        titles.setViews([word, timer], in: .leading)
        titles.setAccessibilityElement(true)
        titles.setAccessibilityRole(.group)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titles.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        mute.symbol = "mic.fill"
        mute.target = self
        mute.action = #selector(muteTapped)
        hangUp.symbol = "phone.down.fill"
        hangUp.text = VoiceCallReading.hangUp
        hangUp.isDanger = true
        hangUp.toolTip = VoiceCallEntryPoint.tooltip(reach: .unknown, active: true)
        hangUp.setAccessibilityLabel(VoiceCallReading.hangUp)
        hangUp.target = self
        hangUp.action = #selector(hangUpTapped)
        settings.text = Localized.text("Open System Settings")
        settings.target = self
        settings.action = #selector(settingsTapped)
        settings.isHidden = true
        for chip in [mute, hangUp, settings] {
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let spacer = RowKit.spacer()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s
        header.setViews([face, titles, spacer, beta, settings, mute, hangUp], in: .leading)
        header.setCustomSpacing(MacTheme.Spacing.m, after: titles)
        header.setClippingResistancePriority(.init(400), for: .horizontal)
    }

    private func buildCaptions() {
        label(youRole, ink: NSColor.tertiaryLabelColor)
        youRole.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        youRole.setContentCompressionResistancePriority(.required, for: .horizontal)
        label(youText, ink: MacTheme.Color.onGlass)
        youText.lineBreakMode = .byTruncatingHead
        youText.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        youText.setContentHuggingPriority(.init(250), for: .horizontal)
        captions.orientation = .horizontal
        captions.alignment = .firstBaseline
        captions.spacing = MacTheme.Spacing.s
        captions.setClippingResistancePriority(.init(250), for: .horizontal)
        captions.setViews([youRole, youText], in: .leading)
        captions.setAccessibilityElement(true)
        captions.setAccessibilityRole(.group)
        paintCaptions([])
    }

    private func buildAgentRow() {
        label(agentText, ink: MacTheme.Color.onGlassSecondary)
        agentText.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        agentText.setContentHuggingPriority(.init(250), for: .horizontal)
        agentBadge.isHidden = true
        agentBadge.setContentHuggingPriority(.required, for: .horizontal)
        agentBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        agentRow.orientation = .horizontal
        agentRow.alignment = .centerY
        agentRow.spacing = MacTheme.Spacing.xs
        agentRow.setViews([agentBadge, agentText], in: .leading)
        agentRow.setAccessibilityElement(true)
        agentRow.setAccessibilityRole(.group)
        agentRow.setAccessibilityLabel(SpokenDigest.idle)
    }

    private func buildNotice() {
        label(noticeText, ink: MacTheme.Color.onGlass, lines: 4)
        noticeText.isSelectable = false
        noticeText.isHidden = true
        noticeText.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        noticeText.setAccessibilityElement(true)
    }

    @objc private func muteTapped() { onToggleMute?() }

    @objc private func hangUpTapped() { onHangUp?() }

    @objc private func settingsTapped() { onOpenSettings?() }

    private func paintMute(_ muted: Bool) {
        guard shownMuted != muted else { return }
        shownMuted = muted
        mute.symbol = muted ? "mic.slash.fill" : "mic.fill"
        mute.accented = muted
        mute.toolTip = muted ? VoiceCallReading.unmuteTooltip : VoiceCallReading.muteTooltip
        mute.setAccessibilityLabel(muted ? VoiceCallReading.unmute : VoiceCallReading.mute)
        mute.setAccessibilityValue(muted ? VoiceCallReading.mutedNote : nil)
        mute.setAccessibilitySelected(muted)
    }

    /// A line's ink says whether it is final: the settled ink, or the next register down while it is
    /// still being heard, with an ellipsis after it so the difference is also a shape. Before
    /// anything is heard the line keeps its place with the placeholder, so the strip never changes
    /// height as the first words arrive.
    private func paintCaptions(_ lines: [VoiceCallLine]) {
        captionSource = lines
        let you = lines.last { $0.kind == .you }
        set(youText, line: you, placeholder: VoiceCallReading.youPlaceholder,
            settled: MacTheme.Color.onGlassSecondary, partial: NSColor.tertiaryLabelColor)
        captions.setAccessibilityLabel(you.map { "\(VoiceCallReading.youLabel): \($0.text)" })
    }

    private func set(
        _ field: NSTextField, line: VoiceCallLine?, placeholder: String, settled: NSColor, partial: NSColor
    ) {
        guard let line else {
            field.stringValue = placeholder
            field.textColor = NSColor.tertiaryLabelColor
            return
        }
        field.stringValue = line.final ? line.text : line.text + "…"
        field.textColor = line.final ? settled : partial
    }

    private func startClock() {
        guard clock == nil, window != nil, snapshot != nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshTimer()
                let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                let wait = max(0.05, 1 - elapsed.truncatingRemainder(dividingBy: 1))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }

    private func refreshTimer() {
        let text = Self.clock(startedAt.map { Date().timeIntervalSince($0) } ?? 0)
        guard timer.stringValue != text else { return }
        timer.stringValue = text
        titles.setAccessibilityValue(text)
    }

    /// Minutes and seconds, in the tabular figures of the type ramp so a second that ticks never
    /// moves the words beside it.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
