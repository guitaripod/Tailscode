import TailscodeCore
import UIKit

extension ForgeJobPhase {
    /// The render, said in the vocabulary every other surface in this app is already drawn in. A
    /// phase that is doing something gets the activity's own motion — the wake sweeps, the queue
    /// holds still because waiting is settled, the card breathes while it works — and a phase that
    /// has stopped gets none at all, because stillness is how a reader tells a finished render from
    /// a slow one.
    var activity: ActivityKind? {
        switch self {
        case .drafting, .done, .cancelled: return nil
        case .submitting: return .connecting
        case .queued(let ahead): return .queued(ahead)
        case .running: return .working
        case .failed: return .failed
        }
    }

    /// What colour the phase's word is worn in. Four meanings, none of them shared: work and a
    /// finished clip are the accent, a failure is the danger slot, and anything settled or waiting
    /// is quiet.
    var tone: ActivityTone {
        switch self {
        case .drafting, .cancelled: return .quiet
        case .submitting, .queued: return .quiet
        case .running, .done: return .live
        case .failed: return .danger
        }
    }

    /// The glyph a stage with no picture in it shows. A render that never produced a frame still
    /// has a face — it is the difference between a card that failed and a card that is blank.
    var stageSymbol: String {
        switch self {
        case .drafting: return "film"
        case .submitting, .queued, .running: return "film"
        case .done: return "play.rectangle"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        }
    }
}

extension ForgeField {
    /// One symbol per decision, so a settings list is read down its left edge rather than word by
    /// word. The client owes the drawing; the words are all Core's.
    var symbol: String {
        switch self {
        case .endpoint: return "desktopcomputer"
        case .prompt: return "text.alignleft"
        case .negative: return "nosign"
        case .size: return "aspectratio"
        case .seconds: return "timer"
        case .fps: return "speedometer"
        case .model: return "cpu"
        case .seed: return "dice"
        }
    }
}

/// One word in a capsule — the render's own badge, the clip's length, whether the machine answered.
/// Small enough to sit at the end of a row without competing with the title it belongs to.
final class ForgePill: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, Theme.Radius.control)
    }

    func apply(_ text: String?, tone: ActivityTone) {
        guard let text, !text.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        let ink = tone.color
        label.attributedText = NSAttributedString(
            string: text.uppercased(), attributes: Theme.Ramp.attributes(.badge, color: ink))
        backgroundColor = ink.withAlphaComponent(0.16)
        isAccessibilityElement = true
        accessibilityLabel = text
    }
}

/// Everything the stage draws, folded into one value so the cell is handed a state rather than
/// asked to reach for four of them.
struct ForgeStageReading {
    let row: ForgeRow
    let job: ForgeJob
    let size: ForgeSize
    /// The finished clip, once it has been confirmed to still be on the renderer.
    let clip: URL?
    /// Why it could not be pointed at, in the renderer's own words. A clip that finished and then
    /// could not be fetched is a different fact from a render that failed, and both have to be
    /// sayable on the same card.
    let clipFailure: String?
    let muted: Bool
}

/// The render in hand: a stage the shape of the frame being made, and under it every word `ForgeJob`
/// has about what is happening to it.
///
/// The stage exists in every state rather than only when there is a picture — a card that appears
/// when a clip lands and is absent before it is a card that reads as broken for the four minutes
/// that matter most. Its height follows the frame size being asked for, so walking the size setting
/// shows what will come back rather than describing it.
final class ForgeStageCell: UICollectionViewListCell {
    var onOpenClip: (() -> Void)?
    var onToggleSound: (() -> Void)?

    private let stage = UIView()
    private let player = ClipPlayerView()
    private let glyph = UIImageView()
    private let badge = ActivityBadgeView(pointSize: 30)
    private let caption = UILabel()
    private let sound = UIButton(type: .system)
    private let title = UILabel()
    private let pill = ForgePill()
    private let subtitle = UILabel()
    private let elapsed = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let note = UILabel()
    private var ratio: NSLayoutConstraint?
    private var fillWidth: NSLayoutConstraint?
    private var clock: Task<Void, Never>?
    private var appliedRatio: CGFloat = 0

    private static let stageFloor: CGFloat = 132
    private static let stageCeiling: CGFloat = 300

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildStage()
        buildReadings()
        let column = UIStackView(arrangedSubviews: [stage, titleRow(), subtitleRow(), track, note])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.m, after: stage)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        clock?.cancel()
        clock = nil
        player.clear()
        onOpenClip = nil
        onToggleSound = nil
    }

    /// The stage itself: a recessed panel the clip plays into, holding the glyph and the activity
    /// badge for every state that has no picture to show yet.
    private func buildStage() {
        stage.backgroundColor = Theme.Color.codeBackground
        stage.layer.cornerRadius = Theme.Radius.card
        stage.layer.cornerCurve = .continuous
        stage.clipsToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        player.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.tintColor = Theme.Color.tertiaryLabel
        badge.translatesAutoresizingMaskIntoConstraints = false
        caption.numberOfLines = 2
        caption.textAlignment = .center
        let idle = UIStackView(arrangedSubviews: [glyph, badge, caption])
        idle.axis = .vertical
        idle.alignment = .center
        idle.spacing = Theme.Spacing.s
        idle.translatesAutoresizingMaskIntoConstraints = false

        var config = Theme.Glass.buttonConfiguration()
        config.buttonSize = .small
        sound.configuration = config
        sound.translatesAutoresizingMaskIntoConstraints = false
        sound.addAction(UIAction { [weak self] _ in self?.onToggleSound?() }, for: .touchUpInside)

        stage.addSubview(player)
        stage.addSubview(idle)
        stage.addSubview(sound)
        let cap = stage.heightAnchor.constraint(lessThanOrEqualToConstant: Self.stageCeiling)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: stage.topAnchor),
            player.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            idle.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            idle.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            idle.leadingAnchor.constraint(
                greaterThanOrEqualTo: stage.leadingAnchor, constant: Theme.Spacing.l),
            idle.trailingAnchor.constraint(
                lessThanOrEqualTo: stage.trailingAnchor, constant: -Theme.Spacing.l),
            sound.trailingAnchor.constraint(
                equalTo: stage.trailingAnchor, constant: -Theme.Spacing.s),
            sound.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -Theme.Spacing.s),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.stageFloor),
            cap,
        ])
        stage.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(stageTapped)))
        stage.isAccessibilityElement = false
    }

    private func buildReadings() {
        title.numberOfLines = 2
        subtitle.numberOfLines = 2
        elapsed.textAlignment = .right
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        note.numberOfLines = 2
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = Theme.Color.accent
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])
    }

    private func titleRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [title, pill])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .firstBaseline
        return row
    }

    private func subtitleRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [subtitle, elapsed])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .firstBaseline
        return row
    }

    func apply(_ reading: ForgeStageReading) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        let job = reading.job
        let wrong = job.phase.tone == .danger || reading.clipFailure != nil
        applyShape(of: reading.size)
        applyStage(reading)
        title.attributedText = NSAttributedString(
            string: reading.row.title,
            attributes: Theme.Ramp.attributes(.cardTitle, color: Theme.Color.label))
        pill.apply(reading.row.badge, tone: job.phase.tone)
        subtitle.attributedText = NSAttributedString(
            string: reading.clipFailure ?? reading.row.detail,
            attributes: Theme.Ramp.attributes(
                .panelDetail,
                color: wrong ? Theme.Color.danger : Theme.Color.secondaryLabel))
        applyNote(reading.row.note)
        applyProgress(reading.row.fraction)
        applyClock(job)
        accessibilityLabel = [reading.row.title, reading.row.detail, reading.row.note]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The stage takes the shape of the frame being asked for, inside a floor and a ceiling — a
    /// portrait clip is twice as tall as a landscape one and neither may take the whole screen.
    private func applyShape(of size: ForgeSize) {
        let wanted = CGFloat(size.height) / CGFloat(max(size.width, 1))
        guard wanted != appliedRatio else { return }
        appliedRatio = wanted
        ratio?.isActive = false
        let pin = stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: wanted)
        pin.priority = UILayoutPriority(999)
        pin.isActive = true
        ratio = pin
    }

    private func applyStage(_ reading: ForgeStageReading) {
        let job = reading.job
        if let clip = reading.clip {
            player.isHidden = false
            player.show(clip)
            player.setMuted(reading.muted)
            glyph.isHidden = true
            badge.activity = nil
            caption.isHidden = true
            sound.isHidden = false
            applySoundIcon()
            stage.isUserInteractionEnabled = true
            return
        }
        player.clear()
        player.isHidden = true
        sound.isHidden = true
        stage.isUserInteractionEnabled = false
        let activity = job.phase.activity
        badge.activity = activity
        badge.isHidden = activity == nil
        glyph.isHidden = activity != nil
        glyph.image = UIImage(
            systemName: job.phase.stageSymbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular))
        glyph.tintColor = job.phase.tone == .danger
            ? Theme.Color.danger : Theme.Color.tertiaryLabel
        let words = reading.clipFailure ?? job.stageName
        caption.isHidden = words == nil
        caption.attributedText = NSAttributedString(
            string: words ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
    }

    private func applySoundIcon() {
        var config = sound.configuration ?? Theme.Glass.buttonConfiguration()
        config.image = UIImage(
            systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        sound.configuration = config
        sound.accessibilityLabel = player.isMuted
            ? String(localized: "Play sound") : String(localized: "Mute")
    }

    private func applyNote(_ words: String?) {
        note.isHidden = words == nil
        note.attributedText = NSAttributedString(
            string: words ?? "",
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
    }

    /// The bar exists exactly where there is progress to show. It only ever grows, because the
    /// census it is driven by never walks backwards, and it grows into its new width rather than
    /// jumping so a render reads as one motion instead of a series of frames.
    private func applyProgress(_ fraction: Double?) {
        guard let fraction else {
            track.isHidden = true
            return
        }
        track.isHidden = false
        let share = CGFloat(max(0.005, min(1, fraction)))
        fillWidth?.isActive = false
        let pin = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: share)
        pin.isActive = true
        fillWidth = pin
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.contentView.layoutIfNeeded()
        }
    }

    /// The elapsed reading ages on the cell's own clock inside a fixed strip of tabular digits, so
    /// a wait that grows a word never moves the card underneath it.
    private func applyClock(_ job: ForgeJob) {
        clock?.cancel()
        clock = nil
        showElapsed(Self.elapsedWords(of: job))
        guard job.isBusy else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.showElapsed(Self.elapsedWords(of: job))
            }
        }
    }

    /// How long it has taken, unless the phase's own sentence already says so — a finished render
    /// reads "Ready · 23s", and a second 23s beside it reads as a different number.
    private static func elapsedWords(of job: ForgeJob) -> String? {
        if case .done = job.phase { return nil }
        return job.spent()
    }

    private func showElapsed(_ words: String?) {
        elapsed.isHidden = words == nil
        elapsed.attributedText = NSAttributedString(
            string: words ?? "",
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.tertiaryLabel))
    }

    @objc private func stageTapped() {
        onOpenClip?()
    }
}

/// A setting, and what it currently says. Everything the board can walk by itself wears the chevron
/// pair that means "this cycles"; the two the board cannot — an address and words — wear the
/// disclosure that means "this opens". A row the render in flight has already consumed is dimmed
/// and takes no touch, because a control that looks live and changes nothing is worse than one that
/// admits it is out of reach.
final class ForgeValueCell: UICollectionViewListCell {
    private let icon = UIImageView()
    private let title = UILabel()
    private let value = UILabel()
    private let note = UILabel()
    private let working = ActivityBadgeView(pointSize: 11)
    private let pill = ForgePill()
    private let mark = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.numberOfLines = 1
        value.numberOfLines = 1
        value.lineBreakMode = .byTruncatingTail
        note.numberOfLines = 2
        mark.contentMode = .center
        mark.tintColor = Theme.Color.tertiaryLabel
        mark.setContentHuggingPriority(.required, for: .horizontal)

        let heading = UIStackView(arrangedSubviews: [title, working, pill, mark])
        heading.axis = .horizontal
        heading.spacing = Theme.Spacing.s
        heading.alignment = .center
        let column = UIStackView(arrangedSubviews: [heading, value, note])
        column.axis = .vertical
        column.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, column])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.m
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Which face a value is set in. A machine's account of itself is a sentence and is set as
    /// prose that wraps; a setting's value is data, and data is set in the mono every other row in
    /// this app sets data in.
    private static func face(of field: ForgeField) -> TypeRole {
        field == .endpoint ? .panelDetail : .rowDetail
    }

    func apply(_ row: ForgeRow, field: ForgeField, tone: ActivityTone, activity: ActivityKind?) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        let live = row.isActivatable
        icon.image = UIImage(
            systemName: field.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        icon.tintColor = Theme.Color.info
        title.attributedText = NSAttributedString(
            string: row.title,
            attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        value.numberOfLines = field == .endpoint ? 2 : 1
        value.attributedText = NSAttributedString(
            string: row.detail,
            attributes: Theme.Ramp.attributes(
                Self.face(of: field),
                color: tone == .danger ? Theme.Color.danger : Theme.Color.secondaryLabel))
        note.isHidden = row.note == nil
        note.attributedText = NSAttributedString(
            string: row.note ?? "",
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
        working.activity = activity
        pill.apply(row.badge, tone: tone)
        mark.image = UIImage(
            systemName: field.isCyclable ? "chevron.up.chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        contentView.alpha = live ? 1 : 0.4
        isUserInteractionEnabled = live
        accessibilityTraits = live ? .button : [.button, .notEnabled]
        isAccessibilityElement = true
        accessibilityLabel = "\(row.title), \(row.detail)"
    }
}

/// The two things a person types. A phone has no second window to open a prompt into, so the box
/// is the row: the placeholder is the same sentence the board uses when the field is empty, and the
/// words go back into the board on every keystroke so the render button never fires on a prompt
/// that is one character behind what is on screen.
final class ForgeWordsCell: UICollectionViewListCell, UITextViewDelegate {
    var onEdit: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?

    private let heading = UILabel()
    private let box = UITextView()
    private let placeholder = UILabel()
    private var height: NSLayoutConstraint!

    private static let promptLines: CGFloat = 4
    private static let avoidLines: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.delegate = self
        box.backgroundColor = .clear
        box.textContainerInset = .zero
        box.textContainer.lineFragmentPadding = 0
        box.autocapitalizationType = .none
        box.autocorrectionType = .yes
        box.keyboardType = .default
        box.translatesAutoresizingMaskIntoConstraints = false
        placeholder.numberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let column = UIStackView(arrangedSubviews: [heading, box])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        contentView.addSubview(placeholder)
        height = box.heightAnchor.constraint(equalToConstant: 80)
        NSLayoutConstraint.activate([
            height,
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEdit = nil
        onFocus = nil
    }

    func apply(_ row: ForgeRow, field: ForgeField, words: String, hint: String) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        heading.attributedText = NSAttributedString(
            string: field.label.localizedUppercase,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        let ink = Theme.Ramp.attributes(.answer, color: Theme.Color.label)
        if box.text != words { box.attributedText = NSAttributedString(string: words, attributes: ink) }
        box.typingAttributes = ink
        placeholder.attributedText = NSAttributedString(
            string: hint,
            attributes: Theme.Ramp.attributes(.answer, color: Theme.Color.tertiaryLabel))
        placeholder.isHidden = !words.isEmpty
        let lines = field == .prompt ? Self.promptLines : Self.avoidLines
        height.constant = ceil(Theme.Ramp.font(.answer).lineHeight * lines)
        box.isEditable = row.isActivatable
        contentView.alpha = row.isActivatable ? 1 : 0.4
        box.accessibilityLabel = field.label
    }

    func focus() {
        box.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        onEdit?(textView.text)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        onFocus?(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onFocus?(false)
    }
}

/// A clip that was made. The receipt is all this device keeps, so a row says what was asked for,
/// how it went and how long ago — and a row whose file the renderer no longer has says that
/// instead of failing the same way on every tap.
final class ForgeClipCell: UICollectionViewListCell {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let stamp = UILabel()
    private let pill = ForgePill()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.numberOfLines = 2
        detail.numberOfLines = 2
        stamp.setContentHuggingPriority(.required, for: .horizontal)
        stamp.setContentCompressionResistancePriority(.required, for: .horizontal)

        let heading = UIStackView(arrangedSubviews: [title, pill])
        heading.axis = .horizontal
        heading.spacing = Theme.Spacing.s
        heading.alignment = .firstBaseline
        let feet = UIStackView(arrangedSubviews: [detail, stamp])
        feet.axis = .horizontal
        feet.spacing = Theme.Spacing.s
        feet.alignment = .firstBaseline
        let column = UIStackView(arrangedSubviews: [heading, feet])
        column.axis = .vertical
        column.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, column])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.m
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: ForgeRow, entry: ForgeEntry, gone: String?) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        let wrong = gone != nil || !entry.isPlayable
        icon.image = UIImage(
            systemName: symbol(playable: entry.isPlayable, gone: gone != nil),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        icon.tintColor = wrong ? ActivityTone.danger.color : Theme.Color.accent
        title.attributedText = NSAttributedString(
            string: row.title,
            attributes: Theme.Ramp.attributes(.rowTitle, color: Theme.Color.label))
        detail.numberOfLines = wrong ? 2 : 1
        detail.lineBreakMode = .byTruncatingTail
        detail.attributedText = NSAttributedString(
            string: gone ?? row.detail,
            attributes: Theme.Ramp.attributes(
                wrong ? .panelDetail : .rowDetail,
                color: wrong ? Theme.Color.danger : Theme.Color.secondaryLabel))
        stamp.attributedText = NSAttributedString(
            string: StatusFacts.age(Date().timeIntervalSince(entry.finishedAt)),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.tertiaryLabel))
        pill.apply(row.badge, tone: wrong ? .danger : .quiet)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(row.title), \(gone ?? row.detail)"
    }

    private func symbol(playable: Bool, gone: Bool) -> String {
        guard playable else { return "exclamationmark.triangle.fill" }
        return gone ? "film" : "play.rectangle.fill"
    }
}

/// A line the board owed the reader — an empty history, a section that failed, the standing fact
/// about where a render actually happens. Never something to press.
final class ForgeNoteCell: UICollectionViewListCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            label.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            label.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ words: String, tone: ActivityTone) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        label.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .panelFootnote,
                color: tone == .danger ? Theme.Color.danger : Theme.Color.tertiaryLabel))
        isAccessibilityElement = true
        accessibilityLabel = words
    }
}

/// The row a compacted section holds the rest of itself behind. The board's own caption for it
/// names a key a phone does not have, so only the count is drawn and the chevron says the rest.
final class ForgeExpanderCell: UICollectionViewListCell {
    private let label = UILabel()
    private let mark = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        mark.contentMode = .center
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, mark])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ row: ForgeRow, expanded: Bool) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        label.attributedText = NSAttributedString(
            string: row.title,
            attributes: Theme.Ramp.attributes(.rowTitle, color: Theme.Color.accent))
        mark.image = UIImage(
            systemName: expanded ? "chevron.up" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        mark.tintColor = Theme.Color.accent
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = row.title
    }
}
