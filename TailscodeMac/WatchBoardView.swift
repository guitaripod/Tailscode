import AppKit
import TailscodeCore

/// What is on, drawn: the sections `WatchChooser` decided, under the box somebody is typing a
/// channel name into. Content rather than chrome, so it sits on the opaque canvas and never on
/// glass, and it scrolls inside its own pane rather than growing past it — a board is a thing to
/// scan while the work continues beside it, not a window that takes the grid over.
///
/// The heading and the keys are the slot's, not the board's: they name what is being scrolled, so
/// scrolling them away with it would take the label off the thing it labels.
@MainActor
final class WatchBoardView: NSView {
    private let scrollView = NSScrollView()
    private let groups = FillingStack()
    private var rowViews: [String: WatchRowView] = [:]
    private var onActivate: ((String, Int) -> Void)?

    init() {
        super.init(frame: .zero)
        groups.spacing = MacTheme.Spacing.m
        groups.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs, left: 0, bottom: MacTheme.Spacing.s, right: 0)
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

    /// - Parameter onActivate: a press, reported as the section it landed in and the offset inside
    ///   it, because a board that draws sections cannot honestly name a row by its place in one
    ///   flat list.
    func render(_ board: WatchChooser, onActivate: @escaping (String, Int) -> Void) {
        self.onActivate = onActivate
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
                let view = WatchRowView()
                view.configure(row, focused: row.id == focused)
                if row.isActivatable {
                    let id = section.id
                    view.onClick = { [weak self] in self?.onActivate?(id, offset) }
                }
                rowViews[row.id] = view
                stack.addArrangedSubview(view)
            }
            groups.addArrangedSubview(stack)
        }
        MediaImageStore.shared.onStored = { [weak self] url in self?.pictureArrived(url) }
    }

    /// Brings the cursor back into view after a key moved it — a board taller than its pane is the
    /// ordinary case, and a cursor that walks off the bottom is a cursor nobody can follow.
    ///
    /// The board is rebuilt before the reveal is asked for, so the row still has a zero frame at
    /// this point: scrolling to it without settling the layout first aims at the origin and lands
    /// the board at its own end instead.
    func reveal(_ rowID: String) {
        guard let view = rowViews[rowID] else { return }
        layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
    }

    private func pictureArrived(_ url: String) {
        guard let image = MediaImageStore.shared.image(for: url) else { return }
        for view in rowViews.values {
            view.apply(image, for: url)
        }
    }

    private static func header(_ section: WatchSection) -> NSView {
        let title = RowKit.label(
            section.title,
            font: MacTheme.Ramp.font(.sectionLabel),
            color: MacTheme.Color.secondaryLabel)
        let detail = RowKit.label(
            section.detail, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
        detail.isHidden = section.detail.isEmpty
        let row = NSStackView(views: [title, RowKit.spacer(), detail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: MacTheme.Spacing.s, bottom: 2, right: MacTheme.Spacing.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

/// One row of the board: the picture the source sent, what it is, who is watching and for how
/// long. The picture's frame is drawn whether or not the bytes have landed, so a row never changes
/// height under the reader's eye when its thumbnail arrives.
@MainActor
final class WatchRowView: NSView {
    private static let thumbWidth: CGFloat = 96
    private static let thumbHeight: CGFloat = 54

    private let thumb = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let star = NSImageView()
    private let titleRow = NSStackView()
    private let lines = FillingStack()
    private var thumbnailURL: String?
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = MacTheme.Radius.control
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        star.image = NSImage(
            systemSymbolName: "star.fill",
            accessibilityDescription: Localized.text("Following"))?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 9 * MacTheme.UIScale.factor, weight: .semibold))
        star.contentTintColor = MacTheme.Color.accent
        star.toolTip = Localized.text("Following")

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.setViews([title, RowKit.spacer()], in: .leading)

        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail

        note.font = MacTheme.Ramp.font(.panelFootnote)
        note.textColor = MacTheme.Color.tertiaryLabel
        note.lineBreakMode = .byTruncatingTail

        lines.spacing = 1
        lines.setViews([titleRow, detail, note], in: .top)
        lines.setContentHuggingPriority(.init(1), for: .horizontal)

        let body = NSStackView(views: [thumb, lines])
        body.orientation = .horizontal
        body.alignment = .centerY
        body.distribution = .fill
        body.spacing = MacTheme.Spacing.s
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: Self.thumbWidth),
            thumb.heightAnchor.constraint(equalToConstant: Self.thumbHeight),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            body.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: WatchRow, focused: Bool) {
        title.stringValue = row.title
        title.font = row.isPrimary ? MacTheme.Ramp.font(.cardTitle) : MacTheme.Ramp.font(.panelLabel)
        title.textColor = row.isActivatable ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel
        detail.stringValue = row.detail
        detail.isHidden = row.detail.isEmpty
        note.stringValue = row.note ?? ""
        note.isHidden = row.note == nil
        setAccessibilityElement(true)
        setAccessibilityRole(row.isActivatable ? .button : .staticText)
        setAccessibilityLabel(
            [row.title, row.badge?.text, row.detail, row.note]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        layer?.backgroundColor =
            focused
            ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor

        for view in titleRow.arrangedSubviews.dropFirst(2) {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let badge = row.badge {
            titleRow.addArrangedSubview(Self.pill(badge.text, tint: Self.tint(of: badge)))
        }
        if row.isFollowed {
            titleRow.addArrangedSubview(star)
        }
        applyThumbnail(row)
    }

    /// A picture that landed while the board was already drawn, dropped into the row that wanted
    /// it — the row is not rebuilt for it, because a rebuilt row loses the cursor's highlight.
    func apply(_ image: NSImage, for url: String) {
        guard thumbnailURL == url else { return }
        thumb.image = image
    }

    /// A press is claimed here and answered on the release, inside the row: pressing a row and
    /// dragging away — or pressing it on the way to a scroll — must not put a stream in the pane
    /// and a channel in the recents with no way left to change your mind.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// A row that stands for a list rather than a stream carries no picture: an expander and a note
    /// are one dim line each, and the leading column collapses so they read as what they are.
    /// Everything else keeps the frame whether or not any bytes ever land — a channel that is
    /// offline and has no avatar has to sit at the same indent as the one above it, or the column
    /// of pictures stops being a column the moment a source answers with half of them.
    private func applyThumbnail(_ row: WatchRow) {
        switch row.kind {
        case .expander, .note:
            thumbnailURL = nil
            thumb.isHidden = true
            thumb.image = nil
            return
        case .channel, .category, .typed:
            thumb.isHidden = false
        }
        let address = row.thumbnail ?? row.avatar
        thumbnailURL = address
        guard let address else {
            thumb.image = nil
            return
        }
        if let image = MediaImageStore.shared.image(for: address) {
            thumb.image = image
        } else {
            thumb.image = nil
            MediaImageStore.shared.fetch(address)
        }
    }

    private static func tint(of badge: WatchBadge) -> NSColor {
        switch badge {
        case .live: return MacTheme.Color.success
        case .offline: return MacTheme.Color.secondaryLabel
        case .plain: return MacTheme.Color.info
        }
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.metricLabel)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        capsule.layer?.cornerRadius = 7
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -1),
        ])
        return capsule
    }
}
