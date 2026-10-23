import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The height a table hands the transcript has to be the height it will draw at, and a header
    /// with room to stand in may never fold.
    ///
    /// A card whose columns hug their content is measured by the box above it for the width of the
    /// whole pane and then allocated only its own natural width, so the two heights have to agree.
    /// The folding half is the one that shipped broken for a year: columns were sized in characters
    /// and handed to Pango as an *average*-character estimate, so a four-letter bold header in a
    /// four-character column hyphenated itself to `Ban-d` with half the window empty beside it.
    /// A header band measured against a real width may never be taller than the same band measured
    /// against no width at all — both are one line, and any difference is a fold.
    static func checkTable() throws -> Int {
        let table = MarkdownTable(
            header: ["Tab", "Mod", "Download"],
            alignments: [.leading, .leading, .leading],
            rows: [
                ["102", "Free Flight", "**Main-102-1-1** (v1.1, main)"],
                [
                    "16", "Retro Sound Pack",
                    "**Spyro Reignited Retro Sound Pack-0-1-1568225269** (main, 2nd)",
                ],
                [
                    "4", "Intro Movie Remover",
                    "**Intro Movie Remover** (skip Credits_Remover optional unless you want it)",
                ],
                ["233", "60fps Cutscenes", "**Reignited Interpolated 60fps Cutscenes** (2.1GB .rar)"],
            ])
        guard gtk_init_check() != 0 else { return 0 }
        let widget = TranscriptRow.table(table, key: "selftest")
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        defer { g_object_unref(UnsafeMutableRawPointer(widget)) }
        guard let scroller = gtk_widget_get_first_child(widget),
            let viewport = gtk_scrolled_window_get_child(op(scroller)),
            let grid = gtk_viewport_get_child(op(viewport))
        else { throw SelfTestFailure("a table is no longer a card in a viewport in a scroller") }
        guard gtk_viewport_get_scroll_to_focus(op(viewport)) == 0 else {
            throw SelfTestFailure(
                "a table's viewport scrolls to focus, so selecting a cell slides the table")
        }

        func measure(
            _ target: UnsafeMutablePointer<GtkWidget>, _ orientation: GtkOrientation, for size: Int32
        ) -> Int32 {
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(target, orientation, size, &minimum, &natural, nil, nil)
            return natural
        }

        let width = measure(grid, GTK_ORIENTATION_HORIZONTAL, for: -1)
        guard width > 0 else { throw SelfTestFailure("a table with cells asks for no width") }
        let drawn = measure(grid, GTK_ORIENTATION_VERTICAL, for: width)
        guard drawn > 0 else { throw SelfTestFailure("a table with rows asks for no height") }
        var checks = 0
        // Whatever the pane is, the row must ask for the whole table's height: it scrolls sideways
        // rather than folding, so a pane narrower than the table may never cost it a row.
        for pane in [Int32(120), width - 120, width, width + 200, width + 900] where pane > 0 {
            let asked = measure(widget, GTK_ORIENTATION_VERTICAL, for: pane)
            guard asked >= drawn else {
                throw SelfTestFailure(
                    "a table asks for \(asked) tall in a \(pane) pane but draws \(drawn) — the "
                        + "rows past that fall on the words below")
            }
            // And no more than it draws, bar the room an overlay scrollbar sits in: a row that
            // asks for height it does not use is a hole in the transcript under the table.
            guard asked <= drawn + 24 else {
                throw SelfTestFailure(
                    "a table asks for \(asked) tall in a \(pane) pane but draws only \(drawn) — "
                        + "the difference is blank page under the table")
            }
            checks += 1
        }
        // And it must never drag the pane out with it: a table wider than the window asks for the
        // window, and reaches the rest under the finger.
        let minimumWidth = { () -> Int32 in
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
            return minimum
        }()
        guard minimumWidth < width else {
            throw SelfTestFailure(
                "a table demands \(minimumWidth) of width, so a narrow pane is dragged out by it")
        }
        guard let head = gtk_widget_get_first_child(grid) else {
            throw SelfTestFailure("a table has no header band")
        }
        let unbound = measure(head, GTK_ORIENTATION_VERTICAL, for: -1)
        for pane in [width, width + 400, width + 1200] {
            _ = measure(widget, GTK_ORIENTATION_HORIZONTAL, for: pane)
            let folded = measure(head, GTK_ORIENTATION_VERTICAL, for: measure(
                grid, GTK_ORIENTATION_HORIZONTAL, for: -1))
            guard folded <= unbound else {
                throw SelfTestFailure(
                    "a table's header stands \(unbound) tall unbound but \(folded) in a "
                        + "\(pane) pane — the columns are being sized in characters again")
            }
            checks += 1
        }
        return checks + 2
    }

    /// A table realized in a real window, laid out by GTK and fitted to its pane by the deferred
    /// reflow, draws its last row inside its own card. Measuring an unrooted widget proves nothing
    /// about this: the clipping lives between the scroller asking its child for a height at one
    /// width and the child being handed another, which only a real allocation shows.
    static func checkTableFitsItsCard() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        // The app's own sheet, because a row's air and a header's tracking are CSS, and a table
        // measured without them is a table no one ever sees.
        MatrixTheme.install()
        let source = [
            "| Phase | Items | gpt-oss 120B (215 tok/s), medium | gpt-oss 120B, high | Qwen 27B (146 tok/s), medium | Qwen 27B, xhigh |",
            "|---|---|---|---|---|---|",
            "| Speed | 27 + long prompts | 12 min | 12 min | 15 min | 15 min |",
            "| Needle | 60 | 4 min | 5 min | 7 min | 9 min |",
            "| MMLU-Pro | 420 | 8 min | 14 min | 15 min | 27 min |",
            "| AIME 2025 | 120 | 15 min | 27 min | 30 min | 54 min |",
            "| Tool calls | 60 | 1 min | 1 min | 1 min | 2 min |",
            "| LiveCodeBench | 101 + grading | 40 min | 70 min | 75 min | 130 min |",
            "| **Total** | | **~1.3 h** | **~2.2 h** | **~2.4 h** | **~4 h** |",
        ]
        guard let table = MarkdownTable.scan(source, from: 0)?.table else {
            throw SelfTestFailure("the probe table does not parse")
        }
        var checks = 0
        for width in [Int32(1480), 1100, 820, 600] {
            let window = gtk_window_new()!
            gtk_window_set_default_size(ptr(UnsafeMutableRawPointer(window)), width, 900)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
            Gtk.addClass(canvas, "transcript")
            let row = TranscriptRow.table(table, key: "selftest-fit-\(width)")
            gtk_box_append(ptr(canvas), row)
            gtk_box_append(ptr(canvas), Gtk.label("after the table", css: "agent-text"))
            gtk_scrolled_window_set_child(op(scroller), canvas)
            gtk_window_set_child(ptr(UnsafeMutableRawPointer(window)), scroller)
            gtk_window_present(ptr(UnsafeMutableRawPointer(window)))
            let until = Date().addingTimeInterval(1.2)
            while Date() < until {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
            defer { gtk_window_destroy(ptr(UnsafeMutableRawPointer(window))) }
            guard let inner = gtk_widget_get_first_child(row),
                let viewport = gtk_scrolled_window_get_child(op(inner)),
                let card = gtk_viewport_get_child(op(viewport)),
                let last = gtk_widget_get_last_child(card)
            else { throw SelfTestFailure("the realized table lost its shape") }
            var bounds = graphene_rect_t()
            _ = gtk_widget_compute_bounds(last, card, &bounds)
            let bottom = Double(bounds.origin.y + bounds.size.height)
            let cardHeight = Double(gtk_widget_get_height(card))
            let rowHeight = Double(gtk_widget_get_height(row))
            var needed: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(
                card, GTK_ORIENTATION_VERTICAL, gtk_widget_get_width(card), &needed, &natural, nil,
                nil)
            // `get_height` is the card's content box and `measure` counts its margin and border,
            // which the row it sits in holds: the last band against the content, the whole card
            // against the row.
            guard bottom <= cardHeight + 0.5, Double(needed) <= rowHeight + 0.5 else {
                throw SelfTestFailure(
                    "a \(width)-wide window draws the table's last row to \(bottom) in a card "
                        + "\(cardHeight) tall (it needs \(needed)) — the bottom is cut off")
            }
            checks += 1
        }
        return checks
    }

    /// The regression this whole mechanism exists to prevent: a backend that stamps nothing on the
    /// record itself. The Claude bridge's transcript is a file that grows, so every `ChatMessage`
    /// read out of it has `isStreaming == false` whether the turn that wrote it is still open or
    /// not — only the conversation knows that. Asking the message alone therefore sealed every
    /// table from that backend on arrival, which switched the draft off silently and put every
    /// stutter this file exists to remove straight back in the window.
    static func checkTableSealingOnBridgeShape() throws -> Int {
        let table = MarkdownTable(
            header: ["Band", "BSSID", "Sig"],
            alignments: [.leading, .leading, .leading],
            rows: [["2.4", "`92:30:66:5E:BF:4D`", "94"]])
        let text = "Scanning.\n\n\(table.markdown)"
        let message = ChatMessage(
            id: "bridge-shape", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "a", kind: .text(text))], createdAt: Date())
        guard !message.isStreaming else {
            throw SelfTestFailure("the fixture no longer matches the bridge's own shape")
        }
        let builder = TranscriptRowBuilder()
        let open = builder.rows(for: [message], turnOpen: true)
        guard open.contains(where: {
            if case .tableDraft = $0.kind { return true }
            return false
        }) else {
            throw SelfTestFailure(
                "a Claude-bridge message with no isStreaming stamp was not drafted while its turn "
                    + "is open — the exact regression this file exists to catch")
        }
        guard !open.contains(where: {
            if case .table = $0.kind { return true }
            return false
        }) else {
            throw SelfTestFailure("the same table is drawn whole while its turn is still open")
        }

        let closed = builder.rows(for: [message], turnOpen: false)
        guard closed.contains(where: {
            if case .table = $0.kind { return true }
            return false
        }) else {
            throw SelfTestFailure("the same message never draws its table once the turn ends")
        }
        return 2
    }

        /// A table being written costs no measurement, and the table that replaces it arrives on light.

    ///
    /// Both halves are invisible in a screenshot — a draft card and a finished table are two
    /// different widgets, and a wash is a value that has already landed by the time anything is
    /// captured — so they are asserted instead: the draft is a card with no grid in it at all, the
    /// table that follows a draft starts below full opacity, and a table nobody watched arrive
    /// starts fully lit, because a settled fact does not animate.
    static func checkTableArrival() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let table = MarkdownTable(
            header: ["Band", "BSSID", "Sig"],
            alignments: [.leading, .leading, .leading],
            rows: [["2.4", "`92:30:66:5E:BF:4D`", "94"], ["5", "`96:30:66:5E:BF:4E`", "92"]])
        var checks = 0

        let draft = TableView.draft(TableDraft(table), key: "selftest-arrival")
        g_object_ref_sink(UnsafeMutableRawPointer(draft))
        defer { g_object_unref(UnsafeMutableRawPointer(draft)) }
        guard gtk_widget_get_first_child(draft) != nil else {
            throw SelfTestFailure("a table draft draws nothing at all")
        }
        var height: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(draft, GTK_ORIENTATION_VERTICAL, -1, &height, &natural, nil, nil)
        guard natural > 0 else { throw SelfTestFailure("a table draft asks for no height") }
        checks += 1

        // The draft that just stood there is what earns the wash, and it is earned exactly once.
        let washed = TableView.make(table, key: "selftest-arrival")
        g_object_ref_sink(UnsafeMutableRawPointer(washed))
        defer { g_object_unref(UnsafeMutableRawPointer(washed)) }
        guard let scroller = gtk_widget_get_first_child(washed),
            let viewport = gtk_scrolled_window_get_child(op(scroller)),
            let card = gtk_viewport_get_child(op(viewport)),
            let head = gtk_widget_get_first_child(card)
        else { throw SelfTestFailure("a washed table is not a card in a viewport in a scroller") }
        if RepeatingMotion.allowed {
            guard gtk_widget_get_opacity(head) < 1 else {
                throw SelfTestFailure(
                    "a table that replaced a draft arrives at full light — the wash never ran")
            }
            checks += 1
        }

        let settled = TableView.make(table, key: "selftest-arrival")
        g_object_ref_sink(UnsafeMutableRawPointer(settled))
        defer { g_object_unref(UnsafeMutableRawPointer(settled)) }
        guard let scroller = gtk_widget_get_first_child(settled),
            let viewport = gtk_scrolled_window_get_child(op(scroller)),
            let card = gtk_viewport_get_child(op(viewport)),
            let head = gtk_widget_get_first_child(card)
        else { throw SelfTestFailure("a settled table lost its shape") }
        guard gtk_widget_get_opacity(head) == 1 else {
            throw SelfTestFailure(
                "a table nobody watched arrive is being animated in — the ledger kept the key")
        }
        return checks + 1
    }

    /// Pango markup is a string, so a code block is one escape away from a parse error that empties
    /// the label: a `<` in a C++ template or an `&&` in a shell line has to arrive as text. Colour
    /// is checked in the same pass, because a block that escapes correctly and colours nothing is
    /// also a failure.
    static func checkSyntax() throws -> Int {
        var checks = 0
        let palette = MatrixTheme.palette
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("syntax case failed: \(label)") }
            checks += 1
        }
        func render(_ source: String, _ language: String?) -> String {
            PangoSyntax.render(source, language: language, palette: palette)
        }

        let keyword = SyntaxPalette.hex(.keyword, in: palette)
        let swift = render("let a = 1", "swift")
        try expect(swift.contains("<span foreground=\"\(keyword)\">let</span>"), "a keyword is a span")

        let templated = render("std::vector<int> v; a && b;", "cpp")
        try expect(templated.contains("&lt;"), "a template's opening angle is text")
        try expect(templated.contains("&gt;"), "a template's closing angle is text")
        try expect(templated.contains("&amp;&amp;"), "an ampersand pair is text")
        try expect(!templated.contains("<int>"), "no run of code becomes a tag")

        let shell = render("grep -r 'a<b' $SRC && cp ${DEST}/x .", "bash")
        try expect(shell.contains("&lt;"), "a shell comparison is text")
        try expect(
            shell.contains(SyntaxPalette.hex(.attribute, in: palette)), "a variable is marked")

        let unknown = render("<not code>", "brainfuck")
        try expect(unknown == "&lt;not code&gt;", "an unknown language is escaped and left plain")

        let comment = render("# just a note", "python")
        try expect(
            comment.contains(SyntaxPalette.hex(.comment, in: palette)), "a comment is quiet")

        guard let addedGround = SyntaxPalette.diffLineBackground(.added, in: palette),
            let removedGround = SyntaxPalette.diffLineBackground(.removed, in: palette)
        else { throw SelfTestFailure("syntax case failed: a diff line has no ground") }
        let diff = render("-old\n+new", "diff")
        try expect(diff.contains("background=\"\(addedGround)\""), "an addition wears its wash")
        try expect(diff.contains("background=\"\(removedGround)\""), "a removal wears its wash")
        try expect(
            diff.contains(SyntaxPalette.hex(.added, in: palette, on: addedGround)),
            "the marker is affirmed on its wash")

        let headed = render("+++ b/App.swift\n+let a = 1", "diff")
        try expect(
            headed.contains(SyntaxPalette.hex(.keyword, in: palette, on: addedGround)),
            "a headed diff lexes its body by the file's language")
        try expect(
            SyntaxHighlighter.displayName(for: "diff", source: "+++ b/App.swift\n+let a = 1")
                == "diff · swift",
            "a headed diff names both facts")

        let toolLine = PangoSyntax.diffLine(
            prefix: "+", body: "let a = 1", kind: .added, language: "swift", palette: palette)
        try expect(
            !toolLine.contains("background="),
            "a tool diff line leaves its wash to CSS, which paints the full row")
        try expect(
            toolLine.contains(SyntaxPalette.hex(.keyword, in: palette, on: addedGround)),
            "a tool diff line is lexed against its wash")
        try expect(parsesAsMarkup(headed), "a diff's markup is legal Pango")
        try expect(parsesAsMarkup(toolLine), "a tool diff line is legal Pango")
        let padded = render("-old\n+new is longer", "diff")
        try expect(
            padded.contains(String(repeating: " ", count: 10) + "</span>"),
            "washes are padded to one straight right edge")
        let hostile = render("+++ b/x.cpp\n+std::vector<int> v && w\n-a < b", "diff")
        try expect(parsesAsMarkup(hostile), "a hostile diff still escapes on its way in")

        try expect(SyntaxHighlighter.displayName(for: "rs") == "rust", "a fence tag is resolved")
        return checks
    }

    static func checkMarkup() throws -> Int {
        let cases: [(input: String, contains: [String], label: String)] = [
            ("**bold** here", ["<b>bold</b>"], "bold"),
            ("some *italic* text", ["<i>italic</i>"], "italic"),
            ("a `snippet` inline", ["<tt>snippet</tt>"], "inline code"),
            ("~~gone~~", ["<s>gone</s>"], "strikethrough"),
            ("## Heading", ["weight=\"700\"", "size=\"117%\"", "Heading"], "heading"),
            ("### Smaller", ["weight=\"600\"", "size=\"107%\"", "Smaller"], "third heading"),
            ("- first\n- second", ["•", "first", "second"], "bullets"),
            ("1. one", ["1.", "one"], "numbered"),
            ("> quoted", ["<i>quoted</i>"], "quote"),
            ("[docs](https://x.dev)", ["<a href=\"https://x.dev\">"], "link"),
            ("published at https://x.dev/p now", ["<a href=\"https://x.dev/p\">"], "bare link"),
            (
                "[docs](https://x.dev) and https://y.dev",
                ["<a href=\"https://x.dev\">", "<a href=\"https://y.dev\">"], "both link forms"
            ),
            ("a < b && c > d", ["&lt;", "&amp;&amp;", "&gt;"], "escaping"),
            ("`<div>`", ["&lt;div&gt;"], "escaped code"),
            ("2 * 3 * 4 = 24", ["24"], "bare asterisks survive"),
        ]
        for testCase in cases {
            let rendered = PangoMarkdown.render(
                testCase.input, dim: "#777777", code: "#67e8f9", accent: "#4ade80")
            for needle in testCase.contains where !rendered.contains(needle) {
                throw SelfTestFailure(
                    "\(testCase.label): \(rendered.debugDescription) lacks \(needle.debugDescription)")
            }
        }
        let literal: [(input: String, poison: String, label: String)] = [
            ("`gtk_box_append` per row", "<i>", "underscores inside code stay code"),
            ("2 * 3 * 4 = 24", "<i>", "arithmetic never italicizes"),
            ("snake_case and more_snake here", "<i>", "intra-word underscores stay literal"),
            ("`a * b` times `c * d`", "<i>", "asterisks inside code stay code"),
        ]
        for testCase in literal {
            let rendered = PangoMarkdown.render(
                testCase.input, dim: "#777777", code: "#67e8f9", accent: "#4ade80")
            if rendered.contains(testCase.poison) {
                throw SelfTestFailure("\(testCase.label): \(rendered.debugDescription)")
            }
        }
        return cases.count + literal.count
    }
}
