import AppKit
import CodingAgentKit
import TailscodeCore

/// The small vocabulary every row view speaks: labels that wrap, labels that truncate, hairlines,
/// flat little buttons, capped scrolls — one place, so the rows stay about their content.
@MainActor
enum RowKit {
    /// The shell every compaction card shares: the raised box, the symbol wearing the story's
    /// tone, the bold title and the detail line. Callers append what their state adds — a bar, a
    /// ticking clock, a reader link.
    static func compactionCard(_ story: CompactionStory, tint: NSColor) -> NSStackView {
        card(symbol: story.symbol, title: story.title, detail: story.detail, tint: tint)
    }

    /// The shape every stated-outcome card in the transcript wears: a symbol in its tint, the
    /// fact, and the sentence under it.
    static func card(symbol: String, title: String, detail: String, tint: NSColor) -> NSStackView {
        let card = FillingStack(topDown: false, stretches: false)
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.translatesAutoresizingMaskIntoConstraints = false
        ground(
            behind: card, fill: MacTheme.Color.subagentBackground,
            stroke: MacTheme.Color.separator, radius: MacTheme.Radius.card)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 13 * MacTheme.UIScale.factor, weight: .semibold))
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let heading = label(title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        header.setHuggingPriority(.defaultHigh, for: .horizontal)
        card.addArrangedSubview(header)
        card.addArrangedSubview(
            wrapping(
                detail, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
        return card
    }

    /// A one-line label truncates rather than holds the window open. Left at AppKit's 750 its
    /// whole line is a width the window has to make room for — a prompt quoted in full is tens of
    /// thousands of points, and the window grew to fit it — so it resists just below the priority
    /// a window keeps its size at, which still ranks it over every label a caller lowered on
    /// purpose.
    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        return label
    }

    static func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func attributedLabel(_ text: NSAttributedString) -> NSTextField {
        let label = ProseLabel(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// The label prose is set in.
    ///
    /// Its links behave the way links do in any Mac text, whichever backend the chat is on: a hand
    /// over one, a click that opens it when released, and a right-click that offers to open or
    /// copy it — rather than depending on the text field's editor having taken the press, and on
    /// the one message menu that offered link items existing only where a chat can be wound back.
    /// And it can be repainted without being measured again, which is what the wave
    /// does to the answer being written on every frame — the words and their fonts are the ones
    /// already measured and only their colours move, but a text field told its value changed asks
    /// for its size again, and the whole transcript's layout ran at the display's rate.
    final class ProseLabel: NSTextField {
        /// Set while a repaint changes colours and nothing else.
        var holdsMeasure = false
        /// What a message offers a hand resting on it — Copy, Undo — for a reader who has no hand
        /// to rest: asked for when the row is read to them, so an undo that stopped being possible
        /// is not still on the list.
        var verbs: (() -> [NSAccessibilityCustomAction])?
        private var linkFrames: (width: CGFloat, links: [(rect: NSRect, target: URL?)])?
        /// The link a press landed on, opened only if the release lands on it too, so a press
        /// dragged away is taken back.
        private var pressedLink: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var attributedStringValue: NSAttributedString {
            didSet { linkFrames = nil }
        }

        override func invalidateIntrinsicContentSize() {
            guard !holdsMeasure else { return }
            super.invalidateIntrinsicContentSize()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            for link in links() { addCursorRect(link.rect, cursor: .pointingHand) }
        }

        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            verbs?() ?? super.accessibilityCustomActions()
        }

        /// The link drawn under a point in this label's own coordinates, if there is one.
        func link(at point: NSPoint) -> URL? {
            links().first { $0.rect.contains(point) }?.target
        }

        override func mouseDown(with event: NSEvent) {
            let target = link(at: convert(event.locationInWindow, from: nil))
            guard event.clickCount == 1, !event.modifierFlags.contains(.control), let target else {
                pressedLink = nil
                return super.mouseDown(with: event)
            }
            pressedLink = target
        }

        override func mouseUp(with event: NSEvent) {
            guard let pressed = pressedLink else { return super.mouseUp(with: event) }
            pressedLink = nil
            guard link(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
            NSWorkspace.shared.open(pressed)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let target = link(at: convert(event.locationInWindow, from: nil)) else {
                return super.menu(for: event)
            }
            let menu = NSMenu()
            for item in Self.linkItems(target) { menu.addItem(item) }
            return menu
        }

        /// Open Link and Copy Link for one address, for every menu that can open over a link.
        static func linkItems(_ target: URL) -> [NSMenuItem] {
            [
                ClosureMenuItem(title: Localized.text("Open Link")) {
                    NSWorkspace.shared.open(target)
                },
                ClosureMenuItem(title: Localized.text("Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.absoluteString, forType: .string)
                },
            ]
        }

        /// Where the links are drawn and where each goes, laid out the way the cell lays out its
        /// text and kept until the words or the width change.
        private func links() -> [(rect: NSRect, target: URL?)] {
            let area = cell?.titleRect(forBounds: bounds) ?? bounds
            if let linkFrames, linkFrames.width == area.width { return linkFrames.links }
            let text = attributedStringValue
            var ranges: [(NSRange, URL?)] = []
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) {
                value, range, _ in
                guard let value else { return }
                ranges.append((range, value as? URL ?? (value as? String).flatMap(URL.init)))
            }
            var found: [(rect: NSRect, target: URL?)] = []
            if !ranges.isEmpty, area.width > 0 {
                let storage = NSTextStorage(attributedString: text)
                let layout = NSLayoutManager()
                let container = NSTextContainer(
                    size: NSSize(width: area.width, height: .greatestFiniteMagnitude))
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                for (range, target) in ranges {
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    layout.enumerateEnclosingRects(
                        forGlyphRange: glyphs,
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                        in: container
                    ) { rect, _ in
                        let top = area.minY + rect.minY
                        found.append(
                            (
                                NSRect(
                                    x: area.minX + rect.minX,
                                    y: self.isFlipped ? top : self.bounds.height - top - rect.height,
                                    width: rect.width, height: rect.height), target
                            ))
                    }
                }
            }
            linkFrames = (area.width, found)
            return found
        }
    }

    /// A ground that answers the appearance it is being drawn under. A layer takes a `CGColor`,
    /// which is a colour with light and dark already resolved out of it, so a block painted after
    /// dark kept that dark through sunrise while the ink above it — dynamic to the last — flipped
    /// without it. Drawing the ground asks the token again every time, which is the only moment
    /// the answer is actually known.
    final class Ground: NSView {
        var fill: NSColor?
        var stroke: NSColor?
        var radius: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset: CGFloat = stroke == nil ? 0 : 0.5
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            if let fill {
                fill.setFill()
                path.fill()
            }
            if let stroke {
                path.lineWidth = 1
                stroke.setStroke()
                path.stroke()
            }
        }
    }

    /// The same ground under a view that arranges its own rows — a card, a code block — laid in
    /// behind everything it holds rather than painted into its layer.
    static func ground(
        behind view: NSView, fill: NSColor?, stroke: NSColor? = nil, radius: CGFloat = 0
    ) {
        let ground = Ground(frame: .zero)
        ground.fill = fill
        ground.stroke = stroke
        ground.radius = radius
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ground.topAnchor.constraint(equalTo: view.topAnchor),
            ground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    static func hairline(verticalPadding: CGFloat = 0) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        guard verticalPadding > 0 else { return line }
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: verticalPadding),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -verticalPadding),
        ])
        return wrap
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// A quiet inline action — "copy", "read summary", "open full output" — drawn as tinted text,
    /// not a bezel, because the transcript is content and bezels are chrome.
    /// A click on a plain view, carrying the closure it should run. AppKit's gesture recognizers
    /// take a target and a selector, and a row built in a static function has neither — so the
    /// gesture is its own target and holds the closure itself.
    final class PressGesture: NSClickGestureRecognizer {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            self.target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler() }
    }

    /// A flat little button. `enabled` is for the ones that stay on screen having already been
    /// pressed: the row still says what was asked for, and says it cannot be asked twice.
    static func linkButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void)
        -> NSButton
    {
        let button = ActionButton(title: title, action: action)
        button.isBordered = false
        button.isEnabled = enabled
        button.contentTintColor = enabled ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// The one action a card that ends a turn badly offers. A link is as tall as its words, which is
    /// a smaller target than a pointer is owed, so this stands at least as tall as a chip.
    static func remedyButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = linkButton(title, action: action)
        let line = button.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 0
        let least = max(CGFloat(ChatChrome.chip(on: .pointer).height), line + 8)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: least).isActive = true
        return button
    }

    static func inset(_ view: NSView, leading: CGFloat, top: CGFloat = 0) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    /// A fenced block, lexed by the shared highlighter and painted in this theme's colours. The
    /// label does not wrap: a long line runs off the right and is scrolled to, because a line of
    /// code that reflowed is a line you cannot read and cannot count.
    static func code(_ body: String, language: String?) -> NSTextField {
        let font = MacTheme.Ramp.font(.code)
        let label: NSTextField
        if SyntaxHighlighter.isDiff(language) {
            let washed = DiffWashField(labelWithAttributedString: diffAttributed(body, font: font))
            washed.washes = SyntaxHighlighter.diffLines(body).compactMap { line in
                guard line.kind == .added || line.kind == .removed else { return nil }
                return (line.row, MacTheme.Color.diffBackground(line.kind))
            }
            washed.lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
            label = washed
        } else {
            let plain = NSMutableAttributedString(
                string: body,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
            for token in SyntaxHighlighter.tokens(body, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= plain.length else { continue }
                plain.addAttribute(
                    .foregroundColor, value: MacTheme.Color.syntax(token.role), range: range)
            }
            label = NSTextField(labelWithAttributedString: plain)
        }
        label.lineBreakMode = .byClipping
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// A field that paints a diff's washes itself, the full width of the line. A background
    /// attribute covers only glyph runs, so an attribute-painted wash stops at the last glyph
    /// and reads as a rendering bug rather than a ground. Code never wraps in this field, so a
    /// source row is a drawn row and the rect is arithmetic — row × line height, edge to edge.
    final class DiffWashField: NSTextField {
        var washes: [(row: Int, color: NSColor)] = [] {
            didSet { needsDisplay = true }
        }
        /// How many rows the field draws, which is what makes one of them measurable: the metric of
        /// a font the field was never told it is set in put every wash a little further down the
        /// block than the line it belongs to, and by the tenth line it was under the wrong code.
        var lines = 0

        override func draw(_ dirtyRect: NSRect) {
            if !washes.isEmpty, lines > 0 {
                let height = bounds.height / CGFloat(lines)
                for wash in washes {
                    let top = CGFloat(wash.row) * height
                    let y = isFlipped ? top : bounds.height - top - height
                    wash.color.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
                }
            }
            super.draw(dirtyRect)
        }
    }

    /// A patch's ink. The wash under each changed line carries the diff's meaning — painted by
    /// the hosting view, full width, never as a background attribute that stops at the last
    /// glyph — which frees the foreground for the file's own language: the marker glyph keeps
    /// the diff's full ink, and every token on a washed line is coloured against the wash it
    /// actually sits on. A patch that names no file keeps the old whole-line red and green,
    /// because guessing a language would colour code as something it is not.
    static func diffAttributed(
        _ source: String, language: String? = nil, font: NSFont
    ) -> NSAttributedString {
        let diff = SyntaxHighlighter.diff(source, language: language)
        let result = NSMutableAttributedString(
            string: source,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
        let length = result.length
        for token in diff.tokens {
            let range = NSRange(location: token.offset, length: token.length)
            guard NSMaxRange(range) <= length else { continue }
            let kind = diff.kind(at: token.offset)
            let colour = kind == .added || kind == .removed
                ? MacTheme.Color.syntax(token.role, on: kind) : MacTheme.Color.syntax(token.role)
            result.addAttribute(.foregroundColor, value: colour, range: range)
        }
        return result
    }

    /// The pane a code block lives in: exactly as tall as the code, as wide as the column, and
    /// scrolling sideways when a line runs past it — never down, because a scroller inside the
    /// transcript's scroller is two gestures fighting over one wheel.
    static func codeScroll(around content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.trailingAnchor.constraint(greaterThanOrEqualTo: clip.trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: content.heightAnchor),
        ])
        return scroll
    }

    /// The lines a block shows right now — a gutter of numbers beside the code, both set in the
    /// same face so a row of one is a row of the other — folded or whole as the reader decided.
    static func codeLines(_ body: String, language: String?, expanded: Bool) -> NSView {
        let fold = TranscriptBlocks.fold(body, expanded: expanded)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        if fold.totalLines > 1 {
            let gutter = label(
                TranscriptBlocks.lineNumbers(fold), font: MacTheme.Ramp.font(.code),
                color: MacTheme.Color.tertiaryLabel)
            gutter.alignment = .right
            gutter.maximumNumberOfLines = 0
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(gutter)
        }
        let scroll = codeScroll(around: code(fold.shown, language: language))
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(scroll)
        return row
    }

    /// The copy button of a block: the bytes go to the pasteboard exactly, and the button says
    /// so for a moment where the pointer already is, beside the toast.
    static func copyButton(_ bytes: String, toast: ((String) -> Void)?) -> NSButton {
        let ref = Weak<NSButton>(nil)
        let button = linkButton(Localized.text("copy")) {
            copyToClipboard(bytes)
            toast?(Localized.text("Code copied"))
            ref.value?.title = Localized.text("copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ref.value?.title = Localized.text("copy")
            }
        }
        ref.value = button
        button.font = MacTheme.Ramp.font(.codeAction)
        return button
    }

    /// A weak hand on a view for a closure the view itself owns, so a button that retitles
    /// itself does not keep itself alive.
    final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    /// A tool's output, given room to be read: whole when it is short, its first lines and a
    /// button naming the rest when it is long — never a box that scrolls inside the transcript.
    /// Whether it is opened belongs to the caller, because the row is rebuilt whenever the call
    /// beneath it changes and a reader's "show more" must not fold itself back up.
    static func foldedOutput(
        _ output: String, opened startsOpen: Bool = false, onToggle: ((Bool) -> Void)? = nil,
        render: @escaping (String) -> NSAttributedString
    ) -> NSView {
        var opened = startsOpen
        let fold = TranscriptBlocks.fold(output, expanded: opened)
        let field = attributedLabel(render(fold.shown))
        guard let title = fold.toggleLabel else { return field }
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(field)
        let shown = Weak(field)
        let button = Weak<NSButton>(nil)
        let toggle = linkButton(title) {
            opened.toggle()
            onToggle?(opened)
            let fold = TranscriptBlocks.fold(output, expanded: opened)
            shown.value?.attributedStringValue = render(fold.shown)
            button.value?.title = fold.toggleLabel ?? ""
        }
        button.value = toggle
        toggle.font = MacTheme.Ramp.font(.codeAction)
        column.addArrangedSubview(toggle)
        return column
    }

    /// A line that begins with an SF Symbol drawn at the line's own size and ink, where it used to
    /// begin with an emoji the system would have painted in colours of its own.
    static func symbolText(
        _ symbol: String, _ text: String, font: NSFont, color: NSColor
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration.applying(.init(paletteColors: [color])))
        line.append(NSAttributedString(attachment: attachment))
        line.append(NSAttributedString(string: " " + text))
        line.addAttributes(
            [.font: font, .foregroundColor: color], range: NSRange(location: 0, length: line.length))
        return line
    }

    /// One of a message's verbs as VoiceOver lists it.
    static func verb(_ title: String, run: @escaping () -> Void) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: title) {
            run()
            return true
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A target-action shim so a row built in a static function can hand a closure to AppKit.
    final class ActionButton: NSButton {
        private var handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(frame: .zero)
            self.title = title
            bezelStyle = .rounded
            target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// What the button does, changed after it was made — a purchase button learns its product
        /// only once the App Store answers, and the window is built before that.
        func setAction(_ action: @escaping () -> Void) {
            handler = action
        }

        @objc private func fire() {
            handler()
        }
    }

    final class FlippedClip: NSClipView {
        nonisolated override var isFlipped: Bool { true }
    }
}
