import TailscodeCore
import UIKit

/// The line under an open brain: what the latest step is, in one line that is replaced rather
/// than grown, and where it stands in the turn. Digits are tabular because the counter changes
/// while a person watches it.
@MainActor
final class BrainTicker: UIView {
    private let dot = UIView()
    private let label = UILabel()
    private let counter = UILabel()
    private var lastKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        counter.adjustsFontForContentSizeCategory = true
        counter.setContentHuggingPriority(.required, for: .horizontal)
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        counter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        addSubview(counter)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.Spacing.s),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            counter.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: Theme.Spacing.s),
            counter.trailingAnchor.constraint(equalTo: trailingAnchor),
            counter.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows the ticker's step, or nothing for a turn at rest.
    func show(_ ticker: NeuralTicker?, ink: BrainInk) {
        isHidden = ticker == nil
        guard let ticker else {
            lastKey = nil
            return
        }
        let key = "\(ticker.stepID)|\(ticker.text)|\(ticker.status)|\(ticker.counter)"
        guard key != lastKey else { return }
        lastKey = key
        let tone = ink.color(for: NeuralNodes.tone(of: ticker.status), zone: ticker.zone)
        dot.backgroundColor = tone
        let text = NSMutableAttributedString(
            string: ticker.title,
            attributes: Theme.Ramp.attributes(.toolName, color: Theme.Color.label))
        if !ticker.detail.isEmpty {
            text.append(
                NSAttributedString(
                    string: "  " + ticker.detail,
                    attributes: Theme.Ramp.attributes(
                        .toolDetail, color: Theme.Color.secondaryLabel)))
        }
        label.attributedText = text
        counter.attributedText = NSAttributedString(
            string: ticker.counter,
            attributes: Theme.Ramp.attributes(.responseStat, color: Theme.Color.tertiaryLabel))
        accessibilityLabel = Localized.text(
            "%1$@, %2$@", ticker.text, ticker.counter)
    }
}

/// The scrubber and its button: a slider across the whole turn, a play and pause control, and the
/// clock of the step the playhead is at. A drag takes the playhead, a release leaves it where it
/// was put, and the end of the slider is the turn as it stands.
@MainActor
final class BrainScrubber: UIView {
    var onPlayPause: (() -> Void)?
    var onBegan: (() -> Void)?
    var onMoved: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onShare: (() -> Void)?

    private let shareButton = UIButton(type: .system)
    private let play = UIButton(type: .system)
    private let track = BrainScrubTrack()
    private let clock = UILabel()
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        play.configuration = config
        play.translatesAutoresizingMaskIntoConstraints = false
        play.addAction(UIAction { [weak self] _ in self?.onPlayPause?() }, for: .touchUpInside)
        play.answersPointer(cornerRadius: Theme.Radius.control)

        track.translatesAutoresizingMaskIntoConstraints = false
        track.onBegan = { [weak self] in
            self?.isDragging = true
            self?.onBegan?()
        }
        track.onMoved = { [weak self] fraction in self?.onMoved?(fraction) }
        track.onEnded = { [weak self] in
            self?.isDragging = false
            self?.onEnded?()
        }

        clock.adjustsFontForContentSizeCategory = true
        clock.textAlignment = .right
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.translatesAutoresizingMaskIntoConstraints = false
        var share = UIButton.Configuration.plain()
        share.image = UIImage(
            systemName: "square.and.arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        share.baseForegroundColor = Theme.Color.accent
        share.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        shareButton.configuration = share
        shareButton.accessibilityLabel = Localized.text("Share this turn")
        shareButton.toolTip = Localized.text("Share this turn")
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.addAction(UIAction { [weak self] _ in self?.onShare?() }, for: .touchUpInside)
        shareButton.answersPointer(cornerRadius: Theme.Radius.control)
        shareButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(play)
        addSubview(track)
        addSubview(clock)
        addSubview(shareButton)
        NSLayoutConstraint.activate([
            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            shareButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 44),
            shareButton.heightAnchor.constraint(equalToConstant: 36),
            play.leadingAnchor.constraint(equalTo: leadingAnchor),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
            play.widthAnchor.constraint(equalToConstant: 44),
            play.heightAnchor.constraint(equalToConstant: 36),
            track.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: Theme.Spacing.xs),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: BrainScrubTrack.touchHeight),
            clock.leadingAnchor.constraint(equalTo: track.trailingAnchor, constant: Theme.Spacing.s),
            clock.trailingAnchor.constraint(equalTo: shareButton.leadingAnchor),
            clock.centerYAnchor.constraint(equalTo: centerYAnchor),
            clock.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Draws the playhead. While a finger is on the track the track is the finger's, not the
    /// model's. `ticks` are where steps fire, as fractions; `spoken` reads a position aloud.
    func show(
        fraction: Double, playing: Bool, clock text: String?, ticks: [Double],
        spoken: @escaping (Double) -> String
    ) {
        track.configure(ticks: ticks, spoken: spoken)
        track.set(value: fraction)
        var config = play.configuration ?? .plain()
        config.image = UIImage(
            systemName: playing ? "pause.fill" : "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.baseForegroundColor = Theme.Color.accent
        play.configuration = config
        play.accessibilityLabel = playing ? Localized.text("Pause") : NeuralReading.replayLabel
        clock.attributedText = NSAttributedString(
            string: text ?? "",
            attributes: Theme.Ramp.attributes(
                .responseStat, color: Theme.Color.tertiaryLabel, alignment: .right))
    }
}

/// The path words in an answer that some step touched literally, as a row of chips. Pointing at
/// one lights the steps behind it and dims the rest; nothing that is not a literal match is offered.
@MainActor
final class BrainChips: UIView {
    var onSelect: ((String?) -> Void)?

    private let scroll = UIScrollView()
    private let row = UIStackView()
    private let caption = UILabel()
    private var tokens: [String] = []
    private var selected: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.adjustsFontForContentSizeCategory = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentHuggingPriority(.required, for: .horizontal)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = Theme.Spacing.xs
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        addSubview(caption)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: Theme.Spacing.s),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(tokens new: [String], selected newSelected: String?) {
        isHidden = new.isEmpty
        guard new != tokens || newSelected != selected else { return }
        tokens = new
        selected = newSelected
        caption.attributedText = NSAttributedString(
            string: Localized.text("In the answer"),
            attributes: Theme.Ramp.attributes(.rowNote, color: Theme.Color.tertiaryLabel))
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for token in new {
            let on = token == newSelected
            var config = UIButton.Configuration.plain()
            config.attributedTitle = AttributedString(
                NSAttributedString(
                    string: token,
                    attributes: Theme.Ramp.attributes(
                        .toolDetail, color: on ? Theme.Color.onAccent : Theme.Color.label)))
            config.background.backgroundColor =
                on ? Theme.Color.accent : Theme.Color.groupedSurface
            config.background.cornerRadius = 15
            config.contentInsets = NSDirectionalEdgeInsets(
                top: 6, leading: 10, bottom: 6, trailing: 10)
            let button = UIButton(configuration: config)
            button.addAction(
                UIAction { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.onSelect?(on ? nil : token)
                }, for: .touchUpInside)
            button.accessibilityLabel = Localized.text("Show the steps behind %@", token)
            button.accessibilityTraits = on ? [.button, .selected] : .button
            row.addArrangedSubview(button)
        }
    }
}

/// The steps of one zone, listed under a dive: what the head flew into, one row a step, with the
/// way back. It is also the touch and screen-reader path into a zone that is too small to pick a
/// node out of.
@MainActor
final class BrainZoneList: UIView {
    var onBack: (() -> Void)?
    var onPick: ((String) -> Void)?

    private let header = UIStackView()
    private let back = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let scroll = UIScrollView()
    private let rows = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.background.withAlphaComponent(0.94)
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        isHidden = true

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        config.baseForegroundColor = Theme.Color.accent
        back.configuration = config
        back.accessibilityLabel = Localized.text("Back to the whole head")
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        back.answersPointer(cornerRadius: Theme.Radius.control)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.xs
        [back, titleLabel, UIView()].forEach(header.addArrangedSubview)
        header.translatesAutoresizingMaskIntoConstraints = false

        rows.axis = .vertical
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.xs),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.m),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformEscape() -> Bool {
        guard !isHidden else { return false }
        onBack?()
        return true
    }

    /// Lists a zone's steps. `steps` are the model's, in turn order.
    func show(zone: NeuralZone, steps: [NeuralStep], ink: BrainInk) {
        let count = Localized.text("%lld steps", steps.count)
        titleLabel.attributedText = NSAttributedString(
            string: Localized.text("%1$@ · %2$@", zone.label, count),
            attributes: Theme.Ramp.attributes(.cardTitle))
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for step in steps {
            rows.addArrangedSubview(row(for: step, total: steps.count, ink: ink))
        }
        isHidden = false
    }

    func dismiss() { isHidden = true }

    private func row(for step: NeuralStep, total: Int, ink: BrainInk) -> UIView {
        let icon = BrainShapeIcon()
        icon.set(
            shape: step.zone.shape,
            color: ink.color(for: NeuralNodes.tone(of: step.status), zone: step.zone))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        let said = NeuralReading.isThought(step) || NeuralReading.isNote(step) ? step.text : step.detail
        let text = NSMutableAttributedString(
            string: String(step.index + 1) + "  ",
            attributes: Theme.Ramp.attributes(.responseStat, color: Theme.Color.tertiaryLabel))
        text.append(
            NSAttributedString(
                string: NeuralReading.title(of: step),
                attributes: Theme.Ramp.attributes(.toolName)))
        if !said.isEmpty {
            text.append(
                NSAttributedString(
                    string: "  " + said,
                    attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel)))
        }
        label.attributedText = text
        label.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.onPick?(step.id)
            }, for: .touchUpInside)
        button.accessibilityLabel = NeuralReading.announcement(for: step, of: total)
        button.answersPointer(cornerRadius: Theme.Radius.control)
        let container = UIView()
        container.addSubview(icon)
        container.addSubview(label)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        return container
    }
}
