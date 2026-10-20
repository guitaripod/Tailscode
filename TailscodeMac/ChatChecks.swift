import AppKit
import CodingAgentKit
import TailscodeCore

/// The compact chat's logic and its views, checked headlessly from `--selftest`: how every row kind
/// is spaced, when a rail arrives and what it says at every stage of its fetches, where its plate
/// goes, how pictures wrap into a strip and when the plate opens and closes. The looks are checked
/// with `--open` and `--shot`; these are the claims a screenshot cannot make.
@MainActor
enum ChatChecks {
    nonisolated static let spec = "chat-check"

    /// The child's side: both halves of the checks under a running application, where AppKit lays
    /// views out on the real main thread and a suspension resumes on it.
    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var failures: [String] = []
            var notes: [String] = []
            do {
                notes.append("\(try runLayout()) layout")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try await runFetches()) fetch")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try BrainChecks.run()) neural trace")
            } catch {
                failures.append("\(error)")
            }
            do {
                notes.append("\(try await BrainChecks.runPoster()) poster")
            } catch {
                failures.append("\(error)")
            }
            print("CHAT_NOTES \(notes.joined(separator: " + "))")
            print(failures.isEmpty ? "CHAT_OK" : "CHAT_FAILED \(failures.joined(separator: " · "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    /// The selftest's side: begun at once so the child runs beside the rest of the selftest, and
    /// read with a blocking wait for the reason `TileChecks.Child` gives — under `--selftest` a
    /// suspension can resume the main queue on another thread, and AppKit refuses a layout engine
    /// touched from two threads.
    final class Child {
        private let process = Process()
        private let pipe = Pipe()
        private var startFailure: String?

        init() {
            guard let executable = Bundle.main.executablePath else {
                startFailure = "no executable path"
                return
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--bench", ChatChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the check: \(error)"
            }
        }

        func verdict(timeout: TimeInterval = 60) -> (failures: [String], notes: String) {
            if let startFailure { return ([startFailure], "") }
            let deadline = Date().addingTimeInterval(timeout)
            let pid = process.processIdentifier
            var exited = false
            while !exited, Date() < deadline {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                exited = reaped == pid || reaped == -1
                if !exited { usleep(50_000) }
            }
            if !exited {
                kill(pid, SIGKILL)
                return (["the check did not finish in \(Int(timeout)) s"], "")
            }
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            let notes = lines.last { $0.hasPrefix("CHAT_NOTES ") }
                .map { String($0.dropFirst("CHAT_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "CHAT_OK" || $0.hasPrefix("CHAT_FAILED") })
            else { return (["the check printed no verdict"], notes) }
            return (
                verdict == "CHAT_OK" ? [] : [String(verdict.dropFirst("CHAT_FAILED ".count))],
                notes
            )
        }
    }

    /// The claims that need a window and a layout pass.
    static func runLayout() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("compact chat: \(label)") }
            checks += 1
        }
        try spacing(expect)
        try settling(expect)
        try placement(expect)
        try strips(expect)
        try galleries(expect)
        try timing(expect)
        try column(expect)
        try quietLines(expect)
        try promptFocus(expect)
        try replacedRows(expect)
        try chrome(expect)
        try railViews(expect)
        return checks
    }

    /// The claims about what a rail learns and when: stubbed pages, no network, no layout.
    static func runFetches() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("compact chat: \(label)") }
            checks += 1
        }
        try await fetches(expect)
        return checks
    }

    private static var windows: [NSWindow] = []

    /// A view laid out with no window builds a throwaway constraint engine on every pass, which a
    /// harness off the main thread may not do; one inside a window that is never shown has the
    /// window's engine, and is what the transcript's own harnesses lay their rows out in.
    private static func stage(_ root: NSView) {
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        windows.append(window)
    }

    private static let compact = ChatMetrics.metrics(for: .compact, input: .pointer)
    private static let comfortable = ChatMetrics.metrics(for: .comfortable, input: .pointer)

    private static func gap(_ a: ChatRowSpacing?, _ b: ChatRowSpacing, _ metrics: ChatMetrics) -> CGFloat {
        ChatLayout.gap(from: a, to: b, metrics: metrics)
    }

    private static func sampleKinds() -> [(String, TranscriptRow.Kind, ChatRowSpacing)] {
        let call = ToolCall(id: "t", name: "Read", status: .completed)
        let picture = FileReference(path: "/a.png", mime: "image/png", filename: "a.png")
        let failure = FailedTurnReading.read(
            ChatMessage(
                id: "a", role: .assistant, agentType: .claudeCode, parts: [],
                createdAt: Date(timeIntervalSince1970: 1), error: "overloaded"), prompt: nil)!
        return [
            ("prompt", .userText("hi", messageID: "u"), .row(.prompt)),
            ("agent prose", .agentProse(text: "x", rendered: NSAttributedString(string: "x")), .row(.prose)),
            ("code", .codeBlock(language: nil, body: "x"), .row(.code)),
            ("rail", .linkRail(urls: ["https://a.example"]), .row(.rail)),
            ("tool", .tool(call), .row(.furniture)),
            ("run", .run([.tool(key: "k", call)]), .row(.furniture)),
            ("thought", .reasoning("hm"), .row(.furniture)),
            ("note", .interruption, .row(.furniture)),
            ("agent picture", .file(picture, mine: false, messageID: "m"), .row(.picture)),
            ("sent picture", .file(picture, mine: true, messageID: "m"), .row(.prompt)),
            ("subagent", .subagent(call), .row(.furniture)),
            ("agent group", .subagentGroup(SubagentFanout(id: "g", members: [])), .row(.furniture)),
            ("workflow", .workflow(call), .row(.code)),
            ("failed turn", .failedTurn(failure), .row(.code)),
            ("turn break", .turnBreak, .turnBreak),
        ]
    }

    private static func spacing(_ expect: (Bool, String) throws -> Void) throws {
        for (name, kind, expected) in sampleKinds() {
            try expect(ChatLayout.spacing(of: kind) == expected, "\(name) is spaced as \(expected)")
        }
        let prose = ChatRowSpacing.row(.prose)
        let tool = ChatRowSpacing.row(.furniture)
        try expect(gap(nil, prose, compact) == 0, "nothing stands above the first row")
        try expect(gap(prose, prose, compact) == 8, "paragraph to paragraph is 8")
        try expect(gap(prose, tool, compact) == 4 && gap(tool, prose, compact) == 4, "prose beside a line is 4 either way")
        try expect(gap(tool, tool, compact) == 2, "two lines sit 2 apart")
        try expect(gap(prose, .row(.code), compact) == 6, "prose to code is 6")
        try expect(gap(.row(.picture), .row(.picture), compact) == 8, "pictures in a strip are 8 apart")
        try expect(gap(prose, .row(.picture), compact) == 6, "prose to a picture is 6")
        try expect(gap(prose, .row(.prompt), compact) == 16, "a prompt is set off by the turn gap")
        try expect(
            gap(prose, .turnBreak, compact) + gap(.turnBreak, .row(.prompt), compact) == 16,
            "the turn break splits the turn gap around its rule")
        let rule = RowKit.hairline(verticalPadding: ChatLayout.turnBreakPadding)
        stage(rule)
        rule.layoutSubtreeIfNeeded()
        try expect(
            abs(rule.fittingSize.height - ChatLayout.turnBreakRowHeight) < 0.5,
            "the turn break's own row is \(rule.fittingSize.height) tall, not \(ChatLayout.turnBreakRowHeight)")
        try expect(
            gap(prose, .turnBreak, compact) + gap(.turnBreak, .row(.prompt), compact)
                + rule.fittingSize.height <= 22,
            "a turn costs the table's gap and its rule — about twenty — not forty")
        try expect(gap(tool, prose, comfortable) == 12, "comfortable keeps the pointer's own 12")
        try expect(
            gap(.row(.prompt), .row(.prose), compact) == 8,
            "a prompt is the heading of its answer, so the answer sits at the paragraph gap")
        for upper in ChatRowClass.allCases {
            for lower in ChatRowClass.allCases {
                if upper != .prompt && lower != .prompt {
                    try expect(
                        gap(.row(upper), .row(lower), compact) == gap(.row(lower), .row(upper), compact),
                        "the air between \(upper) and \(lower) is the same either way round")
                }
                try expect(
                    gap(.row(upper), .row(lower), compact) <= gap(.row(upper), .row(lower), comfortable),
                    "compact is never airier than comfortable for \(upper) over \(lower)")
            }
        }
    }

    private static func message(_ id: String, _ role: MessageRole, _ parts: [MessagePart]) -> ChatMessage {
        ChatMessage(
            id: id, role: role, agentType: .claudeCode, parts: parts, createdAt: Date(timeIntervalSince1970: 1))
    }

    private static func settling(_ expect: (Bool, String) throws -> Void) throws {
        try expect(
            LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: true, turnIsOpen: true),
            "a run closed by a tool is settled while the turn runs")
        try expect(
            !LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: true),
            "the end of an open turn is not")
        try expect(
            LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: false),
            "the end of a finished turn is")
        try expect(
            !LinkRailPolicy.isSettled(lastRowIsLive: true, followedByFurniture: true, turnIsOpen: false),
            "a row still being written is never settled")

        let words = [
            "See https://a.example/1 and https://a.example/1 then https://b.example today",
            "More at https://c.example and https://d.example/x for the rest",
        ]
        let reply = message(
            "a", .assistant,
            [
                MessagePart(id: "p1", kind: .text(words[0])),
                MessagePart(id: "p2", kind: .tool(ToolCall(id: "t", name: "Read", status: .completed))),
                MessagePart(id: "p3", kind: .text(words[1])),
            ])
        let ask = message("u", .user, [MessagePart(id: "q", kind: .text("go"))])
        let kept = UserDefaults.standard.object(forKey: LinkEmbedsSetting.defaultsKey)
        defer {
            if let kept {
                UserDefaults.standard.set(kept, forKey: LinkEmbedsSetting.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LinkEmbedsSetting.defaultsKey)
            }
        }
        UserDefaults.standard.set(true, forKey: LinkEmbedsSetting.defaultsKey)
        let builder = TranscriptRowBuilder()
        func rails(_ rows: [TranscriptRow]) -> [[String]] {
            rows.compactMap { row in
                if case .linkRail(let urls) = row.kind { return urls }
                return nil
            }
        }
        let running = builder.rows(for: [ask, reply], turnOpen: true)
        try expect(
            rails(running) == [["https://a.example/1", "https://b.example"]],
            "while the turn runs only the run a tool closed has its rail: \(rails(running))")
        let finished = builder.rows(for: [ask, reply], turnOpen: false)
        try expect(
            rails(finished) == [
                ["https://a.example/1", "https://b.example"],
                ["https://c.example", "https://d.example/x"],
            ], "the turn ending lets the last run's rail arrive: \(rails(finished))")
        let again = builder.rows(for: [ask, reply], turnOpen: false)
        try expect(again == finished, "a memoised rebuild is the same rows")
        let order = finished.map(\.key)
        try expect(Set(order).count == order.count, "every row, rails included, has its own key")
        guard let firstRail = finished.firstIndex(where: { $0.isLinkRail }),
            case .agentProse = finished[firstRail - 1].kind
        else { throw SelfTestFailure("compact chat: a rail docks directly under the prose of its run") }
        try expect(true, "a rail docks directly under the prose of its run")
        try expect(
            finished[firstRail].streamedText == nil && !finished[firstRail].isPromptBlock
                && finished[firstRail].searchText.hasPrefix("http"),
            "a rail streams nothing, is not the prompt and searches by its addresses")

        let streaming = TranscriptRow.rows(for: reply, sealed: false)
        try expect(
            rails(streaming).count == 1, "a message still being written never carries the rail of its tail")

        let many = (1...15).map { "https://h\($0).example" }.joined(separator: " ")
        let long = message("l", .assistant, [MessagePart(id: "p", kind: .text("Links: \(many)"))])
        try expect(
            rails(builder.rows(for: [ask, long], turnOpen: false)).first?.count == LinkRailPolicy.limit,
            "a rail holds at most the policy's twelve addresses")

        UserDefaults.standard.set(false, forKey: LinkEmbedsSetting.defaultsKey)
        try expect(
            rails(builder.rows(for: [ask, reply], turnOpen: false)).isEmpty,
            "with link previews off there is no rail at all")
        UserDefaults.standard.set(true, forKey: LinkEmbedsSetting.defaultsKey)
        try expect(
            rails(builder.rows(for: [ask, reply], turnOpen: false)).count == 2,
            "turning them back on rebuilds the rails")
    }

    private static func placement(_ expect: (Bool, String) throws -> Void) throws {
        try expect(LinkRailPlate.opensUpward(roomBelow: 100, plateHeight: 288), "little room below opens upward")
        try expect(!LinkRailPlate.opensUpward(roomBelow: 400, plateHeight: 288), "enough room opens downward")
        try expect(
            LinkRailPlate.plateHeight(rows: 3, metrics: compact) == 108
                && LinkRailPlate.plateHeight(rows: 12, metrics: compact) == 288,
            "the plate is three rows tall for three and eight rows for twelve")
        let rail = NSRect(x: 40, y: 500, width: 200, height: 24)
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 900)
        let size = NSSize(width: 440, height: 144)
        let flippedDown = RailPlacement.frame(rail: rail, plateSize: size, bounds: bounds, flipped: true, upward: false)
        let flippedUp = RailPlacement.frame(rail: rail, plateSize: size, bounds: bounds, flipped: true, upward: true)
        try expect(
            flippedDown.minY == rail.maxY + RailPlacement.seam
                && flippedUp.maxY == rail.minY - RailPlacement.seam,
            "in a flipped view down is below the rail and up is above it")
        let plainDown = RailPlacement.frame(rail: rail, plateSize: size, bounds: bounds, flipped: false, upward: false)
        let plainUp = RailPlacement.frame(rail: rail, plateSize: size, bounds: bounds, flipped: false, upward: true)
        try expect(
            plainDown.maxY == rail.minY - RailPlacement.seam
                && plainUp.minY == rail.maxY + RailPlacement.seam,
            "in an unflipped view the same sides are the other way round")
        let edge = RailPlacement.frame(
            rail: NSRect(x: 700, y: 100, width: 80, height: 24), plateSize: size, bounds: bounds, flipped: true,
            upward: false)
        try expect(edge.maxX <= bounds.maxX, "a plate near the right edge is held inside the view")
        try expect(
            RailPlacement.roomBelow(rail: rail, visible: NSRect(x: 0, y: 0, width: 800, height: 700), bottomInset: 80, flipped: true)
                == 700 - 80 - 524,
            "the room below stops where the composer's glass begins")
    }

    private static func strips(_ expect: (Bool, String) throws -> Void) throws {
        let sizes = [CGSize(width: 260, height: 180), CGSize(width: 260, height: 160), CGSize(width: 260, height: 180), CGSize(width: 400, height: 120)]
        let slots = PictureFlow.slots(sizes: sizes, available: 900, gap: 8)
        try expect(
            slots.map(\.line) == [0, 0, 0, 1] && slots.map(\.x) == [0, 268, 536, 0],
            "three pictures share a line and the fourth wraps: \(slots)")
        try expect(slots[3].y == 188, "the next line starts under the tallest picture of the last")
        let lone = PictureFlow.slots(sizes: [CGSize(width: 1200, height: 100), CGSize(width: 100, height: 100)], available: 900, gap: 8)
        try expect(lone.map(\.line) == [0, 1], "a picture wider than the line takes a line of its own")
        let wide = PictureThumb.size(pixels: CGSize(width: 1180, height: 820), maxHeight: 180, maxWidth: 600)
        try expect(wide.height == 180 && wide.width == 259, "a landscape screenshot becomes 259 × 180: \(wide)")
        let tall = PictureThumb.size(pixels: CGSize(width: 300, height: 900), maxHeight: 180, maxWidth: 600)
        try expect(tall.height == 180 && tall.width == 60, "a portrait one is as tall as the bound: \(tall)")
        let small = PictureThumb.size(pixels: CGSize(width: 90, height: 60), maxHeight: 180, maxWidth: 600)
        try expect(small.width == 90 && small.height == 60, "a picture is never enlarged past its pixels")
        let panorama = PictureThumb.size(pixels: CGSize(width: 6000, height: 400), maxHeight: 180, maxWidth: 600)
        try expect(panorama.width == 600, "a panorama stops at the widest")
    }

    /// The pictures an agent made rest as one gallery square, and a picture the person sent stays
    /// where it is: consecutive agent pictures gather under the first one's key, a person's own and
    /// a document break the run, and the square is a picture tall.
    private static func galleries(_ expect: (Bool, String) throws -> Void) throws {
        func picture(_ name: String) -> FileReference {
            FileReference(path: "/tmp/\(name)", mime: "image/png", filename: name)
        }
        let rows: [TranscriptRow] = [
            TranscriptRow(key: "m:a", kind: .file(picture("a.png"), mine: false, messageID: "m")),
            TranscriptRow(key: "m:b", kind: .file(picture("b.png"), mine: false, messageID: "m")),
            TranscriptRow(key: "m:t", kind: .reasoning("between")),
            TranscriptRow(key: "m:mine", kind: .file(picture("mine.png"), mine: true, messageID: "m")),
            TranscriptRow(key: "m:c", kind: .file(picture("c.png"), mine: false, messageID: "m")),
        ]
        let gathered = TranscriptRow.gallery(rows)
        let described = gathered.map { row -> String in
            switch row.kind {
            case .pictures(let pictures): return "gallery:" + pictures.map(\.key).joined(separator: ",")
            case .file: return "file"
            default: return "other"
            }
        }
        try expect(
            described == ["gallery:m:a,m:b", "other", "file", "gallery:m:c"],
            "consecutive agent pictures gather, a person's own does not: \(described)")
        try expect(
            gathered[0].key == "m:a", "a gallery keeps the key of its first picture")
        try expect(TranscriptRow.gallery(gathered) == gathered, "gathering is idempotent")
        let side = PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: ImagePreview.deskWidth)
        let sheet = PictureGalleryLayout.grid(count: 10, side: side, available: 420)
        try expect(
            sheet.tiles.count == 10 && sheet.hidden == 0 && sheet.height <= side + 0.001
                && Set(sheet.tiles.map(\.y)) == [0, 91],
            "ten pictures in a row are a grid of two rows, one picture tall: \(sheet.tiles.count) tiles, \(sheet.height) tall")
        let crowded = PictureGalleryLayout.grid(count: 26, side: side, available: 420)
        try expect(
            crowded.hidden > 0 && crowded.tiles.count + crowded.hidden == 26,
            "a grid takes the columns it can and counts the rest: \(crowded.tiles.count) + \(crowded.hidden)")
        try expect(
            PictureGalleryReading.spoken(count: 2, names: ["a.png", "b.png"]) == "2 pictures, a.png, b.png",
            "the gallery says how many pictures it holds and which")
        try galleryPixels(expect)
    }

    /// The gallery as it is drawn, out of the view and into pixels: the tiles show the inks they
    /// were handed, the corner darkens over the pictures it cannot draw and counts them, a press
    /// lands on the picture under it rather than on the group's first, and a lone picture keeps its
    /// own shape instead of being cropped.
    private static func galleryPixels(_ expect: (Bool, String) throws -> Void) throws {
        func swatch(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
        }
        func picture(
            _ name: String, _ color: NSColor, pixels: NSSize = NSSize(width: 64, height: 64)
        ) -> (TranscriptRow.GalleryPicture, NSColor) {
            let key = "gallery-check:\(name)"
            ImageStore.shared.store(
                DecodedImage(
                    image: swatch(color), data: Data(),
                    pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height)),
                forKey: key)
            return (
                TranscriptRow.GalleryPicture(
                    key: key,
                    reference: FileReference(path: "/tmp/\(name)", mime: "image/png", filename: name)),
                color
            )
        }
        let inks: [NSColor] = [
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1),
            NSColor(srgbRed: 0.9, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.8, green: 0.2, blue: 0.7, alpha: 1),
        ]
        let crowd = (0..<26).map { picture("s\($0).png", inks[$0 % inks.count]) }

        let column = TranscriptColumn(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        column.metrics = ChatLayout.metrics
        var opened: String?
        let context = TranscriptContext()
        context.openImage = { key, _ in opened = key }
        let row = TranscriptRow(key: crowd[0].0.key, kind: .pictures(crowd.map(\.0)))
        let gallery = row.makeView(context: context)
        column.addArrangedSubview(gallery, spacing: ChatLayout.spacing(of: row.kind))
        stage(column)
        column.layoutSubtreeIfNeeded()

        let side = CGFloat(PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: 420))
        try expect(
            gallery.frame.width == 420 && gallery.frame.height == side,
            "in a column a gallery takes the row's width and one picture's height: \(gallery.frame.size)")
        let placed = PictureGalleryLayout.grid(
            count: 26, side: Double(side), available: 420)
        if let second = placed.tiles.dropFirst().first,
            let view = gallery as? PictureGalleryRowView.GalleryView,
            let pressed = view.picture(
                at: NSPoint(x: second.x + second.width / 2, y: second.y + second.height / 2))
        {
            view.onOpen?(pressed)
            try expect(
                opened == crowd[1].0.key,
                "a press lands on the tile under it, and that is the picture the viewer opens on: \(opened ?? "-")")
        }

        let width = Int(420)
        let height = Int(side.rounded())
        guard width > 0, height > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let bitmaps = NSGraphicsContext(bitmapImageRep: rep)
        else { throw SelfTestFailure("compact chat: the gallery would not draw into a bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmaps
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        gallery.draw(gallery.bounds)
        bitmaps.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        func ink(_ x: Double, _ y: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let color = rep.colorAt(x: Int(x.rounded()), y: Int(y.rounded())),
                let space = color.usingColorSpace(.sRGB)
            else { return nil }
            return (space.redComponent, space.greenComponent, space.blueComponent)
        }
        func isInk(_ drawn: (r: CGFloat, g: CGFloat, b: CGFloat)?, _ expected: NSColor) -> Bool {
            guard let drawn, let want = expected.usingColorSpace(.sRGB) else { return false }
            return abs(drawn.r - want.redComponent) < 0.08
                && abs(drawn.g - want.greenComponent) < 0.08
                && abs(drawn.b - want.blueComponent) < 0.08
        }
        for (index, tile) in placed.tiles.enumerated() where index < 3 {
            let drawn = ink(tile.x + tile.width / 2, tile.y + tile.height / 2)
            try expect(
                isInk(drawn, crowd[index].1),
                "tile \(index) is the picture it was handed: \(String(describing: drawn))")
        }
        if let last = placed.tiles.last {
            let covered = ink(last.x + last.width * 0.16, last.y + last.height * 0.18)
            if let want = crowd[last.index].1.usingColorSpace(.sRGB) {
                try expect(
                    covered.map { $0.r + $0.g + $0.b < (want.redComponent + want.greenComponent + want.blueComponent) / 2 } ?? false,
                    "the pictures the sheet cannot draw are counted under a scrim: \(String(describing: covered))")
            }
        }

        let wide = picture("wide.png", inks[0], pixels: NSSize(width: 200, height: 100))
        let lone = PictureGalleryRowView.make([wide.0], context: TranscriptContext())
        let loneSide = CGFloat(PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: 420))
        lone.frame = NSRect(x: 0, y: 0, width: 420, height: loneSide)
        lone.layoutSubtreeIfNeeded()
        try expect(
            lone.intrinsicContentSize.height == loneSide,
            "a lone picture is one picture tall: \(lone.intrinsicContentSize.height)")
    }

    private static func timing(_ expect: (Bool, String) throws -> Void) throws {
        var hover = RailHover()
        hover.pointer(on: .rail("a"), at: 0)
        hover.advance(to: 0.119)
        try expect(hover.open == nil, "a pointer that has rested 119 ms has opened nothing")
        hover.advance(to: 0.120)
        try expect(hover.open == "a", "120 ms of rest opens the plate")
        hover.pointer(on: .plate, at: 0.2)
        hover.pointer(on: .none, at: 1.0)
        hover.advance(to: 1.249)
        try expect(hover.open == "a", "leaving for 249 ms keeps it open")
        hover.pointer(on: .plate, at: 1.25)
        hover.advance(to: 3)
        try expect(hover.open == "a" && hover.deadline == nil, "coming back onto the plate cancels the close")
        hover.pointer(on: .none, at: 3)
        hover.advance(to: 3.25)
        try expect(hover.open == nil, "250 ms away closes it")
        hover.pointer(on: .rail("a"), at: 4)
        hover.advance(to: 4.2)
        hover.escape()
        try expect(hover.open == nil, "Esc closes at once")
        hover.pointer(on: .rail("a"), at: 5)
        hover.pointer(on: .none, at: 5.05)
        hover.advance(to: 6)
        try expect(hover.open == nil, "a pointer that passes over a rail opens nothing")
        hover.pointer(on: .rail("a"), at: 7)
        hover.advance(to: 7.2)
        hover.pointer(on: .rail("b"), at: 7.3)
        hover.advance(to: 7.4)
        try expect(hover.open == "a", "the first rail stays until the second has rested")
        hover.advance(to: 7.42)
        try expect(hover.open == "b", "resting on another rail moves the plate to it")
        hover.openNow("c")
        try expect(hover.open == "c" && hover.deadline == nil, "a press or a key opens at once")
    }

    /// The claims of the chat-screen redesign that a screenshot cannot make: the failed turn has a
    /// card and a way to send it again, the idle band says nothing, Stop is in one place, every chip
    /// is one height, the jump control reads Core, a fan-out collapses, an answer chip wraps rather
    /// than clips, and an agent count is the turn's witness rather than the server's record.
    private static func chrome(_ expect: (Bool, String) throws -> Void) throws {
        let asked = message("u", .user, [MessagePart(id: "p", kind: .text("Run the suite"))])
        var failed = message("a", .assistant, [MessagePart(id: "t", kind: .text("Starting"))])
        failed.error = "The model provider returned 529: overloaded."
        let rows = TranscriptRow.rows(for: [asked, failed])
        let card = rows.first {
            if case .failedTurn = $0.kind { return true }
            return false
        }
        try expect(card != nil, "an errored message draws a failed-turn row")
        try expect(
            rows.last.map { if case .failedTurn = $0.kind { true } else { false } } == true,
            "the failed card stands after the turn's own rows")
        let context = TranscriptContext()
        var resent = ""
        context.askAgain = { resent = $0 }
        if let card {
            let view = card.makeView(context: context)
            stage(view)
            try expect(
                view.accessibilityLabel()?.contains("overloaded") == true,
                "the card is spoken with the server's own words")
            try expect(
                view.accessibilityRole() == .group, "the card is one group for a screen reader")
            let links = allViews(in: view).compactMap { $0 as? NSButton }
            try expect(
                links.contains { $0.title == FailedTurnReading.read(failed, prompt: asked)?.action },
                "the card offers Try again")
            links.first { $0.title == Localized.text("Try again") }?.performClick(nil)
            try expect(resent == "Run the suite", "Try again sends the words that started the turn")
        }
        failed.error = nil
        try expect(
            !TranscriptRow.rows(for: [asked, failed]).contains {
                if case .failedTurn = $0.kind { return true }
                return false
            }, "a turn with no error draws no failed card")

        let idle = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .idle, connection: .live, hasLoadedTranscript: true),
            agents: [], usage: nil, attachments: 0)
        let band = StatusBandView()
        band.render(facts: idle, notice: nil)
        try expect(!band.hasContent, "an idle band with nothing to say is not drawn")
        try expect(
            !idle.segments.contains { $0.id == "phase" }, "idle has no phase segment, ready or not")
        let running = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .running, connection: .live, hasLoadedTranscript: true),
            agents: [], usage: nil, attachments: 0, queued: 2)
        try expect(
            running.segments.allSatisfy { $0.action != .stop }, "the band carries no Stop")
        try expect(
            running.segments.contains { $0.id == "queued" }, "a queue of two is on the band")

        let pills = PillsRow()
        pills.setStopShown(true)
        stage(pills)
        pills.frame = NSRect(x: 0, y: 0, width: 900, height: 24)
        pills.layoutSubtreeIfNeeded()
        let stops = allViews(in: pills).filter {
            guard let chip = $0 as? SymbolChip else { return false }
            return chip.symbol == "stop.fill" && !chip.isHidden
        }
        try expect(stops.count == 1, "\(stops.count) Stop controls in the pills row")
        let heights = allViews(in: pills).compactMap { $0 as? ChipButton }.filter { !$0.isHidden }
            .map(\.frame.height)
        try expect(
            !heights.isEmpty && heights.allSatisfy { abs($0 - heights[0]) < 0.5 },
            "every chip in the row is one height: \(heights)")
        try expect(
            heights.allSatisfy { $0 >= CGFloat(ChatChrome.chip(on: .pointer).height) },
            "no chip is under the table's \(ChatChrome.chip(on: .pointer).height)")

        let reading = JumpReading.read(rowsNow: 12, rowsAtDeparture: 5, needsYou: false)
        try expect(reading.label == Localized.text("New below"), "rows that arrived while away say so without a count")
        try expect(
            JumpReading.read(rowsNow: 12, rowsAtDeparture: 5, needsYou: true).tone == .attention,
            "what needs the reader outranks news")
        let controller = TranscriptViewController()
        _ = controller.view
        controller.followsBottom = false
        controller.refreshJumpReading()
        try expect(
            controller.jumpControl.accessibilityLabel() == JumpReading.read(rowsNow: 0, rowsAtDeparture: nil, needsYou: false).spoken,
            "the jump control is spoken from Core's reading")
        try expect(
            controller.jumpControl.frame.height == 0
                || controller.jumpControl.frame.height >= CGFloat(ChatChrome.chip(on: .pointer).height),
            "the jump control is a chip")

        let flow = StarterFlow()
        flow.centered = false
        let answers = (1...3).map { index -> SymbolChip in
            let chip = SymbolChip()
            chip.text = "Answer number \(index)"
            chip.accented = index == 1
            return chip
        }
        flow.set(answers)
        stage(flow)
        func lines(at width: CGFloat) -> Int {
            flow.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            flow.layout()
            return Set(answers.map { $0.frame.minY }).count
        }
        try expect(lines(at: 900) == 1, "three answers share a line when the card has room")
        try expect(lines(at: 200) > 1, "and break onto more lines instead of clipping a word")
        try expect(
            answers.allSatisfy { $0.frame.height >= CGFloat(ChatChrome.chip(on: .pointer).height) },
            "an answer chip is at least the table's height")

        let held = TranscriptViewController()
        let heldWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        heldWindow.contentView = held.view
        windows.append(heldWindow)
        let answered = message("b", .assistant, [MessagePart(id: "t", kind: .text("Done"))])
        let quiet = ConversationState(
            messages: [asked, answered], status: .idle, connection: .live, hasLoadedTranscript: true)
        held.show(state: quiet)
        held.view.layoutSubtreeIfNeeded()
        held.followsBottom = false
        held.show(state: quiet)
        let grown = message("b", .assistant, [MessagePart(id: "t", kind: .text("Done. Next"))])
        held.show(
            state: ConversationState(
                messages: [asked, grown], status: .running,
                pendingPermissions: [PermissionRequest(id: "p1", sessionID: "s", toolName: "Edit")],
                connection: .live, hasLoadedTranscript: true))
        try expect(
            held.jumpControl.text == Localized.text("Needs you"),
            "a permission that arrives while the reader is up the page says so on the jump chip (\(held.jumpControl.text))")
        held.show(
            state: ConversationState(
                messages: [asked, answered], status: .running, connection: .live,
                hasLoadedTranscript: true))
        try expect(
            held.jumpControl.text != Localized.text("Needs you"),
            "and stops saying it once nothing waits")
        heldWindow.contentView = nil
        windows.removeAll { $0 === heldWindow }

        func fan(_ count: Int) -> [TranscriptRow] {
            let parts = (1...count).map {
                MessagePart(
                    id: "s\($0)",
                    kind: .tool(ToolCall(id: "c\($0)", name: "Task", status: .completed)))
            }
            return TranscriptRow.rows(for: message("f\(count)", .assistant, parts))
        }
        let three = fan(3)
        try expect(
            three.count == 3 && three.allSatisfy { if case .subagent = $0.kind { true } else { false } },
            "three agents stay three cards")
        let five = fan(5)
        try expect(five.count == 1, "five agents collapse behind one row (\(five.count))")
        if let group = five.first {
            let view = group.makeView(context: context)
            stage(view)
            try expect(
                view.accessibilityLabel()?.contains(Localized.text("%lld agents", 5)) == true,
                "the group is named by its count")
            try expect(
                group.spacing == .row(.furniture), "the group sits as furniture, not as prose")
            try expect(
                group.kind.spawnedCalls.count == 5, "a fact about any agent still finds its row")
        }

        let now = Date()
        let agents = [
            SubagentSummary(id: "a", title: "a", updatedAt: now, isActive: true),
            SubagentSummary(id: "b", title: "b", updatedAt: now, isActive: true),
        ]
        let settled = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .idle, connection: .live, hasLoadedTranscript: true),
            agents: agents, usage: nil, attachments: 0)
        try expect(
            settled.activeAgents == 0,
            "agents a server still calls active are not out under a turn that is over (\(settled.activeAgents))")
        let out = StatusFacts.from(
            state: ConversationState(
                messages: [asked], status: .running, connection: .live, hasLoadedTranscript: true),
            agents: agents, usage: nil, attachments: 0)
        try expect(out.activeAgents == 2, "both agents are out inside an open turn")
    }

    private static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private static func column(_ expect: (Bool, String) throws -> Void) throws {
        func block(_ width: CGFloat, _ height: CGFloat) -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.flowWidth = width
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: width),
                view.heightAnchor.constraint(equalToConstant: height),
            ])
            return view
        }
        func stretched(_ height: CGFloat) -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
            return view
        }
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let first = stretched(40)
        let line = stretched(24)
        let pictures = [block(260, 180), block(260, 180), block(260, 180), block(400, 120)]
        let last = stretched(40)
        column.addArrangedSubview(first, spacing: .row(.prose))
        column.addArrangedSubview(line, spacing: .row(.furniture))
        for picture in pictures { column.addArrangedSubview(picture, spacing: .row(.picture)) }
        column.addArrangedSubview(last, spacing: .row(.prose))
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        try expect(line.superview!.frame.minY == 44, "a line sits 4 under the prose above it")
        let stripTop = line.superview!.frame.maxY + 6
        let frames = pictures.map { $0.superview!.frame }
        try expect(
            frames[0].minY == stripTop && frames[1].minY == stripTop && frames[2].minY == stripTop,
            "the strip starts 6 under a line and three pictures share its top")
        try expect(
            frames[1].minX == 268 && frames[2].minX == 536 && frames[3].minX == 0,
            "pictures are 8 apart and the fourth wraps: \(frames.map(\.minX))")
        try expect(frames[3].minY == stripTop + 180 + 8, "the second line of the strip is 8 under the first")
        try expect(
            last.superview!.frame.minY == frames[3].maxY + 6,
            "prose after the strip is 6 under its last line")
        column.metrics = comfortable
        root.layoutSubtreeIfNeeded()
        try expect(
            line.superview!.frame.minY == 52,
            "choosing comfortable re-lays the column and gives the pointer's 12 back: \(line.superview!.frame.minY)")
    }

    private static func quietLines(_ expect: (Bool, String) throws -> Void) throws {
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let words = [
            "Background command finished: go test ./internal/auth/...",
            "Switched from Sonnet 5 to GPT-5.1 Codex at high effort",
        ]
        let rows = words.map {
            SeamLineView(
                symbol: "checkmark.circle", text: $0, tint: .secondaryLabelColor, spoken: $0,
                onPress: nil)
        }
        for row in rows { column.addArrangedSubview(row, spacing: .row(.furniture)) }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let hosts = rows.map { $0.superview! }
        try expect(
            hosts[0].frame.maxY <= hosts[1].frame.minY,
            "two note rows at 320 wide do not overlap: \(hosts.map(\.frame))")
        for row in rows {
            let outside = row.subviews.filter { !row.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
            try expect(
                outside.isEmpty && row.frame.height > CGFloat(compact.seamRowHeight),
                "a note's words stay inside its row, which grows to hold a second line: \(row.frame.height) tall")
        }
    }

    private static func replacedRows(_ expect: (Bool, String) throws -> Void) throws {
        func line() -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return view
        }
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        var rows = (0..<8).map { _ in line() }
        for row in rows { column.addArrangedSubview(row, spacing: .row(.furniture)) }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let before = column.frame.height
        var heights: [CGFloat] = []
        column.postsFrameChangedNotifications = true
        let watch = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: column, queue: nil
        ) { _ in MainActor.assumeIsolated { heights.append(column.frame.height) } }
        defer { NotificationCenter.default.removeObserver(watch) }
        for round in 0..<4 {
            let at = rows.count - 1 - round
            let standing = rows[at].superview?.frame.height
            rows[at].removeFromSuperview()
            let fresh = line()
            column.insertArrangedSubview(fresh, at: at, spacing: .row(.furniture), standingIn: standing)
            rows[at] = fresh
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
        }
        try expect(
            heights.allSatisfy { $0 >= before - 0.5 } && abs(column.frame.height - before) < 0.5,
            "a row replaced by its next version never shortens the page, so a reader at the bottom is not moved: \(before) then \(heights)")
        let hosts = rows.compactMap { $0.superview?.frame }
        let overlapping = zip(hosts, hosts.dropFirst()).filter { $0.maxY > $1.minY + 0.5 }
        try expect(overlapping.isEmpty, "no two rows stand on each other after the replacements: \(hosts)")
    }

    private static func promptFocus(_ expect: (Bool, String) throws -> Void) throws {
        let composer = ComposerView()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 240))
        stage(root)
        root.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let editor = composer.promptEditor
        let field = editor.fieldView
        let frame = field.convert(field.bounds, to: root)
        var misses: [String] = []
        var y = frame.minY + 1
        while y < frame.maxY - 1 {
            var x = frame.minX + 1
            while x < frame.maxX - 1 {
                let hit = root.hitTest(root.convert(NSPoint(x: x, y: y), to: root.superview))
                if !(hit === editor.focusTarget || hit?.isDescendant(of: editor.focusTarget) == true) {
                    misses.append("(\(Int(x - frame.minX)),\(Int(y - frame.minY))) \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                x += 5
            }
            y += 3
        }
        editor.vim.reset(to: "", cursor: 0, mode: .normal)
        try expect(editor.vim.mode == .normal, "the vim box can be left in normal mode, where it draws no caret")
        editor.pointerFocused(vimEnabled: true)
        try expect(
            editor.vim.mode == .insert,
            "a press that takes the keyboard for the vim box leaves it typing, with a caret")
        try expect(
            misses.isEmpty,
            "every point of the visible prompt box lands on the text view: \(misses.count) of them do not, first \(misses.prefix(4)) in a box \(frame.size)")
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func note(_ url: String) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    private static func source(
        asked: Asked, title: String? = "Titled", latency: Duration = .milliseconds(10),
        cached: LinkCardFace? = nil
    ) -> LinkCardSource {
        LinkCardSource(
            cachedFace: { _ in cached },
            metadata: { url in
                asked.note(url)
                try? await Task.sleep(for: latency)
                return title.map { LinkPreviewMetadata(title: "\($0) \(url.suffix(2))", faviconURL: nil) }
            },
            favicon: { _ in nil },
            debounce: .milliseconds(30))
    }

    private static func settle(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private static func addresses(_ count: Int) -> [String] {
        (1...count).map { "https://site\($0).example/p\($0)" }
    }

    private static func railViews(_ expect: (Bool, String) throws -> Void) throws {
        let height = CGFloat(compact.railRowHeight)
        for count in [1, 2, 3, 8] {
            let model = LinkRailModel(urls: addresses(count), source: source(asked: Asked()))
            let line = LinkRailLine(key: "k\(count)", model: model, height: height)
            let shelf = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            stage(shelf)
            shelf.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: shelf.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: shelf.trailingAnchor),
                line.topAnchor.constraint(equalTo: shelf.topAnchor),
            ])
            shelf.layoutSubtreeIfNeeded()
            try expect(line.frame.height == height, "a rail of \(count) is the table's \(Int(height)) pt tall")
            try expect(
                line.hitRect.width > 0 && line.hitRect.width < line.frame.width,
                "only the hosts and the chevron of a rail of \(count) are pressable, not the empty width beside them")
            try expect(
                model.opensDirectly == (count == 1),
                "only a rail of one address opens directly, not a rail of \(count)")
            if count == 1 {
                try expect(
                    line.accessibilityRole() == .link && line.accessibilityHelp() == Localized.text("Opens the link"),
                    "a rail of one address is a link for VoiceOver, not a disclosure")
                var opened = 0
                var copied = 0
                line.directActions = (open: { opened += 1 }, copy: { copied += 1 })
                try expect(line.accessibilityPerformPress() && opened == 1 && copied == 0, "pressing it opens the address")
                continue
            }
            let plate = LinkRailPlateView(model: model, metrics: compact, width: 440)
            let expected = CGFloat(LinkRailPlate.plateHeight(rows: count, metrics: compact)) + 8
            try expect(
                plate.plateSize == NSSize(width: 440, height: expected) && plate.rowViews.count == count,
                "the plate of \(count) is \(Int(expected)) pt tall with a row each")
            try expect(
                plate.rowViews.allSatisfy { $0.accessibilityRole() == .link },
                "the plate's rows are links")
            plate.select(0)
            try expect(plate.selection == 0, "the keyboard's row is the first")
            plate.select(count - 1)
            try expect(plate.selection == count - 1, "and walks to the last")
        }
        let menuLine = LinkRailLine(
            key: "menu", model: LinkRailModel(urls: addresses(2), source: source(asked: Asked())), height: height)
        try expect(
            menuLine.model.reading.copyAllText == addresses(2).joined(separator: "\n"),
            "the rail's menu copies every address, one per line")
        let seam = SeamLineView(
            symbol: "arrow.down.right.and.arrow.up.left", text: "Context compacted · 311.6k → 16.4k · 1m 54s",
            tint: MacTheme.Color.accent, spoken: "Context compacted", onPress: {})
        let shelf = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 100))
        stage(shelf)
        shelf.addSubview(seam)
        NSLayoutConstraint.activate([
            seam.leadingAnchor.constraint(equalTo: shelf.leadingAnchor),
            seam.trailingAnchor.constraint(equalTo: shelf.trailingAnchor),
            seam.topAnchor.constraint(equalTo: shelf.topAnchor),
        ])
        shelf.layoutSubtreeIfNeeded()
        let seamMinimum = CGFloat(compact.seamRowHeight) * MacTheme.UIScale.factor
        try expect(
            seam.frame.height >= seamMinimum && seam.frame.height <= seamMinimum + 3
                && seam.isPressable && seam.accessibilityRole() == .button,
            "a compaction is as tall as a line of the table and never taller: \(seam.frame.height) "
                + "over a minimum of \(seamMinimum)")
        let note = SeamLineView(symbol: "info.circle", text: "Model changed", tint: .secondaryLabelColor, spoken: "Note", onPress: nil)
        try expect(!note.isPressable && note.accessibilityRole() == .staticText, "a note is the same line with nothing behind it")
    }

    private static func fetches(_ expect: (Bool, String) throws -> Void) async throws {
        let height = CGFloat(compact.railRowHeight)
        func fixedHeight(_ line: LinkRailLine) -> Bool {
            line.constraints.contains {
                $0.firstAttribute == .height && $0.relation == .equal && $0.constant == height
            }
        }
        for count in [1, 2, 3, 8] {
            let urls = addresses(count)
            let asked = Asked()
            let model = LinkRailModel(urls: urls, source: source(asked: asked))
            let line = LinkRailLine(key: "k\(count)", model: model, height: height)
            try expect(
                model.reading.items.allSatisfy { $0.face.headlineIsQuiet },
                "before any page speaks every address of \(count) wears its host")
            if count == 1 {
                try expect(
                    line.accessibilityRole() == .link
                        && line.accessibilityLabel() == Localized.text("%@, link", "site1.example"),
                    "the rail of one address says its host and that it is a link")
            } else {
                try expect(
                    line.accessibilityRole() == .button
                        && line.accessibilityLabel() == model.reading.spoken(expanded: false),
                    "the rail of \(count) is one button saying how many links and which")
            }

            model.begin(opened: false)
            try expect(asked.all.isEmpty, "nothing is asked of a page before the debounce is out")
            await settle(250)
            let eager = min(count, LinkRailPolicy.eagerFetch)
            try expect(
                Set(asked.all) == Set(urls.prefix(eager)) && asked.all.count == eager,
                "a rail of \(count) asks about its first \(eager) and no more: \(asked.all.count)")
            try expect(fixedHeight(line), "a fetch landing never changes the height of a rail of \(count)")
            if count == 1 {
                try expect(
                    model.reading.singleTitle == "Titled p1",
                    "a lone address reads as its title: \(model.reading.singleTitle ?? "nil")")
            } else {
                try expect(model.reading.moreLabel == (count > 3 ? "+\(count - 3)" : nil), "the rest are counted")
            }
            try expect(
                line.accessibilityLabel()
                    == (count == 1
                        ? Localized.text("%@, link", "Titled p1") : model.reading.spoken(expanded: false)),
                "the spoken line follows the reading")
            model.begin(opened: true)
            model.begin(opened: true)
            await settle(250)
            try expect(
                Set(asked.all) == Set(urls) && asked.all.count == count,
                "opening asks about every address once, however often it is opened: \(asked.all.count) of \(count)")
        }

        let missing = Asked()
        let hostOnly = LinkRailModel(urls: addresses(2), source: source(asked: missing, title: nil))
        hostOnly.begin(opened: false)
        await settle(250)
        try expect(missing.all.count == 2, "a page that says nothing is still asked")
        try expect(
            hostOnly.reading.items.allSatisfy { $0.face.headlineIsQuiet }
                && hostOnly.reading.hostsLine == "site1.example · site2.example",
            "when a fetch finds nothing the rail keeps the hosts, never a spinner")

        let held = Asked()
        let known = LinkRailModel(
            urls: ["https://held.example/x"],
            source: source(asked: held, cached: .titled(title: "Already Held", host: "held.example")))
        try expect(
            known.reading.singleTitle == "Already Held", "a face the process holds is read at once, with no stand-in")
        known.begin(opened: false)
        await settle(150)
        try expect(held.all.isEmpty, "and no second request is made for it")

        let doomed = Asked()
        weak var gone: LinkRailModel?
        do {
            let slow = LinkRailModel(
                urls: addresses(3), source: source(asked: doomed, latency: .milliseconds(100)))
            gone = slow
            let line = LinkRailLine(key: "doomed", model: slow, height: height)
            slow.begin(opened: false)
            await settle(80)
            try expect(doomed.all.count == 3, "the slow pages' fetches are under way")
            _ = line
        }
        await settle(300)
        try expect(gone == nil, "a rail taken out mid-fetch is released and written into harmlessly")

        let early = Asked()
        do {
            let cut = LinkRailModel(urls: addresses(3), source: source(asked: early))
            cut.begin(opened: false)
            await settle(5)
        }
        await settle(200)
        try expect(early.all.isEmpty, "a rail gone before the debounce is out asks nothing at all")
    }
}
