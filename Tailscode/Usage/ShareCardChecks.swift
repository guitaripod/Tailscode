import MidgarCore
#if DEBUG
    import TailscodeCore
    import UIKit

    /// What `TAILSCODE_SHARE_CHECK=1` runs in the app: the claims the modular share makes, asserted
    /// against the real painter and the real share screen in the real process, one line a claim in
    /// the log (`share-check PASS|FAIL name detail`) and a total at the end. Every fixture account
    /// is painted in every format and looked at pixel by pixel, then the screen is driven the way a
    /// hand drives it. `TAILSCODE_SHARE_CARD_OUT=<dir>` also writes `<fixture>-<format>-<look>.png`
    /// for every fixture and format (`_FIXTURES`, `_FORMATS`, `_STYLES` narrow it, `_SCALE` sets the
    /// magnification), the names the Linux selftest dumps, so the desks can be compared side by side.
    @MainActor
    enum ShareCardChecks {
        private static var passed = 0
        private static var failed = 0

        static var isEnabled: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["TAILSCODE_SHARE_CHECK"] != nil
                || environment["TAILSCODE_SHARE_CARD_OUT"] != nil
        }

        private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            MidgarLog.info(
                "share-check \(condition ? "PASS" : "FAIL") \(name) \(condition ? "" : detail())",
                category: .ui
            )
        }

        static func run() async {
            passed = 0
            failed = 0
            let environment = ProcessInfo.processInfo.environment
            if environment["TAILSCODE_SHARE_CHECK"] != nil {
                paintEverything()
                scalesAndFiles()
                selectionStateMachine()
                await drivenScreen()
            }
            if let directory = environment["TAILSCODE_SHARE_CARD_OUT"], !directory.isEmpty {
                dump(to: directory, environment: environment)
            }
            MidgarLog.info("share-check done pass=\(passed) fail=\(failed)", category: .ui)
        }

        private static func package(_ analytics: UsageAnalytics) -> AnalyticsShare {
            AnalyticsShare(analytics, now: ShareFixtures.now, calendar: ShareFixtures.calendar)
        }

        private static func paintEverything() {
            for fixture in ShareFixtures.all() {
                let share = package(fixture.analytics)
                for format in ShareFormat.allCases {
                    let label = "\(fixture.name) \(format.rawValue)"
                    let selection = ShareSelection(format: format, style: .midnight)
                    let card = share.card(selection, dark: true)
                    let image = AnalyticsCardRenderer.image(card, scale: 1)
                    check(
                        "\(label) size",
                        Int(image.size.width) == Int(card.canvasWidth.rounded())
                            && Int(image.size.height) == Int(card.height.rounded())
                            && card.canvasWidth == format.canvasWidth
                            && (format.canvasHeight.map { $0 == card.height } ?? true),
                        "\(image.size) vs \(card.canvasWidth)x\(card.height)")
                    guard let pixels = Pixels(image) else {
                        check("\(label) readable", false, "no bitmap")
                        continue
                    }
                    let canvas = AnalyticsShare.Rect(0, 0, card.canvasWidth, card.height)
                    let inside = card.panels.allSatisfy { Self.contains(canvas, $0.rect) }
                        && (card.footer.map { Self.contains(canvas, $0.rect) } ?? true)
                    check("\(label) inside the canvas", inside)
                    check("\(label) no panel overflows", card.panels.allSatisfy(\.fits))
                    for panel in card.panels {
                        let ink = pixels.ink(in: panel.content, against: panel)
                        check("\(label) \(panel.module) not blank", ink > 40, "\(ink)")
                    }
                    if let footer = card.footer {
                        let ink = pixels.ink(in: footer.rect, groundAt: footer.rect.x - 4, y: footer.rect.y + 4)
                        check("\(label) footer not blank", ink > 20, "\(ink)")
                    }
                    if format != .long {
                        let margin = format == .post ? 44.0 : 40.0
                        let stray = pixels.strayInk(leftOf: margin - 10, rightOf: card.canvasWidth - margin + 10)
                        check("\(label) nothing in the margins", stray == 0, "\(stray)")
                    }
                    check(
                        "\(label) png",
                        (image.pngData().map { $0.count > 800 && [UInt8]($0.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] }) ?? false)
                }
            }
        }

        private static func contains(_ outer: AnalyticsShare.Rect, _ inner: AnalyticsShare.Rect) -> Bool {
            inner.x >= outer.x - 0.5 && inner.y >= outer.y - 0.5
                && inner.x + inner.width <= outer.x + outer.width + 0.5
                && inner.y + inner.height <= outer.y + outer.height + 0.5
        }

        private static func scalesAndFiles() {
            guard let rich = ShareFixtures.analytics(named: "rich") else {
                check("rich fixture", false, "missing")
                return
            }
            let share = package(rich)
            func card(_ format: ShareFormat) -> AnalyticsShare.Card {
                share.card(ShareSelection(format: format, style: .midnight), dark: true)
            }
            check(
                "the post rasterises at 2x on a 3x screen",
                AnalyticsCardRenderer.exportScale(for: card(.post), displayScale: 3) == 2)
            check(
                "a square keeps the screen's 3x",
                AnalyticsCardRenderer.exportScale(for: card(.square), displayScale: 3) == 3)
            check(
                "a 1x screen is never magnified",
                AnalyticsCardRenderer.exportScale(for: card(.portrait), displayScale: 1) == 1)
            let post = AnalyticsCardRenderer.png(
                share, selection: ShareSelection(format: .post, style: .aurora), dark: true,
                displayScale: 3)
            let measured = post.flatMap { UIImage(data: $0.data) }.map { ($0.size.width * $0.scale, $0.size.height * $0.scale) }
            check(
                "the post file is 3200x1800", measured?.0 == 3200 && measured?.1 == 1800,
                "\(String(describing: measured))")
            check("the file keeps Core's name", post?.filename == share.filename, post?.filename ?? "nil")
            let tallest = ShareFixtures.all().map { fixture in
                package(fixture.analytics).card(ShareSelection(format: .long, style: .midnight), dark: true)
            }.max { $0.height < $1.height }
            if let tallest {
                let scale = AnalyticsCardRenderer.exportScale(for: tallest, displayScale: 3)
                check(
                    "the tall column stays inside the bitmap budget",
                    tallest.height * scale <= AnalyticsCardRenderer.largestSide + 1,
                    "\(tallest.height * scale)")
            }
            let file = AnalyticsCardRenderer.temporaryFile(
                share, selection: ShareSelection(format: .square, style: .aurora), dark: true,
                displayScale: 2)
            check(
                "the staged file wears the suggested name",
                file?.lastPathComponent == share.filename
                    && file.flatMap { try? Data(contentsOf: $0) }.map { $0.count > 800 } == true)
        }

        private static func scratchDefaults() -> UserDefaults {
            let name = "tailscode.sharecheck"
            let defaults = UserDefaults(suiteName: name) ?? .standard
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        private static func selectionStateMachine() {
            guard let rich = ShareFixtures.analytics(named: "rich"),
                let noDaily = ShareFixtures.analytics(named: "noDaily")
            else {
                check("fixtures", false, "missing")
                return
            }
            var selection = ShareSelection(format: .post)
            let curated = ShareFormat.post.curated
            check("a post opens on its curated set", selection.fit(rich).shown == ShareModule.selectable.filter(curated.contains))
            check("a post at capacity says so", selection.fit(rich).isFull)
            let refused = selection.toggle(.activity, in: rich)
            check(
                "a fifth module is refused with Core's words",
                refused
                    == .refused(
                        Localized.text(
                            "%1$@ holds %2$d modules. Turn one off to add another.",
                            ShareFormat.post.title, 4)),
                "\(refused)")
            check("a refused press changes nothing", selection.fit(rich).shown.count == 4)
            check("a module comes off", selection.toggle(.models, in: rich) == .removed)
            check("then another goes on", selection.toggle(.activity, in: rich) == .added)
            check(
                "the choice is the new set",
                selection.fit(rich).shown == ShareModule.selectable.filter([.activity, .daily, .tokens, .records].contains),
                "\(selection.fit(rich).shown)")
            check(
                "the column keeps its own curated set",
                ShareSelection(format: .long).requested == ShareFormat.long.curated)
            let defaults = scratchDefaults()
            ShareSelectionStore.save(selection, defaults: defaults)
            let loaded = ShareSelectionStore.load(defaults: defaults)
            check(
                "the choice survives a round trip",
                loaded.format == selection.format && loaded.chosen == selection.chosen,
                "\(loaded.chosen)")
            check(
                "an untouched format wears its curated set after a round trip",
                loaded.requested == selection.requested && loaded.chosen[.long] == nil)
            var blocked = ShareSelection(format: .square)
            check(
                "a module the account cannot fill is blocked with its reason",
                blocked.fit(noDaily).state(of: .daily)
                    == .blocked(ShareModule.daily.unavailableReason(in: noDaily) ?? ""))
            check(
                "pressing it is refused",
                blocked.toggle(.daily, in: noDaily) == .refused(ShareModule.daily.unavailableReason(in: noDaily) ?? ""))
            let greedy = ShareSelection(
                format: .square, chosen: [.square: [.activity, .daily, .week, .models, .tokens, .records]])
            let fit = greedy.fit(rich)
            check(
                "a square asked for six holds four and names what it left out",
                fit.shown.count == 4 && fit.dropped.count == 2
                    && fit.note?.contains(fit.dropped.map(\.title).joined(separator: ", ")) == true,
                "\(fit.shown) \(fit.dropped) \(fit.note ?? "nil")")
        }

        private static func drivenScreen() async {
            guard let rich = ShareFixtures.analytics(named: "rich"),
                let noDaily = ShareFixtures.analytics(named: "noDaily")
            else { return }
            let defaults = UserDefaults.standard
            let keys = [ShareFormat.storageKey, ShareSelectionStore.modulesKey, CardStyleSelection.storageKey]
            let kept = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) }
            }
            let screen = ShareCardViewController(analytics: rich, selection: ShareSelection(format: .post))
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                check("a window scene to host the screen", false, "none")
                return
            }
            let host = UIWindow(windowScene: scene)
            host.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.rootViewController = UINavigationController(rootViewController: screen)
            host.makeKeyAndVisible()
            host.layoutIfNeeded()
            let drew = await until { screen.previewImage != nil }
            check("the screen draws a picture", drew)
            let aspect = screen.previewImage.map { $0.size.width / $0.size.height } ?? 0
            check("a post preview is 16:9", abs(aspect - 16.0 / 9.0) < 0.01, "\(aspect)")
            check(
                "the picture's description is the preview's label",
                screen.altText == screen.view.descendantLabelled(screen.altText), "")
            check(
                "the chips follow the choice",
                screen.isOn(.daily) && screen.isOn(.models) && !screen.isOn(.activity) && screen.isEnabled(.activity))
            screen.press(.activity)
            check("a refused chip says why", screen.noteText?.contains("4") == true, screen.noteText ?? "nil")
            check("a refused press leaves the chips alone", !screen.isOn(.activity) && screen.isOn(.models))
            screen.press(.models)
            screen.press(.activity)
            check("a chip goes off and another on", !screen.isOn(.models) && screen.isOn(.activity))
            check(
                "the screen remembers the choice",
                ShareSelectionStore.load().chosen[.post] == ShareModule.selectable.filter([.activity, .daily, .tokens, .records].contains))
            screen.choose(.long)
            let tall = await until {
                (screen.previewImage.map { $0.size.height > $0.size.width * 1.5 }) ?? false
            }
            check("the full-length preview is a tall column", tall)
            check("the format is remembered", ShareSelectionStore.load().format == .long)
            check("the format's look follows it", screen.selection.style.id == CardStyleSelection.current(for: .long).id)
            check("the caption is a post's length", screen.caption.count <= AnalyticsShare.captionLimit && !screen.caption.isEmpty)

            let thin = ShareCardViewController(analytics: noDaily, selection: ShareSelection(format: .post))
            thin.loadViewIfNeeded()
            check(
                "a chip the account cannot fill is disabled",
                !thin.isEnabled(.daily) && !thin.isOn(.daily) && thin.isEnabled(.models))
            host.isHidden = true
        }

        private static func until(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<60 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }

        private static func dump(to directory: String, environment: [String: String]) {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func list(_ key: String) -> Set<String>? {
                environment[key].map { Set($0.split(separator: ",").map(String.init)) }
            }
            let fixtures = list("TAILSCODE_SHARE_CARD_FIXTURES")
            let formats = list("TAILSCODE_SHARE_CARD_FORMATS")
            let styles = list("TAILSCODE_SHARE_CARD_STYLES")
            let scale = environment["TAILSCODE_SHARE_CARD_SCALE"].flatMap(Double.init).map { CGFloat($0) } ?? 2
            var written = 0
            for fixture in ShareFixtures.all() where fixtures?.contains(fixture.name) ?? true {
                let share = package(fixture.analytics)
                for format in ShareFormat.allCases where formats?.contains(format.rawValue) ?? true {
                    let looks =
                        styles.map { wanted in CardStyle.all.filter { wanted.contains($0.id) } }
                        ?? [CardStyleSelection.defaultStyle(for: format)]
                    for style in looks {
                        let card = share.card(ShareSelection(format: format, style: style), dark: true)
                        guard let data = AnalyticsCardRenderer.image(card, scale: scale).pngData() else {
                            check("dump \(fixture.name) \(format.rawValue)", false, "no png")
                            continue
                        }
                        let name = "\(fixture.name)-\(format.rawValue)-\(style.id).png"
                        do {
                            try data.write(to: folder.appendingPathComponent(name))
                            written += 1
                        } catch {
                            check("dump \(name)", false, "\(error)")
                        }
                    }
                }
            }
            MidgarLog.info("share-check dumped \(written) pictures to \(directory)", category: .ui)
        }
    }

    private extension UIView {
        func descendantLabelled(_ label: String) -> String? {
            if accessibilityLabel == label { return label }
            for view in subviews {
                if let found = view.descendantLabelled(label) { return found }
            }
            return nil
        }
    }

    /// A bitmap the checks can ask about: how much of a rectangle is ink rather than ground.
    private struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(_ image: UIImage) {
            guard let cg = image.cgImage else { return nil }
            let columns = cg.width
            let rows = cg.height
            var buffer = [UInt8](repeating: 0, count: columns * rows * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard
                    let context = CGContext(
                        data: raw.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                        bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: columns, height: rows))
                return true
            }
            guard drawn else { return nil }
            width = columns
            height = rows
            data = buffer
        }

        private func channels(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            let offset = (cy * width + cx) * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }

        private func differs(_ one: (Int, Int, Int), _ other: (Int, Int, Int), by tolerance: Int) -> Bool {
            abs(one.0 - other.0) > tolerance || abs(one.1 - other.1) > tolerance
                || abs(one.2 - other.2) > tolerance
        }

        func ink(in rect: AnalyticsShare.Rect, against panel: AnalyticsShare.Card.Panel) -> Int {
            ink(in: rect, groundAt: panel.rect.x + panel.inset / 2, y: rect.y + rect.height / 2)
        }

        func ink(in rect: AnalyticsShare.Rect, groundAt x: Double, y: Double) -> Int {
            let ground = channels(Int(x), Int(y))
            var count = 0
            let x0 = Int(rect.x), x1 = Int(rect.x + rect.width)
            let y0 = Int(rect.y), y1 = Int(rect.y + rect.height)
            for row in stride(from: max(0, y0), to: min(height, y1), by: 1) {
                for column in stride(from: max(0, x0), to: min(width, x1), by: 1)
                where differs(channels(column, row), ground, by: 40) {
                    count += 1
                }
            }
            return count
        }

        func strayInk(leftOf left: Double, rightOf right: Double) -> Int {
            var count = 0
            for row in stride(from: 0, to: height, by: 3) {
                let leftGround = channels(0, row)
                for column in stride(from: 1, to: Int(left), by: 2)
                where differs(channels(column, row), leftGround, by: 30) {
                    count += 1
                }
                let rightGround = channels(width - 1, row)
                for column in stride(from: Int(right), to: width - 1, by: 2)
                where differs(channels(column, row), rightGround, by: 30) {
                    count += 1
                }
            }
            return count
        }
    }
#endif
