import AppKit
import CodingAgentKit
import TailscodeCore

/// Where a chapter began, above the message that opened it: the number and the time in the small
/// label, the title under it in full ink, wrapping rather than cut. Pressing it (or Space and
/// Return with full keyboard access) opens the chapters popover on this chapter.
final class ChapterHeadingView: NSView, KeyboardPressable {
    private let column = NSStackView()
    private let onPress: () -> Void
    let heading: ChapterHeading

    init(_ heading: ChapterHeading, onPress: @escaping () -> Void) {
        self.heading = heading
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let kicker = RowKit.label(
            StatusMark.chapters + " " + heading.label.uppercased() + "  ·  " + heading.time,
            font: MacTheme.Ramp.font(.seamLabel), color: MacTheme.Color.secondaryLabel)
        let title = RowKit.wrapping(
            heading.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        title.maximumNumberOfLines = 0
        title.isSelectable = false
        kicker.setAccessibilityElement(false)
        title.setAccessibilityElement(false)
        column.setViews([kicker, title], in: .top)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let breathing: CGFloat = 4 * MacTheme.UIScale.factor
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: breathing),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -breathing),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        setAccessibilityLabel(heading.spoken)
        setAccessibilityHelp(Localized.text("Shows how this chat got here"))
        HoverPlate.attach(to: column, placement: .behind(PointerPlate.inlineOutset), radius: 6)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var reading: String { heading.label + " " + heading.title }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pressRect: NSRect { column.frame.insetBy(dx: -MacTheme.Spacing.s, dy: -2) }

    override var focusRingMaskBounds: NSRect { pressRect }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: pressRect, xRadius: 6, yRadius: 6).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(pressRect, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard pressRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseUp(with: event)
        }
        onPress()
    }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

extension TranscriptRow {
    /// The heading row's view, wired to open the chapters popover on the chapter it names.
    @MainActor
    static func chapterHeading(
        _ heading: ChapterHeading, key: String, context: TranscriptContext
    ) -> NSView {
        let anchor = key.hasSuffix(":chapter") ? String(key.dropLast(":chapter".count)) : nil
        let open = context.openChapters
        return ChapterHeadingView(heading) { open?(anchor) }
    }
}

/// The chapters a strip draws to scale: one rounded piece per chapter by its share of the person's
/// messages, the current one in the accent. Purely a picture — the rows say the same thing to a
/// screen reader — so it is no accessibility element.
final class ChapterStripView: NSView {
    private let pieces: [ChapterStripPiece]

    init(_ pieces: [ChapterStripPiece]) {
        self.pieces = pieces
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 3
        let room = bounds.width - gap * CGFloat(max(0, pieces.count - 1))
        var x: CGFloat = 0
        for piece in pieces {
            let width = max(6, room * piece.share)
            let rect = NSRect(x: x, y: 0, width: min(width, bounds.width - x), height: bounds.height)
            (piece.isCurrent ? MacTheme.Color.accent : MacTheme.Color.label.withAlphaComponent(0.22))
                .setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            x += width + gap
        }
    }
}

/// One chapter in the popover: its number, title, what it came to, its span and who named it,
/// the current one lit. A press, Space or Return jumps to where it began.
final class ChapterRowControl: NSView, KeyboardPressable {
    let line: ChapterLine
    private let onPress: () -> Void
    private let column = NSStackView()

    init(_ line: ChapterLine, onPress: @escaping () -> Void) {
        self.line = line
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        if line.isCurrent {
            layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor
        }
        let number = RowKit.label(
            "\(line.number)", font: MacTheme.Ramp.font(.metricLabel),
            color: line.isCurrent ? .white : MacTheme.Color.secondaryLabel)
        number.alignment = .center
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.layer?.borderWidth = line.isCurrent ? 0 : 1
        badge.layer?.borderColor = MacTheme.Color.tertiaryLabel.cgColor
        badge.layer?.backgroundColor = line.isCurrent ? MacTheme.Color.accent.cgColor : nil
        badge.translatesAutoresizingMaskIntoConstraints = false
        number.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(number)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            number.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let title = RowKit.wrapping(
            line.title, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        var views: [NSView] = [title]
        if line.isCurrent {
            let current = RowKit.label(
                Localized.text("Current"), font: MacTheme.Ramp.font(.metricLabel),
                color: MacTheme.Color.accent)
            let head = NSStackView(views: [title, current])
            head.orientation = .horizontal
            head.alignment = .firstBaseline
            head.spacing = MacTheme.Spacing.s
            views = [head]
        }
        if let gist = line.gist {
            views.append(
                RowKit.wrapping(gist, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.label))
        }
        views.append(
            RowKit.wrapping(
                line.span, font: MacTheme.Ramp.font(.metricLabel), color: MacTheme.Color.secondaryLabel))
        if let note = line.note {
            let field = RowKit.wrapping(
                note, font: NSFontManager.shared.convert(
                    MacTheme.Ramp.font(.panelDetail), toHaveTrait: .italicFontMask),
                color: MacTheme.Color.secondaryLabel)
            views.append(field)
        }
        for view in views { view.setAccessibilityElement(false) }
        column.setViews(views, in: .top)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        let row = NSStackView(views: [badge, column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(line.spoken)
        if line.anchorID != nil {
            HoverPlate.attach(to: self, placement: .behind(NSEdgeInsets()), radius: 9)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { line.anchorID != nil }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if line.anchorID != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard line.anchorID != nil, bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onPress()
    }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode), line.anchorID != nil else {
            return super.keyDown(with: event)
        }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard line.anchorID != nil else { return false }
        onPress()
        return true
    }
}

/// How a long chat got here, in a popover off the band or a heading: the header, the strip to
/// scale, and one row per chapter, scrolled so the chapter it was opened for — or the current one
/// — is in view and has the keyboard. ↑ and ↓ move between rows, Return jumps, Esc closes. It
/// reads again when the conversation's chapters change while it is up.
final class ChaptersPanelViewController: NSViewController {
    private let read: () -> ChapterReading?
    private let reveal: (String) -> Void
    private var focus: String?
    private let column = NSStackView()
    private let list = NSStackView()
    private let scroller = NSScrollView()
    private(set) var rows: [ChapterRowControl] = []
    private var heightLimit: NSLayoutConstraint?

    private static let width: CGFloat = 400

    init(focus: String?, read: @escaping () -> ChapterReading?, reveal: @escaping (String) -> Void) {
        self.read = read
        self.reveal = reveal
        self.focus = focus
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedClip()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroller.documentView = document
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),
        ])
        let root = NSView()
        root.addSubview(column)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusRow()
    }

    /// The conversation's chapters changed, or it gained a message, while the popover is up: it
    /// reads them again and gives the keyboard back to the row that had it.
    func chaptersChanged() {
        guard isViewLoaded else { return }
        let held = rows.first { $0 === view.window?.firstResponder }?.line.anchorID
        render()
        if let held {
            focus = held
            focusRow()
        }
    }

    func focus(on anchor: String?) {
        focus = anchor
        focusRow()
    }

    private func render() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        guard let reading = read(), reading.isShown else {
            column.addArrangedSubview(
                RowKit.wrapping(
                    Localized.text("This chat is still in its first chapter."),
                    font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel))
            return
        }
        let title = RowKit.label(
            Localized.text("Chapters"), font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        let header = RowKit.wrapping(
            reading.header, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel)
        column.addArrangedSubview(title)
        column.addArrangedSubview(header)
        if let strip = reading.strip {
            let view = ChapterStripView(strip)
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m)
                .isActive = true
        }
        for line in reading.lines {
            let row = ChapterRowControl(line) { [weak self] in
                guard let anchor = line.anchorID else { return }
                self?.reveal(anchor)
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            rows.append(row)
        }
        column.addArrangedSubview(scroller)
        scroller.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m)
            .isActive = true
        list.layoutSubtreeIfNeeded()
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let wanted = min(list.fittingSize.height, screen * 0.6)
        heightLimit?.isActive = false
        heightLimit = scroller.heightAnchor.constraint(equalToConstant: max(60, wanted))
        heightLimit?.isActive = true
        for (index, row) in rows.enumerated() {
            row.nextKeyView = rows[(index + 1) % rows.count]
        }
    }

    private func focusRow() {
        guard !rows.isEmpty else { return }
        let index = focus.flatMap { anchor in rows.firstIndex { $0.line.anchorID == anchor } }
            ?? rows.count - 1
        let row = rows[index]
        view.window?.makeFirstResponder(row)
        row.scrollToVisible(row.bounds)
    }

    override func keyDown(with event: NSEvent) {
        guard let current = rows.firstIndex(where: { $0 === view.window?.firstResponder }) else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 125:
            let next = rows[min(rows.count - 1, current + 1)]
            view.window?.makeFirstResponder(next)
            next.scrollToVisible(next.bounds)
        case 126:
            let previous = rows[max(0, current - 1)]
            view.window?.makeFirstResponder(previous)
            previous.scrollToVisible(previous.bounds)
        default:
            super.keyDown(with: event)
        }
    }
}

/// A document view that lays out top down, so the list starts at the top of its scroller.
private final class FlippedClip: NSView {
    override var isFlipped: Bool { true }
}
