import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A clock that only moves when it is told to, so the plate's 120 ms and 250 ms are proven as
/// arithmetic rather than waited for.
private final class FakeClock: @unchecked Sendable {
    private var now: UInt32 = 0
    private var pending: [(due: UInt32, order: Int, work: @Sendable () -> Void)] = []
    private var counter = 0

    func schedule(_ delay: UInt32, _ work: @escaping @Sendable () -> Void) {
        counter += 1
        pending.append((now + delay, counter, work))
    }

    func advance(_ milliseconds: UInt32) {
        let target = now + milliseconds
        while let next = pending.filter({ $0.due <= target }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = max(now, next.due)
            next.work()
        }
        now = target
    }
}

private final class AskedLog: @unchecked Sendable {
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

extension SelfTest {
    /// Everything the compact chat promises that does not need a person looking: the one table of
    /// gaps over the Linux row kinds, when a rail may exist, where its plate goes, when the plate
    /// opens and goes, how pictures chunk into strips, the rail drawn in every stage of its life
    /// from stubbed facts and torn down mid-fetch, and the density reaching the stylesheet.
    static func checkCompactChat() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("compact chat: \(label)") }
            checks += 1
        }

        try checkGaps(expect)
        try checkRailSettling(expect)
        try checkPlacementAndTiming(expect)
        try checkStrips(expect)
        try checkDensityStyle(expect)
        guard gtk_init_check() != 0 else { return checks }
        try checkRailWidgets(expect)
        return checks
    }

    private static func row(_ key: String, _ kind: TranscriptRow.Kind) -> TranscriptRow {
        TranscriptRow(key: key, kind: kind)
    }

    private static func checkGaps(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        let compact = ChatMetrics.metrics(for: .compact, input: .pointer)
        let comfortable = ChatMetrics.metrics(for: .comfortable, input: .pointer)
        let sequence: [TranscriptRow] = [
            row("p1", .userText("ask", messageID: "u1")),
            row("a1", .agentProse(text: "one", markup: "one")),
            row("a2", .agentProse(text: "two", markup: "two")),
            row("r1", .reasoning("hm")),
            row("r2", .reasoning("hm again")),
            row("c1", .codeBlock(language: "swift", body: "let x = 1")),
            row("rail", .linkRail(urls: ["https://a.example"])),
            row("s1", .pictureStrip([])),
            row("s2", .pictureStrip([])),
            row("br", .turnBreak),
            row("p2", .userText("again", messageID: "u2")),
        ]
        let table = TranscriptGaps.margins(for: sequence, metrics: compact)
        try expect(table.count == sequence.count, "one margin per row")
        try expect(table[0] == 0, "the first row has no air above it")
        try expect(
            table[1] == compact.gap(from: .prompt, to: .prose)
                && table[1] == compact.turnGap,
            "a prompt and its answer are set a turn apart: \(table[1])")
        try expect(table[2] == compact.paragraphGap, "paragraph to paragraph: \(table[2])")
        try expect(
            table[3] == compact.proseToFurnitureGap, "prose to a flat line: \(table[3])")
        try expect(table[4] == compact.furnitureGap, "one flat line to the next: \(table[4])")
        try expect(table[5] == compact.proseToCodeGap, "a flat line to code: \(table[5])")
        try expect(
            table[6] == compact.gap(from: .code, to: .rail), "code to a rail: \(table[6])")
        try expect(
            table[7] == compact.gap(from: .rail, to: .picture), "a rail to a picture strip: \(table[7])")
        try expect(table[8] == compact.imageStripGap, "a strip beside a strip: \(table[8])")
        try expect(
            table[9] == compact.turnGap / 2 && table[10] == compact.turnGap / 2,
            "a turn break splits the turn gap across its rule: \(table[9]) \(table[10])")
        let airy = TranscriptGaps.margins(for: sequence, metrics: comfortable)
        try expect(
            zip(table, airy).allSatisfy { $0 <= $1 } && table != airy,
            "no compact gap is larger than its comfortable twin, and the two differ")
        try expect(
            TranscriptGaps.margins(for: [], metrics: compact).isEmpty
                && TranscriptGaps.margins(for: [sequence[1]], metrics: compact) == [0],
            "nothing, and one row, are handled")
        let classes = Set(
            TranscriptRow.Kind.sampleKindsForClasses.compactMap {
                TranscriptRow(key: "k", kind: $0).chatClass
            })
        try expect(
            classes.isSuperset(of: [.prompt, .prose, .code, .furniture, .seam, .rail, .picture]),
            "every class of the table is the class of some row kind: \(classes)")
    }

    private static func message(_ id: String, _ parts: [MessagePart]) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, agentType: .claudeCode, parts: parts, createdAt: Date())
    }

    private static func text(_ id: String, _ words: String) -> MessagePart {
        MessagePart(id: id, kind: .text(words))
    }

    private static func railURLs(_ rows: [TranscriptRow]) -> [[String]] {
        rows.compactMap { row in
            if case .linkRail(let urls) = row.kind { return urls }
            return nil
        }
    }

    private static func checkRailSettling(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        let prose =
            "See https://a.example/1 and https://a.example/1 then https://b.example, https://c.example and https://d.example for more."
        let sealed = TranscriptRow.rows(for: message("m", [text("t", prose)]), sealed: true)
        try expect(
            railURLs(sealed) == [
                [
                    "https://a.example/1", "https://b.example", "https://c.example",
                    "https://d.example",
                ]
            ], "a settled run earns one rail: every address once, in order, not three: \(railURLs(sealed))")
        guard let proseIndex = sealed.firstIndex(where: { row in
            if case .agentProse = row.kind { return true }
            return false
        }), sealed.indices.contains(proseIndex + 1), sealed[proseIndex + 1].isLinkRail
        else { throw SelfTestFailure("compact chat: the rail docks directly under its paragraph") }
        try expect(true, "the rail docks directly under the paragraph that mentioned it")
        try expect(
            sealed[proseIndex + 1].key == "m:rail0" && Set(sealed.map(\.key)).count == sealed.count,
            "the rail has a key of its own and every row's is its own")

        let streaming = TranscriptRow.rows(for: message("m", [text("t", prose)]), sealed: false)
        try expect(
            railURLs(streaming).isEmpty,
            "a run still being written has no rail: its own growth would keep pushing it down")

        let closed = TranscriptRow.rows(
            for: message(
                "m",
                [
                    text("t", prose), MessagePart(id: "th", kind: .reasoning("thinking")),
                    text("u", "and later https://e.example/tail"),
                ]), sealed: false)
        try expect(
            railURLs(closed).count == 1 && railURLs(closed)[0].count == 4,
            "a run followed by furniture has closed even while the turn is open — and the run after it has not: \(railURLs(closed))")
        try expect(
            closed.contains { $0.key == "m:rail0" } && !closed.contains { $0.key == "m:rail1" },
            "the first rail is the message's first")

        let both = TranscriptRow.rows(
            for: message(
                "m",
                [
                    text("t", "first https://a.example"),
                    MessagePart(id: "th", kind: .reasoning("thinking")),
                    text("u", "second https://b.example"),
                ]), sealed: true)
        try expect(
            railURLs(both) == [["https://a.example"], ["https://b.example"]]
                && both.map(\.key).contains("m:rail0") && both.map(\.key).contains("m:rail1"),
            "prose, furniture and more prose is two runs and two rails")

        let withCode = TranscriptRow.rows(
            for: message(
                "m", [text("t", "link https://a.example\n\n```\nlet x = 1\n```\n\nmore words")]),
            sealed: true)
        let kinds = withCode.map { row -> String in
            switch row.kind {
            case .agentProse: return "prose"
            case .codeBlock: return "code"
            case .linkRail: return "rail"
            default: return "other"
            }
        }
        try expect(
            kinds == ["prose", "code", "prose", "rail"],
            "code inside a run does not end it, and the rail docks under the run's last paragraph: \(kinds)")

        let many = (0..<15).map { "https://host\($0).example/p" }.joined(separator: " ")
        let capped = TranscriptRow.rows(for: message("m", [text("t", many)]), sealed: true)
        try expect(
            railURLs(capped).first?.count == LinkRailPolicy.limit,
            "a longer run is capped at \(LinkRailPolicy.limit)")

        setenv("TAILSCODE_LINKS", "0", 1)
        let off = TranscriptRow.rows(for: message("m", [text("t", prose)]), sealed: true)
        unsetenv("TAILSCODE_LINKS")
        try expect(railURLs(off).isEmpty, "the one switch off means no rail at all")

        let builder = TranscriptRowBuilder()
        let before = railURLs(builder.rows(for: [message("m", [text("t", prose)])])).count
        setenv("TAILSCODE_LINKS", "0", 1)
        let plain = railURLs(builder.rows(for: [message("m", [text("t", prose)])])).count
        unsetenv("TAILSCODE_LINKS")
        let after = railURLs(builder.rows(for: [message("m", [text("t", prose)])])).count
        try expect(
            before == 1 && plain == 0 && after == before,
            "flipping the switch rebuilds the same message with and without its rail, memo included: \(before) \(plain) \(after)")

        setenv("TAILSCODE_DENSE", "0", 1)
        let comfortable = Preferences.chatDensity
        setenv("TAILSCODE_DENSE", "1", 1)
        let compact = Preferences.chatDensity
        unsetenv("TAILSCODE_DENSE")
        try expect(
            comfortable == .comfortable && compact == .compact
                && Preferences.chatDensity == ChatDensitySetting.current,
            "TAILSCODE_DENSE maps onto the setting — 0 comfortable, 1 compact — and lets go of it")
        let rail = sealed[proseIndex + 1]
        try expect(
            rail.streamedText == nil && !rail.isPromptBlock && rail.searchText.contains("a.example"),
            "a rail streams nothing, is not part of the prompt, and searches by its addresses")
    }

    private static func checkPlacementAndTiming(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        let atTheTail = LinkRailPlacement.place(
            railX: 40, railY: 600, railHeight: 24, overlayWidth: 900, overlayHeight: 640,
            plateWidth: 440, plateHeight: 146)
        try expect(
            atTheTail.upward && atTheTail.y == 600 - 146 - LinkRailPlacement.gap,
            "a rail with no room below opens its plate upward: \(atTheTail)")
        let high = LinkRailPlacement.place(
            railX: 40, railY: 100, railHeight: 24, overlayWidth: 900, overlayHeight: 640,
            plateWidth: 440, plateHeight: 146)
        try expect(
            !high.upward && high.y == 100 + 24 + LinkRailPlacement.gap,
            "a rail with room below opens downward: \(high)")
        let crampedAbove = LinkRailPlacement.place(
            railX: 40, railY: 60, railHeight: 24, overlayWidth: 900, overlayHeight: 120,
            plateWidth: 440, plateHeight: 146)
        try expect(
            crampedAbove.upward && crampedAbove.y == 0,
            "with room on neither side the roomier wins — above, held to the top: \(crampedAbove)")
        let crampedBelow = LinkRailPlacement.place(
            railX: 40, railY: 10, railHeight: 24, overlayWidth: 900, overlayHeight: 120,
            plateWidth: 440, plateHeight: 146)
        try expect(
            !crampedBelow.upward && crampedBelow.y == 36,
            "and below when that is the roomier side: \(crampedBelow)")
        let edge = LinkRailPlacement.place(
            railX: 800, railY: 100, railHeight: 24, overlayWidth: 900, overlayHeight: 640,
            plateWidth: 440, plateHeight: 146)
        try expect(edge.x == 460, "the plate is pulled inside the overlay: \(edge.x)")
        let metrics = ChatMetrics.metrics(for: .compact, input: .pointer)
        try expect(
            LinkRailPlate.plateHeight(rows: 3, metrics: metrics) == 108
                && LinkRailPlate.plateHeight(rows: 12, metrics: metrics) == 288
                && LinkRailPlate.opensUpward(roomBelow: 100, plateHeight: 108),
            "three rows are 108 and twelve scroll past eight at 288")

        let clock = FakeClock()
        let machine = RailHoverMachine(schedule: { clock.schedule($0, $1) })
        var opened: [Int] = []
        var closed: [Int] = []
        machine.onOpen = { opened.append($0) }
        machine.onClose = { closed.append($0) }

        machine.move(over: .rail(1))
        clock.advance(119)
        try expect(opened.isEmpty, "a pointer on a rail for 119 ms has opened nothing")
        clock.advance(1)
        try expect(opened == [1] && machine.open == 1, "and at 120 ms the plate opens")

        machine.move(over: nil)
        clock.advance(249)
        try expect(closed.isEmpty, "a pointer off both for 249 ms has closed nothing")
        clock.advance(1)
        try expect(closed == [1] && machine.open == nil, "and at 250 ms it closes")

        machine.move(over: .rail(1))
        clock.advance(120)
        machine.move(over: nil)
        clock.advance(200)
        machine.move(over: .plate(1))
        clock.advance(1000)
        try expect(machine.open == 1, "reaching the plate in time keeps it open for as long as the pointer is on it")
        machine.move(over: nil)
        machine.move(over: nil)
        clock.advance(249)
        machine.move(over: .rail(1))
        clock.advance(1000)
        try expect(machine.open == 1, "returning to the rail cancels the close, and moves while off do not restart it")
        machine.move(over: nil)
        clock.advance(250)
        try expect(machine.open == nil, "and leaving again closes it")

        opened = []
        machine.move(over: .rail(2))
        clock.advance(60)
        machine.move(over: nil)
        clock.advance(500)
        try expect(opened.isEmpty, "a pointer that crossed a rail without resting opens nothing")

        machine.move(over: .rail(2))
        clock.advance(120)
        machine.escape()
        try expect(machine.open == nil, "escape takes the plate down at once")
        machine.move(over: .rail(2))
        clock.advance(1000)
        try expect(machine.open == nil, "and keeps it down while the pointer stays on that rail")
        machine.move(over: nil)
        machine.move(over: .rail(2))
        clock.advance(120)
        try expect(machine.open == 2, "until the pointer has been elsewhere")

        machine.move(over: .rail(3))
        clock.advance(120)
        try expect(machine.open == 3 && closed.last == 2, "another rail takes the plate over")

        machine.toggle(3)
        try expect(machine.open == nil, "a click on an open rail closes it")
        machine.toggle(3)
        try expect(machine.open == 3, "and on a closed one opens it at once")
        machine.suspend(true)
        machine.move(over: nil)
        clock.advance(1000)
        try expect(machine.open == 3, "a menu of the plate's own keeps it up while the pointer is on the menu")
        machine.suspend(false)
        machine.forget(3)
        try expect(machine.open == nil, "a rail that was destroyed takes its plate with it")
    }

    private static func checkStrips(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        func picture(_ name: String) -> FileReference {
            FileReference(path: "/tmp/\(name)", mime: "image/png", filename: name)
        }
        let rows: [TranscriptRow] = [
            row("m:a", .file(picture("a.png"), mine: false)),
            row("m:b", .file(picture("b.png"), mine: false)),
            row("m:t", .agentProse(text: "between", markup: "between")),
            row("m:c", .file(picture("c.png"), mine: false)),
            row("m:mine", .file(picture("mine.png"), mine: true)),
            row("m:doc", .file(FileReference(path: "/tmp/x.pdf", mime: "application/pdf", filename: "x.pdf"), mine: false)),
            row("m:d", .file(picture("d.png"), mine: false)),
        ]
        let stripped = TranscriptRow.strip(rows)
        let described = stripped.map { row -> String in
            switch row.kind {
            case .pictureStrip(let pictures): return "strip:" + pictures.map(\.key).joined(separator: ",")
            case .file(_, let mine): return mine ? "mine" : "file"
            default: return "prose"
            }
        }
        try expect(
            described == ["strip:m:a,m:b", "prose", "strip:m:c", "mine", "file", "strip:m:d"],
            "consecutive agent pictures share one row, a person's own and a document stay as they were: \(described)")
        try expect(
            stripped[0].key == "m:a" && stripped[0].holdsPicture("m:b") && !stripped[0].holdsPicture("m:c"),
            "a strip is named after its first picture and knows which pixels it draws")
        try expect(
            TranscriptRow.strip(stripped) == stripped,
            "chunking is idempotent")

        let landscape = PictureStripView.thumbnail(width: 340, height: 236, maxHeight: 180, maxWidth: 340)
        try expect(
            landscape.height == 180 && landscape.width == 259,
            "a 340 × 236 landscape picture becomes 259 × 180: \(landscape)")
        let portrait = PictureStripView.thumbnail(width: 300, height: 500, maxHeight: 180, maxWidth: 340)
        try expect(portrait.height == 180 && portrait.width == 108, "a portrait one is 108 × 180: \(portrait)")
        let small = PictureStripView.thumbnail(width: 50, height: 50, maxHeight: 180, maxWidth: 340)
        try expect(small.width == 50 && small.height == 50, "a small picture is never enlarged")
        let wide = PictureStripView.thumbnail(width: 2000, height: 400, maxHeight: 180, maxWidth: 340)
        try expect(wide.width == 340 && wide.height == 68, "a panorama is held to the desk's width: \(wide)")
        try expect(
            PictureStripView.filename(of: FileReference(path: "/a/b/shot.png")) == "shot.png"
                && PictureStripView.filename(of: FileReference()) == "file",
            "a picture is known by its filename, never its path")
        let table = TranscriptRow.rows(
            for: ChatMessage(
                id: "m", role: .assistant, agentType: .claudeCode,
                parts: [
                    MessagePart(id: "1", kind: .file(picture("1.png"))),
                    MessagePart(id: "2", kind: .file(picture("2.png"))),
                ], createdAt: Date()), sealed: true)
        try expect(
            TranscriptRow.strip(table).count == 1,
            "two pictures of one message are one strip")
    }

    private static func checkDensityStyle(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        let palette = MatrixTheme.palette
        let compact = MatrixTheme.css(for: palette, density: .compact)
        let comfortable = MatrixTheme.css(for: palette, density: .comfortable)
        try expect(compact != comfortable, "the two densities make two stylesheets")
        try expect(
            compact.contains("padding: 8px 18px") && comfortable.contains("padding: 18px 26px"),
            "the transcript's padding follows the density")
        try expect(
            compact.contains(".disclosure { padding: 0; min-height: 24px; }"),
            "a flat activity line is 24 px")
        try expect(
            compact.contains(".link-rail") && !compact.contains(".link-card"),
            "the rail is styled and the card is gone")
    }

    private static func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            while g_main_context_iteration(nil, 0) != 0 {}
            if done() { return true }
            usleep(4000)
        }
        return done()
    }

    /// Lets go of the one reference the test took with `g_object_ref_sink`, which finalizes a
    /// widget nothing else holds and so emits its destroy signal.
    private static func destroy(_ widget: UnsafeMutablePointer<GtkWidget>) {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    private static func labelText(_ label: UnsafeMutablePointer<GtkWidget>) -> String {
        gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
    }

    private static func stub(
        asked: AskedLog, titles: [String: String], latency: Duration = .milliseconds(10),
        cached: [String: LinkCardFace] = [:]
    ) -> LinkCardSource {
        LinkCardSource(
            cachedFace: { cached[$0] },
            metadata: { url in
                asked.note(url)
                try? await Task.sleep(for: latency)
                return titles[url].map { LinkPreviewMetadata(title: $0, faviconURL: nil) }
            },
            favicon: { _ in nil },
            debounce: .milliseconds(20))
    }

    private static func checkRailWidgets(
        _ expect: (Bool, String) throws -> Void
    ) throws {
        let baseline = LinkRailRegistry.shared.count
        let urls = (0..<8).map { "https://site\($0).example/page/\($0)" }
        let height = Int32(ChatMetrics.metrics(for: .compact, input: .pointer).railRowHeight)

        for count in [1, 2, 3, 8] {
            let addresses = Array(urls.prefix(count))
            let asked = AskedLog()
            let titles = Dictionary(uniqueKeysWithValues: addresses.map { ($0, "Title of \($0.suffix(1))") })
            let parts = LinkRailView.build(
                urls: addresses, key: "k\(count)", context: nil,
                source: stub(asked: asked, titles: titles))
            g_object_ref_sink(UnsafeMutableRawPointer(parts.widget))
            let line = parts.line
            var requested: Int32 = 0
            gtk_widget_get_size_request(parts.widget, nil, &requested)
            try expect(requested == height, "\(count): the line is \(height) px before anything is fetched")
            try expect(
                line.icons.count == min(3, count),
                "\(count): \(min(3, count)) favicon seat(s)")
            if count == 1 {
                try expect(
                    labelText(line.hosts) == "site0.example",
                    "1: before the page speaks the host is the line: \(labelText(line.hosts))")
                try expect(gtk_widget_get_visible(line.afterTitle) == 0, "1: no host after a stand-in title")
            } else {
                let hosts = addresses.prefix(3).compactMap { URL(string: $0)?.host }
                try expect(
                    labelText(line.hosts) == hosts.joined(separator: " · "),
                    "\(count): the stack's hosts are joined by a middle dot: \(labelText(line.hosts))")
            }
            if count > 3 {
                try expect(
                    labelText(line.more) == "+\(count - 3)" && gtk_widget_get_visible(line.more) != 0,
                    "\(count): the rest are a count: \(labelText(line.more))")
            } else {
                try expect(gtk_widget_get_visible(line.more) == 0, "\(count): no count when nothing lies beyond the stack")
            }
            try expect(
                gtk_label_get_ellipsize(op(line.hosts)) == PANGO_ELLIPSIZE_END
                    && gtk_label_get_single_line_mode(op(line.hosts)) != 0,
                "\(count): the hosts ellipsize at the end of one line")
            let role = tailscode_accessible_role(parts.widget)
            if count == 1 {
                try expect(
                    labelText(line.chevron) == "↗" && parts.model.reading.opensDirectly,
                    "1: a rail of one address is the link — a quiet ↗, not a disclosure")
                try expect(
                    role == Int32(GTK_ACCESSIBLE_ROLE_LINK.rawValue),
                    "1: and it announces itself as a link: \(role)")
                try expect(
                    LinkRailView.menuRows(model: parts.model, ref: WidgetRef(parts.widget)).map(\.title)
                        == [Localized.text("Copy address")],
                    "1: right-click offers Copy address and nothing else")
                try expect(
                    parts.model.reading.spokenAsLink.hasSuffix(", link"),
                    "1: a screen reader is told its title and that it is a link")
            } else {
                try expect(labelText(line.chevron) == "›", "\(count): collapsed reads ›")
                try expect(
                    role == Int32(GTK_ACCESSIBLE_ROLE_BUTTON.rawValue)
                        && !parts.model.reading.opensDirectly,
                    "\(count): a longer rail is a disclosure button: \(role)")
                try expect(
                    LinkRailView.menuRows(model: parts.model, ref: WidgetRef(parts.widget)).map(\.title)
                        == [LinkRailReading.copyAllTitle, LinkRailReading.openAllTitle],
                    "\(count): right-click offers copy all and open all")
            }
            try expect(
                pump(3, until: { asked.all.count == min(3, count) }),
                "\(count): only the stack is asked about at creation: \(asked.all.count)")
            if count == 1 {
                try expect(
                    pump(2, until: { labelText(line.hosts) == "Title of 0" }),
                    "1: the page's own title replaces the host in the same label")
                try expect(
                    labelText(line.afterTitle) == "site0.example"
                        && gtk_widget_get_visible(line.afterTitle) != 0,
                    "1: with its host after it")
            }
            gtk_widget_get_size_request(parts.widget, nil, &requested)
            try expect(requested == height, "\(count): a fetch landing does not change the line's height")
            if count > 3 {
                parts.model.setOpen(true)
                parts.model.fetch(opened: true)
                try expect(
                    pump(3, until: { asked.all.count == count }),
                    "\(count): opening the plate asks about the rest, once: \(asked.all.count)")
                parts.model.fetch(opened: true)
                _ = pump(0.2)
                try expect(
                    asked.all.count == count && Set(asked.all).count == count,
                    "\(count): opening again asks for nothing twice")
                try expect(labelText(line.chevron) == "⌄", "\(count): open reads ⌄")
                parts.model.setOpen(false)
            }
            try expect(
                parts.model.reading.spoken(expanded: false).contains("\(count)")
                    || count == 1,
                "\(count): the accessible label is Core's reading")
            destroy(parts.widget)
        }
        try expect(
            pump(0.5, until: { LinkRailRegistry.shared.count == baseline }),
            "destroying a rail drops it from the registry: \(LinkRailRegistry.shared.count) vs \(baseline)")

        let missing = AskedLog()
        let hostOnly = LinkRailView.build(
            urls: ["https://x.example/a/b"], key: "ho", context: nil,
            source: stub(asked: missing, titles: [:]))
        g_object_ref_sink(UnsafeMutableRawPointer(hostOnly.widget))
        try expect(pump(2, until: { missing.all.count == 1 }), "a failing page is still asked")
        _ = pump(0.15)
        try expect(
            labelText(hostOnly.line.hosts) == "x.example"
                && gtk_widget_get_visible(hostOnly.line.afterTitle) == 0,
            "a fetch that finds nothing keeps the host as the face, never a spinner")
        destroy(hostOnly.widget)

        let held = LinkCardFace.titled(title: "Already Held", host: "held.example")
        let known = AskedLog()
        let instant = LinkRailView.build(
            urls: ["https://held.example/x"], key: "held", context: nil,
            source: stub(asked: known, titles: [:], cached: ["https://held.example/x": held]))
        g_object_ref_sink(UnsafeMutableRawPointer(instant.widget))
        try expect(
            labelText(instant.line.hosts) == "Already Held",
            "a face the process already holds is painted at once")
        _ = pump(0.2)
        try expect(known.all.isEmpty, "and is not asked for again")
        destroy(instant.widget)

        let doomed = AskedLog()
        let slow = LinkRailView.build(
            urls: ["https://slow.example/a"], key: "slow", context: nil,
            source: stub(
                asked: doomed, titles: ["https://slow.example/a": "Late"], latency: .milliseconds(150)))
        g_object_ref_sink(UnsafeMutableRawPointer(slow.widget))
        try expect(pump(2, until: { doomed.all.count == 1 }), "the slow page's fetch is under way")
        destroy(slow.widget)
        _ = pump(0.5)
        try expect(true, "a rail torn down mid-fetch is never written into and nothing crashes")

        let flat = Int32(ChatMetrics.metrics(for: .compact, input: .pointer).seamRowHeight)
        let seam = TranscriptRow(
            key: "seam",
            kind: .compaction(
                Compaction(
                    trigger: .manual, tokensBefore: 311_600, tokensAfter: 16_400, duration: 114,
                    summary: "the summary")
            )
        ).makeWidget(context: TranscriptContext())
        g_object_ref_sink(UnsafeMutableRawPointer(seam))
        var seamHeight: Int32 = 0
        gtk_widget_get_size_request(seam, nil, &seamHeight)
        try expect(seamHeight == flat, "a seam is one \(flat)-px divider line: \(seamHeight)")
        var seamWords: [String] = []
        var seamChild = gtk_widget_get_first_child(seam)
        var seamControls = 0
        while let current = seamChild {
            if gtk_widget_has_css_class(current, "seam-line-press") != 0,
                let label = gtk_button_get_child(ptr(current))
            {
                seamControls += 1
                seamWords.append(labelText(label))
            }
            seamChild = gtk_widget_get_next_sibling(current)
        }
        try expect(
            seamControls == 1 && seamWords.first?.hasPrefix("Context compacted · ") == true
                && seamWords.first?.contains("›") == true,
            "it reads title · trade · time and a chevron, and opens the reader: \(seamWords)")
        try expect(
            !(seamWords.first ?? "").contains("%"),
            "and carries neither the bar's sentence nor its progress: \(seamWords)")
        destroy(seam)
        let bare = TranscriptRow(
            key: "seam2", kind: .compaction(Compaction(trigger: .auto, tokensAfter: 9_000))
        ).makeWidget(context: TranscriptContext())
        g_object_ref_sink(UnsafeMutableRawPointer(bare))
        var bareControls = 0
        var bareChild = gtk_widget_get_first_child(bare)
        while let current = bareChild {
            if gtk_widget_has_css_class(current, "seam-line-press") != 0 { bareControls += 1 }
            bareChild = gtk_widget_get_next_sibling(current)
        }
        try expect(bareControls == 0, "a seam with no summary is not pressable")
        destroy(bare)

        let code = TranscriptRow(
            key: "code", kind: .codeBlock(language: "swift", body: "let a = 1\nlet b = 2")
        ).makeWidget(context: TranscriptContext())
        g_object_ref_sink(UnsafeMutableRawPointer(code))
        let column = gtk_overlay_get_child(op(code))
        try expect(
            gtk_widget_has_css_class(code, "code-wrap") != 0
                && column.map { gtk_widget_has_css_class($0, "code-block") != 0 } == true,
            "a code block is its lines inside a wrapper that carries the plate")
        let firstOfColumn = column.flatMap { gtk_widget_get_first_child($0) }
        try expect(
            firstOfColumn.map { gtk_widget_has_css_class($0, "code-header") == 0 } == true
                && firstOfColumn.map { child in
                    var seen = false
                    var below = gtk_widget_get_first_child(child)
                    while let current = below {
                        if gtk_widget_has_css_class(current, "code-copy") != 0 { seen = true }
                        below = gtk_widget_get_next_sibling(current)
                    }
                    return !seen
                } == true,
            "and there is no header row, no label and no copy, above them")
        var plateFound = false
        var overlayChild = gtk_widget_get_first_child(code)
        while let current = overlayChild {
            if gtk_widget_has_css_class(current, "code-plate") != 0 { plateFound = true }
            overlayChild = gtk_widget_get_next_sibling(current)
        }
        try expect(plateFound, "the language and the copy are a plate over the corner")
        destroy(code)

        let model = LinkRailRegistry.shared.make(
            key: "plate", urls: Array(urls.prefix(3)), source: stub(asked: AskedLog(), titles: [:]),
            toast: nil)
        let metrics = ChatMetrics.metrics(for: .compact, input: .pointer)
        let plate = LinkRailPlateView.build(
            model: model, metrics: metrics, menuAnchor: { nil }, menuOpen: { _ in })
        g_object_ref_sink(UnsafeMutableRawPointer(plate.content))
        try expect(
            plate.rows.count == 3 && plate.height == 108,
            "a plate of three is three 36-px rows: \(plate.rows.count) \(plate.height)")
        var rowHeight: Int32 = 0
        gtk_widget_get_size_request(plate.rows[0], nil, &rowHeight)
        try expect(rowHeight == 36, "each row is 36 px: \(rowHeight)")
        let big = LinkRailRegistry.shared.make(
            key: "big", urls: urls, source: stub(asked: AskedLog(), titles: [:]), toast: nil)
        let bigPlate = LinkRailPlateView.build(
            model: big, metrics: metrics, menuAnchor: { nil }, menuOpen: { _ in })
        g_object_ref_sink(UnsafeMutableRawPointer(bigPlate.content))
        try expect(
            bigPlate.rows.count == 8 && bigPlate.height == 288
                && gtk_scrolled_window_get_max_content_height(op(bigPlate.content)) == 288,
            "eight rows fill the plate and more would scroll: \(bigPlate.height)")
        destroy(plate.content)
        destroy(bigPlate.content)
        LinkRailRegistry.shared.remove(model.id)
        LinkRailRegistry.shared.remove(big.id)
    }
}

extension TranscriptRow.Kind {
    /// One kind from every class the gap table names, for the proof that the table is reachable.
    fileprivate static var sampleKindsForClasses: [TranscriptRow.Kind] {
        [
            .userText("a", messageID: "m"), .agentProse(text: "a", markup: "a"),
            .codeBlock(language: nil, body: "a"), .reasoning("a"),
            .linkRail(urls: ["https://a.example"]), .pictureStrip([]), .turnBreak,
            .compaction(Compaction(trigger: .manual)),
        ]
    }
}
