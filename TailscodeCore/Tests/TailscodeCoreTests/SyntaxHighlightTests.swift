import Foundation
import Testing

@testable import TailscodeCore

/// The lexer, proved on the shapes that actually break a highlighter: a comment marker inside a
/// string, a keyword inside a comment, a block that is still being written, and a language the
/// app has never heard of. Every claim here is a claim about all three clients at once — they
/// render the same token stream, so a rule proved once is a rule they cannot drift on.
@Suite struct SyntaxHighlightTests {
    private func roles(_ source: String, _ language: String) -> [(SyntaxRole, String)] {
        let utf16 = Array(source.utf16)
        return SyntaxHighlighter.tokens(source, language: language).map { token in
            let slice = Array(utf16[token.offset..<(token.offset + token.length)])
            return (token.role, String(decoding: slice, as: UTF16.self))
        }
    }

    private func text(_ source: String, _ language: String, role: SyntaxRole) -> [String] {
        roles(source, language).filter { $0.0 == role }.map(\.1)
    }

    @Test func tokensAreOrderedAndNeverOverlap() {
        let source = """
            /// Doc.
            func greet(_ name: String) -> Int {
                let count = 0x1F_00
                return count // trailing
            }
            """
        let tokens = SyntaxHighlighter.tokens(source, language: "swift")
        #expect(!tokens.isEmpty)
        var cursor = 0
        for token in tokens {
            #expect(token.offset >= cursor)
            #expect(token.length > 0)
            cursor = token.offset + token.length
        }
        #expect(cursor <= source.utf16.count)
    }

    @Test func offsetsSurviveEmojiAndAccents() {
        let source = "let 🎉 = \"héllo\" // ✓ done"
        let utf16 = Array(source.utf16)
        for token in SyntaxHighlighter.tokens(source, language: "swift") {
            #expect(token.offset + token.length <= utf16.count)
        }
        #expect(text(source, "swift", role: .string) == ["\"héllo\""])
        #expect(text(source, "swift", role: .comment) == ["// ✓ done"])
    }

    @Test func commentMarkerInsideStringIsNotAComment() {
        let source = #"let url = "https://example.com/path" // real"#
        #expect(text(source, "swift", role: .string) == [#""https://example.com/path""#])
        #expect(text(source, "swift", role: .comment) == ["// real"])
    }

    @Test func quoteInsideCommentDoesNotOpenAString() {
        let source = """
            // it's a comment
            let value = 1
            """
        #expect(text(source, "swift", role: .comment) == ["// it's a comment"])
        #expect(text(source, "swift", role: .string).isEmpty)
    }

    @Test func keywordInsideCommentIsNotAKeyword() {
        let source = "# def not_a_function(): pass"
        #expect(text(source, "python", role: .keyword).isEmpty)
        #expect(text(source, "python", role: .comment) == [source])
    }

    @Test func escapedQuoteDoesNotEndTheString() {
        let source = #"let quoted = "she said \"hi\"" ; let after = 2"#
        #expect(text(source, "swift", role: .string) == [#""she said \"hi\"""#])
        #expect(text(source, "swift", role: .number) == ["2"])
    }

    /// The half-written block is the normal case while a turn streams, so an unterminated string
    /// or comment has to claim the rest of the source instead of falling back to no colour at all.
    @Test func unterminatedRunsClaimTheRest() {
        let stringy = "let name = \"still typing"
        #expect(text(stringy, "swift", role: .string) == ["\"still typing"])

        let blocky = "/* opened and never"
        #expect(text(blocky, "swift", role: .comment) == [blocky])
    }

    @Test func nestedBlockCommentsClose() {
        let source = "/* outer /* inner */ still */ let x = 1"
        #expect(text(source, "swift", role: .comment) == ["/* outer /* inner */ still */"])
        #expect(text(source, "swift", role: .keyword) == ["let"])
    }

    @Test func numbersKeepTheirRadixAndSeparators() {
        #expect(text("let a = 0xFF_00", "swift", role: .number) == ["0xFF_00"])
        #expect(text("let b = 1_000_000", "swift", role: .number) == ["1_000_000"])
        #expect(text("let c = 1.5e-3", "swift", role: .number) == ["1.5e-3"])
    }

    @Test func callsReadAsFunctionsAndTypesAsTypes() {
        let source = "let parsed = Decoder().decode(Payload.self)"
        let functions = text(source, "swift", role: .function)
        let types = text(source, "swift", role: .type)
        #expect(functions.contains("decode"))
        #expect(types.contains("Payload"))
        #expect(text(source, "swift", role: .keyword) == ["let", "self"])
    }

    @Test func attributesAndDecoratorsAreTheirOwnRole() {
        #expect(text("@MainActor final class A {}", "swift", role: .attribute) == ["@MainActor"])
        #expect(text("@dataclass\nclass A: pass", "python", role: .attribute) == ["@dataclass"])
        #expect(
            text("#[derive(Debug, Clone)]\nstruct A;", "rust", role: .attribute)
                == ["#[derive(Debug, Clone)]"])
    }

    /// `#` opens a comment in the hash languages and a directive in C, so the sigil alone cannot
    /// decide — only a `#` where a line begins is a directive.
    @Test func hashIsADirectiveOnlyWhereALineBegins() {
        #expect(text("#include <stdio.h>", "c", role: .attribute) == ["#include"])
        #expect(text("int a = b # c;", "c", role: .attribute).isEmpty)
    }

    @Test func shellVariablesAndBracedExpansionsAreMarked() {
        let source = "echo \"$HOME and ${XDG_CONFIG_HOME}\""
        #expect(text(source, "bash", role: .attribute).isEmpty)
        let bare = "cp $SRC ${DEST}/out"
        #expect(text(bare, "bash", role: .attribute) == ["$SRC", "${DEST}"])
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let upper = text("SELECT id FROM users WHERE id = 1", "sql", role: .keyword)
        let lower = text("select id from users where id = 1", "sql", role: .keyword)
        #expect(upper.count == lower.count)
        #expect(upper.contains("SELECT"))
        #expect(lower.contains("select"))
    }

    @Test func diffIsLexedByItsFirstColumn() {
        let source = """
            --- a/File.swift
            +++ b/File.swift
            @@ -1,3 +1,3 @@
             context
            -let old = 1
            +let new = 2
            """
        #expect(text(source, "diff", role: .removed) == ["-let old = 1"])
        #expect(text(source, "diff", role: .added) == ["+let new = 2"])
        #expect(text(source, "diff", role: .type) == ["@@ -1,3 +1,3 @@"])
        #expect(text(source, "diff", role: .attribute) == ["--- a/File.swift", "+++ b/File.swift"])
    }

    @Test func jsonSeparatesKeysFromStringValues() {
        let source = """
            {
              "name": "tailscode",
              "count": 3,
              "on": true
            }
            """
        #expect(text(source, "json", role: .attribute) == ["\"name\"", "\"count\"", "\"on\""])
        #expect(text(source, "json", role: .string) == ["\"tailscode\""])
        #expect(text(source, "json", role: .number) == ["3"])
        #expect(text(source, "json", role: .keyword) == ["true"])
    }

    @Test func yamlKeysAndCommentsRead() {
        let source = """
            # a note
            name: tailscode
            ports:
              - 8080
              - 9090
            """
        #expect(text(source, "yaml", role: .comment) == ["# a note"])
        #expect(text(source, "yaml", role: .attribute) == ["name", "ports"])
        #expect(text(source, "yaml", role: .number) == ["8080", "9090"])
    }

    /// A bare word in a list has no colon after it, so it is a value — a highlighter that colours
    /// every first word on a line turns a list of strings into a list of keys.
    @Test func yamlListItemsAreNotKeys() {
        let source = """
            hosts:
              - alpha
              - beta
            """
        #expect(text(source, "yaml", role: .attribute) == ["hosts"])
    }

    @Test func tomlSectionsAreTheirOwnRole() {
        let source = """
            [package]
            name = "tailscode"
            version = 2
            """
        #expect(text(source, "toml", role: .type) == ["[package]"])
        #expect(text(source, "toml", role: .attribute) == ["name", "version"])
        #expect(text(source, "toml", role: .string) == ["\"tailscode\""])
    }

    @Test func markupSeparatesTagsAttributesAndValues() {
        let source = "<a class=\"link\" href='/x'>text</a><!-- note -->"
        #expect(text(source, "html", role: .attribute) == ["class", "href"])
        #expect(text(source, "html", role: .string) == ["\"link\"", "'/x'"])
        #expect(text(source, "html", role: .comment) == ["<!-- note -->"])
        #expect(text(source, "html", role: .keyword).contains("<a"))
    }

    @Test func styleSeparatesSelectorsFromProperties() {
        let source = """
            .card { color: #fff; margin: 4px }
            """
        #expect(text(source, "css", role: .attribute).contains("color"))
        #expect(text(source, "css", role: .attribute).contains("margin"))
        #expect(text(source, "css", role: .type).contains("card"))
    }

    @Test func markdownHeadingsFencesAndLinks() {
        let source = """
            # Title
            Some `inline` code and a [link](https://example.com).
            ```swift
            let a = 1
            ```
            > quoted
            """
        #expect(text(source, "markdown", role: .keyword) == ["# Title"])
        #expect(text(source, "markdown", role: .comment) == ["> quoted"])
        #expect(text(source, "markdown", role: .type) == ["[link](https://example.com)"])
        let strings = text(source, "markdown", role: .string)
        #expect(strings.contains("`inline`"))
    }

    @Test func unknownLanguagesAndPlainTextStayUncoloured() {
        #expect(SyntaxHighlighter.tokens("hello world", language: nil).isEmpty)
        #expect(SyntaxHighlighter.tokens("hello world", language: "brainfuck").isEmpty)
        #expect(SyntaxHighlighter.tokens("hello world", language: "text").isEmpty)
    }

    @Test func aFenceTagCarriesItsInfoStringAndCase() {
        #expect(SyntaxHighlighter.isKnown("Swift"))
        #expect(SyntaxHighlighter.isKnown("js title=\"x.js\""))
        #expect(SyntaxHighlighter.displayName(for: "py") == "python")
        #expect(SyntaxHighlighter.displayName(for: nil) == "code")
        #expect(SyntaxHighlighter.displayName(for: "brainfuck") == "brainfuck")
    }

    @Test func oversizedBlocksAreLeftAlone() {
        let huge = String(repeating: "let value = 1\n", count: 6_000)
        #expect(huge.utf16.count > SyntaxHighlighter.sourceLimit)
        #expect(SyntaxHighlighter.tokens(huge, language: "swift").isEmpty)
    }

    /// Every language in the table has to terminate on every input, including the inputs that are
    /// nothing like it — a transcript pastes a Swift error into a `json` fence often enough.
    @Test func everyLanguageTerminatesOnForeignInput() {
        let samples = [
            "", "\n\n", "```", "\"\"\"", "/*", "<<<<<<< HEAD", "0x", "@", "#", "$",
            "let a = \"unclosed", "{\"a\":", "- - -", "[[[", "'''", "--", "$>{",
            "\u{1F600}\u{1F600}", "a\tb\r\nc",
        ]
        for tag in SyntaxHighlighter.dialects.keys {
            for sample in samples {
                let tokens = SyntaxHighlighter.tokens(sample, language: tag)
                var cursor = 0
                for token in tokens {
                    #expect(token.offset >= cursor, "\(tag) overlapped on \(sample.debugDescription)")
                    cursor = token.offset + token.length
                }
                #expect(
                    cursor <= sample.utf16.count,
                    "\(tag) ran past the end of \(sample.debugDescription)")
            }
        }
    }

    /// The point of deriving from the palette rather than shipping a syntax theme: every theme and
    /// every face highlights code, and every role reads on the canvas it is drawn on.
    @Test func everyRoleReadsOnEveryPalettesCodeBackground() {
        for theme in AppTheme.all {
            for palette in [theme.dark.corrected(), theme.light.corrected()] {
                for role in SyntaxRole.allCases {
                    let hex = SyntaxPalette.hex(role, in: palette)
                    guard let ratio = Contrast.ratio(hex, on: palette.codeBg) else {
                        Issue.record("\(theme.id)/\(palette.name) \(role) is not a colour")
                        continue
                    }
                    let floor = role == .comment ? Contrast.secondary : Contrast.readable
                    #expect(
                        ratio >= floor - 0.05,
                        "\(theme.id)/\(palette.name) \(role) reads at \(ratio) on its code canvas")
                }
            }
        }
    }

    @Test func rolesDoNotCollapseIntoOneColour() {
        for theme in AppTheme.all {
            let palette = theme.dark.corrected()
            let table = SyntaxPalette.table(for: palette)
            let distinct = Set(
                [SyntaxRole.keyword, .type, .string, .number, .comment].compactMap { table[$0] })
            #expect(
                distinct.count >= 4,
                "\(theme.id) collapses its code roles into \(distinct.count) colours")
        }
    }
}
