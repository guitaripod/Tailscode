import TailscodeCore
import UIKit

/// What the dock has to say once a call is over, or never began: the face it wore, a title in the
/// call's words, the reason when there is one, and whether the way back is Settings.
struct CallNotice: Equatable {
    let face: VoiceCallFace
    let title: String
    let line: String?
    let offersSettings: Bool
}

/// A live call, docked as a strip directly above the composer so the transcript stays fully visible
/// above it and the person watches the agent work while talking. It is a state of the conversation
/// rather than a screen: the call's face with its word and a tabular timer, the last thing each
/// side said, the agent's account wearing its own `ActivityKind` face, mute, hang up, and the beta
/// mark.
///
/// On a screen with no height to spare (a phone on its side) the strip is its header alone: the face,
/// the timer, mute and hang up, without the captions and the agent's account.
///
/// Every part has one fixed height for as long as the state lasts. Captions and the account are one
/// line each and always present, with a placeholder where nothing has been said yet, so no frame of
/// a call re-lays anything out; only a state change (live, ended) changes the strip's height, once.
/// Every word is Core's.
@MainActor
final class CallDockView: UIView {
    var onHangUp: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var reportLines: () -> [String] = { [] }

    var level: () -> Double {
        get { face.level }
        set { face.level = newValue }
    }

    private let face = CallFaceView()
    private let word = UILabel()
    private let timer = UILabel()
    private lazy var titles = UIStackView(arrangedSubviews: [word, timer])
    private lazy var beta = BetaBadge(feature: .voiceCall, reportLines: { [weak self] in self?.reportLines() ?? [] })
    private let mute = CallDockButton()
    private let hangUp = CallDockButton()
    private let settings = UIButton(type: .system)
    private let youRole = UILabel()
    private let youText = UILabel()
    private let voiceRole = UILabel()
    private let voiceText = UILabel()
    private let captions = UIStackView()
    private let agentBadge = ActivityBadgeView(pointSize: 12)
    private let agentText = UILabel()
    private let agentRow = UIStackView()
    private let noticeText = UILabel()
    private let header = UIStackView()
    private let column = UIStackView()
    private var startedAt: Date?
    private var clock: Task<Void, Never>?
    private var snapshot: VoiceCallSnapshot?
    private var shownMuted: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        layer.cornerRadius = CGFloat(ChatChrome.Radius.card)
        layer.cornerCurve = .continuous
        buildHeader()
        buildCaptions()
        buildAgentRow()
        buildNotice()
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        [header, captions, agentRow, noticeText].forEach(column.addArrangedSubview)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xs),
        ])
        paint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: CallDockView, _) in view.paint()
        }
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (view: CallDockView, _) in
            guard let snapshot = view.snapshot else { return }
            view.show(snapshot)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopClock() : startClock()
    }

    func show(_ snapshot: VoiceCallSnapshot) {
        self.snapshot = snapshot
        startedAt = snapshot.startedAt
        isHidden = false
        let compact = traitCollection.verticalSizeClass == .compact
        [mute, hangUp, beta].forEach { $0.isHidden = false }
        [captions, agentRow].forEach { $0.isHidden = compact }
        [noticeText, settings].forEach { $0.isHidden = true }
        timer.isHidden = false
        face.show(snapshot.face)
        word.text = snapshot.word
        titles.accessibilityLabel = snapshot.spoken
        accessibilityElements = [titles, captions, agentRow, mute, hangUp, beta].filter { !$0.isHidden }
        paintCaptions(snapshot.lines)
        paintMute(snapshot.muted)
        refreshTimer()
        startClock()
        setNeedsLayout()
    }

    func show(_ notice: CallNotice) {
        stopClock()
        snapshot = nil
        isHidden = false
        [captions, agentRow, mute, hangUp, beta, timer].forEach { $0.isHidden = true }
        noticeText.isHidden = notice.line == nil
        noticeText.text = notice.line
        settings.isHidden = !notice.offersSettings
        face.show(notice.face)
        word.text = notice.title
        titles.accessibilityLabel = [notice.title, notice.line].compactMap { $0 }.joined(separator: ". ")
        titles.accessibilityValue = nil
        accessibilityElements = [titles, noticeText, settings].filter { !$0.isHidden }
        setNeedsLayout()
    }

    func hide() {
        stopClock()
        snapshot = nil
        isHidden = true
    }

    func show(agent digest: String, activity: ActivityKind?) {
        if agentText.text != digest { agentText.text = digest }
        agentBadge.activity = activity
        agentRow.accessibilityLabel = [activity?.spoken, digest].compactMap { $0 }.joined(separator: ". ")
    }

    private func buildHeader() {
        word.font = Theme.Ramp.font(.control)
        word.textColor = Theme.Color.label
        word.adjustsFontForContentSizeCategory = true
        word.numberOfLines = 1
        word.lineBreakMode = .byTruncatingTail
        word.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timer.font = Theme.Ramp.font(.statusLine)
        timer.textColor = Theme.Color.secondaryLabel
        timer.adjustsFontForContentSizeCategory = true
        timer.numberOfLines = 1
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        titles.isAccessibilityElement = true
        titles.accessibilityTraits = .updatesFrequently
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titles.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configure(mute, symbol: "mic.fill", action: { [weak self] in self?.onToggleMute?() })
        configure(hangUp, symbol: "phone.down.fill", action: { [weak self] in self?.onHangUp?() })
        hangUp.accessibilityLabel = VoiceCallReading.hangUp
        hangUp.disc.backgroundColor = Theme.Color.danger
        hangUp.glyph.tintColor = Theme.Color.onAccent

        var openSettings = UIButton.Configuration.plain()
        openSettings.title = String(localized: "Open Settings")
        settings.configuration = openSettings
        settings.addAction(UIAction { [weak self] _ in self?.onOpenSettings?() }, for: .touchUpInside)
        settings.isHidden = true
        settings.setContentHuggingPriority(.required, for: .horizontal)
        settings.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        [face, titles, spacer, beta, settings, mute, hangUp].forEach(header.addArrangedSubview)
        header.setCustomSpacing(Theme.Spacing.m, after: titles)
        header.setCustomSpacing(0, after: beta)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(ChatChrome.chip(on: .touch).hit))
            .isActive = true
    }

    private func configure(_ button: CallDockButton, symbol: String, action: @escaping () -> Void) {
        button.setSymbol(symbol)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func buildCaptions() {
        youRole.text = VoiceCallReading.youLabel
        voiceRole.text = VoiceCallReading.voiceLabel
        for role in [youRole, voiceRole] {
            role.font = Theme.Ramp.font(.panelFootnote)
            role.textColor = Theme.Color.tertiaryLabel
            role.adjustsFontForContentSizeCategory = true
            role.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            role.setContentCompressionResistancePriority(.required, for: .horizontal)
            role.isAccessibilityElement = false
        }
        voiceRole.widthAnchor.constraint(equalTo: youRole.widthAnchor).isActive = true
        for text in [youText, voiceText] {
            text.font = Theme.Ramp.font(.panelDetail)
            text.adjustsFontForContentSizeCategory = true
            text.numberOfLines = 1
            text.lineBreakMode = .byTruncatingHead
            text.isAccessibilityElement = false
        }
        let you = UIStackView(arrangedSubviews: [youRole, youText])
        let voice = UIStackView(arrangedSubviews: [voiceRole, voiceText])
        for row in [you, voice] {
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = Theme.Spacing.s
        }
        captions.axis = .vertical
        captions.spacing = 2
        captions.addArrangedSubview(you)
        captions.addArrangedSubview(voice)
        captions.isAccessibilityElement = true
        captions.accessibilityTraits = .updatesFrequently
        paintCaptions([])
    }

    private func buildAgentRow() {
        agentText.font = Theme.Ramp.font(.panelDetail)
        agentText.textColor = Theme.Color.secondaryLabel
        agentText.adjustsFontForContentSizeCategory = true
        agentText.numberOfLines = 1
        agentText.lineBreakMode = .byTruncatingTail
        agentText.text = SpokenDigest.idle
        agentText.isAccessibilityElement = false
        agentBadge.isHidden = true
        agentBadge.setContentHuggingPriority(.required, for: .horizontal)
        agentBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        agentRow.axis = .horizontal
        agentRow.alignment = .center
        agentRow.spacing = Theme.Spacing.xs
        agentRow.addArrangedSubview(agentBadge)
        agentRow.addArrangedSubview(agentText)
        agentRow.isAccessibilityElement = true
        agentRow.accessibilityLabel = SpokenDigest.idle
    }

    private func buildNotice() {
        noticeText.font = Theme.Ramp.font(.panelDetail)
        noticeText.textColor = Theme.Color.label
        noticeText.adjustsFontForContentSizeCategory = true
        noticeText.numberOfLines = 0
        noticeText.isHidden = true
        noticeText.isAccessibilityElement = true
    }

    private func paint() {
        backgroundColor = ChatChip.fillColor(share: ChatChrome.fill(.live).inkShare)
        hangUp.disc.backgroundColor = Theme.Color.danger
        hangUp.glyph.tintColor = Theme.Color.onAccent
        shownMuted = nil
        paintMute(snapshot?.muted ?? false)
    }

    private func paintMute(_ muted: Bool) {
        guard shownMuted != muted else { return }
        shownMuted = muted
        mute.setSymbol(muted ? "mic.slash.fill" : "mic.fill")
        mute.glyph.tintColor = muted ? Theme.Color.warning : Theme.Color.label
        mute.disc.backgroundColor = Theme.Color.background
        mute.accessibilityLabel = muted ? VoiceCallReading.unmute : VoiceCallReading.mute
        mute.accessibilityValue = muted ? VoiceCallReading.mutedNote : nil
        mute.accessibilityTraits = muted ? [.button, .selected] : .button
    }

    private func paintCaptions(_ lines: [VoiceCallLine]) {
        let you = lines.last { $0.kind == .you }
        let voice = lines.last { $0.kind == .voice }
        set(youText, line: you, placeholder: VoiceCallReading.youPlaceholder, settled: Theme.Color.secondaryLabel,
            partial: Theme.Color.tertiaryLabel)
        set(voiceText, line: voice, placeholder: VoiceCallReading.voicePlaceholder, settled: Theme.Color.label,
            partial: Theme.Color.secondaryLabel)
        captions.accessibilityLabel = [
            you.map { "\(VoiceCallReading.youLabel): \($0.text)" },
            voice.map { "\(VoiceCallReading.voiceLabel): \($0.text)" },
        ].compactMap { $0 }.joined(separator: ". ")
    }

    /// A line's ink says whether it is final: the settled ink of its speaker, or the next register
    /// down while it is still being heard. A side that has said nothing yet keeps its place with
    /// the placeholder, so the strip never changes height as the first words arrive.
    private func set(
        _ label: UILabel, line: VoiceCallLine?, placeholder: String, settled: UIColor, partial: UIColor
    ) {
        guard let line else {
            label.text = placeholder
            label.textColor = Theme.Color.tertiaryLabel
            return
        }
        label.text = line.text
        label.textColor = line.final ? settled : partial
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
        guard let startedAt else {
            timer.text = Self.clock(0)
            return
        }
        let text = Self.clock(Date().timeIntervalSince(startedAt))
        guard timer.text != text else { return }
        timer.text = text
        titles.accessibilityValue = text
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

/// A round control with a 44-point target and a 36-point disc, so what is drawn is never smaller
/// than a finger asks for and never larger than the strip can hold.
@MainActor
final class CallDockButton: UIButton {
    let disc = UIView()
    let glyph = UIImageView()

    init() {
        super.init(frame: .zero)
        disc.isUserInteractionEnabled = false
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.layer.cornerRadius = 18
        disc.layer.cornerCurve = .continuous
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disc)
        disc.addSubview(glyph)
        let hit = CGFloat(ChatChrome.chip(on: .touch).hit)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: hit),
            heightAnchor.constraint(equalToConstant: hit),
            disc.widthAnchor.constraint(equalToConstant: 36),
            disc.heightAnchor.constraint(equalToConstant: 36),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    func setSymbol(_ name: String) {
        glyph.image = UIImage(
            systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }
}
