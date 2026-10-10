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
        try timing(expect)
        try column(expect)
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
            ("subagent", .subagent(call), .row(.prose)),
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
        try expect(
            seam.frame.height == CGFloat(compact.seamRowHeight) && seam.isPressable
                && seam.accessibilityRole() == .button,
            "a compaction is one line the table's height tall, pressable for its reader")
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
