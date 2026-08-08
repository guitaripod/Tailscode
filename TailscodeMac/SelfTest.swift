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
            let checks = try checkShortcuts()
            report("shortcuts: \(checks) keys resolve, rebind and stay conflict-free")
        } catch {
            report("shortcuts: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVideoSlot()
            report("video slot: \(checks) answers, resolver \(VideoResolver.tool() ?? "missing")")
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

        let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
        if shellOutput.contains("tailscode-shell-ok") {
            report("shell: ok (one command at a time in a login shell)")
        } else {
            report("shell: no output")
            failures += 1
        }

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
        try expect(
            paragraph(in: listed, over: "plain line") == nil, "prose is not indented like a list")
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
        return checks
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
            }
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
