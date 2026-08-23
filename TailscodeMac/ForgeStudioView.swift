import AVKit
import AppKit
import TailscodeCore

/// The forge as a studio: the stage is the room, the words are typed once, the settings walk as
/// chips, and what was made is a strip of clips. Every word is still `ForgeBoard`'s.
@MainActor
final class ForgeStudioView: NSView {
    var onCycle: ((ForgeField) -> Void)?
    var onConfigure: (() -> Void)?
    var onCall: (() -> Void)?
    var onActivateHistory: ((Int) -> Void)?
    var onClipMenu: ((ForgeEntry, NSView, NSPoint) -> Void)?

    private let split = NSSplitView()
    private let stage = ForgeHeroStage()
    private let film = ForgeFilmstrip()
    private let renderer = ForgeChipButton()
    private let chips = ForgeChipWrap()
    private let call = RowKit.ActionButton(title: ForgeBoard().renderCall) {}
    private let status = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stageColumn = FillingStack(views: [status, stage, film])
        stageColumn.spacing = MacTheme.Spacing.s
        stageColumn.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        stage.setContentHuggingPriority(.init(1), for: .vertical)
        stage.setContentCompressionResistancePriority(.init(1), for: .vertical)

        film.onActivate = { [weak self] offset in self?.onActivateHistory?(offset) }
        film.onClipMenu = { [weak self] entry, view, point in
            self?.onClipMenu?(entry, view, point)
        }
        renderer.onPress = { [weak self] in self?.onConfigure?() }
        chips.onCycle = { [weak self] field in self?.onCycle?(field) }
        call.setAction { [weak self] in self?.onCall?() }

        split.addArrangedSubview(stageColumn)
        split.addArrangedSubview(makeControls())
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = split.bounds.width
        guard width > 0 else { return }
        let stageWidth = width * ForgeStudio.stageShare
        if abs(split.dividerPosition - stageWidth) > 8 {
            split.setPosition(stageWidth, ofDividerAt: 0)
        }
    }

    func attachPrompt(_ field: NSView, avoid: NSView, aside: NSView) {
        controls.insertArrangedSubview(field, at: 1)
        controls.insertArrangedSubview(avoid, at: 2)
        controls.insertArrangedSubview(aside, at: 4)
    }

    private let controls = FillingStack()

    private func makeControls() -> NSView {
        controls.spacing = MacTheme.Spacing.s
        controls.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        controls.addArrangedSubview(renderer)
        controls.addArrangedSubview(chips)
        controls.addArrangedSubview(call)
        controls.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(ForgeStudio.controlWidth))
            .isActive = true
        controls.setHuggingPriority(.defaultHigh, for: .horizontal)
        return controls
    }

    func render(_ board: ForgeBoard, clip: URL?, clipFailure: String?, gone: (ForgeEntry) -> String?)
    {
        status.stringValue = board.job.title
        status.font = MacTheme.Ramp.font(.cardTitle)
        status.textColor = MacTheme.Color.label
        status.lineBreakMode = .byTruncatingTail
        stage.render(board.job, clip: clip, failure: clipFailure, size: board.recipe.size)
        film.render(board, gone: gone)
        if let row = board.rows.first(where: { $0.kind == .field(.endpoint) }) {
            renderer.render(
                title: row.title, detail: row.detail, badge: row.badge,
                focused: row.id == board.focused?.id)
        }
        chips.render(board)
        call.title = board.renderCall
        call.contentTintColor = board.isBusy ? MacTheme.Color.danger : MacTheme.Color.accent
    }

    func quietStage() { stage.pause() }

    var promptHost: NSView { controls }
}

private extension NSSplitView {
    var dividerPosition: CGFloat {
        guard arrangedSubviews.count > 1 else { return 0 }
        return arrangedSubviews[0].frame.width
    }
}

@MainActor
final class ForgeHeroStage: NSView {
    private let glyph = NSImageView()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let bar = ForgeBarView()
    private let idle = NSStackView()
    private var player: AVPlayerView?
    private var clipURL: URL?
    private var ratio: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        glyph.contentTintColor = MacTheme.Color.tertiaryLabel
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        caption.textColor = MacTheme.Color.secondaryLabel
        caption.alignment = .center
        caption.maximumNumberOfLines = 3
        idle.orientation = .vertical
        idle.alignment = .centerX
        idle.spacing = MacTheme.Spacing.s
        idle.setViews([glyph, caption, bar], in: .center)
        idle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(idle)
        NSLayoutConstraint.activate([
            idle.centerXAnchor.constraint(equalTo: centerXAnchor),
            idle.centerYAnchor.constraint(equalTo: centerYAnchor),
            idle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: MacTheme.Spacing.l),
            idle.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.l),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ job: ForgeJob, clip: URL?, failure: String?, size: ForgeSize) {
        applyShape(of: size)
        if let clip {
            show(clip)
            idle.isHidden = true
            return
        }
        player?.isHidden = true
        idle.isHidden = false
        glyph.image = NSImage(
            systemSymbolName: job.phase.stageSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 36 * MacTheme.UIScale.factor, weight: .regular))
        glyph.contentTintColor =
            job.phase.tone == .danger ? MacTheme.Color.danger : MacTheme.Color.tertiaryLabel
        caption.stringValue = failure ?? (job.isBusy ? (job.stageName ?? job.subtitle) : job.subtitle)
        caption.textColor =
            (failure != nil || job.phase.tone == .danger)
            ? MacTheme.Color.danger : MacTheme.Color.secondaryLabel
        if let fraction = job.fraction {
            bar.fraction = fraction
            bar.isHidden = false
        } else {
            bar.isHidden = true
        }
    }

    func pause() { player?.player?.pause() }

    private func applyShape(of size: ForgeSize) {
        let wanted = CGFloat(size.height) / CGFloat(max(size.width, 1))
        ratio?.isActive = false
        let pin = heightAnchor.constraint(equalTo: widthAnchor, multiplier: min(wanted, 1.35))
        pin.priority = .init(750)
        pin.isActive = true
        ratio = pin
    }

    private func show(_ url: URL) {
        if clipURL == url {
            player?.isHidden = false
            return
        }
        clipURL = url
        let view = ensurePlayer()
        view.isHidden = false
        view.player = AVPlayer(url: url)
    }

    private func ensurePlayer() -> AVPlayerView {
        if let player { return player }
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: idle)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        player = view
        return view
    }
}

@MainActor
final class ForgeChipWrap: NSView {
    var onCycle: ((ForgeField) -> Void)?
    private let stack = FillingStack()

    init() {
        super.init(frame: .zero)
        stack.spacing = MacTheme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ board: ForgeBoard) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let fields = ForgeStudio.chips
        let stride = 3
        var index = 0
        while index < fields.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            row.distribution = .fillEqually
            for field in fields[index..<min(index + stride, fields.count)] {
                guard let item = board.rows.first(where: { $0.kind == .field(field) }) else {
                    continue
                }
                let chip = ForgeChipButton()
                chip.render(
                    title: item.detail, detail: field.label, badge: nil,
                    focused: item.id == board.focused?.id)
                chip.isEnabled = item.isActivatable
                chip.toolTip = item.note
                chip.onPress = { [weak self] in self?.onCycle?(field) }
                row.addArrangedSubview(chip)
            }
            stack.addArrangedSubview(row)
            index += stride
        }
    }
}

@MainActor
final class ForgeChipButton: NSButton {
    var onPress: (() -> Void)?
    private let name = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let pill = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        target = self
        action = #selector(fire)
        name.font = MacTheme.Ramp.font(.sectionLabel)
        name.textColor = MacTheme.Color.tertiaryLabel
        value.font = MacTheme.Ramp.font(.rowTitle)
        value.textColor = MacTheme.Color.label
        value.lineBreakMode = .byTruncatingTail
        let column = NSStackView(views: [name, value])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(title: String, detail: String, badge: String?, focused: Bool) {
        name.stringValue = detail
        value.stringValue = title
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                focused
                ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor
                : MacTheme.Color.canvasRaised.cgColor
            layer?.borderWidth = focused ? 1 : 0
            layer?.borderColor = MacTheme.Color.accent.cgColor
        }
        setAccessibilityLabel("\(detail), \(title)")
        setAccessibilityRole(.button)
    }

    @objc private func fire() { onPress?() }
}

@MainActor
final class ForgeFilmstrip: NSView {
    var onActivate: ((Int) -> Void)?
    var onClipMenu: ((ForgeEntry, NSView, NSPoint) -> Void)?
    private let scroll = NSScrollView()
    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        scroll.documentView = row
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: CGFloat(ForgeStudio.filmHeight)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ board: ForgeBoard, gone: (ForgeEntry) -> String?) {
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let section = board.sections.first(where: { $0.id == ForgeBoard.historyID }) else {
            return
        }
        for (offset, item) in section.rows.enumerated() {
            let card = ForgeFilmCard()
            card.render(item, gone: item.entry.flatMap(gone), focused: item.id == board.focused?.id)
            card.onPress = { [weak self] in self?.onActivate?(offset) }
            if let entry = item.entry {
                card.onMenu = { [weak self, weak card] point in
                    guard let card else { return }
                    self?.onClipMenu?(entry, card, point)
                }
            }
            row.addArrangedSubview(card)
        }
        row.frame.size = NSSize(
            width: row.fittingSize.width, height: CGFloat(ForgeStudio.filmHeight) - 4)
    }
}

@MainActor
final class ForgeFilmCard: NSView {
    var onPress: (() -> Void)?
    var onMenu: ((NSPoint) -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor = MacTheme.Color.label
        title.lineBreakMode = .byTruncatingTail
        detail.font = MacTheme.Ramp.font(.rowNote)
        detail.textColor = MacTheme.Color.tertiaryLabel
        detail.lineBreakMode = .byTruncatingTail
        let column = NSStackView(views: [title, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 148),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ row: ForgeRow, gone: String?, focused: Bool) {
        title.stringValue = row.title
        detail.stringValue = gone ?? row.detail
        detail.textColor = gone == nil ? MacTheme.Color.tertiaryLabel : MacTheme.Color.danger
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                focused
                ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor
                : MacTheme.Color.canvasRaised.cgColor
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(row.title), \(gone ?? row.detail)")
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
    override func rightMouseDown(with event: NSEvent) {
        onMenu?(convert(event.locationInWindow, from: nil))
    }
}
