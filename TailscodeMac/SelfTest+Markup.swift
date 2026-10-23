import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The transcript's markdown, checked as attributes rather than as pixels: emphasis must
    /// carry its trait, code its monospace, a link its URL — and arithmetic, snake_case and
    /// asterisks inside code spans must survive untouched, which is the failure a renderer grows
    /// quietly.
    static func checkMarkup() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("markup case failed: \(label)") }
            checks += 1
        }
        func attributes(
            in rendered: NSAttributedString, over needle: String
        ) -> [NSAttributedString.Key: Any]? {
            let range = (rendered.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return rendered.attributes(at: range.location, effectiveRange: nil)
        }
        func font(_ attributes: [NSAttributedString.Key: Any]?) -> NSFont? {
            attributes?[.font] as? NSFont
        }
        func weight(_ font: NSFont?) -> CGFloat {
            let traits =
                font?.fontDescriptor.object(forKey: .traits)
                as? [NSFontDescriptor.TraitKey: Any]
            return traits?[.weight] as? CGFloat ?? 0
        }
        func hasItalic(_ rendered: NSAttributedString) -> Bool {
            var found = false
            rendered.enumerateAttribute(
                .font, in: NSRange(location: 0, length: rendered.length)
            ) { value, _, _ in
                if let font = value as? NSFont,
                    font.fontDescriptor.symbolicTraits.contains(.italic)
                {
                    found = true
                }
            }
            return found
        }

        func paragraph(in rendered: NSAttributedString, over needle: String)
            -> NSParagraphStyle?
        {
            let range = (rendered.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return rendered.attributes(at: range.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        }

        let listed = MacMarkdown.render("- first item\n- second item\n\nplain line")
        let item = paragraph(in: listed, over: "first item")
        try expect(item != nil, "a list item is its own paragraph")
        try expect(
            (item?.headIndent ?? 0) > (item?.firstLineHeadIndent ?? 0),
            "a wrapped list line hangs past its bullet instead of returning to the margin")
        try expect((item?.paragraphSpacing ?? 0) > 0, "items are spaced apart, not run together")
        let prose = paragraph(in: listed, over: "plain line")
        try expect(
            (prose?.headIndent ?? 0) == 0 && (prose?.firstLineHeadIndent ?? 0) == 0,
            "prose is not indented like a list")
        try expect(!listed.string.contains("- first"), "the marker is replaced by its glyph")

        let bold = MacMarkdown.render("**bold** here")
        try expect(
            weight(font(attributes(in: bold, over: "bold")))
                > weight(font(attributes(in: bold, over: "here"))),
            "bold carries more weight than its neighbours")
        try expect(!bold.string.contains("*"), "the asterisks are consumed")

        let italic = MacMarkdown.render("some *italic* text")
        try expect(
            font(attributes(in: italic, over: "italic"))?.fontDescriptor.symbolicTraits
                .contains(.italic) == true, "italic carries the trait")
        try expect(!italic.string.contains("*"), "the emphasis marks are consumed")

        let arithmetic = MacMarkdown.render("2 * 3 * 4 = 24")
        try expect(
            !hasItalic(arithmetic) && arithmetic.string.contains("2 * 3 * 4 = 24"),
            "arithmetic never italicizes")
        let snake = MacMarkdown.render("snake_case and more_snake here")
        try expect(
            !hasItalic(snake) && snake.string.contains("snake_case"),
            "intra-word underscores stay literal")

        let code = MacMarkdown.render("a `snippet` inline")
        try expect(
            font(attributes(in: code, over: "snippet"))?.fontDescriptor.symbolicTraits
                .contains(.monoSpace) == true, "a code span renders monospaced")
        try expect(!code.string.contains("`"), "the backticks are consumed")
        let codeStars = MacMarkdown.render("`a * b` times `c * d`")
        try expect(
            !hasItalic(codeStars) && codeStars.string.contains("a * b"),
            "asterisks inside code stay code")
        let codeUnderscore = MacMarkdown.render("`gtk_box_append` per row")
        try expect(
            !hasItalic(codeUnderscore) && codeUnderscore.string.contains("gtk_box_append"),
            "underscores inside code stay code")

        let heading = MacMarkdown.render("## Heading")
        let headingFont = font(attributes(in: heading, over: "Heading"))
        let bodyFont = font(attributes(in: MacMarkdown.render("plain words"), over: "plain"))
        try expect(
            (headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? .greatestFiniteMagnitude)
                && weight(headingFont) > weight(bodyFont),
            "a heading is larger and heavier than body text")

        let link = MacMarkdown.render("[docs](https://x.dev)")
        try expect(
            (attributes(in: link, over: "docs")?[.link] as? URL)?.absoluteString
                == "https://x.dev", "a link carries its URL")
        try expect(!link.string.contains("]("), "the link markup is consumed")
        return checks
    }

    /// The rule a press is routed by, over real views in a real window: two panes side by side
    /// with a gap between them for the divider, and one hidden the way a zoom hides it.
    /// A code block is the one row whose layout is a claim: it must colour by role, and it must
    /// run off the right rather than reflow. A build cannot catch a label that quietly went back
    /// to wrapping, so the widths are measured here instead of looked at.
    static func checkCode() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("code case failed: \(label)") }
            checks += 1
        }
        func colour(in rendered: NSAttributedString, over needle: String) -> NSColor? {
            let range = (rendered.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return rendered.attributes(at: range.location, effectiveRange: nil)[.foregroundColor]
                as? NSColor
        }

        let source = "let name = \"a string\" // trailing note\nfunc go() -> Int { 42 }"
        let label = RowKit.code(source, language: "swift")
        let rendered = label.attributedStringValue
        try expect(rendered.string == source, "the block is the bytes it was given")

        let keyword = colour(in: rendered, over: "let")
        let text = colour(in: rendered, over: "name")
        let string = colour(in: rendered, over: "\"a string\"")
        let comment = colour(in: rendered, over: "// trailing note")
        try expect(keyword != nil && keyword != text, "a keyword is not prose")
        try expect(string != nil && string != keyword, "a string is not a keyword")
        try expect(comment != nil && comment != string, "a comment is not a string")

        try expect(label.maximumNumberOfLines == 0, "every line of the block is drawn")
        try expect(label.lineBreakMode == .byClipping, "a long line is clipped, never wrapped")

        let narrow: CGFloat = 120
        let wide = RowKit.code(String(repeating: "x", count: 400), language: "swift")
        let scroll = RowKit.codeScroll(around: wide)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: narrow, height: 400))
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        try expect(wide.frame.width > narrow, "a long line runs past the pane instead of folding")
        try expect(wide.frame.height > 0 && wide.frame.height < 200, "one long line stays one line")

        let diff = RowKit.code("-let old = 1\n+let new = 2", language: "diff").attributedStringValue
        let removed = colour(in: diff, over: "-let old = 1")
        let added = colour(in: diff, over: "+let new = 2")
        try expect(removed != nil && added != nil && removed != added, "a diff reads by its column")
        let washed = RowKit.code("-let old = 1\n+let new = 2", language: "diff")
            as? RowKit.DiffWashField
        try expect(
            washed?.washes.map(\.row) == [0, 1],
            "a diff's changed lines carry full-width washes, drawn rows 0 and 1")

        let headed = RowKit.code(
            "+++ b/App.swift\n+let a = \"s\"", language: "diff").attributedStringValue
        let headedKeyword = colour(in: headed, over: "let")
        let headedString = colour(in: headed, over: "\"s\"")
        try expect(
            headedKeyword != nil && headedString != nil && headedKeyword != headedString,
            "a headed diff lexes its body by the file's language")
        try expect(
            SyntaxHighlighter.displayName(for: "diff", source: "+++ b/App.swift\n+let a = 1")
                == "diff · swift",
            "a headed diff names both facts")

        try expect(SyntaxHighlighter.displayName(for: "py") == "python", "a fence tag is resolved")
        return checks
    }
}
