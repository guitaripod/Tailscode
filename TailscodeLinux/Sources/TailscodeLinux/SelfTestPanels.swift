import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    static func checkPalettes() throws -> Int {
        var ids = Set<String>()
        var names = Set<String>()
        for theme in AppTheme.all {
            guard ids.insert(theme.id).inserted else {
                throw SelfTestFailure("two themes answer to \(theme.id)")
            }
            guard names.insert(theme.name).inserted else {
                throw SelfTestFailure("two themes are called \(theme.name)")
            }
            guard !theme.blurb.isEmpty, AppTheme.named(theme.id) == theme else {
                throw SelfTestFailure("\(theme.id) does not come back from the catalog")
            }
        }
        guard AppTheme.named("no-such-theme") == AppTheme.fallback,
            AppTheme.named(nil) == AppTheme.fallback
        else { throw SelfTestFailure("an unknown theme does not fall back") }

        for theme in AppTheme.all {
            guard MatrixTheme.palette(for: theme.id, dark: true).name == theme.dark.name,
                MatrixTheme.palette(for: theme.id, dark: false).name == theme.light.name
            else { throw SelfTestFailure("choosing \(theme.id) does not reach its palettes") }
        }
        guard MatrixTheme.palette(for: "no-such-theme", dark: true).name
            == AppTheme.fallback.dark.name
        else { throw SelfTestFailure("an unknown saved theme does not fall back on screen") }

        for palette in AppTheme.all.flatMap({ [$0.dark.corrected(), $0.light.corrected()] }) {
            guard palette.isDark == ((Contrast.luminance(palette.canvas) ?? 1) < 0.18) else {
                throw SelfTestFailure("\(palette.name): its canvas disagrees with isDark")
            }
            let slots = [
                palette.canvas, palette.canvasRaised, palette.rule, palette.text,
                palette.textDim, palette.accent, palette.accentDim, palette.warn,
                palette.danger, palette.info, palette.special, palette.codeBg,
                palette.subagentBg, palette.findHit, palette.onAccent,
                palette.brandClaude, palette.brandOpencode, palette.brandGrok,
                palette.brandDeepseek, palette.brandOllama,
            ]
            for slot in slots {
                guard slot.hasPrefix("#"), slot.count == 7,
                    slot.dropFirst().allSatisfy(\.isHexDigit)
                else { throw SelfTestFailure("\(palette.name): \(slot) is not a color") }
            }
            for rule in palette.contrastContract {
                guard let ratio = Contrast.ratio(rule.color, on: rule.against) else {
                    throw SelfTestFailure("\(palette.name): \(rule.slot) is not measurable")
                }
                guard ratio >= rule.ratio else {
                    throw SelfTestFailure(
                        String(
                            format: "%@: %@ reads at %.2f:1, needs %.1f:1",
                            palette.name, rule.slot, ratio, rule.ratio))
                }
            }
            try checkSignalsAreDistinct(palette)
            let css = MatrixTheme.css(for: palette)
            guard css.contains(palette.canvas), css.contains(palette.accent),
                css.contains(palette.findHit), !css.contains("Optional(")
            else { throw SelfTestFailure("\(palette.name): css does not carry the palette") }
            try checkLabelSemantics(css, palette)
        }
        let sample = "**bold** and `code` and *soft*"
        func render(_ palette: Palette) -> String {
            PangoMarkdown.render(
                sample, dim: palette.textDim, code: palette.info, accent: palette.accent)
        }
        let night = AppTheme.fallback.dark.corrected()
        let day = AppTheme.fallback.light.corrected()
        let first = render(night)
        let again = render(night)
        let light = render(day)
        guard first == again, first != light, light.contains(day.info) else {
            throw SelfTestFailure("markup cache does not respect the palette")
        }
        return AppTheme.all.count
    }

    /// Two meanings that wear the same colour are one meaning to a reader. Every signal slot has
    /// to be told apart from every other one at a glance, so no two may sit inside 1.6:1 of each
    /// other — which is what catches a palette edit that quietly makes "running" and "needs you"
    /// the same amber again.
    static func checkSignalsAreDistinct(_ palette: Palette) throws {
        let signals = [
            ("accent", palette.accent), ("warn", palette.warn), ("danger", palette.danger),
            ("info", palette.info), ("special", palette.special), ("textDim", palette.textDim),
        ]
        for (index, one) in signals.enumerated() {
            for other in signals.dropFirst(index + 1) {
                guard one.1 != other.1 else {
                    throw SelfTestFailure(
                        "\(palette.name): \(one.0) and \(other.0) are the same colour")
                }
            }
        }
    }

    /// The label contract, asserted against the stylesheet the app actually loads: a running turn
    /// and a turn waiting on the reader must not draw from the same slot, an offline row must not
    /// borrow the failure colour, and no brand may be hardcoded past the palette.
    static func checkLabelSemantics(_ css: String, _ palette: Palette) throws {
        let required = [
            ".glyph-running { color: \(palette.accent); }",
            ".glyph-needs { color: \(palette.warn); }",
            ".seg-live { color: \(palette.accent); }",
            ".seg-warn { color: \(palette.warn); }",
            ".seg-error { color: \(palette.danger); }",
            ".brand-claude { color: \(palette.brandClaude); }",
            ".brand-omp { color: \(MatrixTheme.brandOmp(in: palette)); }",
            ".gauge-fill-omp { background-color: \(MatrixTheme.brandOmp(in: palette)); border-radius: 3px; }",
            ".brand-ollama-cloud { color: \(palette.brandOllama); }",
            ".gauge-fill-ollama-cloud { background-color: \(palette.brandOllama); border-radius: 3px; }",
        ]
        for rule in required where !css.contains(rule) {
            throw SelfTestFailure("\(palette.name): missing label rule — \(rule)")
        }
        for token in StatusFacts.Segment.allCSS where !css.contains(".\(token) {") {
            throw SelfTestFailure("\(palette.name): the band can wear .\(token) and nothing styles it")
        }
        guard !css.contains(".seg-offline { color: \(palette.danger)") else {
            throw SelfTestFailure("\(palette.name): offline is drawn as a failure")
        }
        for kind in ActivityKind.everyState {
            let icon = kind.icon
            guard css.contains(".\(icon.glyphCSS) {") else {
                throw SelfTestFailure(
                    "\(palette.name): \(kind) draws .\(icon.glyphCSS) and nothing styles it")
            }
            guard css.contains(".\(icon.bandCSS) {") else {
                throw SelfTestFailure(
                    "\(palette.name): \(kind) bands .\(icon.bandCSS) and nothing styles it")
            }
        }
    }

    /// What a conversation cost is money on a screen, so the arithmetic is asserted rather than
    /// eyeballed: the bars are relative to the priciest turn, the tiers add up to the total, and
    /// an estimate says so in the badge itself.
    /// The repository surface, asserted where GTK can actually lose it: the shared reading of a
    /// working tree, the Pango markup a diff becomes, and — the failure mode unique to this
    /// toolkit — every class the panel puts on a widget having a rule in the stylesheet. A class
    /// nobody styles is invisible ink, and no build catches it.
    static func checkGit() throws -> Int {
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
                    path: "build/", worktree: "?", untracked: true, directory: true, contains: 12),
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

        let markup = GitDiffWindow.markup(
            """
            diff --git a/a.swift b/a.swift
            @@ -10,2 +10,2 @@
             kept
            -gone
            +arrived
            """)
        let palette = MatrixTheme.palette
        try expect(markup.contains(palette.accent), "an added line is not drawn in the accent")
        try expect(markup.contains(palette.danger), "a removed line is not drawn in the danger")
        try expect(
            markup.contains("+ arrived") && markup.contains("− gone"),
            "both sides of the change are drawn")
        try expect(!markup.contains("<span foreground=\'\'>"), "a colour resolved to nothing")

        let css = MatrixTheme.css(for: palette)
        for tone in GitTone.allCases {
            try expect(css.contains(".\(tone.css) {"), "\(tone.rawValue) has no rule to draw with")
        }
        let badge = GitState(snapshot: snapshot).badgeParts
        try expect(badge.first?.tone == .neutral, "the branch is not a state")
        try expect(
            Set(badge.map(\.tone)).count >= 4, "the chip's marks do not carry their own meanings")
        try expect(
            badge.map(\.text).joined(separator: " ") == GitState(snapshot: snapshot).badge,
            "the runs and the plain chip say different things")
        for name in ["git-row", "git-alert", "git-diff", "git-neutral-ink"] {
            try expect(css.contains(".\(name) {"), "\(name) has no rule to draw with")
        }
        return checks
    }

    static func checkSpend() throws -> Int {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        func turn(_ minute: Int, _ cost: Double, output: Int = 1000) -> SessionSpendReport.Turn {
            SessionSpendReport.Turn(
                at: start.addingTimeInterval(Double(minute) * 60), seconds: 30,
                model: "claude-opus-5", calls: 2,
                tokens: SessionSpendReport.Tokens(output: output, cacheRead: output * 40),
                costUSD: cost, prompt: "turn \(minute)")
        }
        let turns = [turn(0, 1), turn(30, 4), turn(90, 1)]
        var tokens = SessionSpendReport.Tokens()
        for item in turns {
            tokens.output += item.tokens.output
            tokens.cacheRead += item.tokens.cacheRead
        }
        let spend = SessionSpend(
            report: SessionSpendReport(
                costUSD: 6, tokens: tokens, turns: turns,
                byModel: [
                    SessionSpendReport.ModelShare(
                        model: "claude-opus-5", turns: 3, tokens: tokens, costUSD: 6)
                ],
                startedAt: turns.first?.at, endedAt: turns.last?.at))

        guard spend.badge == "~$6.00" else { throw SelfTestFailure("badge: \(spend.badge)") }
        guard spend.turns.map(\.share) == [0.25, 1, 0.25] else {
            throw SelfTestFailure("bars are not relative to the priciest turn")
        }
        let tierMoney = spend.tiers.reduce(0) { $0 + $1.costUSD }
        guard abs(tierMoney - spend.costUSD) < 0.0001 else {
            throw SelfTestFailure("tiers add up to \(tierMoney), not \(spend.costUSD)")
        }
        guard spend.priciest?.costUSD == 4, spend.turnCount == 3 else {
            throw SelfTestFailure("the expensive turn is not the one that cost most")
        }
        guard let rate = spend.perHourUSD, abs(rate - 4) < 0.0001 else {
            throw SelfTestFailure("an hour and a half of six dollars is not \(spend.perHourUSD ?? 0)")
        }
        guard !spend.headline.isEmpty, spend.source.contains(Localized.text("Estimated")) else {
            throw SelfTestFailure("the panel does not say where its numbers came from")
        }
        return spend.turns.count + spend.tiers.count + spend.headline.count
    }

    /// The notice's face is a real image, a picture handed back is painted into it rather than
    /// ignored, and only the turn that just ended can hand one back: an earlier turn's screenshot
    /// or one the person attached would be the wrong answer. A body with a tag in it reaches a
    /// markup-reading daemon escaped. Headless: cairo and pango, no daemon.
    static func checkNotificationPlate() throws -> Int {
        guard
            let face = NotificationPlate.render(
                tone: "#3DDC97", ink: "#0B0B0B", canvas: "#111111", glyph: "✓", picture: nil),
            face.starts(with: Data([0x89, 0x50, 0x4E, 0x47])), face.count > 500
        else { throw SelfTestFailure("the face plate is not a PNG") }
        guard
            let pictured = NotificationPlate.render(
                tone: "#E0A100", ink: "#111111", canvas: "#111111", glyph: "?", picture: face),
            pictured.starts(with: Data([0x89, 0x50, 0x4E, 0x47])), pictured.count > 500,
            pictured != face
        else { throw SelfTestFailure("a picture is not painted into the plate") }

        let words = NotificationPlate.wording(
            headline: "Needs approval", facts: ["Bash"], lines: ["rm -rf <build> && exit"])
        guard words.markup == "<b>Needs approval</b> · Bash\nrm -rf &lt;build&gt; &amp;&amp; exit",
            words.plain == "Needs approval · Bash\nrm -rf <build> && exit"
        else { throw SelfTestFailure("a body is not escaped for markup: \(words.markup)") }

        let drawn = FileReference(
            path: "/tmp/selftest/notice.png", mime: "image/png", filename: "notice.png")
        ImageCache.save(face, for: drawn)
        let now = Date()
        func message(_ id: String, _ role: MessageRole, _ kind: MessagePart.Kind) -> ChatMessage {
            ChatMessage(
                id: id, role: role, agentType: .claudeCode,
                parts: [MessagePart(id: id, kind: kind)], createdAt: now)
        }
        var state = ConversationState()
        state.messages = [
            message("ask", .user, .text("draw it")), message("shot", .assistant, .file(drawn)),
            message("done", .assistant, .text("Drew it.")),
        ]
        guard NotificationPlate.cachedPicture(in: state) == face else {
            throw SelfTestFailure("the picture the turn handed back is not in its notice")
        }
        state.messages.append(message("again", .user, .text("thanks")))
        state.messages.append(message("ok", .assistant, .text("Welcome.")))
        guard NotificationPlate.cachedPicture(in: state) == nil else {
            throw SelfTestFailure("an earlier turn's picture is in this turn's notice")
        }
        state.messages = [
            message("mine", .user, .file(drawn)), message("seen", .assistant, .text("Seen.")),
        ]
        guard NotificationPlate.cachedPicture(in: state) == nil else {
            throw SelfTestFailure("a picture the person attached is in the notice")
        }
        return 6
    }

    /// The share card is Core geometry painted through cairo: a demo ledger must yield words, a
    /// stable filename and a PNG whose signature is a real image, every awkward account must paint
    /// on every format at the size the format promises with ink in every panel, and the share
    /// window must offer the choices the person is owed — not a layout that only looks right once
    /// someone opens the panel by hand.
    static func checkAnalyticsShare() throws -> Int {
        guard
            let analytics = UsageAnalytics(
                servers: [("demo", DemoWorld.demoAnalytics())], missingServers: [])
        else { throw SelfTestFailure("demo analytics produced nothing to share") }
        let package = AnalyticsShare(analytics)
        guard package.plainText.contains(analytics.headline) else {
            throw SelfTestFailure("plain text lost the total")
        }
        guard package.markdown.contains(analytics.headline) else {
            throw SelfTestFailure("markdown lost the total")
        }
        guard package.filename.hasSuffix(".png"), package.filename.hasPrefix("tailscode-month-")
        else { throw SelfTestFailure("filename: \(package.filename)") }
        guard package.card.height > 400, AnalyticsShare.Card.width == 1080 else {
            throw SelfTestFailure("card geometry drifted")
        }
        let long = ShareSelection(format: .long, style: .midnight)
        guard let png = AnalyticsCardRenderer.png(package, selection: long, scale: 1), png.count > 800
        else { throw SelfTestFailure("renderer produced no PNG") }
        let signature = [UInt8](png.prefix(8))
        guard signature == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw SelfTestFailure("PNG signature missing")
        }
        let painted = try checkEveryFormatPaints()
        try checkShareDialog()
        try dumpShareCards()
        return 7 + painted
    }

    /// Every fixture account on every format: the picture is the size the format promises, the
    /// hero panel and every tile carry ink of their own, and the footer says what the numbers are.
    static func checkEveryFormatPaints() throws -> Int {
        var painted = 0
        for fixture in ShareFixtures.all() {
            let package = AnalyticsShare(
                fixture.analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
            for format in ShareFormat.allCases {
                let selection = ShareSelection(format: format, style: .midnight)
                let card = package.card(selection)
                guard let poster = AnalyticsCardRenderer.paint(card, scale: 1) else {
                    throw SelfTestFailure("\(fixture.name) cannot be painted as \(format)")
                }
                guard poster.width == Int(card.canvasWidth.rounded()),
                    poster.height == Int(card.height.rounded()),
                    card.canvasWidth == format.canvasWidth
                else { throw SelfTestFailure("\(fixture.name) \(format): wrong size") }
                if let height = format.canvasHeight, card.height != height {
                    throw SelfTestFailure("\(fixture.name) \(format): height \(card.height)")
                }
                let ground = poster.pixel(x: card.canvasWidth - 2, y: card.height / 2)
                for panel in card.panels {
                    let ink = poster.pixels(in: panel.content, notNear: ground)
                    guard ink > 40 else {
                        throw SelfTestFailure(
                            "\(fixture.name) \(format): the \(panel.module) panel is empty (\(ink))")
                    }
                }
                if let footer = card.footer {
                    guard poster.pixels(in: footer.rect, notNear: ground) > 20 else {
                        throw SelfTestFailure("\(fixture.name) \(format): the footer is empty")
                    }
                }
                guard let png = poster.png, png.count > 800 else {
                    throw SelfTestFailure("\(fixture.name) \(format): no PNG")
                }
                painted += 1
            }
        }
        return painted
    }

    /// The share window offers every format, a chip per module with the unavailable ones disabled
    /// and explained, and the picture follows what is pressed: a different format is a different
    /// canvas, a module switched off is a different picture, and a full poster refuses another.
    static func checkShareDialog() throws {
        guard gtk_init_check() != 0 else { return }
        Gtk.installStyle()
        guard let analytics = ShareFixtures.analytics(named: "localSessions") else {
            throw SelfTestFailure("the local-only fixture is missing")
        }
        let suite = UserDefaults.standard
        let rememberedFormat = suite.string(forKey: ShareFormat.storageKey)
        let rememberedModules = suite.string(forKey: ShareSelectionStore.modulesKey)
        let rememberedStyle = suite.string(forKey: CardStyleSelection.storageKey)
        defer {
            suite.set(rememberedFormat, forKey: ShareFormat.storageKey)
            suite.set(rememberedModules, forKey: ShareSelectionStore.modulesKey)
            suite.set(rememberedStyle, forKey: CardStyleSelection.storageKey)
            SettingsFile.capture()
        }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 900, 900)
        gtk_window_present(ptr(window))
        let dialog = ShareCardDialog.present(
            analytics, parent: ptr(window), selection: ShareSelection(format: .post))
        defer {
            dialog.close()
            gtk_window_destroy(ptr(window))
        }
        let drawn = brainPump(60) { dialog.hasPreview }
        guard drawn else { throw SelfTestFailure("the share window draws no picture") }
        guard dialog.offers.contains(Localized.text("Copy caption")),
            dialog.offers.contains(Localized.text("Save image…")),
            dialog.offers.contains(Localized.text("Copy card"))
        else { throw SelfTestFailure("the share window does not offer its ways out: \(dialog.offers)") }
        guard let first = dialog.previewSize, first.width * 9 == first.height * 16 || abs(Double(first.width) / Double(first.height) - 16.0 / 9.0) < 0.01
        else { throw SelfTestFailure("a post preview is not 16:9: \(String(describing: dialog.previewSize))") }
        guard !dialog.isEnabled(.tools), !dialog.isOn(.tools), dialog.isEnabled(.tokens),
            dialog.isOn(.local)
        else {
            throw SelfTestFailure("a module the account cannot fill is offered")
        }
        guard dialog.caption.hasPrefix(analytics.headline), dialog.altText.contains(analytics.windowLabel)
        else { throw SelfTestFailure("the caption or the description lost the headline") }
        let before = dialog.altText
        dialog.press(.tokens)
        guard !dialog.isOn(.tokens), dialog.altText != before else {
            throw SelfTestFailure("switching a module off changed nothing")
        }
        dialog.choose(.square)
        let followed = brainPump(60) { dialog.previewSize.map { $0.width == $0.height } ?? false }
        guard followed else {
            throw SelfTestFailure(
                "the preview did not follow the format: \(String(describing: dialog.previewSize))")
        }
        guard suite.string(forKey: ShareFormat.storageKey) == "square" else {
            throw SelfTestFailure("the format was not remembered")
        }
    }

    /// `TAILSCODE_SHARE_CARD_OUT=<dir>` writes the cards an agent can look at: every fixture account
    /// in every format and look, at one point per pixel (`TAILSCODE_SHARE_CARD_SCALE` to change
    /// it), named `<fixture>-<format>-<style>.png`. `TAILSCODE_SHARE_CARD_FIXTURES`,
    /// `_FORMATS` and `_STYLES` take comma lists to narrow it.
    static func dumpShareCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAILSCODE_SHARE_CARD_OUT"], !path.isEmpty else { return }
        func list(_ key: String) -> Set<String>? {
            environment[key].map { Set($0.split(separator: ",").map(String.init)) }
        }
        let fixtures = list("TAILSCODE_SHARE_CARD_FIXTURES")
        let formats = list("TAILSCODE_SHARE_CARD_FORMATS")
        let styles = list("TAILSCODE_SHARE_CARD_STYLES")
        let scale = environment["TAILSCODE_SHARE_CARD_SCALE"].flatMap(Double.init) ?? 1
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in ShareFixtures.all() where fixtures?.contains(fixture.name) ?? true {
            let package = AnalyticsShare(
                fixture.analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
            for format in ShareFormat.allCases where formats?.contains(format.rawValue) ?? true {
                for style in CardStyle.all where styles?.contains(style.id) ?? (style.id == CardStyleSelection.defaultStyle(for: format).id) {
                    let selection = ShareSelection(format: format, style: style)
                    guard let png = AnalyticsCardRenderer.png(package, selection: selection, scale: scale)
                    else { throw SelfTestFailure("\(fixture.name) \(format) \(style.id) cannot be painted") }
                    try png.write(
                        to: directory.appendingPathComponent(
                            "\(fixture.name)-\(format.rawValue)-\(style.id).png"))
                }
            }
        }
    }

    /// A month spent entirely on models that bill nothing is still a month, and a server whose
    /// ledger is one running total per conversation is not a server that measured zero. Both are
    /// asserted here because both fail silently: a chart of zeroes and a "0 turns" read as an
    /// account nobody used, which is exactly backwards.
    static func checkFreeLedger() throws -> Int {
        let tokens = SessionSpendReport.Tokens(input: 400_000, output: 60000)
        let report = UsageAnalyticsReport(
            since: Date(timeIntervalSinceNow: -30 * 86400), generatedAt: Date(), days: 30,
            totals: UsageAnalyticsReport.Totals(
                costUSD: 0, tokens: tokens, sessions: 9, activeDays: 1),
            daily: [
                UsageAnalyticsReport.Day(
                    day: Self.today(), costUSD: 0, tokens: tokens, sessions: 9)
            ],
            models: [
                SessionSpendReport.ModelShare(
                    model: "ollama/qwen3-coder:30b", turns: 0, tokens: tokens, costUSD: 0)
            ],
            coverage: .sessionTotals)
        guard let analytics = UsageAnalytics(servers: [("desktop · opencode", report)]) else {
            throw SelfTestFailure("a free month produced no analytics at all")
        }
        guard !analytics.headline.contains("$") else {
            throw SelfTestFailure("a month that cost nothing leads with money: \(analytics.headline)")
        }
        guard analytics.days.contains(where: { $0.share > 0 }) else {
            throw SelfTestFailure("every bar in a free month is flat")
        }
        guard analytics.models.first?.isFree == true, analytics.models.first?.share == 1 else {
            throw SelfTestFailure("a free model is drawn as an unused one")
        }
        guard analytics.localWork?.models.first?.money == "Local" else {
            throw SelfTestFailure("nothing says the work ran for nothing")
        }
        guard analytics.hours.isEmpty, analytics.tools.isEmpty else {
            throw SelfTestFailure("a section nobody could measure is drawn empty")
        }
        guard analytics.activityLine.contains("turns") == false else {
            throw SelfTestFailure("a turn count nobody took is stated as a fact")
        }
        guard analytics.coverageNote?.contains("desktop · opencode") == true else {
            throw SelfTestFailure("the machine that could not count is not named")
        }
        guard let png = AnalyticsCardRenderer.png(
                AnalyticsShare(analytics), selection: ShareSelection(format: .post, style: .midnight),
                scale: 1),
            png.count > 800
        else { throw SelfTestFailure("a free month cannot be shared") }
        return 8
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// The moving half of the same contract: work has to move, an answer the agent is waiting for
    /// has to move differently, and anything settled has to hold perfectly still — stillness is
    /// how a reader tells a stopped turn from a slow one. Asserted here rather than left to the
    /// eye, because a glyph that quietly stops breathing looks exactly like a session that ended.
    /// Work that is open moves — except work the server has found stuck, which is open (the process
    /// still holds the chat) and holds still on purpose, because stillness is how a reader tells
    /// a stopped task from a slow one.
    static func checkActivityMotion() throws {
        for kind in ActivityKind.everyState where kind.isInFlight {
            if case .stalled = kind {
                guard !kind.icon.motion.isAnimated else {
                    throw SelfTestFailure("\(kind) is stuck and moves anyway")
                }
                continue
            }
            guard kind.icon.motion.isAnimated else {
                throw SelfTestFailure("\(kind) is in flight and holds still")
            }
        }
        for kind in [ActivityKind.failed, .offline, .queued(2)] where kind.icon.motion.isAnimated {
            throw SelfTestFailure("\(kind) is settled and moves anyway")
        }
        guard ActivityKind.working.icon.motion != ActivityKind.needsApproval.icon.motion else {
            throw SelfTestFailure("a running turn and one waiting on the reader move alike")
        }
        for kind in ActivityKind.everyState
        where kind.icon.motion.honoring(reduceMotion: true) != .still {
            throw SelfTestFailure("\(kind) keeps moving when the desk asked for no motion")
        }
        let spread = stride(from: 0.0, to: ActivityTuning.sweepPeriod, by: 0.02)
            .map { ActivityKind.compacting.icon.glyph(at: $0) }
        guard Set(spread) == Set(ActivityIcon.sweepCycle) else {
            throw SelfTestFailure("a sweep does not reach every frame it owns")
        }
        guard SessionRowState.live.activity == .working,
            SessionRowState.idle.activity == nil
        else { throw SelfTestFailure("a row's state and its activity disagree") }
        guard SessionRowState.background(tasks: 1).activity == .inBackground(tasks: 1),
            SessionRowState.background(tasks: 1).isInFlight,
            ActivityKind.inBackground(tasks: 1).icon.motion.isAnimated
        else { throw SelfTestFailure("work carried between turns does not read as work") }
        guard SessionRowState.stalled(tasks: 1).activity == .stalled(tasks: 1),
            SessionRowState.stalled(tasks: 1).isInFlight,
            SessionRowState.stalled(tasks: 1).carriesBackgroundWork,
            ActivityKind.stalled(tasks: 1).icon.tone == .attention,
            !ActivityKind.stalled(tasks: 1).icon.motion.isAnimated
        else { throw SelfTestFailure("work the server found stuck does not read as stuck") }
    }
}
