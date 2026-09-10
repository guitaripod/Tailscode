import TailscodeCore
import UIKit

/// Everything the stage draws, in one value, so the cell is told what the studio is rather than
/// reaching back into it while it scrolls.
struct ImageStageReading {
    let slot: ImageGenSlot
    let exhibit: ImageExhibit?
    /// The picture at full size, when this device has it.
    let image: UIImage?
    /// A small copy to show while the full one is fetched — a kept picture's tile.
    let placeholder: UIImage?
    /// Height over width of what the stage should be shaped for.
    let ratio: CGFloat
    /// What a screen reader is told the picture is: its words, when they are known.
    let caption: String?
    let startedAt: Date?
    let progress: ImageGenProgress?
}

/// The room: one picture at the size the screen can give it, and — when there is no picture yet —
/// the state that explains why. An empty studio argues for itself rather than showing a grey
/// rectangle, and a render in flight paints in place of the picture so the eye never has to go
/// looking for where the answer will appear: the last picture stays under it, dimmed, while the
/// machine's own words say what it is doing and the sampler's own count fills the bar.
final class ImageStageCell: UICollectionViewListCell {
    var onOpen: (() -> Void)?

    private let stage = UIView()
    private let picture = UIImageView()
    private let scrim = UIView()
    private let glyph = UIImageView()
    private let badge = ActivityBadgeView(pointSize: 22)
    private let title = UILabel()
    private let body = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let idle = UIStackView()
    private var ratio: NSLayoutConstraint?
    private var appliedRatio: CGFloat = 0
    private var clock: Task<Void, Never>?
    private var reading: ImageStageReading?

    private static let floor: CGFloat = 260

    override init(frame: CGRect) {
        super.init(frame: frame)
        stage.backgroundColor = Theme.Color.codeBackground
        stage.layer.cornerRadius = Theme.Radius.card
        stage.layer.cornerCurve = .continuous
        stage.clipsToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        picture.contentMode = .scaleAspectFit
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.isAccessibilityElement = false
        scrim.backgroundColor = Theme.Color.codeBackground.withAlphaComponent(0.72)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isHidden = true
        glyph.contentMode = .center
        glyph.tintColor = Theme.Color.tertiaryLabel
        badge.translatesAutoresizingMaskIntoConstraints = false
        title.numberOfLines = 3
        title.textAlignment = .center
        body.numberOfLines = 3
        body.textAlignment = .center
        bar.trackTintColor = Theme.Color.separator
        bar.progressTintColor = Theme.Color.accent
        bar.layer.cornerRadius = 2
        bar.clipsToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 168).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        idle.axis = .vertical
        idle.alignment = .center
        idle.spacing = Theme.Spacing.s
        idle.translatesAutoresizingMaskIntoConstraints = false
        [glyph, badge, title, body, bar].forEach(idle.addArrangedSubview)
        idle.setCustomSpacing(Theme.Spacing.m, after: body)

        contentView.addSubview(stage)
        stage.addSubview(picture)
        stage.addSubview(scrim)
        stage.addSubview(idle)
        stage.addSubview(spinner)
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            stage.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            stage.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            stage.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.floor),
            picture.topAnchor.constraint(equalTo: stage.topAnchor),
            picture.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: stage.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            idle.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            idle.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            idle.leadingAnchor.constraint(
                greaterThanOrEqualTo: stage.leadingAnchor, constant: Theme.Spacing.xl),
            idle.trailingAnchor.constraint(
                lessThanOrEqualTo: stage.trailingAnchor, constant: -Theme.Spacing.xl),
            spinner.trailingAnchor.constraint(
                equalTo: stage.trailingAnchor, constant: -Theme.Spacing.m),
            spinner.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        stage.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(stageTapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        clock?.cancel()
        clock = nil
        onOpen = nil
        reading = nil
    }

    func apply(_ reading: ImageStageReading, ceiling: CGFloat) {
        self.reading = reading
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        applyShape(reading.ratio, ceiling: ceiling)
        applyStage(reading)
    }

    /// The stage takes the shape of the picture on it — or, with none, of the one being asked for
    /// — inside a floor and a ceiling, so a portrait render is tall and neither shape takes the
    /// whole screen.
    private func applyShape(_ wanted: CGFloat, ceiling: CGFloat) {
        let width = max(contentView.bounds.width - 2 * Theme.Spacing.m, 200)
        let capped = min(wanted, max(ceiling, Self.floor) / width)
        guard abs(capped - appliedRatio) > 0.001 else { return }
        appliedRatio = capped
        ratio?.isActive = false
        let pin = stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: capped)
        pin.priority = UILayoutPriority(999)
        pin.isActive = true
        ratio = pin
    }

    private func applyStage(_ reading: ImageStageReading) {
        clock?.cancel()
        clock = nil
        let shown = reading.image ?? reading.placeholder
        picture.image = shown
        picture.isHidden = shown == nil
        spinner.stopAnimating()
        if !reading.slot.isBusy, reading.slot.failure == nil, shown != nil {
            scrim.isHidden = true
            idle.isHidden = true
            badge.activity = nil
            stage.isUserInteractionEnabled = reading.image != nil
            if reading.image == nil { spinner.startAnimating() }
            accessibilityLabel = reading.caption ?? ImageGenLibraryWords.title
            accessibilityTraits = [.image, .button]
            isAccessibilityElement = true
            return
        }
        scrim.isHidden = shown == nil
        idle.isHidden = false
        stage.isUserInteractionEnabled = false
        accessibilityTraits = []
        bar.isHidden = true
        switch reading.slot.phase {
        case .painting:
            badge.activity = .working
            badge.isHidden = false
            glyph.isHidden = true
            show(title: reading.slot.activePrompt ?? "", tone: Theme.Color.label)
            applyProgress(reading.progress, startedAt: reading.startedAt)
            startClock()
        case .failed(_, let reason):
            badge.activity = nil
            badge.isHidden = true
            glyph.isHidden = false
            showGlyph("exclamationmark.triangle", tint: Theme.Color.danger)
            show(title: reason, tone: Theme.Color.danger)
            show(body: reading.slot.activePrompt ?? "")
        case .asking, .composing:
            badge.activity = nil
            badge.isHidden = true
            glyph.isHidden = false
            showGlyph(ImageGenEntryPoint.symbol, tint: Theme.Color.tertiaryLabel)
            show(title: ImageGenWords.emptyTitle, tone: Theme.Color.label)
            show(body: ImageGenWords.emptyBody)
        }
        isAccessibilityElement = true
        accessibilityLabel = [title.text, body.text].compactMap { $0 }.joined(separator: ", ")
    }

    /// The machine's own words and the sampler's own count, moved in place: a frame changes the
    /// line and the bar, never the layout around them.
    func applyProgress(_ progress: ImageGenProgress?, startedAt: Date?) {
        guard let reading, reading.slot.isBusy else { return }
        show(body: reading.slot.waitingLine(since: startedAt, progress: progress))
        if let fraction = progress?.bar {
            let wasHidden = bar.isHidden
            bar.isHidden = false
            bar.setProgress(Float(fraction), animated: !wasHidden)
        } else {
            bar.isHidden = true
        }
        self.reading = ImageStageReading(
            slot: reading.slot, exhibit: reading.exhibit, image: reading.image,
            placeholder: reading.placeholder, ratio: reading.ratio, caption: reading.caption,
            startedAt: startedAt, progress: progress)
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a cell that keeps a timer alive over a settled state spends frames on
    /// nothing.
    private func startClock() {
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let reading = self.reading else { return }
                self.show(
                    body: reading.slot.waitingLine(
                        since: reading.startedAt, progress: reading.progress))
            }
        }
    }

    private func showGlyph(_ symbol: String, tint: UIColor) {
        glyph.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        glyph.tintColor = tint
    }

    private func show(title words: String, tone: UIColor) {
        title.isHidden = words.isEmpty
        title.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(.cardTitle, color: tone, alignment: .center))
    }

    private func show(body words: String) {
        body.isHidden = words.isEmpty
        body.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
    }

    @objc private func stageTapped() {
        onOpen?()
    }
}

/// The words that made the picture, and what it cost. Facts rather than a caption: the prompt is
/// what a person reads before deciding whether to roll again, and the line under it is mono and
/// tabular so a column of renders can be compared down the page. A kept picture says once that
/// its words came from the file.
final class ImageCaptionCell: UICollectionViewListCell {
    private let caption = UILabel()
    private let facts = UILabel()
    private let note = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.numberOfLines = 6
        facts.numberOfLines = 2
        note.numberOfLines = 2
        let column = UIStackView(arrangedSubviews: [caption, facts, note])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(caption words: String, facts line: String, note words2: String?, known: Bool) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        caption.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .cardBody, color: known ? Theme.Color.label : Theme.Color.tertiaryLabel))
        facts.isHidden = line.isEmpty
        facts.attributedText = NSAttributedString(
            string: line,
            attributes: Theme.Ramp.attributes(.responseStat, color: Theme.Color.tertiaryLabel))
        note.isHidden = words2 == nil
        note.attributedText = NSAttributedString(
            string: words2 ?? "",
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
        isAccessibilityElement = true
        accessibilityLabel = [words, line, words2].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// What a finished picture can be made to do, which is the reason this is a place rather than a
/// button. One row, every verb the same width, an icon over its word — the shape a hand already
/// knows from the share sheet — and the one that destroys something drawn in the failure colour.
final class ImageActionsCell: UICollectionViewListCell {
    var onAction: ((ImageGenAction) -> Void)?

    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = Theme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }

    func apply(_ actions: [ImageGenAction], referenceHeld: Bool, busy: Bool) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            row.addArrangedSubview(button(for: action, referenceHeld: referenceHeld, busy: busy))
        }
    }

    private func button(for action: ImageGenAction, referenceHeld: Bool, busy: Bool) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .top
        config.imagePadding = Theme.Spacing.xs
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: 0, bottom: Theme.Spacing.s, trailing: 0)
        config.image = UIImage(
            systemName: action == .reference && referenceHeld ? "checkmark.circle.fill" : action.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        var title = AttributedString(action.phoneTitle)
        title.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = title
        config.titleAlignment = .center
        config.baseForegroundColor = action.isDestructive ? Theme.Color.danger : Theme.Color.accent
        let button = UIButton(configuration: config)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.addAction(
            UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        button.accessibilityLabel = action.title
        button.accessibilityHint = action.hint
        button.isEnabled = !(action == .again && busy)
        if action == .reference, referenceHeld {
            button.accessibilityValue = String(localized: "Already the reference")
        }
        return button
    }
}

/// The studio with nowhere to send a picture: the argument and the one button, the same as the
/// forge leads with. It appears only when a renderer this device knew has been forgotten while the
/// surface was up — the door decides whether the studio is offered at all.
final class ImageSetupCell: UICollectionViewListCell {
    var onSetup: (() -> Void)?

    private let title = UILabel()
    private let body = UILabel()
    private let button = PrimaryButton(title: ForgeSetup.title)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.numberOfLines = 2
        body.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [title, body, button])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        button.addAction(UIAction { [weak self] _ in self?.onSetup?() }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSetup = nil
    }

    func apply() {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = Theme.Color.groupedSurface
        background.cornerRadius = Theme.Radius.card
        backgroundConfiguration = background
        title.attributedText = NSAttributedString(
            string: ImageGenEntryPoint.tooltip(configured: false),
            attributes: Theme.Ramp.attributes(.cardTitle))
        body.attributedText = NSAttributedString(
            string: ImageGenWords.emptyBody,
            attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
    }
}

/// The shelf's heading: which machine, how many, how fresh, and the one control that asks again.
final class ImageLibraryHeader: UICollectionReusableView {
    var onRefresh: (() -> Void)?

    private let title = UILabel()
    private let line = UILabel()
    private let refresh = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.numberOfLines = 1
        line.numberOfLines = 1
        let column = UIStackView(arrangedSubviews: [title, line])
        column.axis = .vertical
        column.spacing = 2
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.image = UIImage(
            systemName: "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        refresh.configuration = config
        refresh.accessibilityLabel = ImageGenLibraryWords.refresh
        refresh.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .touchUpInside)
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true
        let row = UIStackView(arrangedSubviews: [column, spinner, refresh])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(machine: String, line words: String, loading: Bool) {
        title.attributedText = NSAttributedString(
            string: ImageGenLibraryWords.heading(machine: machine),
            attributes: Theme.Ramp.attributes(.panelTitle))
        line.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.secondaryLabel))
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        refresh.isEnabled = !loading
        isAccessibilityElement = false
        title.accessibilityLabel = "\(ImageGenLibraryWords.heading(machine: machine)), \(words)"
    }
}

/// One kept picture, drawn small. The tile asks the library for its own thumbnail and shows it
/// when it lands, keyed so a cell reused mid-flight never wears the wrong picture; the one on the
/// stage is framed in the accent.
final class ImageTileCell: UICollectionViewCell {
    private let picture = UIImageView()
    private let frameView = UIView()
    private let placeholder = UIImageView()
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.Color.codeBackground
        contentView.layer.cornerRadius = 6
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.translatesAutoresizingMaskIntoConstraints = false
        placeholder.contentMode = .center
        placeholder.tintColor = Theme.Color.tertiaryLabel
        placeholder.image = UIImage(
            systemName: "photo",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .light))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 6
        frameView.layer.cornerCurve = .continuous
        frameView.isUserInteractionEnabled = false
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.isHidden = true
        contentView.addSubview(placeholder)
        contentView.addSubview(picture)
        contentView.addSubview(frameView)
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: contentView.topAnchor),
            picture.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            frameView.topAnchor.constraint(equalTo: contentView.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            frameView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = UUID()
        picture.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        frameView.layer.borderColor = Theme.Color.accent.cgColor
    }

    func apply(_ item: ImageGenLibraryItem, library: ImageLibrary, onStage: Bool) {
        frameView.isHidden = !onStage
        accessibilityTraits = onStage ? [.image, .button, .selected] : [.image, .button]
        let facts = library.facts(of: item)
        accessibilityLabel = facts.map(ImageGenFacts.caption(for:)) ?? item.filename
        if let held = library.cachedThumbnail(of: item) {
            picture.image = held
            return
        }
        picture.image = nil
        let mine = token
        Task { [weak self] in
            let image = await library.thumbnail(of: item)
            guard let self, self.token == mine, let image else { return }
            UIView.transition(with: self.picture, duration: 0.18, options: .transitionCrossDissolve) {
                self.picture.image = image
            }
        }
    }
}

/// What the shelf says when it has no tiles to show: that it is asking, that there is nothing
/// yet, or why it could not ask — in the machine's name, never as a blank.
final class ImageLibraryStateCell: UICollectionViewListCell {
    private let glyph = UIImageView()
    private let title = UILabel()
    private let body = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.contentMode = .center
        title.numberOfLines = 2
        title.textAlignment = .center
        body.numberOfLines = 3
        body.textAlignment = .center
        spinner.hidesWhenStopped = true
        let column = UIStackView(arrangedSubviews: [spinner, glyph, title, body])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xl),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: ImageLibrary.State) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        switch state {
        case .idle, .loading:
            spinner.startAnimating()
            glyph.isHidden = true
            set(title: ImageGenLibraryWords.loading, tone: Theme.Color.secondaryLabel)
            set(body: nil)
        case .loaded:
            spinner.stopAnimating()
            glyph.isHidden = false
            glyph.image = UIImage(
                systemName: "photo.stack",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light))
            glyph.tintColor = Theme.Color.tertiaryLabel
            set(title: ImageGenLibraryWords.emptyTitle, tone: Theme.Color.label)
            set(body: ImageGenLibraryWords.emptyBody)
        case .failed(let reason):
            spinner.stopAnimating()
            glyph.isHidden = false
            glyph.image = UIImage(
                systemName: "wifi.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light))
            glyph.tintColor = Theme.Color.warning
            set(title: reason, tone: Theme.Color.label)
            set(body: nil)
        }
        isAccessibilityElement = true
        accessibilityLabel = [title.text, body.text].compactMap { $0 }.joined(separator: ", ")
    }

    private func set(title words: String, tone: UIColor) {
        title.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(.cardTitle, color: tone, alignment: .center))
    }

    private func set(body words: String?) {
        body.isHidden = words == nil
        body.attributedText = NSAttributedString(
            string: words ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
    }
}

/// One decision, worn as a control, in both places a picture is composed — the studio's dock and
/// the composer's lane. A press walks the value because a chip is a value that walks; the whole
/// short list is a press and a hold away, because a phone has no tooltip to say what the other
/// shapes are called.
enum ImageChip {
    @MainActor
    static func button(symbol: String, title: String, image: UIImage? = nil) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byTruncatingTail
        if let image {
            let side: CGFloat = 20
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = UIScreen.main.scale
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
                .image { _ in
                    let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 5)
                    path.addClip()
                    let scale = max(side / image.size.width, side / image.size.height)
                    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(
                        in: CGRect(
                            x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                            width: drawn.width, height: drawn.height))
                }
            config.image = thumb.withRenderingMode(.alwaysOriginal)
        } else {
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        }
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = name
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        return button
    }

    /// The engine list says what each engine is for and which the machine, as last seen, cannot
    /// run — greyed with the count of files it lacks, rather than offered and refused at send.
    @MainActor
    static func engineMenu(
        slot: ImageGenSlot, sighting: ImageGenSighting?, onEngine: @escaping (ImageGenEngine) -> Void
    ) -> UIMenu {
        UIMenu(
            title: ImageGenField.engine.label,
            children: ImageGenEngine.allCases.map { engine in
                let missing = sighting?.reachable == true ? sighting?.missing(for: engine).count ?? 0 : 0
                let subtitle = missing > 0
                    ? ImageGenWords.engineUnavailable(engine, missing: missing) : engine.detail
                return UIAction(
                    title: engine.short, subtitle: subtitle,
                    image: missing > 0 ? UIImage(systemName: "exclamationmark.triangle") : nil,
                    state: engine == slot.engine ? .on : .off
                ) { _ in onEngine(engine) }
            })
    }

    @MainActor
    static func aspectMenu(slot: ImageGenSlot, onAspect: @escaping (ImageGenAspect) -> Void) -> UIMenu {
        UIMenu(
            title: ImageGenField.aspect.label,
            children: ImageGenAspect.allCases.map { aspect in
                UIAction(
                    title: aspect.short, subtitle: aspect.label,
                    state: aspect == slot.aspect ? .on : .off
                ) { _ in onAspect(aspect) }
            })
    }

    /// The sources a reference can come from on this device, as menu rows.
    @MainActor
    static func sourceActions(
        available: [ImageGenReferenceSource], onPick: @escaping (ImageGenReferenceSource) -> Void
    ) -> [UIAction] {
        available.map { source in
            UIAction(title: source.title, image: UIImage(systemName: source.symbol)) { _ in
                onPick(source)
            }
        }
    }
}
