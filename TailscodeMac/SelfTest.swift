import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `TailscodeMac --selftest` drives the whole chain with no window: the markdown renderer, the
/// slash completion, the shared shortcut registry, the composer's vim mode and the local stores
/// first — pure logic a headless box checks perfectly well — then every configured server's
/// health, its session list, and the newest session's stream until a transcript lands.
///
/// A Mac reached over ssh has no window server, so a screenshot cannot prove the app works from a
/// build loop. This can.
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() async -> Never {
        startWatchdog()
        var failures = 0

        do {
            let checks = try checkMarkup()
            report("markup: \(checks) shapes render")
        } catch {
            report("markup: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCode()
            report("code: \(checks) claims hold — roles colour, lines never fold")
        } catch {
            report("code: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCascade()
            report("cascade: \(checks) prefixes reveal cleanly")
        } catch {
            report("cascade: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTheme()
            report("theme: \(checks) palettes reach AppKit and keep their meanings")
        } catch {
            report("theme: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCompletion()
            report("completion: \(checks) queries rank and gate")
        } catch {
            report("completion: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTranscriptRows()
            report("transcript rows: \(checks) claims hold — a step keeps its own key")
        } catch {
            report("transcript rows: \(error)")
            failures += 1
        }

        let runFailures = WorkflowRunCheck.run()
        if runFailures.isEmpty {
            report("workflow run: every ending settles the run, stops its clock and holds still")
        } else {
            report("workflow run: \(runFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkWorkflowCard()
            report("workflow card: \(checks) claims hold — the mark is the run's, at one tempo")
        } catch {
            report("workflow card: \(error)")
            failures += 1
        }

        let cutOffFailures = InterruptedTurnCheck.run()
        if cutOffFailures.isEmpty {
            report("cut-off turn: the words, the cost, the press and the refusal all hold")
        } else {
            report("cut-off turn: \(cutOffFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkInterruptedCard()
            report("cut-off card: \(checks) claims hold — nothing on it is this client's wording")
        } catch {
            report("cut-off card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShortcuts()
            report("shortcuts: \(checks) keys resolve, rebind and stay conflict-free")
        } catch {
            report("shortcuts: \(error)")
            failures += 1
        }

        #if !TAILSCODE_MAS
            do {
                let checks = try checkVideoSlot()
                report(
                    "video slot: \(checks) answers, resolver \(VideoResolver.tool() ?? "missing")")
            } catch {
                report("video slot: \(error)")
                failures += 1
            }

            do {
                let checks = try checkWatchBoard()
                report("watch board: \(checks) rows, badges and pictures draw")
            } catch {
                report("watch board: \(error)")
                failures += 1
            }

            do {
                let checks = try checkWatchAccounts()
                report("watch accounts: \(checks) rows and sign-in steps render")
            } catch {
                report("watch accounts: \(error)")
                failures += 1
            }
        #endif

        let forgeFailures = ForgeBoardCheck.run()
        if forgeFailures.isEmpty {
            report("video forge: the graph, the frames, the job's walk and the board all hold")
        } else {
            report("video forge: \(forgeFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkForgeSurface()
            report("forge surface: \(checks) claims hold across \(ForgeDemo.states.count) states")
        } catch {
            report("forge surface: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrowserSlot()
            report("browser slot: \(checks) answers, engine WKWebView")
        } catch {
            report("browser slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkGit()
            report("git: \(checks) claims hold — the tree reads, the patch colours")
        } catch {
            report("git: \(error)")
            failures += 1
        }

        do {
            let checks = try checkUpdates()
            report("updates: \(checks) claims hold — nothing unchecked reads as current")
        } catch {
            report("updates: \(error)")
            failures += 1
        }

        do {
            let checks = try checkParity()
            report("parity: \(checks) capabilities answered")
        } catch {
            report("parity: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVim()
            report("vim: \(checks) commands behave")
        } catch {
            report("vim: \(error)")
            failures += 1
        }

        let chooserFailures = PaneChooserCheck.run()
        if chooserFailures.isEmpty {
            report("pane chooser: servers, chats and keys behave")
        } else {
            report("pane chooser: \(chooserFailures.joined(separator: " · "))")
            failures += 1
        }

        let newChatFailures = NewChatChooserCheck.run()
        if newChatFailures.isEmpty {
            report("new chat: folders rank, modes swap, keys behave")
        } else {
            report("new chat: \(newChatFailures.joined(separator: " · "))")
            failures += 1
        }

        let selectionFailures = ChatSelectionCheck.run()
        if selectionFailures.isEmpty {
            report("chat selection: two servers stay two chats, copy counts once")
        } else {
            report("chat selection: \(selectionFailures.joined(separator: " · "))")
            failures += 1
        }

        let modelFailures = ModelChooserCheck.run()
        if modelFailures.isEmpty {
            report("model chooser: providers fold, ranking holds, keys behave")
        } else {
            report("model chooser: \(modelFailures.joined(separator: " · "))")
            failures += 1
        }

        #if !TAILSCODE_MAS
            let watchFailures = WatchChooserCheck.run()
            if watchFailures.isEmpty {
                report("watch directory: sections compact, keys stay off the letters")
            } else {
                report("watch directory: \(watchFailures.joined(separator: " · "))")
                failures += 1
            }

            let accountFailures = WatchAccountsCheck.run()
            if accountFailures.isEmpty {
                report("watch accounts: each site states itself, the device flow keeps its shape")
            } else {
                report("watch accounts: \(accountFailures.joined(separator: " · "))")
                failures += 1
            }
        #endif

        do {
            let checks = try checkPaneHitTest()
            report("pane hit test: \(checks) presses land where they look")
        } catch {
            report("pane hit test: \(error)")
            failures += 1
        }

        do {
            try checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        do {
            try checkImageStore()
            report("image store: pictures round-trip and stay keyed to their file")
        } catch {
            report("image store: \(error)")
            failures += 1
        }

        #if !TAILSCODE_MAS
            let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
            if shellOutput.contains("tailscode-shell-ok") {
                report("shell: ok (one command at a time in a login shell)")
            } else {
                report("shell: no output")
                failures += 1
            }
        #endif

        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report(
                    "\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = sessions.first else { continue }
                let state = try await firstState(of: newest, on: backend)
                report(
                    "  \(newest.title): \(state.messages.count) messages · \(state.connection)")
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }
        do {
            let count = try await checkTwoObservers(profiles)
            report("two observers: agree on \(count) messages")
        } catch {
            report("two observers: \(error)")
            failures += 1
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// The transcript's markdown, checked as attributes rather than as pixels: emphasis must
    /// carry its trait, code its monospace, a link its URL — and arithmetic, snake_case and
    /// asterisks inside code spans must survive untouched, which is the failure a renderer grows
    /// quietly.
    private static func checkMarkup() throws -> Int {
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
    private static func checkCode() throws -> Int {
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
        let scroll = RowKit.codeScroll(around: wide, cap: nil)
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

    private static func checkPaneHitTest() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("hit test case failed: \(label)") }
            checks += 1
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        func pane(_ frame: NSRect) -> NSViewController {
            let controller = NSViewController()
            controller.view = NSView(frame: frame)
            window.contentView?.addSubview(controller.view)
            return controller
        }
        let left = pane(NSRect(x: 0, y: 0, width: 195, height: 200))
        let right = pane(NSRect(x: 205, y: 0, width: 195, height: 200))
        let hidden = pane(NSRect(x: 0, y: 0, width: 400, height: 200))
        hidden.view.isHidden = true
        let detached = NSViewController()
        detached.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let panes = [left, right, hidden, detached]

        func hit(_ x: Double, _ y: Double) -> NSViewController? {
            SplitPaneHost.hitTest(panes, at: NSPoint(x: x, y: y))
        }
        try expect(hit(40, 100) === left, "a press in the left pane is the left pane's")
        try expect(hit(300, 100) === right, "a press in the right pane is the right pane's")
        try expect(hit(200, 100) == nil, "a press on the divider belongs to no pane")
        try expect(hit(194.5, 100) === left, "the pane owns its own last column")
        try expect(hit(-5, 100) == nil, "a press outside the tree belongs to no pane")
        try expect(hit(40, 260) == nil, "a press above the tree belongs to no pane")
        try expect(
            hit(40, 100) !== hidden, "a pane the zoom has hidden never takes the press")
        try expect(
            SplitPaneHost.hitTest([detached], at: NSPoint(x: 40, y: 100)) == nil,
            "a pane in no window takes nothing")
        return checks
    }

    /// The catalog is proved as arithmetic in Core; what this checks is the half Core cannot see —
    /// that a saved id reaches an `NSColor` on this toolkit, that both faces of a theme come back
    /// different, that the accent the cascade leads with is the accent the tokens hand out, and
    /// that no two meanings collapsed into one colour on the way across.
    private static func checkTheme() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        try expect(
            ThemePalette.palette(themeID: ThemeSelection.systemID, dark: true) == nil,
            "the system choice resolved to a palette")
        for theme in AppTheme.all {
            let night = ThemePalette.palette(themeID: theme.id, dark: true)
            let day = ThemePalette.palette(themeID: theme.id, dark: false)
            try expect(night?.name == theme.dark.name, "\(theme.id) does not reach its night")
            try expect(day?.name == theme.light.name, "\(theme.id) does not reach its day")
            try expect(
                NSColor(hex: theme.dark.corrected().accent) != nil,
                "\(theme.id) has an accent AppKit cannot make")
            checks += 1
        }
        for face in [NSAppearance(named: .darkAqua), NSAppearance(named: .aqua)] {
            guard let face else { throw SelfTestFailure("AppKit has no such appearance") }
            var resolved: [String: String] = [:]
            face.performAsCurrentDrawingAppearance {
                resolved = [
                    "accent": CascadeTint.hex(MacTheme.Color.accent),
                    "warning": CascadeTint.hex(MacTheme.Color.warning),
                    "danger": CascadeTint.hex(MacTheme.Color.danger),
                    "info": CascadeTint.hex(MacTheme.Color.info),
                    "mark": CascadeTint.hex(MacTheme.Color.mark),
                ]
            }
            try expect(
                Set(resolved.values).count == resolved.count,
                "two meanings wear one colour under \(face.name.rawValue)")
            checks += 1
        }
        try expect(
            CascadeTint.hex(CascadeTint.edge(ultracode: false, phase: 0.5))
                == CascadeTint.hex(MacTheme.Color.accent),
            "the wave leads with an accent the tokens do not know")
        checks += 1
        return checks
    }

    /// The paced reveal, checked where it can actually go wrong on this toolkit: every prefix the
    /// renderer is allowed to see must produce text that has already eaten its own punctuation —
    /// an answer that flashes its asterisks as each `**bold**` closes is the artefact that makes a
    /// smooth reveal look broken — the reservation must never reach past what has been rendered,
    /// and the wave must land every glyph back on the colour it would have had without it.
    private static func checkCascade() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let source = """
            Here is **bold** text, some *italic*, a `snippet`, a [link](https://x.dev), \
            and ~~struck~~ words.

            - first bullet with `code`
            - second bullet with **weight**

            ## A heading arrives
            """
        let characters = Array(source)
        var checks = 0
        for cut in 0...characters.count {
            let safe = LiveCascade.renderable(String(characters[..<cut]), sealed: false)
            let rendered = MacMarkdown.render(safe, cache: false).string
            for marker in ["**", "~~", "`"] {
                try expect(
                    !rendered.contains(marker),
                    "prefix \(cut) leaked \(marker): \(rendered.debugDescription)")
            }
            checks += 1
        }

        let full = MacMarkdown.render(source, cache: false)
        var live = LiveCascade()
        live.focus("row", rendered: full.string, sealed: false, at: 0)
        try expect(live.revealed == 0, "a row born under our eyes starts empty")
        var time = 0.0
        var last = 0
        while time < 30, !live.isSettled {
            time += 1.0 / 120
            live.focus("row", rendered: full.string, sealed: false, at: time)
            live.advance(to: time)
            try expect(live.revealed >= last, "the reveal went backwards")
            try expect(live.revealed <= full.length, "the reveal ran past what had arrived")
            last = live.revealed
        }
        try expect(live.revealed == full.length, "the reveal never landed on its source")
        checks += 3

        let edge = CascadeTint.edge(ultracode: false, phase: 0.5)
        try expect(
            CascadeTint.hex(edge) == CascadeTint.hex(MacTheme.Color.accent),
            "a plain turn leads with the app's own accent")
        let shown = full.length / 2
        let tail = CascadeTail(
            revealed: shown, span: StreamCascade.span, phase: 0.3, edge: edge,
            spark: CascadeTint.spark(for: edge))
        let painted = tail.paint(full, settled: MacTheme.Color.label)
        try expect(
            painted.length == full.length,
            "the paint changed the layout instead of only the ink")
        try expect(painted.string == full.string, "the paint changed the words, not just the ink")
        let unshown =
            painted.attribute(.foregroundColor, at: shown + 1, effectiveRange: nil) as? NSColor
        try expect(
            (unshown?.alphaComponent ?? 1) == 0,
            "text the reveal has not reached was drawn instead of held")
        let far = shown - StreamCascade.span * 2
        try expect(far > 0, "the sample text is too short to have a settled half")
        try expect(
            (painted.attribute(.foregroundColor, at: far, effectiveRange: nil) as? NSColor)
                == (full.attribute(.foregroundColor, at: far, effectiveRange: nil) as? NSColor),
            "a glyph the wave has passed kept its own colour")
        let atEdge =
            painted.attribute(.foregroundColor, at: shown - 1, effectiveRange: nil) as? NSColor
        try expect(atEdge != nil, "the leading glyph carries the wave")
        try expect(
            (atEdge?.alphaComponent ?? 1) < 1, "the leading glyph fades in rather than popping")
        try expect(
            (atEdge?.alphaComponent ?? 0) >= StreamCascade.entryFloor,
            "the leading glyph appears from a whisper, not from nothing")
        checks += 7
        return checks
    }

    private static func checkCompletion() throws -> Int {
        let commands = ["steam-add-game", "usage", "update-zeroclaw", "flyr", "compact"].map {
            AgentCommand(name: $0, details: "", source: .skill)
        }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("completion case failed: \(label)") }
            checks += 1
        }
        try expect(SlashCompletion.query(in: "/st") == "st", "query reads the word")
        try expect(SlashCompletion.query(in: "/") == "", "bare slash asks for everything")
        try expect(SlashCompletion.query(in: "/goal clear") == nil, "arguments end the query")
        try expect(SlashCompletion.query(in: "plain text") == nil, "prose is not a query")
        try expect(
            SlashCompletion.matches(commands, query: "u").map(\.name) == [
                "update-zeroclaw", "usage",
            ], "prefix matches sort alphabetically")
        try expect(
            SlashCompletion.matches(commands, query: "add").map(\.name) == ["steam-add-game"],
            "a match inside the name still surfaces")
        try expect(
            SlashCompletion.matches(commands, query: "").first?.name == "compact",
            "everything, alphabetically, for a bare slash")
        try expect(
            SlashCompletion.matches(commands, query: "zzz").isEmpty, "no match means no list")

        let offered = CommandCatalogStore.forQuickAsk(commands)
        try expect(
            !offered.contains { $0.name == "compact" || $0.name == "usage" },
            "a quick ask is never offered the commands that read a transcript it has yet to write")
        guard
            case .command(let picked, let arguments) = QuickAskSend.decide(
                text: "/flyr HEL", commands: offered, resolvesFromPromptText: false
            ).kind
        else { throw SelfTestFailure("completion case failed: a typed command runs as a command") }
        try expect(
            picked.name == "flyr" && arguments == "HEL",
            "a typed command runs as a command, arguments and all")
        try expect(
            QuickAskSend.decide(
                text: "/compact keep the plan", commands: commands, resolvesFromPromptText: false
            ).kind == .prompt, "compaction is never what a quick ask means")
        try expect(
            QuickAskSend.decide(
                text: "/flyr HEL", commands: offered, resolvesFromPromptText: true
            ).kind == .prompt, "an agent that resolves its own grammar gets the prompt untouched")
        try expect(
            SlashPresentation.noMatchWording("commit", hasProject: false)
                != SlashPresentation.noMatchWording("commit", hasProject: true),
            "a word missing for want of a project says which reason it is")
        return checks
    }

    /// What the reader opened stays open while the turn that drew it keeps arriving. A step's place
    /// inside a run is not its identity — a lone call becomes the second step of a run the moment
    /// another joins it — so the key it was drawn under has to survive the fold that reshapes it.
    private static func checkTranscriptRows() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("transcript row case failed: \(label)") }
            checks += 1
        }
        func call(_ id: String) -> ToolCall {
            ToolCall(id: id, name: "Read", status: .completed)
        }

        let lone = TranscriptRow.fuse([TranscriptRow(key: "m1:p1", kind: .tool(call("t1")))])
        try expect(
            lone.map(\.key) == ["run:m1:p1"], "a lone call already wears the key its run will")
        let fanned = TranscriptRow.fuse([
            TranscriptRow(key: "m1:p1", kind: .tool(call("t1"))),
            TranscriptRow(key: "m1:p2", kind: .tool(call("t2"))),
        ])
        try expect(
            fanned.map(\.key) == ["run:m1:p1"],
            "a second step joins that row instead of renaming it")
        guard case .run(let steps) = fanned.first?.kind else {
            throw SelfTestFailure("transcript row case failed: two calls fold into one run")
        }
        try expect(
            steps.map(\.key) == ["m1:p1", "m1:p2"], "and every step keeps the key its row had")
        try expect(
            TranscriptRow.fuse([
                TranscriptRow(key: "m1:p1", kind: .reasoning("first")),
                TranscriptRow(key: "m1:p2", kind: .reasoning("second")),
            ]).map(\.key) == ["m1:p1", "m1:p2"],
            "a run that never reached a tool stays its own thoughts, each still itself")

        let context = TranscriptContext()
        context.expanded.set("run:m1:p1", open: true)
        try expect(
            context.isExpanded("run:m1:p1"),
            "so the row opened while it was a lone call is still open once it is a run")
        context.expanded.set("run:m1:p1", open: false)
        try expect(!context.isExpanded("run:m1:p1"), "and closing it closes it")
        return checks
    }

    /// The workflow card's own mark, which is the whole of what a reader saw go wrong: a ring still
    /// turning over a run that ended long ago. Proved without a window, because what a mark is doing
    /// is a state it wears rather than an animation to watch — and a screenshot could never tell a
    /// settled ring from a sweep caught mid-frame anyway.
    private static func checkWorkflowCard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("workflow card case failed: \(label)") }
            checks += 1
        }
        let call = ToolCall(
            id: "call-1", name: "Workflow", status: .completed,
            output: "Workflow launched in background. Task ID: task-1")
        let context = TranscriptContext()
        func mark(of state: WorkflowRun.State?) throws -> ActivityMarkLabel {
            context.workflowRuns = state.map {
                [call.id: WorkflowRun(id: call.id, name: "kaytetty-best", state: $0)]
            } ?? [:]
            let view = WorkflowCardView.make(call, key: "wf", context: context)
            guard let label = markLabel(in: view) else {
                throw SelfTestFailure("workflow card case failed: the header wears a live mark")
            }
            return label
        }

        try expect(try mark(of: .running).icon?.motion == .turning, "a live run turns")
        try expect(try mark(of: .launching).icon == .openWork, "and so does one still launching")
        for ending in [WorkflowRun.State.finished, .stopped("stopped"), .failed("broke")] {
            try expect(
                try mark(of: ending).icon?.motion == .still, "an ending holds perfectly still")
        }
        try expect(
            try mark(of: .finished).stringValue == ActivityIcon.finished.glyph,
            "and shows the ending's own glyph rather than the frame the sweep died on")
        try expect(
            try mark(of: .stopped("stopped")).icon?.tone == .quiet,
            "a run that was stopped is not blamed for a fault")
        try expect(try mark(of: nil).icon == .idle, "a call whose run has not landed has not started")

        context.workflowRuns = [call.id: WorkflowRun(id: call.id, name: "n", state: .running)]
        let card = WorkflowCardView.make(call, key: "wf", context: context)
        context.workflowRuns = [call.id: WorkflowRun(id: call.id, name: "n", state: .finished)]
        try expect(
            WorkflowCardView.restate(card, call: call, context: context),
            "the once-a-second tick restates the card in place")
        try expect(
            markLabel(in: card)?.icon == .finished,
            "and the ending reaches the mark without a rebuild")

        try expect(
            CADisplayLink.activityTempo.preferred == Float(ActivityTuning.frameRate)
                && CADisplayLink.activityTempo.minimum == Float(ActivityTuning.minimumFrameRate),
            "every clock this client drives by hand asks for the vocabulary's tempo")
        return checks
    }

    private static func markLabel(in view: NSView) -> ActivityMarkLabel? {
        if let label = view as? ActivityMarkLabel { return label }
        guard let row = view as? DisclosureRow, let header = row.headerView else { return nil }
        return header.subviews.compactMap { $0 as? ActivityMarkLabel }.first
    }

    /// The card a cut-off turn draws, built as the transcript builds it, in every state it has.
    ///
    /// What is proved here is that the Mac renders Core's answers rather than its own: the sentence
    /// about what never ran, the one about what leaving the card undecided costs, and the two button
    /// titles all have to be the strings Core hands over, character for character. The press states
    /// are proved on the view because that is where the defect was — a press that changed nothing on
    /// screen — and a resumed card is proved to offer nothing, because both of its actions would lie.
    private static func checkInterruptedCard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("cut-off card: \(label)") }
            checks += 1
        }
        let context = TranscriptContext()
        context.resumeInterrupted = {}
        context.dismissInterrupted = {}
        func view(_ turn: InterruptedTurn) -> NSView {
            TranscriptRow(key: "interrupted", kind: .interruptedTurn(turn))
                .makeView(context: context)
        }
        func says(_ turn: InterruptedTurn, _ text: String) -> Bool {
            words(in: view(turn)).contains { $0.contains(text) }
        }

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let cutOff = TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started,
            detectedAt: started.addingTimeInterval(200),
            progress: TurnInterruption.Progress(toolCount: 3, lastTool: "Edit"),
            queued: ["and then the mac"])
        guard let waiting = InterruptedTurnReading.read(cutOff) else {
            throw SelfTestFailure("cut-off card: an interrupted turn reads as a card")
        }

        guard let queuedLine = waiting.queuedLine, let cost = waiting.cost else {
            throw SelfTestFailure(
                "cut-off card: an undecided card has both a queued line and a cost to state")
        }
        try expect(says(waiting, waiting.prompt), "the card carries what was asked")
        try expect(
            says(waiting, queuedLine),
            "what never ran is said in Core's sentence, not one retyped here")
        try expect(
            says(waiting, cost),
            "and the card says the session will not carry itself on while it stands")
        let offered = buttons(in: view(waiting))
        try expect(
            offered.map(\.title) == [waiting.resumeTitle, waiting.dismissTitle],
            "an undecided card offers exactly the two actions, in Core's words")
        try expect(offered.allSatisfy(\.isEnabled), "both of which can be pressed")

        let pickingUp = InterruptedTurnReading.pressed(waiting, .pickUp)
        let pressed = buttons(in: view(pickingUp))
        try expect(
            pressed.first?.title == InterruptedTurn.pickingUpTitle,
            "a press renames its own button the instant it lands")
        try expect(
            pressed.allSatisfy { !$0.isEnabled }, "and the card stops taking a second press")
        try expect(
            pickingUp.cost == nil && !says(pickingUp, cost),
            "a decided card stops charging for standing")
        try expect(
            buttons(in: view(InterruptedTurnReading.pressed(waiting, .letGo))).last?.title
                == InterruptedTurn.lettingGoTitle,
            "letting go acknowledges itself the same way")

        let resumed = InterruptedTurnReading.read(
            TurnInterruption(
                turnID: "t1", prompt: "port the toggles", startedAt: started,
                detectedAt: started.addingTimeInterval(200), resumedAt: Date()))
        guard let resumed else {
            throw SelfTestFailure("cut-off card: a resumed turn still draws its card")
        }
        try expect(
            buttons(in: view(resumed)).isEmpty,
            "a turn the server picked back up offers nothing, because both actions would lie")
        try expect(says(resumed, resumed.detail), "and says instead that the work is going again")
        return checks
    }

    /// Every word actually on a built row, so a claim about what a card says is checked against the
    /// pixels rather than against the value that was passed in.
    private static func words(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for child in view.subviews { found += words(in: child) }
        return found
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for child in view.subviews { found += buttons(in: child) }
        return found
    }

    /// The whole keyboard system without a window: the shipped table resolves, canonicalisation
    /// folds keypad and shifted keys, sequences pend and land, the terminal keeps the shell's
    /// chords, approvals win only while one waits, and the rebinding file's grammar applies,
    /// unbinds and reports nonsense — the same cases the Linux desktop asserts, because the
    /// registry is the same table.
    private static func checkShortcuts() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shortcut case failed: \(label)") }
            checks += 1
        }
        func chord(
            _ character: Character, control: Bool = false, shift: Bool = false
        ) -> KeyChord? {
            var state: UInt32 = 0
            if control { state |= KeyChord.controlMask }
            if shift { state |= KeyChord.shiftMask }
            guard let scalar = character.unicodeScalars.first else { return nil }
            return KeyChord.canonical(keyval: UInt32(scalar.value), state: state)
        }
        func action(
            _ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext,
            pending: [KeyChord] = [], awaiting: Bool = false
        ) -> KeyAction? {
            guard let chord else { return nil }
            let outcome = set.resolve(
                chord, context: context, pending: pending, awaitingApproval: awaiting)
            if case .run(let found) = outcome { return found }
            return nil
        }
        func pends(_ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext) -> Bool {
            guard let chord else { return false }
            let outcome = set.resolve(
                chord, context: context, pending: [], awaitingApproval: false)
            if case .pending = outcome { return true }
            return false
        }

        let set = ShortcutSet.build(overrides: [:])
        try expect(set.issues.isEmpty, "shipped defaults carry no conflicts: \(set.issues)")

        let parsed = KeySpec.parse("ctrl+shift+h")
        try expect(
            parsed?.chords == [chord("h", control: true, shift: true)].compactMap { $0 },
            "ctrl+shift+h parses to one canonical chord")
        try expect(
            KeySpec.parse("normal,insert:ctrl+b")?.contexts == [.normal, .insert],
            "a context prefix limits a spec")
        try expect(
            KeySpec.parse("J")?.chords.first == chord("j", shift: true),
            "an uppercase letter folds to shift plus lowercase")
        try expect(KeySpec.parse("g g")?.chords.count == 2, "a sequence is two chords")
        try expect(KeySpec.parse("bogus+key") == nil, "nonsense refuses to parse")

        try expect(action(set, chord("j"), .normal) == .scrollDown, "j scrolls")
        try expect(action(set, chord("J", shift: true), .normal) == .selectNext, "J selects")
        try expect(action(set, chord("e"), .normal) == .archiveSelected, "e archives")
        try expect(
            action(set, chord("p"), .normal) == .toggleProjectScope, "p scopes to the project")
        try expect(
            action(set, chord("a", shift: true), .normal) == nil,
            "A is spent on a shortcut the machine-wide chord already covers, and the composer's "
                + "vim wants it")
        try expect(action(set, chord("x"), .normal) == .deleteSelected, "x deletes")
        try expect(action(set, chord(" "), .normal) == .toggleMarked, "space marks a chat")
        try expect(
            action(set, chord("a", control: true), .normal) == .toggleMarkAll,
            "ctrl+a marks every chat shown")
        try expect(
            action(set, KeyChord.canonical(keyval: Keymap.enter, state: 0), .normal)
                == .openSelected, "enter opens")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.keypadEnter, state: Keymap.control),
                .insert) == .send, "keypad enter folds into enter for ^⏎")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.shiftTab, state: Keymap.shift), .normal)
                == .cycleBackward, "shift+tab cycles backwards")

        try expect(pends(set, chord("g"), .normal), "g waits for a second key")
        let g = chord("g")
        try expect(
            action(set, g, .normal, pending: [g].compactMap { $0 }) == .scrollTop,
            "g g reaches the top")
        try expect(pends(set, chord("y"), .normal), "y waits for a second key")
        let y = chord("y")
        try expect(
            action(set, y, .normal, pending: [y].compactMap { $0 }) == .copySessionID,
            "y y copies the session id")
        try expect(
            action(set, chord("p"), .normal, pending: [y].compactMap { $0 })
                == .copyProjectPath, "y p copies the project path")

        try expect(action(set, chord("f"), .normal) == .findInConversation, "f finds")
        try expect(action(set, chord("f"), .insert) == nil, "bare f types in insert")
        try expect(
            action(set, chord("f", control: true), .insert) == .findInConversation,
            "^f finds while typing")
        try expect(
            action(set, chord("b", control: true), .terminal) == nil,
            "the terminal keeps ^b for the shell")
        try expect(
            action(set, chord("f", control: true), .terminal) == nil,
            "the terminal keeps ^f for the shell")
        try expect(
            action(set, chord("b", control: true, shift: true), .terminal) == .toggleSidebar,
            "^⇧B still toggles the chat list over a shell")
        try expect(
            action(set, KeyChord.canonical(keyval: 0xFFAD, state: Keymap.control), .terminal)
                == .zoomOut, "keypad minus folds into ^- zoom")

        try expect(
            action(set, chord("y"), .normal, awaiting: true) == .allowOnce,
            "y answers a waiting approval")
        try expect(
            action(set, chord("n"), .normal, awaiting: true) == .deny,
            "n denies a waiting approval")
        try expect(
            action(set, chord("n"), .normal) == .newChat,
            "n means a new chat once nothing waits")

        let rebound = ShortcutSet.build(overrides: ["chat.new": ["c"]])
        try expect(action(rebound, chord("c"), .normal) == .newChat, "a rebind lands")
        try expect(action(rebound, chord("n"), .normal) == nil, "a rebind frees the old key")
        let unbound = ShortcutSet.build(overrides: ["chat.new": []])
        try expect(
            action(unbound, chord("n"), .normal) == nil && unbound.issues.isEmpty,
            "an empty rebind unbinds cleanly")
        try expect(
            !ShortcutSet.build(overrides: ["chat.new": ["bogus+key"]]).issues.isEmpty,
            "an unreadable rebind is reported")
        try expect(
            !ShortcutSet.build(overrides: ["chat.filter": ["g"]]).issues.isEmpty,
            "shadowing a sequence's first key is reported")
        try expect(
            ShortcutSet.build(overrides: [:]).helpSections().contains {
                $0.rows.contains { $0.keys.contains("^⏎") }
            }, "the cheatsheet lists effective keys")
        return checks
    }

    #if !TAILSCODE_MAS
        /// A slot is a pane, so what it holds has to read back the same after a restart, and the keys
        /// it answers have to be the keys the other desktop answers.
        private static func checkVideoSlot() throws -> Int {
            var checks = 0
            func expect(_ condition: Bool, _ label: String) throws {
                guard condition else { throw SelfTestFailure("video slot: \(label)") }
                checks += 1
            }

            try expect(VideoTarget.classify("kamet0") == .twitch("kamet0"), "a bare word is a channel")
            try expect(
                VideoTarget.classify("https://www.twitch.tv/kamet0") == .twitch("kamet0"),
                "a channel link is that channel")
            try expect(
                VideoTarget.classify("@LofiGirl") == .youtube("@LofiGirl"), "a handle is a channel")
            try expect(
                VideoTarget.classify("lofi hip hop") == .search("lofi hip hop"), "words are a search")
            try expect(VideoTarget.classify("  ") == nil, "nothing typed points nowhere")
            for target: VideoTarget in [
                .twitch("kamet0"), .youtube("@LofiGirl"), .search("two words"), .link("/tmp/a.mp4"),
            ] {
                try expect(
                    VideoTarget.classify(target.address) == target, "\(target.address) round-trips")
            }
            try expect(
                VideoTarget.search("two words").extractionArgument == "ytsearch1:two words",
                "a search is extracted as a search")

            var slot = VideoSlot()
            try expect(slot.isAsking, "an empty slot asks")
            slot.point(at: .twitch("kamet0"))
            try expect(slot.phase == .loading && slot.title == "kamet0", "a pointed slot opens")
            slot.loaded(title: "Kamet0 · LEC")
            try expect(slot.phase == .playing && slot.title == "Kamet0 · LEC", "the stream names it")
            try expect(
                slot.subtitle.hasSuffix(VideoNotice.splitCostTag),
                "a playing slot says what it costs the grid")
            slot.paused = true
            try expect(
                !slot.subtitle.contains(VideoNotice.splitCostTag),
                "a paused slot costs nothing and stops saying so")
            slot.paused = false
            try expect(!slot.notice.isEmpty, "an empty slot has the whole of it to read")
            slot.ask()
            try expect(
                slot.isAsking && slot.draft == "kamet0",
                "changing it offers the channel back, not the stream's own title")

            var layout = SplitLayout()
            let first = layout.focusedPane
            guard let second = layout.split(first, axis: .horizontal) else {
                throw SelfTestFailure("video slot: the layout would not split")
            }
            let snapshot = SplitSnapshot(
                layout: layout, sessions: [:],
                videos: [second.raw: VideoTarget.twitch("kamet0").address])
            guard let encoded = snapshot.encoded, let restored = SplitSnapshot.decode(encoded) else {
                throw SelfTestFailure("video slot: the layout would not persist")
            }
            try expect(restored.video(for: second) == .twitch("kamet0"), "a restart reopens the slot")
            try expect(restored.video(for: first) == nil, "a chat pane restores as a chat")

            guard let space = KeyChord.canonical(keyval: 0x20, state: 0),
                let controlM = KeyChord.canonical(keyval: 0x6D, state: KeyChord.controlMask)
            else { throw SelfTestFailure("video slot: a keystroke would not resolve") }
            try expect(VideoCommand.command(for: space) == .playPause, "space pauses")
            try expect(VideoCommand.command(for: controlM) == nil, "a control chord stays the app's")
            return checks
        }

        /// The board an empty video slot draws, checked as the facts a row is rendered from: the badge
        /// it wears, the picture it offers, the star it earns, and the two rows — an expander and a
        /// note — that carry no picture at all. The keys matter as much as the rows here, because the
        /// same keystrokes are typing into the box above the board: a letter must never be the board's.
        private static func checkWatchBoard() throws -> Int {
            var checks = 0
            func expect(_ condition: Bool, _ label: String) throws {
                guard condition else { throw SelfTestFailure("watch board: \(label)") }
                checks += 1
            }

            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let now = start.addingTimeInterval(3600)
            let caedrel = MediaChannel(source: .twitch, handle: "caedrel", name: "Caedrel")
            let quiet = MediaChannel(source: .twitch, handle: "quietone", name: "Quiet One")
            let live = MediaEntry(
                channel: caedrel,
                stream: MediaStream(
                    title: "LCK", category: "League of Legends", viewers: 36579, startedAt: start,
                    thumbnail: "https://example.dev/preview.jpg", tags: ["English"]),
                checkedAt: now)

            var board = WatchChooser(watchlist: [caedrel, quiet], followed: [caedrel])
            try expect(!board.heading.isEmpty, "the board names what it is showing")
            try expect(!board.hint.isEmpty, "and says which keys move it")
            try expect(
                board.notice == VideoNotice.splitCost, "and carries what a stream costs the grid")
            board.filled(live: MediaFeed(entries: [live]))
            board.tick(now)
            guard let onAir = board.sections.first, let row = onAir.rows.first else {
                throw SelfTestFailure("watch board: the board drew no rows")
            }
            try expect(row.title == "Caedrel", "the row is the channel, named as a person would")
            try expect(row.badge == .live("37K"), "a live row wears its audience")
            try expect(row.detail == "LCK", "the line under the name is what is on")
            try expect(
                row.note?.hasPrefix("League of Legends") == true,
                "and the dimmer line under that is the context, without the count said twice")
            try expect(row.thumbnail != nil, "a live row offers a picture to draw")
            try expect(row.isFollowed, "a followed channel earns its star")
            try expect(board.focused?.id == row.id, "the cursor starts on the first row it can press")

            guard board.sections.count > 1, let offAir = board.sections.last,
                let quietRow = offAir.rows.first
            else { throw SelfTestFailure("watch board: the offline half of the list vanished") }
            board.focus(section: offAir.id, offset: 0)
            try expect(
                board.focused?.id == quietRow.id,
                "a press maps through its section and its offset inside it")
            try expect(quietRow.badge == .offline(Localized.text("offline")), "an offline row says so")

            let popular = (0..<6).map { index in
                MediaEntry(
                    channel: MediaChannel(source: .twitch, handle: "t\(index)", name: "Top \(index)"),
                    stream: MediaStream(title: "on", viewers: 1000 - index))
            }
            board.filled(top: MediaFeed(entries: popular))
            let expanders = board.rows.filter { row in
                if case .expander = row.kind { return true }
                return false
            }
            guard let expander = expanders.first else {
                throw SelfTestFailure("watch board: a compacted section offered no expander")
            }
            try expect(expander.thumbnail == nil, "a row that stands for a list carries no picture")
            try expect(expander.badge == nil, "and no badge")
            try expect(expander.isActivatable, "but it is still a row to press")

            var failing = WatchChooser(watchlist: [caedrel], followed: [])
            failing.filled(live: MediaFeed(failures: ["Twitch did not answer"]))
            guard let note = failing.rows.first(where: { $0.kind == .note }) else {
                throw SelfTestFailure("watch board: a source that failed said nothing")
            }
            try expect(!note.isActivatable, "a note is text the board owed, not something to press")
            try expect(failing.focused?.id != note.id, "so the cursor never stops on one")

            var typed = WatchChooser(watchlist: [caedrel], followed: [])
            typed.type("kamet0")
            try expect(typed.rows.first?.isPrimary == true, "what was typed leads its own answer")
            try expect(
                typed.rows.first?.kind == .typed(.twitch("kamet0")),
                "and means exactly what the box has always meant")
            try expect(typed.pendingSearch == "kamet0", "the sources are owed a question")

            guard let letter = KeyChord.canonical(keyval: 0x61, state: 0),
                let down = KeyChord.canonical(keyval: Keymap.down, state: 0),
                let follow = KeyChord.canonical(keyval: 0x66, state: KeyChord.controlMask)
            else { throw SelfTestFailure("watch board: a keystroke would not resolve") }
            try expect(
                WatchChooser.command(for: letter) == nil, "a letter belongs to the box being typed in")
            try expect(WatchChooser.command(for: down) == .down, "the arrows belong to the board")
            try expect(WatchChooser.command(for: follow) == .follow, "ctrl+f follows what is focused")

            let first = "https://example.dev/one.jpg"
            let second = "https://example.dev/two.jpg"
            try expect(
                MediaThumbDisk.identity(for: first) != MediaThumbDisk.identity(for: second),
                "two pictures never share one cache slot")
            let bytes = Data((0..<256).map { UInt8($0 % 251) })
            MediaThumbDisk.save(bytes, for: first)
            try expect(MediaThumbDisk.load(first) == bytes, "a thumbnail round-trips on disk")
            try expect(MediaThumbDisk.load(second) == nil, "an unfetched picture loads nothing")
            return checks
        }

        /// The settings section and the sign-in sheet, checked as the facts they are drawn from: two
        /// rows in a stable order, each one a statement before it is a control, a Twitch that needs
        /// nothing registered, a YouTube that says at length what it needs when this build was given no
        /// application for it — and a flow whose heading, code and one button change together as it
        /// moves, because the sheet renders nothing else.
        private static func checkWatchAccounts() throws -> Int {
            var checks = 0
            func expect(_ condition: Bool, _ label: String) throws {
                guard condition else { throw SelfTestFailure("watch accounts: \(label)") }
                checks += 1
            }

            try expect(
                MediaAccounts.isInstalled,
                "the Keychain is handed over before anything reads an account")
            try expect(
                !WatchAccounts.heading.isEmpty && !WatchAccounts.description.isEmpty,
                "the section says what signing in is for")
            try expect(!WatchAccounts.summary.isEmpty, "and states in one line who is signed in")

            let rows = WatchAccounts.rows()
            try expect(rows.count == MediaSource.allCases.count, "one row per site")
            try expect(rows.map(\.source) == [.twitch, .youtube], "in the order the sites are listed")
            try expect(
                rows.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.actionTitle.isEmpty },
                "each row names itself, states itself, and titles its own button")

            guard let twitch = rows.first(where: { $0.source == .twitch }),
                let youtube = rows.first(where: { $0.source == .youtube })
            else { throw SelfTestFailure("watch accounts: a site drew no row") }
            try expect(
                MediaAccounts.authority(for: .twitch).isConfigured,
                "Twitch's device flow needs no application registered")
            try expect(twitch.note == nil, "so its row owes no explanation under it")
            try expect(
                twitch.isSignedIn || twitch.action == .signIn(.twitch),
                "and a signed-out Twitch offers the one button that fixes that")
            if MediaAccounts.authority(for: .youtube).isConfigured {
                try expect(youtube.note == nil, "a configured YouTube explains nothing either")
            } else {
                try expect(
                    youtube.action == .configure(.youtube),
                    "an unregistered YouTube says what it needs rather than offering a button that fails")
                try expect(youtube.note?.isEmpty == false, "and says it at length")
                try expect(
                    youtube.note?.contains("TAILSCODE_YOUTUBE_CLIENT_ID") == true,
                    "naming the variables the alert's Copy button hands over")
            }

            var flow = WatchSignIn(source: .twitch)
            try expect(flow.step == .starting && !flow.isFinished, "a flow starts by asking")
            try expect(flow.code == nil && flow.link == nil, "with no code to print and nothing to open")
            try expect(flow.instruction?.isEmpty == false, "but says what it is doing meanwhile")
            let prompt = DevicePrompt(
                deviceCode: "device", userCode: "WXYZ-1234",
                verificationURL: "https://www.twitch.tv/activate?device-code=WXYZ-1234", interval: 5,
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
            flow.began(prompt)
            try expect(flow.code == "WXYZ-1234", "then prints the code the site will ask for")
            try expect(flow.link == prompt.verificationURL, "and opens where it is confirmed")
            try expect(
                flow.actionTitle == Localized.text("Open %@", MediaSource.twitch.label),
                "which is what the one button is titled")
            flow.granted(MediaAccount(source: .twitch, name: "Marcus", handle: "marcus"))
            try expect(flow.isFinished, "granting finishes it")
            try expect(
                flow.heading == Localized.text("Signed in as %@", "Marcus"), "and names the account")
            try expect(flow.code == nil, "taking the code back down")
            try expect(
                flow.actionTitle == Localized.text("Done"), "and leaving one button, which closes")
            var refused = WatchSignIn(source: .youtube)
            refused.failed("Google would not answer")
            try expect(refused.detail == "Google would not answer", "a failure states its own reason")
            try expect(refused.isFinished, "with no polling left running behind it")
            try expect(
                refused.actionTitle == Localized.text("Try again"), "and one button that asks again")
            return checks
        }
    #endif

    /// The forge as this window draws it, state by state. A render is minutes of another machine's
    /// card, so the states between pressing the button and holding a file cannot be reached in a
    /// build loop — and they are exactly the ones worth checking, because each of them is a
    /// different sentence and each of them draws a different row. Every value asserted here is
    /// Core's: what this proves is that the pane can be put into the state and that the row it
    /// builds carries the words, the badge, the bar and the reach the board handed it.
    private static func checkForgeSurface() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("forge surface: \(label)") }
            checks += 1
        }
        func jobRow(_ board: ForgeBoard) throws -> ForgeRow {
            guard let row = board.rows.first(where: { $0.kind == .job }) else {
                throw SelfTestFailure("forge surface: the render has no row")
            }
            return row
        }
        func section(_ board: ForgeBoard, _ id: String) throws -> ForgeSection {
            guard let section = board.sections.first(where: { $0.id == id }) else {
                throw SelfTestFailure("forge surface: no \(id) section")
            }
            return section
        }

        for name in ForgeDemo.states {
            let board = ForgeDemo.board(name)
            try expect(
                board.sections.map(\.id).starts(
                    with: [ForgeBoard.rendererID, ForgeBoard.renderID, ForgeBoard.settingsID]),
                "\(name) draws the renderer, the render and the settings, in that order")
            try expect(!board.notice.isEmpty, "\(name) still says where a render happens")
        }

        var unset = ForgeDemo.board("unset")
        try expect(
            unset.renderCall == Localized.text("Set up the renderer"),
            "with no machine, the button says it would go and get one")
        try expect(unset.begin() == .configure, "and pressing it asks for the address")
        try expect(
            unset.value(of: .endpoint) == Localized.text("Not set up yet"),
            "while the row says there is none")

        let checking = ForgeDemo.board("checking")
        try expect(checking.isChecking, "a machine being asked is a state of its own")
        try expect(try section(checking, ForgeBoard.rendererID).phase == .checking, "and its section says so")
        try expect(try section(checking, ForgeBoard.rendererID).rows.first?.badge == nil,
            "a machine mid-question wears no word yet")

        let down = ForgeDemo.board("down")
        try expect(
            try section(down, ForgeBoard.rendererID).rows.first?.detail
                == ForgeEndpoint.sentence(for: .timedOut, host: ForgeDemo.host),
            "a machine that did not answer says so in Core's own sentence")
        try expect(
            try section(down, ForgeBoard.rendererID).rows.first?.badge == Localized.text("down"),
            "and wears the word for it")

        var ready = ForgeDemo.board("ready")
        try expect(try jobRow(ready).detail == Localized.text("Ready to render"), "a described draft is ready")
        try expect(ready.renderCall == Localized.text("Render"), "and the button says what it would do")
        try expect(ready.canRender, "and it can")
        try expect(ready.begin() == .render(ready.recipe), "on exactly what is on the board")

        let waking = ForgeDemo.board("waking")
        try expect(try jobRow(waking).badge == Localized.text("waking"), "the twelve-second wake has a word")
        try expect(try jobRow(waking).fraction == nil, "and no bar, because there is nothing honest to fill")

        let queued = ForgeDemo.board("queued")
        try expect(try jobRow(queued).badge == Localized.text("queued"), "a queued render says so")
        try expect(
            try jobRow(queued).detail == Localized.text("%@ ahead in the queue", "2"),
            "and how many are ahead of it")
        try expect(try jobRow(queued).fraction == nil, "still with no bar")

        var running = ForgeDemo.board("running")
        try expect(try jobRow(running).fraction == 0.5, "a running render carries the node census as its bar")
        try expect(try jobRow(running).badge == Localized.text("50%"), "and the same number in the corner")
        try expect(
            try jobRow(running).note?.contains(Localized.text("step %@ of %@", "3", "4")) == true,
            "the sampler's own step is said in words, never as the bar")
        try expect(running.renderCall == Localized.text("Stop"), "and the button stops it")
        try expect(running.begin() == .cancel, "which is what pressing it does")
        try expect(
            running.rows.first(where: { $0.kind == .field(.size) })?.isActivatable == false,
            "the settings the render already consumed are out of reach")

        let collecting = ForgeDemo.board("collecting")
        try expect(
            try jobRow(collecting).detail == Localized.text("Saving the file…"),
            "a full bar with no file yet is a state with its own words")
        try expect(try jobRow(collecting).badge == Localized.text("saving"), "and its own word")

        var done = ForgeDemo.board("done")
        try expect(try jobRow(done).badge == Localized.text("ready"), "a delivered render says it is ready")
        try expect(done.renderCall == Localized.text("Play"), "and the button plays it")
        try expect(done.begin() == .play(ForgeDemo.asset), "on the file that came back")

        let failed = ForgeDemo.board("failed")
        try expect(
            try jobRow(failed).detail == "UNETLoader failed: CUDA out of memory",
            "a render that failed says why rather than going quiet")
        try expect(try jobRow(failed).badge == Localized.text("failed"), "with a word in the corner")
        try expect(try section(failed, ForgeBoard.renderID).phase == .failed("UNETLoader failed: CUDA out of memory"),
            "and the whole section wears the failure")

        let stopped = ForgeDemo.board("stopped")
        try expect(try jobRow(stopped).detail == Localized.text("Stopped"), "a cancelled render says only that")
        try expect(try jobRow(stopped).badge == Localized.text("stopped"), "and holds still")

        var empty = ForgeDemo.board("empty")
        guard let note = empty.rows.firstIndex(where: { $0.kind == .note }) else {
            throw SelfTestFailure("forge surface: an empty history drew nothing at all")
        }
        try expect(
            empty.rows[note].title == Localized.text("Nothing rendered yet"),
            "an empty history says it is empty rather than vanishing")
        empty.focus(note)
        try expect(empty.cursor != note, "and the cursor does not stop on it")

        let history = ForgeDemo.board("history")
        let kept = try section(history, ForgeBoard.historyID)
        try expect(kept.rows.count == ForgeBoard.compactLimit + 1, "a long history compacts")
        try expect(kept.hidden == 3, "and says how many it is holding back")
        guard let lost = history.rows.first(where: { $0.entry?.isPlayable == false }) else {
            throw SelfTestFailure("forge surface: the history lost its unplayable row")
        }
        try expect(lost.badge == Localized.text("failed"), "a clip that never arrived says so")
        try expect(lost.detail == ForgeFailure.noOutput(ForgeDemo.host).description, "and keeps the reason")

        let row = ForgeRowView()
        row.configure(
            try jobRow(running), phase: .checking, focused: true, activity: .working, aside: nil)
        try expect(row.accessibilityRole() == .button, "a row the board would act on is a button")
        try expect(
            row.accessibilityLabel()?.contains(Localized.text("50%")) == true,
            "and reads out the word in its corner")
        try expect(row.alphaValue == 1, "a row within reach is drawn at full strength")

        let spent = ForgeRowView()
        guard let size = running.rows.first(where: { $0.kind == .field(.size) }) else {
            throw SelfTestFailure("forge surface: the frame size is not a row")
        }
        spent.configure(size, phase: .ready, focused: false, activity: nil, aside: nil)
        try expect(spent.accessibilityRole() == .staticText, "a setting out of reach is not a button")
        try expect(spent.alphaValue < 1, "and is drawn as out of reach rather than as ordinary")

        let gone = ForgeRowView()
        let sentence = ForgeFailure.missingFile(ForgeDemo.host).description
        gone.configure(lost, phase: .ready, focused: false, activity: nil, aside: sentence)
        try expect(
            gone.accessibilityLabel()?.contains(sentence) == true,
            "a kept clip whose file is gone carries that sentence into what is read out")

        let stage = ForgeRowView()
        stage.configure(try jobRow(done), phase: .ready, focused: false, activity: nil, aside: nil)
        try expect(!stage.holdsClip, "a finished render with no file located yet draws no player")
        stage.showClip(URL(fileURLWithPath: "/tmp/tailscode-forge-selftest.mp4"), failure: nil)
        try expect(stage.holdsClip, "and one the machine confirmed plays where it was made")
        stage.showClip(nil, failure: nil)
        try expect(!stage.holdsClip, "a render that started again takes the last one's player away")

        let bar = ForgeBarView()
        bar.fraction = 0.5
        try expect(bar.intrinsicContentSize.height > 0, "the bar has a height to draw itself into")
        try expect(
            bar.intrinsicContentSize.width == NSView.noIntrinsicMetric,
            "and takes the width of whatever row it is in")

        let mark = ForgeMarkButton(target: nil, action: #selector(NSApplication.terminate(_:)))
        mark.render()
        try expect(
            mark.image != nil, "the toolbar's way in wears the symbol every client wears for it")
        try expect(
            mark.toolTip == ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil),
            "and promises what Core says it promises")
        try expect(
            mark.accessibilityLabel() == ForgeEntryPoint.accessibilityLabel(rendering: false),
            "reading out the same words a tooltip nobody hears would have said")
        try expect(
            ForgeEntryPoint.activity(rendering: false) == nil,
            "an idle control wears no badge, because a mark on nothing is decoration")
        try expect(
            ForgeEntryPoint.activity(rendering: true) == .working,
            "and a render out wears the state that breathes")

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let watching = ForgeRunner.shared.watcherCount
        host.contentView?.addSubview(mark)
        try expect(
            ForgeRunner.shared.watcherCount == watching + 1,
            "a control on screen is called back, so its badge follows the render")
        mark.removeFromSuperview()
        try expect(
            ForgeRunner.shared.watcherCount == watching,
            "and lets go the moment it leaves, rather than being called for the life of the process")

        let sheet = ForgeSheet.present(on: host)
        try expect(ForgeSheet.current === sheet, "the forge that is up is the one a press finds")
        try expect(
            ForgeSheet.present(on: host) === sheet,
            "so a second press fetches that one forward rather than building another over it")
        sheet.close()
        try expect(
            ForgeSheet.current == nil,
            "a closed forge is gone at the press rather than a runloop turn later")
        let reopened = ForgeSheet.present(on: host)
        try expect(
            reopened !== sheet,
            "which is what lets the press after a close open the forge instead of raising a dead one")
        reopened.close()
        try expect(
            ForgeRunner.shared.watcherCount == watching,
            "and a surface that has gone is watching nothing")

        try expect(
            ForgeSurface.preferredWidth >= ForgeSurface.minimumWidth
                && ForgeSurface.preferredHeight >= ForgeSurface.minimumHeight,
            "the modal opens no smaller than it is allowed to be shrunk to")
        try expect(
            ForgeSurface.dismissNote(rendering: false) == nil,
            "closing over nothing needs no reassurance")
        try expect(
            ForgeSurface.dismissNote(rendering: true) != nil,
            "and closing over a render says the render keeps going")
        return checks
    }

    /// A page is a pane, so what it holds has to read back the same after a restart, and a browsing
    /// pane must leave the keyboard to the page except for the chords a browser owns.
    private static func checkBrowserSlot() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("browser slot: \(label)") }
            checks += 1
        }

        try expect(WebTarget.classify("swift.org") == .page("https://swift.org"), "a host is a page")
        try expect(WebTarget.classify(":3000") == .page("http://localhost:3000"), "a port is local")
        try expect(
            WebTarget.classify("localhost:8080/health") == .page("http://localhost:8080/health"),
            "a local path is kept")
        try expect(
            WebTarget.classify("how to split a pane") == .search("how to split a pane"),
            "words are a search")
        try expect(WebTarget.classify("  ") == nil, "nothing typed points nowhere")
        try expect(
            WebTarget.search("two words").url.hasPrefix("https://duckduckgo.com/?q="),
            "a search is a real page")

        var slot = WebSlot()
        try expect(slot.isAsking, "an empty slot asks")
        slot.point(at: .page("https://swift.org"))
        slot.arrived(url: "https://www.swift.org/", title: "Swift Programming Language")
        try expect(slot.phase == .showing, "a landed page shows")
        try expect(slot.title == "Swift Programming Language", "the page names the pane")
        slot.ask()
        try expect(slot.draft == "https://www.swift.org/", "the address bar opens on where it is")

        var layout = SplitLayout()
        let first = layout.focusedPane
        guard let second = layout.split(first, axis: .vertical) else {
            throw SelfTestFailure("browser slot: the layout would not split")
        }
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [:], videos: [:],
            pages: [second.raw: "https://swift.org/documentation/"])
        guard let encoded = snapshot.encoded, let restored = SplitSnapshot.decode(encoded) else {
            throw SelfTestFailure("browser slot: the layout would not persist")
        }
        try expect(
            restored.page(for: second) == .page("https://swift.org/documentation/"),
            "a restart reopens the page")

        guard let plain = KeyChord.canonical(keyval: 0x61, state: 0),
            let address = KeyChord.canonical(keyval: 0x6C, state: KeyChord.controlMask),
            let back = KeyChord.canonical(keyval: 0xFF51, state: KeyChord.altMask)
        else { throw SelfTestFailure("browser slot: a keystroke would not resolve") }
        try expect(WebCommand.command(for: plain) == nil, "a letter belongs to the page")
        try expect(WebCommand.command(for: address) == .address, "ctrl+l opens the address bar")
        try expect(WebCommand.command(for: back) == .back, "alt+left goes back")
        return checks
    }

    /// The repository surface where it can actually go wrong on this toolkit: the shared reading
    /// of a working tree must survive being drawn — a panel that cannot build its own view is a
    /// popover that opens empty — and a patch must reach AppKit with its meanings still apart.
    private static func checkGit() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("git: \(label)") }
            checks += 1
        }
        let snapshot = GitSnapshot(
            root: "/home/dev/project", branch: "master", head: "abc12345",
            upstream: "origin/master", ahead: 2, behind: 1, stashes: 1, operation: "rebase",
            remote: "git@github.com:acme/project.git",
            changes: [
                GitChange(
                    path: "Sources/App/Main.swift", index: "M", worktree: "M", insertions: 3,
                    deletions: 1, stagedInsertions: 8, stagedDeletions: 2),
                GitChange(
                    path: "docs/", worktree: "?", untracked: true, directory: true, contains: 4),
                GitChange(path: "Package.swift", index: "U", worktree: "U", conflicted: true),
            ],
            commits: [
                GitCommitSummary(
                    hash: "deadbeefcafe", short: "deadbeef", subject: "a change", author: "dev",
                    at: Date(timeIntervalSince1970: 1_700_000_000), refs: ["HEAD -> master"])
            ], changedTotal: 3)
        let state = GitState(snapshot: snapshot)
        try expect(
            state.sections.map(\.kind) == [.conflicts, .staged, .changed, .untracked],
            "sections triage in order")
        try expect(state.alert?.contains("Rebase") == true, "an unfinished rebase leads the header")
        try expect(
            state.badge.contains("↑2") && state.badge.contains("↓1"),
            "the chip carries both drifts")
        try expect(
            state.facts.contains { $0.value == "acme/project" },
            "the remote is named the way a person names it")

        let panel = GitPanelViewController(
            state: state, title: "a chat", patch: { _ in nil }, commit: { _ in nil },
            openDiff: { _, _, _ in })
        try expect(panel.view.subviews.count == 1, "the panel builds its own view")

        let parts = state.badgeParts
        try expect(parts.first?.tone == .neutral, "the branch is drawn as a state")
        try expect(Set(parts.map(\.tone)).count >= 4, "the chip's marks share one colour")
        try expect(
            parts.map(\.text).joined(separator: " ") == state.badge,
            "the runs and the plain chip say different things")
        var badgeInks: Set<String> = []
        let tinted = GitPanelViewController.tinted(state.summaryParts, font: MacTheme.Ramp.font(.panelFootnote))
        tinted.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: tinted.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { badgeInks.insert(CascadeTint.hex(colour)) }
        }
        try expect(badgeInks.count >= 3, "the working-tree line is written in one colour")

        let rendered = GitDiffWindowController.render(
            """
            diff --git a/a.swift b/a.swift
            @@ -10,2 +10,2 @@
             kept
            -gone
            +arrived
            """)
        var colours: Set<String> = []
        rendered.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { colours.insert(CascadeTint.hex(colour)) }
        }
        try expect(colours.count >= 3, "a patch reaches AppKit with its meanings apart")
        try expect(
            rendered.string.contains("+ arrived") && rendered.string.contains("− gone"),
            "both sides of the change are drawn")
        return checks
    }

    /// The update surface where it can go wrong on this client: Core must refuse to call a machine
    /// current when nothing was actually compared, a fleet holding a machine nobody has heard from
    /// must not read as up to date, the Update Center must be able to build its own view, and the
    /// ledger must remember and forget exactly what it was told — the probe rows it writes are
    /// taken back out, because these stores are the real ones and a self-test that left marks
    /// behind would nag about a server that never existed.
    private static func checkUpdates() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("updates: \(label)") }
            checks += 1
        }
        let now = Date()

        let quiet = UpdateReadings.server(
            profileID: "probe-quiet", title: "quiet", subtitle: "claude-bridge",
            outcome: .answered(ServerUpdate(version: "1.4.0", manager: "systemd")),
            checkedAt: now)
        if case .current = quiet.verdict {
            throw SelfTestFailure("updates: a server that never looked read as up to date")
        }
        checks += 1
        try expect(!quiet.verdict.compared, "an answer that compared nothing says so")
        try expect(!quiet.stands(), "a machine that cannot say does not hold the mark up")

        let behind = UpdateReadings.server(
            profileID: "probe-behind", title: "behind", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 3,
                    changes: ["a change", "another"], canUpdate: true, manager: "systemd")),
            checkedAt: now)
        try expect(behind.verdict.offer?.canInstallHere == true, "a bridge that can install offers")
        try expect(behind.invitation == .installHere, "and the offer is the one press")
        try expect(behind.stands(), "an update that exists holds the mark up")

        let current = UpdateReadings.server(
            profileID: "probe-current", title: "current", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.5.0",
                    remote: ServerUpdate.RemoteCheck(
                        checked: true, ok: true, at: now, ref: "origin/master"),
                    latestVersion: "1.5.0", canUpdate: true, manager: "systemd")),
            checkedAt: now)
        guard case .current = current.verdict else {
            throw SelfTestFailure("updates: a server that looked and found nothing is current")
        }
        checks += 1

        let owed = UpdateReadings.server(
            profileID: "probe-owed", title: "owed", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.6.0", running: "1.5.0", restartRequired: true,
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    canUpdate: true, manager: "systemd",
                    busy: ServerUpdate.Busy(
                        quiet: false, turns: 1, reason: "A turn is running on that machine."),
                    canRestart: true)),
            checkedAt: now)
        try expect(
            owed.invitation
                == .restartHere(
                    supervisor: "systemd", waitingFor: "A turn is running on that machine."),
            "a build already on a supervised machine is one press, not another build")
        try expect(
            owed.invitation?.promise != nil,
            "and the press says beforehand what a turn running there costs it")
        let owedFleet = UpdateRollup(readings: [owed])
        try expect(
            owedFleet.updateOrder.isEmpty,
            "update everything never rebuilds a machine that only needed starting")
        try expect(
            owedFleet.restartableServers.count == 1, "though it is named as one that needs starting")

        let stranded = UpdateReadings.server(
            profileID: "probe-stranded", title: "stranded", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.6.0", running: "1.5.0", restartRequired: true,
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    canUpdate: true, manager: "manual", canRestart: false)),
            checkedAt: now)
        try expect(
            stranded.invitation == .copyCommand(BridgeInstall.installCommand),
            "a machine with nothing to start it again is handed the command instead")

        let dirty = UpdateReadings.server(
            profileID: "probe-dirty", title: "dirty", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 1, canUpdate: false,
                    reason: "the checkout has uncommitted changes", manager: "systemd",
                    obstacle: ServerUpdate.Obstacle(
                        kind: "dirty", summary: "the checkout has uncommitted changes",
                        items: ["Sources/a.swift", "Sources/b.swift"], more: 3))),
            checkedAt: now)
        try expect(
            dirty.verdict.offer?.detailLines.count == 3,
            "an obstacle names what is in the way and says how much it left out")

        let selfTaking = UpdateReadings.server(
            profileID: "probe-auto", title: "auto", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0",
                    remote: ServerUpdate.RemoteCheck(checked: true, ok: true, ref: "origin/master"),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 2, canUpdate: true,
                    manager: "systemd",
                    automation: ServerUpdate.Automation(
                        enabled: true, nextLookAt: now.addingTimeInterval(600)))),
            checkedAt: now)
        try expect(
            selfTaking.automation?.willTake == true,
            "a machine whose policy is on and has nothing in the way takes it itself")
        try expect(selfTaking.verdict.offer != nil, "it is still behind, because it is")
        try expect(
            !selfTaking.stands(),
            "but a machine that will take it itself is not a request that somebody act")

        let switchRow = AutoUpdateRow()
        switchRow.write(nil)
        try expect(switchRow.isHidden, "a server too old for a policy is offered no switch at all")
        switchRow.write(selfTaking.automation, now: now)
        try expect(!switchRow.isHidden, "and a machine with one is offered it")

        let old = UpdateReadings.server(
            profileID: "probe-old", title: "old", subtitle: "claude-bridge",
            outcome: .routeMissing(version: "1.1.0"), checkedAt: now)
        try expect(!old.verdict.compared, "a bridge too old for the route compared nothing")
        try expect(
            old.invitation == .copyCommand(BridgeInstall.installCommand),
            "and is handed the one command instead")

        let mixed = UpdateRollup(readings: [quiet, current, old])
        try expect(!mixed.everythingChecked, "one machine that could not say sinks the whole claim")
        try expect(
            mixed.headline != Localized.text("Everything is up to date"),
            "a fleet with a silent machine never reads as up to date")
        try expect(
            UpdateRollup(readings: [current]).everythingChecked,
            "a fleet that all answered may say so")
        let standing = UpdateRollup(readings: [behind, quiet, current])
        try expect(standing.showsMark, "the mark stands for the offer")
        try expect(standing.motion == .still, "an offer is a settled fact and holds perfectly still")
        try expect(standing.updateOrder == [behind.component], "only what one press finishes")

        let board = UpdateBoardViewController()
        try expect(board.view.subviews.count == 1, "the update board builds its own view")
        let footer = UpdateFooterView()
        footer.render()
        try expect(
            footer.isHidden == !UpdateLedger.rollup().showsMark,
            "the standing mark is shown exactly when something stands")

        let probeID = "selftest-\(UUID().uuidString)"
        let component = UpdateComponent.server(profileID: probeID)
        let probe = UpdateReadings.server(
            profileID: probeID, title: "selftest probe", subtitle: "claude-bridge",
            outcome: .answered(
                ServerUpdate(
                    version: "1.4.0", remote: ServerUpdate.RemoteCheck(checked: true, ok: true),
                    latestVersion: "1.5.0", updateAvailable: true, behind: 1, canUpdate: true,
                    manager: "systemd")),
            checkedAt: now)
        UpdateLedger.record(probe)
        guard let remembered = UpdateLedger.remembered(component) else {
            throw SelfTestFailure("updates: a recorded reading did not come back")
        }
        checks += 1
        try expect(remembered.verdict == probe.verdict, "and came back as it went in")
        try expect(!UpdateLedger.isAcknowledged(remembered), "nothing is set aside until it is")
        UpdateLedger.acknowledge(remembered)
        try expect(UpdateLedger.isAcknowledged(remembered), "setting an offer aside is remembered")
        try expect(
            !UpdateLedger.rollup().standing.contains { $0.id == remembered.id },
            "a set-aside offer stops holding the mark up")
        UpdateLedger.forget(component)
        try expect(UpdateLedger.remembered(component) == nil, "the probe left nothing behind")
        try expect(
            UpdateLedger.acknowledgements()[component.key] == nil,
            "and took its acknowledgement with it")
        return checks
    }

    private static func checkParity() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("parity: \(label)") }
            checks += 1
        }
        try expect(
            CapabilityRegistry.missingDefinitions.isEmpty, "every capability has a spec")
        for capability in AppCapability.allCases {
            switch ParityManifest.evidence(for: capability) {
            case .implemented(let anchor):
                try expect(!anchor.isEmpty, "\(capability.rawValue) names its anchor")
            case .partial(let anchor, let missing):
                try expect(
                    !anchor.isEmpty && !missing.isEmpty,
                    "\(capability.rawValue) names its anchor and its debt")
            case .gap(let reason), .notApplicable(let reason):
                try expect(!reason.isEmpty, "\(capability.rawValue) states its reason")
            case .varies:
                try expect(false, "\(capability.rawValue) resolves to one answer for this copy")
            }
        }
        for problem in MacParity.audit() {
            try expect(false, problem)
        }
        return checks
    }

    /// The composer's vim mode, driven the way a person drives it: a starting buffer, a string
    /// of keys, and the text that must come out — plus the pending-command flag the key monitor
    /// leans on to keep `3x` and `diw` landing mid-command.
    private static func checkVim() throws -> Int {
        let cases: [(text: String, keys: String, expected: String, label: String)] = [
            ("hello world", "dw", "world", "dw"),
            ("hello world", "x", "ello world", "x"),
            ("hello world", "wciwthere", "hello there", "ciw"),
            ("say \"a thing\" now", "f\"ci\"other", "say \"other\" now", "ci\""),
            ("call(one, two)", "f(di(", "call()", "di("),
            ("alpha\nbeta\ngamma", "jdd", "alpha\ngamma", "dd"),
            ("alpha\nbeta", "yyp", "alpha\nalpha\nbeta", "yy then p"),
            ("alpha beta", "vlld", "ha beta", "visual delete"),
            ("alpha", "A!", "alpha!", "A"),
            ("alpha", "ohi", "alpha\nhi", "o"),
            ("one two three", "d2w", "three", "count with operator"),
            ("indent", ">>", "    indent", ">>"),
            ("alpha", "xu", "alpha", "undo"),
            ("one\ntwo", "J", "one two", "J"),
            ("first\nsecond", "Vd", "second", "visual-line delete"),
            ("hello", "$x", "hell", "$x"),
            ("one, two", "dt,", ", two", "dt"),
            ("hello", "ggx", "ello", "gg"),
        ]
        var checked = 0
        for testCase in cases {
            let engine = VimEngine()
            engine.reset(to: testCase.text, cursor: 0, mode: .normal)
            var text = testCase.text
            var cursor = 0
            for character in testCase.keys {
                let outcome = engine.handle(
                    VimKey(character: character), text: text, cursor: cursor)
                if case .passThrough = outcome {
                    var characters = Array(text)
                    characters.insert(character, at: min(cursor, characters.count))
                    text = String(characters)
                    cursor += 1
                    engine.syncFromEditor(text: text, cursor: cursor)
                } else {
                    text = engine.document.text
                    cursor = engine.document.cursor
                }
            }
            guard text == testCase.expected else {
                throw SelfTestFailure(
                    "\(testCase.label): expected \(testCase.expected.debugDescription), got \(text.debugDescription)"
                )
            }
            checked += 1
        }

        let engine = VimEngine()
        engine.reset(to: "alpha beta", cursor: 0, mode: .normal)
        let midCommand: [(Character, Bool, String)] = [
            ("d", true, "an operator waits"),
            ("i", true, "a text object waits"),
            ("w", false, "diw completes"),
            ("3", true, "a count waits"),
            ("x", false, "the count is spent"),
            ("f", true, "f waits for its key"),
            ("z", false, "f lands"),
            ("g", true, "g waits for its key"),
            ("g", false, "gg completes"),
        ]
        for (character, expected, label) in midCommand {
            _ = engine.handle(
                VimKey(character: character), text: engine.document.text,
                cursor: engine.document.cursor)
            guard engine.awaitsMore == expected else {
                throw SelfTestFailure("awaitsMore: \(label)")
            }
            checked += 1
        }
        return checked
    }

    /// The local stores, exercised with probe identities and put back exactly as found: every
    /// toggle is its own inverse, so a self-test run leaves the user's saved, archived and seen
    /// state untouched. The stores speak to the real defaults — they accept no scratch suite —
    /// which is precisely why the round trip must net to zero.
    private static func checkStores() throws {
        let probeProfile = "selftest-\(UUID().uuidString)"
        let probeSession = "selftest-\(UUID().uuidString)"

        guard ArchivedChatStore.toggle(profileID: probeProfile, sessionID: probeSession) else {
            throw SelfTestFailure("archiving reported the wrong direction")
        }
        guard ArchivedChatStore.contains(profileID: probeProfile, sessionID: probeSession) else {
            throw SelfTestFailure("an archived chat did not round-trip")
        }
        guard !ArchivedChatStore.toggle(profileID: probeProfile, sessionID: probeSession),
            !ArchivedChatStore.contains(profileID: probeProfile, sessionID: probeSession)
        else { throw SelfTestFailure("an archived chat survived its unarchive") }

        let session = AgentSession(
            id: probeSession, agentType: .claudeCode, title: "selftest probe",
            directory: "/tmp/selftest", createdAt: Date(), updatedAt: Date())
        let entry = SessionEntry(
            profileID: probeProfile, profileName: "probe", host: "probe",
            backendType: .claudeCode, session: session)
        guard SavedChatStore.toggle(entry), SavedChatStore.contains(entry) else {
            throw SelfTestFailure("a saved chat did not round-trip")
        }
        guard
            let saved = SavedChatStore.all().first(where: { $0.sessionID == probeSession }),
            saved.title == "selftest probe", saved.directory == "/tmp/selftest",
            saved.backend == .claudeCode
        else { throw SelfTestFailure("the bookmark lost its snapshot") }
        guard !SavedChatStore.toggle(entry), !SavedChatStore.contains(entry) else {
            throw SelfTestFailure("a saved chat survived its unsave")
        }

        let updatedAt = Date()
        SessionSeenStore.markUnread(probeSession, updatedAt: updatedAt)
        guard SessionSeenStore.unreadEvaluator()(probeSession, updatedAt) else {
            throw SelfTestFailure("marking unread did not badge the row")
        }
        SessionSeenStore.markSeen(probeSession)
        guard !SessionSeenStore.unreadEvaluator()(probeSession, updatedAt) else {
            throw SelfTestFailure("marking seen did not clear the badge")
        }
        let defaults = UserDefaults.standard
        if var seen = defaults.dictionary(forKey: "tailscode.seen.sessions") as? [String: Double] {
            seen[probeSession] = nil
            defaults.set(seen, forKey: "tailscode.seen.sessions")
        }
    }

    /// A picture must come back byte-identical, keyed to its server file — and two different
    /// files must never collide into one cache slot.
    private static func checkImageStore() throws {
        let scratch = "/tmp/tailscode-selftest-\(UUID().uuidString)"
        let first = FileReference(path: "\(scratch)/a.png", mime: "image/png", filename: "a.png")
        let second = FileReference(path: "\(scratch)/b.png", mime: "image/png", filename: "b.png")
        guard let one = ImageDisk.identity(for: first),
            let two = ImageDisk.identity(for: second), one != two
        else { throw SelfTestFailure("two files share one identity") }
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        ImageDisk.save(bytes, for: first)
        guard ImageDisk.load(first) == bytes else {
            throw SelfTestFailure("bytes did not round-trip")
        }
        guard ImageDisk.load(second) == nil else {
            throw SelfTestFailure("an unsaved file loaded")
        }
        guard ImageDisk.identity(for: FileReference()) == nil else {
            throw SelfTestFailure("an unidentifiable file got an identity")
        }
    }

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    private static func checkTwoObservers(_ profiles: [ConnectionProfile]) async throws -> Int {
        guard let profile = profiles.first,
            let backend = ServerDirectory.shared.backend(for: profile),
            let session = try await backend.listSessions().max(by: { $0.updatedAt < $1.updatedAt })
        else { throw SelfTestFailure("nothing to observe") }

        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        async let first = settled(conversation)
        async let second = settled(conversation)
        let (a, b) = try await (first, second)

        guard !a.isEmpty else { throw SelfTestFailure("first observer saw nothing") }
        guard a == b else {
            throw SelfTestFailure("observers diverged: \(a.count) vs \(b.count) messages")
        }
        return a.count
    }

    private static func settled(_ conversation: AgentConversation) async throws -> [String] {
        let deadline = Date().addingTimeInterval(20)
        for await state in await conversation.states() {
            if state.hasLoadedTranscript { return state.messages.map(\.id) }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("observer never loaded a transcript")
    }

    /// The first snapshot that has actually loaded a transcript, or whatever arrived within the
    /// deadline — a stream that never delivers is the failure this is looking for.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        var latest = ConversationState()
        let deadline = Date().addingTimeInterval(15)
        for await state in await conversation.states() {
            latest = state
            if state.hasLoadedTranscript || Date() > deadline { break }
        }
        return latest
    }

    /// A self-test that hangs is worse than one that fails: it stalls the build loop on a machine
    /// nobody is looking at.
    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
