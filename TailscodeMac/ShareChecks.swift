import AppKit
import TailscodeCore

/// What `--selftest` holds the usage share to on the Mac with no display and no server: every
/// fixture account painted on every format at Retina density with the size the format promises, ink
/// in every panel and nothing outside the panels and the footer; and the share sheet's own state
/// machine — its chips, its capacity sentence, what it remembers and the picture that follows what
/// is pressed. `TAILSCODE_SHARE_CARD_OUT=<dir>` writes the pictures for looking at, named like
/// Linux's (`<fixture>-<format>-<style>.png`), with `_SCALE`, `_FIXTURES`, `_FORMATS` and `_STYLES`
/// to narrow them.
@MainActor
enum ShareChecks {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("share check failed: \(label)") }
            checks += 1
        }
        guard
            let analytics = UsageAnalytics(
                servers: [("demo", DemoWorld.demoAnalytics())], missingServers: [])
        else { throw SelfTestFailure("demo analytics produced nothing to share") }
        let package = AnalyticsShare(analytics)
        try expect(package.plainText.contains(analytics.headline), "plain text keeps the total")
        try expect(package.markdown.contains(analytics.headline), "markdown keeps the total")
        try expect(
            package.filename.hasSuffix(".png") && package.filename.hasPrefix("tailscode-month-"),
            "filename \(package.filename)")
        try expect(package.card.height > 400 && AnalyticsShare.Card.width == 1080, "card geometry")
        let long = ShareSelection(format: .long, style: .midnight)
        let sample = AnalyticsCardRenderer.png(package, selection: long, scale: 1, dark: true)
        try expect(
            sample.map { [UInt8]($0.prefix(8)) == pngSignature && $0.count > 800 } ?? false,
            "the full-length card is a PNG")
        checks += try paintEveryFormat()
        checks += try await driveSheet()
        try dump()
        return checks
    }

    private static func inset(_ rect: AnalyticsShare.Rect, by amount: Double) -> AnalyticsShare.Rect {
        AnalyticsShare.Rect(
            rect.x - amount, rect.y - amount, rect.width + amount * 2, rect.height + amount * 2)
    }

    private static func contains(_ rect: AnalyticsShare.Rect, _ x: Double, _ y: Double) -> Bool {
        x >= rect.x && x <= rect.maxX && y >= rect.y && y <= rect.maxY
    }

    private static func channels(_ hex: String) -> (red: Int, green: Int, blue: Int) {
        let rgb = Contrast.channels(hex) ?? (0.5, 0.5, 0.5)
        return (Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded()))
    }

    /// Every fixture account on every format at 2x: the bitmap is twice the format's size and the
    /// PNG says so, every panel carries ink over its own ground, the footer says something, and no
    /// pixel outside the panels and the footer differs from the bare canvas.
    private static func paintEveryFormat() throws -> Int {
        var checks = 0
        for fixture in ShareFixtures.all() {
            let package = AnalyticsShare(
                fixture.analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
            for format in ShareFormat.allCases {
                let label = "\(fixture.name) \(format.rawValue)"
                let card = package.card(ShareSelection(format: format, style: .midnight), dark: true)
                guard let poster = AnalyticsCardRenderer.paint(card, scale: 2),
                    let bare = AnalyticsCardRenderer.paint(card, scale: 2, panels: false)
                else { throw SelfTestFailure("\(label) cannot be painted") }
                let wide = Int(card.canvasWidth.rounded())
                let tall = Int((card.height * 2).rounded())
                guard card.canvasWidth == format.canvasWidth, poster.width == wide * 2,
                    poster.height == tall,
                    poster.logicalSize == NSSize(width: CGFloat(wide), height: CGFloat(tall) / 2)
                else { throw SelfTestFailure("\(label): wrong size \(poster.width)x\(poster.height)") }
                if let height = format.canvasHeight, card.height != height {
                    throw SelfTestFailure("\(label): height \(card.height)")
                }
                let everything = AnalyticsShare.Rect(0, 0, card.canvasWidth, card.height)
                var covered: [AnalyticsShare.Rect] = []
                for panel in card.panels {
                    guard panel.rect.x >= 0, panel.rect.y >= 0, panel.rect.maxX <= everything.maxX + 0.5,
                        panel.rect.maxY <= everything.maxY + 0.5
                    else { throw SelfTestFailure("\(label): the \(panel.module) panel leaves the canvas") }
                    let ink: Int
                    if panel.surface == .raised {
                        ink = poster.pixels(in: panel.content, notNear: channels(card.palette.raised))
                    } else {
                        ink = poster.pixels(in: panel.content, differingFrom: bare)
                    }
                    guard ink > 40 else {
                        throw SelfTestFailure("\(label): the \(panel.module) panel is blank (\(ink))")
                    }
                    covered.append(inset(panel.rect, by: 2))
                }
                if let footer = card.footer {
                    let ink = poster.pixels(in: footer.rect, differingFrom: bare)
                    guard ink > 20 else { throw SelfTestFailure("\(label): the footer is blank") }
                    covered.append(inset(footer.rect, by: 4))
                }
                let strays = stray(poster: poster, bare: bare, card: card, covered: covered)
                guard strays == 0 else {
                    throw SelfTestFailure("\(label): \(strays) samples painted outside every panel")
                }
                guard let png = poster.png, [UInt8](png.prefix(8)) == pngSignature,
                    let rep = NSBitmapImageRep(data: png), rep.pixelsWide == wide * 2,
                    rep.pixelsHigh == tall, rep.size == poster.logicalSize
                else { throw SelfTestFailure("\(label): the PNG is not \(wide * 2)x\(tall) at 2x") }
                checks += 1
            }
        }
        return checks
    }

    /// Samples the canvas on a grid of three points and counts those outside `covered` where the
    /// picture is not the bare canvas: text or a bar that escaped the panel it was clipped to.
    private static func stray(
        poster: AnalyticsCardRenderer.Poster, bare: AnalyticsCardRenderer.Poster, card: AnalyticsShare.Card,
        covered: [AnalyticsShare.Rect]
    ) -> Int {
        var count = 0
        var y = 0.5
        while y < card.height {
            var x = 0.5
            while x < card.canvasWidth {
                if !covered.contains(where: { contains($0, x, y) }) {
                    let here = poster.pixel(x: x, y: y)
                    let there = bare.pixel(x: x, y: y)
                    if abs(here.red - there.red) > 2 || abs(here.green - there.green) > 2
                        || abs(here.blue - there.blue) > 2
                    {
                        count += 1
                    }
                }
                x += 3
            }
            y += 3
        }
        return count
    }

    /// The sheet as a person drives it, on the account that has nothing for the tools chip: the
    /// chips, the reasons, the capacity sentence and which module it names, what is remembered, and
    /// a picture that follows the format and the modules. Laid out narrow and wide, nothing the sheet
    /// holds leaves it.
    private static func driveSheet() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("share sheet failed: \(label)") }
            checks += 1
        }
        let name = "tailscode.selftest.share"
        guard let suite = UserDefaults(suiteName: name) else {
            throw SelfTestFailure("no defaults suite for the share sheet")
        }
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }
        guard let sessions = ShareFixtures.analytics(named: "localSessions"),
            let rich = ShareFixtures.analytics(named: "rich")
        else { throw SelfTestFailure("the share fixtures are missing") }

        let panel = ShareCardPanel(
            analytics: sessions, selection: ShareSelection(format: .post), defaults: suite)
        await panel.settle()
        let first = panel.drawn
        try expect(first?.logicalSize == NSSize(width: 1600, height: 900), "a post preview is 1600x900")
        try expect(panel.content.previewSize == NSSize(width: 1600, height: 900), "the preview is on the sheet")
        try expect(
            !panel.content.isChipEnabled(.tools) && !panel.content.isChipOn(.tools)
                && panel.content.isChipEnabled(.models),
            "a module the account cannot fill is dimmed and one it can is on offer")
        try expect(
            panel.content.chipHelp(.tools) == ShareModule.tools.unavailableReason(in: sessions),
            "the reason is the chip's help")
        try expect(panel.caption.hasPrefix(sessions.headline), "the caption leads with the headline")
        try expect(panel.caption.count <= 280, "the caption fits a post")
        try expect(panel.altText.contains(sessions.windowLabel), "the description names the window")
        try expect(panel.content.previewDescription == panel.altText, "the preview wears the description")
        try expect(
            panel.content.buttonTitles == [
                Localized.text("Copy caption"), Localized.text("Copy image"),
                Localized.text("Save as…"), Localized.text("Share"),
            ], "the sheet offers its four ways out")

        let before = panel.altText
        panel.press(.models)
        try expect(!panel.content.isChipOn(.models) && panel.altText != before, "a chip switches its module")
        let saved = ShareSelectionStore.load(defaults: suite)
        try expect(
            saved.format == .post && saved.chosen[.post] == panel.selection.chosen[.post]
                && !(saved.chosen[.post] ?? []).contains(.models),
            "a switched module is remembered")
        panel.choose(.square)
        await panel.settle()
        try expect(
            panel.drawn?.logicalSize == NSSize(width: 1080, height: 1080),
            "the picture follows the format")
        try expect(suite.string(forKey: ShareFormat.storageKey) == "square", "the format is remembered")
        let reopened = ShareCardPanel(analytics: sessions, defaults: suite)
        try expect(
            reopened.selection.format == .square
                && reopened.selection.chosen[.post] == panel.selection.chosen[.post],
            "a sheet opened again wears the choice")
        panel.pick(.paper)
        try expect(suite.string(forKey: CardStyleSelection.storageKey) == CardStyle.paper.id, "the look is remembered")
        await panel.settle()
        let paper = panel.drawn?.pixel(x: 4, y: 4)
        panel.pick(.midnight)
        await panel.settle()
        let midnight = panel.drawn?.pixel(x: 4, y: 4)
        try expect(paper.map { $0.red } != midnight.map { $0.red }, "the look redraws the picture")

        let full = ShareCardPanel(
            analytics: rich, selection: ShareSelection(format: .post), defaults: suite)
        await full.settle()
        let shown = full.fit.shown
        try expect(shown.count == ShareFormat.post.capacity, "a full poster shows its capacity")
        let spare = ShareModule.selectable.first { !shown.contains($0) && $0.isAvailable(in: rich) }
        guard let spare else { throw SelfTestFailure("the rich account has no module to refuse") }
        let fullSentence = Localized.text(
            "%1$@ holds %2$d modules. Turn one off to add another.", ShareFormat.post.title,
            ShareFormat.post.capacity ?? 0)
        try expect(
            !full.content.isChipEnabled(spare) && full.content.chipHelp(spare) == fullSentence,
            "a full poster dims what would not fit and says why")
        full.press(spare)
        try expect(
            full.note == fullSentence && !full.content.isChipOn(spare),
            "pressing past capacity changes nothing and says so")
        full.press(shown[0])
        try expect(full.content.isChipEnabled(spare) && full.note == nil, "making room reopens the chips")

        let many = ShareSelection(
            format: .post, chosen: [.post: [.activity, .daily, .week, .models, .tokens, .records]])
        let crowded = ShareCardPanel(analytics: rich, selection: many, defaults: suite)
        let dropped = crowded.fit.dropped
        try expect(
            !dropped.isEmpty && dropped.allSatisfy { crowded.note?.contains($0.title) == true },
            "a format at capacity says which modules it dropped")

        for width in [480.0, 760.0] {
            crowded.content.frame = NSRect(x: 0, y: 0, width: width, height: 640)
            crowded.content.layoutSubtreeIfNeeded()
            await crowded.settle()
            crowded.content.layoutSubtreeIfNeeded()
            let bounds = crowded.content.bounds
            try expect(
                crowded.content.chipFrames.allSatisfy { bounds.contains($0) },
                "every chip is inside the sheet at \(Int(width)) wide")
            try expect(
                bounds.contains(crowded.content.previewFrame)
                    && crowded.content.previewFrame.height > 40,
                "the picture is inside the sheet at \(Int(width)) wide")
        }
        return checks
    }

    private static func dump() throws {
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
                for style in CardStyle.all
                where styles?.contains(style.id) ?? (style.id == CardStyleSelection.defaultStyle(for: format).id) {
                    let selection = ShareSelection(format: format, style: style)
                    guard
                        let png = AnalyticsCardRenderer.png(
                            package, selection: selection, scale: CGFloat(scale), dark: true)
                    else { throw SelfTestFailure("\(fixture.name) \(format) \(style.id) cannot be painted") }
                    try png.write(
                        to: directory.appendingPathComponent(
                            "\(fixture.name)-\(format.rawValue)-\(style.id).png"))
                }
            }
        }
    }
}
