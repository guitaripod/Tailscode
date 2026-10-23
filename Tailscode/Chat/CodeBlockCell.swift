import TailscodeCore
import UIKit

/// Renders a fenced code block with a language header, one-tap raw copy, and collapse for long
/// blocks — a native client owning the exact clipboard string.
final class CodeBlockCell: UICollectionViewCell {
    static let reuseID = "CodeBlockCell"
    private static var collapsedLineLimit: Int { Theme.Chat.metrics.codeCollapseLines }

    private let container = UIView()
    private let langLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let codeScroll = UIScrollView()
    private let codeLabel = DiffWashLabel()
    private let lineNumberLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var source = ""
    private var onToggle: (() -> Void)?
    private var containerTop: NSLayoutConstraint!
    private var toggleTop: NSLayoutConstraint!
    private var toggleBottom: NSLayoutConstraint!
    private var plainBottom: NSLayoutConstraint!
    /// The glyphs the label is currently showing, kept so a frame of the wave can be tinted over
    /// them rather than built again from the highlighter's output.
    private var paintedStorage: NSMutableAttributedString?
    /// What the last arrival of the wave laid out and highlighted, so the frames between two
    /// arrivals do not split and highlight the whole block again.
    private var cascadeLaid: (revision: Int, expanded: Bool, text: String, base: NSAttributedString)?
    /// The text the label was last given, which is what decides whether this row is still the row
    /// the reader was reading sideways.
    private var laidOutText = ""
    private var aurora: AuroraStreamView?
    private var auroraStack: AuroraTextStack?
    private var auroraSource: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.backgroundColor = Theme.Color.codeBackground
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        langLabel.font = Theme.Ramp.font(.codeLabel)
        langLabel.textColor = Theme.Color.tertiaryLabel
        langLabel.translatesAutoresizingMaskIntoConstraints = false

        var copyConfig = UIButton.Configuration.plain()
        copyConfig.image = UIImage(
            systemName: "doc.on.doc", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyConfig.baseForegroundColor = Theme.Color.secondaryLabel
        copyConfig.contentInsets = .zero
        copyButton.configuration = copyConfig
        copyButton.accessibilityLabel = String(localized: "Copy code")
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        codeScroll.showsVerticalScrollIndicator = false
        codeScroll.showsHorizontalScrollIndicator = true
        codeScroll.alwaysBounceVertical = false
        codeScroll.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.numberOfLines = 0
        codeLabel.font = Self.monoFont
        codeLabel.textColor = Theme.Color.label
        codeLabel.lineBreakMode = .byClipping
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        lineNumberLabel.numberOfLines = 0
        lineNumberLabel.font = Self.monoFont
        lineNumberLabel.textColor = Theme.Color.tertiaryLabel
        lineNumberLabel.textAlignment = .right
        lineNumberLabel.isAccessibilityElement = false
        lineNumberLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.titleLabel?.font = Theme.Ramp.font(.panelDetail)
        toggleButton.setTitleColor(Theme.Color.accent, for: .normal)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [langLabel, copyButton, codeScroll, toggleButton].forEach(container.addSubview)
        [lineNumberLabel, codeLabel].forEach(codeScroll.addSubview)

        let content = codeScroll.contentLayoutGuide
        let frame = codeScroll.frameLayoutGuide
        containerTop = container.topAnchor.constraint(
            equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            containerTop,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.s),

            langLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.s),
            langLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            copyButton.centerYAnchor.constraint(equalTo: langLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            codeScroll.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: Theme.Spacing.xs),
            codeScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            codeScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            frame.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualTo: frame.widthAnchor),

            lineNumberLabel.topAnchor.constraint(equalTo: content.topAnchor),
            lineNumberLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lineNumberLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            codeLabel.topAnchor.constraint(equalTo: content.topAnchor),
            codeLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            codeLabel.leadingAnchor.constraint(equalTo: lineNumberLabel.trailingAnchor, constant: Theme.Spacing.s),
            codeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.s),

            toggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            toggleButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        toggleTop = toggleButton.topAnchor.constraint(
            equalTo: codeScroll.bottomAnchor, constant: Theme.Spacing.xs)
        toggleBottom = toggleButton.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -Theme.Spacing.s)
        plainBottom = codeScroll.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -Theme.Spacing.s)
        plainBottom.isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { containerTop.constant = gapAbove }
    }

    func configure(
        _ block: CodeBlock, expanded: Bool, cascade: CascadeTail? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        source = block.source
        langLabel.text = SyntaxHighlighter.displayName(for: block.language, source: block.source)
        var copyConfig = copyButton.configuration ?? .plain()
        copyConfig.image = UIImage(
            systemName: "doc.on.doc", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = copyConfig
        let layout = Self.laidOut(block.source, expanded: expanded)
        rewindIfAnotherBlock(layout.text)
        let base = Self.highlightedCode(layout.text, language: block.language)
        releaseAurora()
        cascadeLaid = cascade.map { ($0.textRevision, expanded, layout.text, base) }
        let drawn =
            cascade.map {
                paintAurora(base, cascade: $0, key: Self.auroraKey($0, expanded: expanded))
            } ?? false
        if !drawn {
            let storage = NSMutableAttributedString(
                attributedString: cascade.map { $0.paint(base, settled: Theme.Color.label) } ?? base)
            paintedStorage = storage
            codeLabel.attributedText = storage
        }
        codeLabel.washes = Self.washes(layout.text, language: block.language)
        lineNumberLabel.text = Self.lineNumbers(count: layout.shownLines)
        let title =
            layout.isLong && !expanded
            ? String(localized: "Show all \(layout.totalLines) lines")
            : String(localized: "Collapse")
        toggleButton.setTitle(title, for: .normal)
        toggleButton.isHidden = !layout.isLong
        reserveToggle(layout.isLong)
    }

    /// Whether the toggle line takes room under the code. A hidden button keeps its constraints, so
    /// a block with nothing to fold used to stand a button's height taller than its last line; the
    /// body is now sized to its content and the toggle's constraints exist only while it is shown.
    private func reserveToggle(_ shown: Bool) {
        guard toggleTop.isActive != shown else { return }
        if shown {
            plainBottom.isActive = false
            toggleTop.isActive = true
            toggleBottom.isActive = true
        } else {
            toggleTop.isActive = false
            toggleBottom.isActive = false
            plainBottom.isActive = true
        }
    }

    /// Puts the block back at its first column, but only when it is a different block.
    ///
    /// A code row scrolls sideways because a line is longer than the phone, and where the reader
    /// scrolled it to is theirs. `configure` runs again for every streamed arrival, for a frame the
    /// wave could not paint in place, for an image elsewhere finishing its decode, for the toggle
    /// and for the hand-back at the end of a turn — and rewinding on all of them meant a long line
    /// could not be read at all: the next token pulled it back to column one. Text that continues
    /// what was already there is the same block still being written, and it keeps its place; a cell
    /// recycled onto another block, or a block collapsed back down, starts over.
    private func rewindIfAnotherBlock(_ text: String) {
        defer { laidOutText = text }
        guard !text.hasPrefix(laidOutText) else { return }
        codeScroll.setContentOffset(.zero, animated: false)
    }

    /// What the block actually lays out, which everything that touches the row has to agree on.
    ///
    /// A long block shows its first lines until the reader opens it, and that decision was being
    /// made three times over: `configure` laid out the prefix, a frame of the wave painted the
    /// whole source, and the pacer counted the whole source's characters. So the cell alternated
    /// two different heights — opaque on every arrival, faded on every frame — and the reveal
    /// finished while the reader was still fourteen lines behind, because the pacer was counting
    /// characters the cell would never lay out. One answer, asked here, keyed off whether the
    /// reader has opened the row and never off what the toggle button's title happens to say in
    /// the language the phone is set to.
    static func laidOut(_ source: String, expanded: Bool)
        -> (text: String, shownLines: Int, totalLines: Int, isLong: Bool)
    {
        let lines = source.components(separatedBy: "\n")
        let isLong = lines.count > collapsedLineLimit
        guard isLong, !expanded else {
            return (source, lines.count, lines.count, isLong)
        }
        return (
            lines.prefix(collapsedLineLimit).joined(separator: "\n"), collapsedLineLimit,
            lines.count, true
        )
    }

    /// The grounds under a diff's changed lines, as geometry for `DiffWashLabel` to paint. Any
    /// other language has none.
    static func washes(_ source: String, language: String?) -> [(row: Int, color: UIColor)] {
        guard SyntaxHighlighter.isDiff(language) else { return [] }
        return SyntaxHighlighter.diffLines(source).compactMap { line in
            guard line.kind == .added || line.kind == .removed else { return nil }
            return (line.row, Theme.Color.diffBackground(line.kind))
        }
    }

    /// A frame that moved only the band: the same glyphs, freshly tinted. The highlighter's own
    /// colours are the settled ones, so a keyword leaves the wave the keyword colour rather than
    /// the prose colour — the cascade tints what is there rather than replacing it.
    ///
    /// The glyphs are whatever `configure` laid out, which for a long block the reader has not
    /// opened is its first fourteen lines. Painting the whole source here instead would grow the
    /// cell to the full block on the display's clock and shrink it back on the next arrival, with
    /// the gutter still numbering fourteen — a frame is allowed to change light, never a size the
    /// layout depends on.
    func applyCascade(_ cascade: CascadeTail, block: CodeBlock, expanded: Bool) {
        let base: NSAttributedString
        let reused: Bool
        if let held = cascadeLaid, held.revision == cascade.textRevision, held.expanded == expanded {
            base = held.base
            reused = true
        } else {
            let laid = Self.laidOut(block.source, expanded: expanded).text
            base = Self.highlightedCode(laid, language: block.language)
            cascadeLaid = (cascade.textRevision, expanded, laid, base)
            reused = false
        }
        if paintAurora(base, cascade: cascade, key: Self.auroraKey(cascade, expanded: expanded)) {
            return
        }
        releaseAurora()
        if let storage = paintedStorage, storage.length == base.length,
            reused || storage.string == base.string
        {
            cascade.repaint(storage, base: base, settled: Theme.Color.label)
            codeLabel.repaint(storage)
            return
        }
        let storage = NSMutableAttributedString(
            attributedString: cascade.paint(base, settled: Theme.Color.label))
        paintedStorage = storage
        codeLabel.attributedText = storage
    }

    /// What names one laid-out arrival of a block for the alpha renderer: the arrival and whether
    /// the reader has the whole block open, never the source itself.
    private static func auroraKey(_ cascade: CascadeTail, expanded: Bool) -> String {
        "\(cascade.textRevision):\(expanded)"
    }

    /// One frame of the alpha renderer over a block of code.
    ///
    /// Code has no inline markdown to protect and no wrapping to be surprised by, so the band is
    /// simply the tail of what the highlighter produced — the same range, read out of a layout of
    /// this cell's own and handed to the GPU by being made clear in the label's storage. The
    /// highlighter's colours survive it: the wave tints what is already there, so a keyword leaving
    /// the edge lands on the colour it would have had if it had never been in one.
    private func paintAurora(_ base: NSAttributedString, cascade: CascadeTail, key: String) -> Bool
    {
        guard let frame = cascade.aurora, let view = ensureAurora() else { return false }
        if auroraSource != key {
            let stack = auroraStack ?? AuroraTextStack()
            auroraStack = stack
            codeLabel.attributedText = base
            paintedStorage = nil
            layoutIfNeeded()
            stack.adopt(base)
            let band = max(0, min(cascade.revealed, base.length) - cascade.span)
            guard base.length > band,
                view.adopt(
                    layoutManager: stack.layoutManager, container: stack.container,
                    glyphOrigin: .zero, from: band, upTo: base.length)
            else { return false }
            let storage = NSMutableAttributedString(attributedString: base)
            storage.addAttribute(
                .foregroundColor, value: UIColor.clear,
                range: NSRange(location: band, length: base.length - band))
            paintedStorage = storage
            codeLabel.repaint(storage)
            auroraSource = key
        }
        view.paint(frame)
        return true
    }

    /// Where the last written line of code ends, in this cell's coordinates. A line of code ends
    /// at its newline and nowhere else, so the written height is the written lines' worth of the
    /// block's own line height — exact rather than measured.
    func revealedBottom(_ revealed: Int, block: CodeBlock, expanded: Bool) -> CGFloat {
        let laid = Self.laidOut(block.source, expanded: expanded).text as NSString
        let shown = min(max(revealed, 0), laid.length)
        let lines = shown == 0 ? 0 : laid.substring(to: shown).components(separatedBy: "\n").count
        let height = CGFloat(lines) * Self.monoFont.lineHeight
        return codeLabel.convert(CGPoint(x: 0, y: height), to: contentView).y
    }

    private func ensureAurora() -> AuroraStreamView? {
        if let aurora { return aurora }
        guard AuroraStreamView.isAvailable else { return nil }
        let view = AuroraStreamView()
        view.translatesAutoresizingMaskIntoConstraints = false
        codeScroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: codeLabel.topAnchor),
            view.bottomAnchor.constraint(equalTo: codeLabel.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: codeLabel.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: codeLabel.trailingAnchor),
        ])
        aurora = view
        return view
    }

    private func releaseAurora() {
        guard auroraSource != nil || aurora?.isLit == true else { return }
        auroraSource = nil
        aurora?.release()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseAurora()
        cascadeLaid = nil
    }

    private static func lineNumbers(count: Int) -> String {
        (1...count).map { "\($0)" }.joined(separator: "\n")
    }

    static var monoFont: UIFont { Theme.Ramp.font(.code) }

    private static let highlightCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 60
        return cache
    }()

    static func relieveHighlightCache() {
        highlightCache.removeAllObjects()
    }

    /// The shared lexer's tokens, painted in this theme's colours. Nothing about which run is a
    /// keyword is decided here — that answer is Core's, and the Linux and Mac clients ask it the
    /// same question, which is what keeps one block of code looking like itself on three screens.
    ///
    /// The cache needs no theme in its key: the colours put in are dynamic, so the text system
    /// resolves them against the trait collection of whatever draws them, and a cached block
    /// repaints itself when the theme changes rather than going stale.
    static func highlightedCode(
        _ source: String, language: String?, font: UIFont = monoFont
    ) -> NSAttributedString {
        let key = "\(font.pointSize)#\(language ?? "")#\(source)" as NSString
        if let cached = highlightCache.object(forKey: key) { return cached }
        let result: NSAttributedString
        if SyntaxHighlighter.isDiff(language) {
            result = diffAttributed(source, font: font)
        } else {
            let plain = NSMutableAttributedString(string: source, attributes: [
                .font: font, .foregroundColor: Theme.Color.label,
            ])
            let length = plain.length
            for token in SyntaxHighlighter.tokens(source, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= length else { continue }
                plain.addAttribute(
                    .foregroundColor, value: Theme.Color.syntax(token.role), range: range)
            }
            result = plain
        }
        highlightCache.setObject(result, forKey: key)
        return result
    }

    /// A patch's ink. The wash under each changed line carries the diff's meaning — painted by
    /// the hosting view, full width, never as a background attribute that stops at the last
    /// glyph — which frees the foreground for the file's own language: the marker glyph keeps
    /// the diff's full ink, and every token on a washed line is coloured against the wash it
    /// actually sits on. A patch that names no file keeps the old whole-line red and green,
    /// because guessing a language would colour code as something it is not.
    static func diffAttributed(
        _ source: String, language: String? = nil, font: UIFont
    ) -> NSAttributedString {
        let diff = SyntaxHighlighter.diff(source, language: language)
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font, .foregroundColor: Theme.Color.label,
        ])
        let length = result.length
        for token in diff.tokens {
            let range = NSRange(location: token.offset, length: token.length)
            guard NSMaxRange(range) <= length else { continue }
            let kind = diff.kind(at: token.offset)
            let color = kind == .added || kind == .removed
                ? Theme.Color.syntax(token.role, on: kind) : Theme.Color.syntax(token.role)
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
        return result
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = source
        Theme.Haptics.success()
        var config = copyButton.configuration
        config?.image = UIImage(
            systemName: "checkmark", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = config
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            var reset = copyButton.configuration
            reset?.image = UIImage(
                systemName: "doc.on.doc", withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            copyButton.configuration = reset
        }
    }

    @objc private func toggleTapped() {
        Theme.Haptics.selection()
        onToggle?()
    }
}
