import AVKit
import AppKit
import TailscodeCore

/// The forge, drawn. `ForgeBoard` decides the four sections — the renderer and whether it answered,
/// the render in hand with its bar, what the next one is made from, and the clips already made —
/// and this turns each of them into a heading and its rows. Nothing here decides what a row says,
/// which state it is in, or what pressing it means: every word comes off the row, and the only
/// judgement made here is which of the window's tones a badge wears and which state deserves a mark
/// that moves.
///
/// It is content, so it sits on the opaque canvas and scrolls under the floating dock rather than
/// beside it — the same scroll-edge arrangement the transcript keeps under its composer.
@MainActor
final class ForgeBoardView: NSView {
    private let scrollView = NSScrollView()
    private let groups = FillingStack()
    /// The render's own row, kept rather than rebuilt. A render yields snapshots several times a
    /// second, and it is the one row that can be holding a player — a player rebuilt under the
    /// reader is a clip that starts again every time a frame lands off the socket.
    private let stageRow = ForgeRowView()
    private var rowViews: [String: ForgeRowView] = [:]

    /// A press, reported as the section it landed in and the offset inside it, because a board that
    /// draws sections cannot honestly name a row by its place in one flat list.
    var onActivate: ((String, Int) -> Void)?
    /// A right-click on a kept clip, with the view and the point to hang a menu on.
    var onClipMenu: ((ForgeEntry, NSView, NSPoint) -> Void)?

    init() {
        super.init(frame: .zero)
        groups.spacing = MacTheme.Spacing.m
        groups.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.l)
        groups.translatesAutoresizingMaskIntoConstraints = false

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = groups
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            groups.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            groups.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            groups.topAnchor.constraint(equalTo: clip.topAnchor),
            groups.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Room for the chrome that floats over this: the pane's identity strip at the top, the prompt
    /// dock at the bottom. Content runs underneath both rather than stopping short of them.
    var insets: NSEdgeInsets {
        get { scrollView.contentInsets }
        set {
            guard newValue.top != scrollView.contentInsets.top
                || newValue.bottom != scrollView.contentInsets.bottom
            else { return }
            scrollView.contentInsets = newValue
        }
    }

    /// - Parameters:
    ///   - clip: where the render in hand's own file is, once the machine has confirmed it still
    ///     has it. The stage draws a player for it in place rather than sending anybody elsewhere.
    ///   - clipFailure: why that lookup did not answer, in the sentence whoever refused it wrote.
    ///   - gone: what a kept clip says when the renderer no longer has its file — asked per row
    ///     rather than stored on it, because a receipt outlives the file it names.
    func render(
        _ board: ForgeBoard, clip: URL?, clipFailure: String?,
        gone: (ForgeEntry) -> String?
    ) {
        rowViews = [:]
        for view in groups.arrangedSubviews {
            groups.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let focused = board.focused?.id
        for section in board.sections {
            let stack = FillingStack()
            stack.spacing = 2
            stack.addArrangedSubview(Self.header(section))
            for (offset, row) in section.rows.enumerated() {
                let view = self.view(for: row)
                view.configure(
                    row, phase: section.phase, focused: row.id == focused,
                    activity: Self.activity(of: row, board: board), aside: aside(row, gone: gone))
                if case .job = row.kind { view.showClip(clip, failure: clipFailure) }
                view.onClick =
                    row.isActivatable
                    ? { [weak self] in self?.onActivate?(section.id, offset) } : nil
                view.onSecondaryClick =
                    row.entry.map { entry in
                        { [weak self, weak view] point in
                            guard let view else { return }
                            self?.onClipMenu?(entry, view, point)
                        }
                    }
                rowViews[row.id] = view
                stack.addArrangedSubview(view)
            }
            groups.addArrangedSubview(stack)
        }
    }

    /// Brings the cursor back into view after a key moved it. The board is rebuilt before the
    /// reveal is asked for, so the row still has a zero frame at this point: scrolling to it
    /// without settling the layout first aims at the origin and lands the board at its own end.
    func reveal(_ rowID: String) {
        guard let view = rowViews[rowID] else { return }
        layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
    }

    /// Stops whatever the stage is playing without taking the frame off the screen — what a pane
    /// that has just been handed a full-size player owes the small one inside it.
    func quietStage() {
        stageRow.pauseClip()
    }

    private func view(for row: ForgeRow) -> ForgeRowView {
        if case .job = row.kind { return stageRow }
        return ForgeRowView()
    }

    private func aside(_ row: ForgeRow, gone: (ForgeEntry) -> String?) -> String? {
        guard let entry = row.entry else { return nil }
        return gone(entry)
    }

    /// The one row that can be mid-question. A machine being asked whether it is there is work, and
    /// work in this app has a face that moves rather than a label that sits still; a render that is
    /// actually running breathes, and every settled state — queued, failed, stopped — holds still.
    private static func activity(of row: ForgeRow, board: ForgeBoard) -> ActivityKind? {
        if row.sectionID == ForgeBoard.rendererID {
            return board.isChecking ? .connecting : nil
        }
        guard case .job = row.kind else { return nil }
        switch board.job.phase {
        case .submitting: return .connecting
        case .running: return .working
        case .drafting, .queued, .done, .failed, .cancelled: return nil
        }
    }

    /// A section's heading. The render's own detail is the caption of the button in the dock and
    /// the settings' is the line under the stage, so printing either here would make a reader look
    /// for a difference that is not there.
    ///
    /// The two halves sit in the stack's own gravity areas rather than either side of a spacer, and
    /// a heading with nothing to say on the right carries no view at all: an empty spacer in a
    /// baseline-aligned row has no height to take, and a hidden arranged subview has no width, and
    /// both of those are a frame Auto Layout cannot solve rather than a frame that happens to look
    /// right.
    private static func header(_ section: ForgeSection) -> NSView {
        let title = RowKit.label(
            section.title, font: MacTheme.Ramp.font(.sectionLabel),
            color: MacTheme.Color.secondaryLabel)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.setViews([title], in: .leading)
        let spoken = spoken(of: section)
        if !spoken.isEmpty {
            row.setViews(
                [
                    RowKit.label(
                        spoken, font: MacTheme.Ramp.font(.panelFootnote),
                        color: MacTheme.Color.tertiaryLabel)
                ], in: .trailing)
        }
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: MacTheme.Spacing.s, bottom: 2, right: MacTheme.Spacing.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static func spoken(of section: ForgeSection) -> String {
        guard section.id != ForgeBoard.renderID, section.id != ForgeBoard.settingsID else {
            return ""
        }
        return section.detail
    }

    /// The line the board carries under the renderer: what a render actually costs, said before
    /// somebody spends four minutes of somebody else's card on it. It belongs to no row, so it is
    /// the one thing on this board that is not one.
}

/// One row of the board: what it is, what it says, the word in its corner, how far it has got, and
/// — on the render's own row — the clip that came back. Every value is the row's; the only choices
/// here are which tone the badge wears and how tall the bar is.
@MainActor
final class ForgeRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let aside = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let badgeCapsule = NSView()
    private let activityBadge = ActivityBadgeView(pointSize: 11)
    /// The mark's column, held open whether or not this row has a mark to put in it. A badge that
    /// came and went with the phase would walk every title two characters left and back again on
    /// every state a render passes through, and a column that only some rows keep is not a column.
    private let markSlot = NSView()
    private let bar = ForgeBarView()
    private let titleRow = NSStackView()
    private let lines = FillingStack()
    private var playerView: AVPlayerView?
    private var clipURL: URL?

    var onClick: (() -> Void)?
    var onSecondaryClick: ((NSPoint) -> Void)?

    /// The tallest a clip is drawn inside a row. A pane can be most of a 6K display wide, and a
    /// preview that grew with it would push the settings and the history off the board it belongs
    /// to — the full-size view is one press away and is where a clip is meant to be watched.
    private static let clipCeiling: CGFloat = 260
    /// The width the mark's column holds, which is the badge's own intrinsic size at the point size
    /// this board draws it at.
    private static let markColumn: CGFloat = 16

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.font = MacTheme.Ramp.font(.pill)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeCapsule.wantsLayer = true
        badgeCapsule.layer?.cornerRadius = 7
        badgeCapsule.translatesAutoresizingMaskIntoConstraints = false
        badgeCapsule.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeCapsule.leadingAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: badgeCapsule.trailingAnchor, constant: -5),
            badge.topAnchor.constraint(equalTo: badgeCapsule.topAnchor, constant: 1),
            badge.bottomAnchor.constraint(equalTo: badgeCapsule.bottomAnchor, constant: -1),
        ])

        markSlot.translatesAutoresizingMaskIntoConstraints = false
        markSlot.addSubview(activityBadge)
        activityBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markSlot.widthAnchor.constraint(equalToConstant: Self.markColumn),
            markSlot.heightAnchor.constraint(equalToConstant: Self.markColumn),
            activityBadge.centerXAnchor.constraint(equalTo: markSlot.centerXAnchor),
            activityBadge.centerYAnchor.constraint(equalTo: markSlot.centerYAnchor),
        ])

        title.setContentHuggingPriority(.init(1), for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.setViews([markSlot, title], in: .leading)

        detail.font = MacTheme.Ramp.font(.rowDetail)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.isSelectable = false
        detail.maximumNumberOfLines = 3
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        note.font = MacTheme.Ramp.font(.rowNote)
        note.textColor = MacTheme.Color.tertiaryLabel
        note.lineBreakMode = .byTruncatingTail

        aside.font = MacTheme.Ramp.font(.rowNote)
        aside.textColor = MacTheme.Color.danger
        aside.isSelectable = false
        aside.maximumNumberOfLines = 2
        aside.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        lines.spacing = 2
        lines.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.xs,
            right: MacTheme.Spacing.s)
        lines.setViews([titleRow, detail, bar, note, aside], in: .top)
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        _ row: ForgeRow, phase: ForgePhase, focused: Bool, activity: ActivityKind?,
        aside asideText: String?
    ) {
        title.stringValue = row.title
        title.font =
            row.isPrimary ? MacTheme.Ramp.font(.cardTitle) : MacTheme.Ramp.font(.rowTitle)
        title.textColor = Self.ink(for: row)
        detail.stringValue = row.detail
        detail.isHidden = row.detail.isEmpty
        detail.textColor =
            Self.isFailed(phase) && row.isPrimary
            ? MacTheme.Color.danger : MacTheme.Color.secondaryLabel
        note.stringValue = row.note ?? ""
        note.isHidden = row.note?.isEmpty ?? true
        aside.stringValue = asideText ?? ""
        aside.isHidden = asideText == nil
        activityBadge.activity = activity
        if let fraction = row.fraction {
            bar.fraction = fraction
            bar.isHidden = false
        } else {
            bar.isHidden = true
        }
        applyBadge(row, phase: phase)
        applyGround(focused: focused, row: row)
        alphaValue = (row.isActivatable || row.kind == .note) ? 1 : 0.55
        setAccessibilityElement(true)
        setAccessibilityRole(row.isActivatable ? .button : .staticText)
        setAccessibilityLabel(
            [row.title, row.badge, row.detail, row.note, asideText]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The clip the render in hand produced, played where it was made rather than in a window of
    /// its own. It never starts by itself: a pane sitting beside a conversation that begins making
    /// noise on its own is a pane somebody has to go and silence.
    func showClip(_ url: URL?, failure: String?) {
        if let failure, !failure.isEmpty, url == nil {
            aside.stringValue = failure
            aside.isHidden = false
        }
        guard url != clipURL else { return }
        clipURL = url
        guard let url else {
            playerView?.player?.pause()
            playerView?.player = nil
            playerView?.isHidden = true
            return
        }
        let view = ensurePlayerView()
        view.isHidden = false
        view.player = AVPlayer(url: url)
    }

    func pauseClip() {
        playerView?.player?.pause()
    }

    /// Whether this row is holding a clip to watch, which only the render's own row ever is.
    var holdsClip: Bool { playerView?.isHidden == false }

    private func ensurePlayerView() -> AVPlayerView {
        if let playerView { return playerView }
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.cornerRadius = MacTheme.Radius.control
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        lines.insertArrangedSubview(view, at: lines.arrangedSubviews.count)
        let ratio = view.heightAnchor.constraint(
            equalTo: view.widthAnchor, multiplier: 9.0 / 16.0)
        ratio.priority = .init(999)
        let ceiling = view.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.clipCeiling * MacTheme.UIScale.factor)
        let settled = view.heightAnchor.constraint(
            equalToConstant: Self.clipCeiling * MacTheme.UIScale.factor)
        settled.priority = .init(500)
        NSLayoutConstraint.activate([ratio, ceiling, settled])
        playerView = view
        return view
    }

    /// A press is claimed here and answered on the release, inside the row: pressing a row and
    /// dragging away — or pressing it on the way to a scroll — must not start four minutes of
    /// somebody else's card with no way left to change your mind.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        onSecondaryClick(convert(event.locationInWindow, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The word in the row's corner, put into the stack's trailing area or taken out of it. Hiding
    /// it instead would leave a view in a horizontal stack with nothing deciding its width, which
    /// is an ambiguous frame rather than an invisible one.
    private func applyBadge(_ row: ForgeRow, phase: ForgePhase) {
        guard let text = row.badge, !text.isEmpty else {
            titleRow.setViews([], in: .trailing)
            return
        }
        titleRow.setViews([badgeCapsule], in: .trailing)
        badge.stringValue = text
        let tint = Self.tone(for: row, phase: phase)
        badge.textColor = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badgeCapsule.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        }
    }

    private func applyGround(focused: Bool, row: ForgeRow) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if focused {
                layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.18).cgColor
            } else if row.isPrimary {
                layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    private static func isFailed(_ phase: ForgePhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private static func ink(for row: ForgeRow) -> NSColor {
        guard row.kind != .note else { return MacTheme.Color.secondaryLabel }
        return row.isActivatable ? MacTheme.Color.label : MacTheme.Color.secondaryLabel
    }

    /// Which tone a badge wears, read off state rather than off the word inside it: a clip says
    /// whether its file is still fetchable, and every other row takes its section's phase, so
    /// nothing here has to recognise a string Core is free to reword.
    private static func tone(for row: ForgeRow, phase: ForgePhase) -> NSColor {
        if let entry = row.entry {
            return entry.isPlayable ? MacTheme.Color.info : MacTheme.Color.danger
        }
        switch phase {
        case .ready: return MacTheme.Color.success
        case .failed: return MacTheme.Color.danger
        case .checking: return MacTheme.Color.info
        case .idle: return MacTheme.Color.secondaryLabel
        }
    }
}

/// The render's own bar, drawn only where the board handed a fraction over. Submitting and queueing
/// carry none on purpose — there is nothing honest to fill — so those states get the word in the
/// corner and no bar at all rather than a bar that has not moved for twelve seconds.
@MainActor
final class ForgeBarView: NSView {
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 5 * MacTheme.UIScale.factor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        MacTheme.Color.canvasRaised.setFill()
        track.fill()
        let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
        guard width > 0 else { return }
        let filled = NSRect(
            x: bounds.minX, y: bounds.minY, width: max(width, bounds.height),
            height: bounds.height)
        MacTheme.Color.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
