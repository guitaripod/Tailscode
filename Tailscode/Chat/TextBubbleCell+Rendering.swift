import CodingAgentKit
import TailscodeCore
import UIKit

extension TextBubbleCell {
    func configure(
        text: String, role: MessageRole, reasoning: Bool, timestamp: Bool = false,
        cascade: CascadeTail? = nil
    ) {
        let isUser = role == .user
        contentChanged()
        measuresItself = false

        padText(isUser && !timestamp ? CGFloat(Theme.Chat.metrics.promptBubblePadding) : 0)
        aurora.release()
        cascadeBase = nil
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
        applyHorizontalInsets(
            outer: isUser || timestamp ? Theme.Spacing.l : Theme.Spacing.s,
            inner: isUser || timestamp ? Theme.Spacing.m : Theme.Spacing.s)

        if timestamp {
            wearsAnswerStyle = false
            constrainWords()
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.tertiaryLabel
            textView.font = Theme.Ramp.font(.rowStamp)
            textView.textAlignment = .center
            textView.text = text
            leadingPin.isActive = false
            trailingPin.isActive = false
            maxWidth.isActive = false
            if timestampLeading == nil {
                timestampLeading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
                timestampTrailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
            }
            timestampLeading?.isActive = true
            timestampTrailing?.isActive = true
            return
        }

        maxWidth.isActive = isUser
        leadingPin.isActive = !isUser
        trailingPin.isActive = true
        measuresItself = !isUser
        if measuresItself { placeWords() } else { constrainWords() }
        if textView.textAlignment != .natural { textView.textAlignment = .natural }
        let detectsLinks = cascade == nil
        if (textView.dataDetectorTypes == [.link]) != detectsLinks {
            textView.dataDetectorTypes = detectsLinks ? [.link] : []
        }

        if reasoning {
            wearsAnswerStyle = false
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.secondaryLabel
            textView.font = Theme.Ramp.font(.thought)
            if let cascade {
                let string = NSAttributedString(
                    string: text,
                    attributes: Theme.Ramp.attributes(
                        .thought, color: Theme.Color.secondaryLabel))
                if !paintAurora(string, cascade: cascade, reasoning: true) {
                    adopt(cascade.paint(string, settled: Theme.Color.secondaryLabel))
                    cascadeBase = (cascade.textRevision, true, string)
                }
            } else {
                textView.text = text
            }
            textView.linkTextAttributes = [
                .foregroundColor: Theme.Color.secondaryLabel,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        } else if isUser {
            wearsAnswerStyle = false
            bubble.backgroundColor = Theme.Color.userBubble
            textView.textColor = Theme.Color.onAccent
            textView.font = Theme.Ramp.font(.prompt)
            textView.attributedText = NSAttributedString(
                string: text,
                attributes: Theme.Ramp.attributes(.prompt, color: Theme.Color.onAccent))
            textView.linkTextAttributes = [.foregroundColor: Theme.Color.onAccent]
        } else {
            bubble.backgroundColor = .clear
            if !wearsAnswerStyle {
                textView.textColor = Theme.Color.label
                textView.font = Theme.Ramp.font(.answer)
            }
            let rendered = Self.rendered(text, color: Theme.Color.label)
            let drawn = cascade.map { paintAurora(rendered, cascade: $0, reasoning: false) } ?? false
            if !drawn {
                adopt(cascade.map { $0.paint(rendered, settled: Theme.Color.label) } ?? rendered)
                if let cascade { cascadeBase = (cascade.textRevision, false, rendered) }
            }
            if !wearsAnswerStyle {
                textView.linkTextAttributes = [
                    .foregroundColor: Theme.Color.accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
                wearsAnswerStyle = true
            }
        }
    }

    /// A frame of the wave. When the glyphs did not change, only colours move, so the storage is
    /// re-tinted in place and nothing re-measures; when text arrived, the full render lands at
    /// once. Either way the paragraph is measured once per arrival and never again.
    ///
    /// What the glyphs are is decided by `CascadeTail.textRevision`, never by reading the words:
    /// the answer is rendered and compared with the storage once per arrival, and every frame
    /// between two arrivals goes straight to the tail.
    func applyCascade(_ cascade: CascadeTail, text: String, reasoning: Bool) {
        if let held = cascadeBase, held.revision == cascade.textRevision, held.reasoning == reasoning,
            !aurora.isLit, cascade.aurora == nil,
            textView.textStorage.length == held.text.length
        {
            textView.paintingColours {
                cascade.repaint(
                    textView.textStorage, base: held.text,
                    settled: reasoning ? Theme.Color.secondaryLabel : Theme.Color.label)
            }
            return
        }
        contentChanged()
        if reasoning {
            let string = NSAttributedString(
                string: text,
                attributes: Theme.Ramp.attributes(.thought, color: Theme.Color.secondaryLabel))
            if paintAurora(string, cascade: cascade, reasoning: true) { return }
            aurora.release()
            adopt(cascade.paint(string, settled: Theme.Color.secondaryLabel))
            cascadeBase = (cascade.textRevision, true, string)
            return
        }
        let rendered = Self.rendered(text, color: Theme.Color.label)
        if paintAurora(rendered, cascade: cascade, reasoning: false) { return }
        aurora.release()
        if textView.textStorage.length == rendered.length,
            textView.textStorage.string == rendered.string
        {
            textView.paintingColours {
                cascade.repaint(textView.textStorage, base: rendered, settled: Theme.Color.label)
            }
        } else {
            adopt(cascade.paint(rendered, settled: Theme.Color.label))
        }
        cascadeBase = (cascade.textRevision, false, rendered)
    }

    private func paintAurora(
        _ rendered: NSAttributedString, cascade: CascadeTail, reasoning: Bool
    ) -> Bool {
        aurora.paint(
            rendered, cascade: cascade,
            key: (reasoning ? "thought:" : "answer:") + String(cascade.textRevision))
    }

    /// Where the last written glyph ends, in this cell's coordinates — the bottom edge of the
    /// text the reader can actually see, read off the layout the row was measured with. The
    /// transcript follows this rather than the row's bottom, which is where the laid-out but
    /// still invisible remainder of the paragraph ends.
    func revealedBottom(_ revealed: Int) -> CGFloat {
        let storage = textView.textStorage
        let shown = min(max(revealed, 0), storage.length)
        var y = textView.textContainerInset.top
        if shown > 0 {
            let manager = textView.layoutManager
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: shown),
                actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            y += rect.maxY
        }
        return textView.convert(CGPoint(x: 0, y: y), to: contentView).y
    }

    /// Renders inline markdown (bold/italic/code/links) while preserving whitespace, and styles
    /// inline `code` spans with a monospaced font and a subtle fill.
    private static let renderCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 200
        return cache
    }()

    static func relieveRenderCache() {
        renderCache.removeAllObjects()
    }

    static func rendered(_ text: String, color: UIColor) -> NSAttributedString {
        let key = "\(text)#\(color.description)" as NSString
        if let cached = renderCache.object(forKey: key) { return cached }
        let base = Theme.Ramp.font(.answer)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let result: NSAttributedString
        if var attr = try? AttributedString(markdown: text, options: options) {
            attr.font = base
            attr.foregroundColor = color
            let headingFont = Theme.Ramp.font(.cardTitle)
            for run in attr.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attr[run.range].font = Theme.Ramp.font(.code)
                    attr[run.range].backgroundColor = Theme.Color.reasoningBackground
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    traits.insert(.traitBold)
                }
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    traits.insert(.traitItalic)
                }
                if !traits.isEmpty, run.inlinePresentationIntent?.contains(.code) != true {
                    attr[run.range].font = base.withTraits(traits)
                }
            }
            let mutable = NSMutableAttributedString(attr)
            mutable.addAttribute(
                .paragraphStyle, value: Self.prose(),
                range: NSRange(location: 0, length: mutable.length))
            var edits: [(range: NSRange, replacement: String)] = []
            var ruleLocations = Set<Int>()
            mutable.mutableString.enumerateSubstrings(
                in: NSRange(location: 0, length: mutable.length),
                options: .byLines
            ) { _, substringRange, _, _ in
                let line = mutable.attributedSubstring(from: substringRange).string
                let marks = line.prefix(while: { $0 == "#" }).count
                if marks >= 1, marks <= 6, line.dropFirst(marks).hasPrefix(" ") {
                    let font = marks <= 2 ? Theme.Ramp.font(.headline) : headingFont
                    mutable.addAttribute(.font, value: font, range: substringRange)
                    edits.append(
                        (NSRange(location: substringRange.location, length: marks + 1), ""))
                    return
                }
                let trimmedStart = line.drop { $0 == " " }
                let indentDepth = line.count - trimmedStart.count
                if Self.isHorizontalRule(line) {
                    ruleLocations.insert(substringRange.location)
                    edits.append((substringRange, ""))
                } else if trimmedStart.hasPrefix("- ") || trimmedStart.hasPrefix("* ") {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = CGFloat(indentDepth) * 6
                    paragraph.headIndent = CGFloat(indentDepth) * 6 + 14
                    paragraph.paragraphSpacing = Self.listItemSpacing
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    let item = trimmedStart.dropFirst(2)
                    if let box = ["[ ] ": "☐  ", "[x] ": "☑  ", "[X] ": "☑  "]
                        .first(where: { item.hasPrefix($0.key) })
                    {
                        edits.append((
                            NSRange(location: substringRange.location + indentDepth, length: 6),
                            box.value
                        ))
                    } else {
                        edits.append((
                            NSRange(location: substringRange.location + indentDepth, length: 2),
                            indentDepth >= 2 ? "◦  " : "•  "
                        ))
                    }
                } else if let digits = Self.orderedListPrefixLength(trimmedStart) {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = CGFloat(indentDepth) * 6
                    paragraph.headIndent = CGFloat(indentDepth) * 6 + CGFloat(digits + 1) * 8
                    paragraph.paragraphSpacing = Self.listItemSpacing
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                } else if trimmedStart.hasPrefix("> ") {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = 12
                    paragraph.headIndent = 12
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    mutable.addAttribute(
                        .foregroundColor, value: Theme.Color.secondaryLabel, range: substringRange)
                    edits.append((
                        NSRange(location: substringRange.location + indentDepth, length: 2), ""
                    ))
                }
            }
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                if ruleLocations.contains(edit.range.location) {
                    mutable.replaceCharacters(in: edit.range, with: Self.rule(font: base))
                } else {
                    mutable.replaceCharacters(in: edit.range, with: edit.replacement)
                }
            }
            linkFilePaths(in: mutable)
            result = mutable
        } else {
            let mutable = NSMutableAttributedString(
                string: text, attributes: [.font: base, .foregroundColor: color])
            linkFilePaths(in: mutable)
            result = mutable
        }
        renderCache.setObject(result, forKey: key)
        return result
    }

    /// The line a rule becomes: one attachment that is as wide as the line it stands on, so it is a
    /// full-width hairline in the separator colour at any width or type size.
    private static func rule(font: UIFont) -> NSAttributedString {
        NSAttributedString(
            attachment: HairlineAttachment(font: font),
            attributes: [.foregroundColor: Theme.Color.separator, .paragraphStyle: prose()])
    }

    /// A line of three or more dashes on its own, which is how a model draws a rule between
    /// sections.
    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
    }

    /// Every paragraph in an answer starts from the ramp's leading, so an indented list item is not
    /// set tighter than the prose above it merely for having asked to be indented.
    static func prose() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Typography.spec(.answer).lineHeight
        return paragraph
    }

    /// A list reads as a list when the gap between two items is bigger than the gap inside one.
    /// Equal spacing everywhere is what makes a wrapped item look like two items — the hanging
    /// indent says where an item continues, and this says where the next one starts.
    static let listItemSpacing: CGFloat = 3

    /// The digit count of a `1. ` / `12) ` ordered-list marker, or nil when
    /// the line is not a list item — used to hang wrapped lines past the number.
    private static func orderedListPrefixLength(_ line: Substring) -> Int? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return digits.count
    }

    private static let filePathRegex = try? NSRegularExpression(
        pattern: "(?<![\\w/~.-])(~?/(?:[\\w.@%+-]+/)+[\\w.@%+-]+(:\\d+)?)")

    /// Absolute and home-relative paths in assistant prose become tappable
    /// links (`tailscode-path` scheme) so a mentioned file can be copied or
    /// dropped into the composer without hand-selecting text.
    static func pathActionURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "tailscode-path"
        components.host = "path"
        components.queryItems = [URLQueryItem(name: "p", value: path)]
        return components.url
    }

    static func path(fromActionURL url: URL) -> String? {
        guard url.scheme == "tailscode-path" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "p" })?.value
    }

    private static func linkFilePaths(in text: NSMutableAttributedString) {
        guard let regex = filePathRegex, text.length <= 12_000, text.string.contains("/")
        else { return }
        let matches = regex.matches(
            in: text.string, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            var range = match.range(at: 1)
            var hasLink = false
            text.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                if value != nil {
                    hasLink = true
                    stop.pointee = true
                }
            }
            guard !hasLink else { continue }
            var token = (text.string as NSString).substring(with: range)
            while let last = token.last, ".,;:)".contains(last) {
                token.removeLast()
                range.length -= 1
            }
            guard token.dropFirst().contains("/"), let url = pathActionURL(for: token) else { continue }
            text.addAttribute(.link, value: url, range: range)
        }
    }
}
