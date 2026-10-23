import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    /// A view laid out with no window builds a throwaway constraint engine on every pass, which a
    /// harness off the main thread may not do; one inside a window that is never shown has the
    /// window's engine, and is what the transcript's own harnesses lay their rows out in.
    static func stage(_ root: NSView) {
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        windows.append(window)
    }

    static let compact = ChatMetrics.metrics(for: .compact, input: .pointer)

    static let comfortable = ChatMetrics.metrics(for: .comfortable, input: .pointer)

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

    static func spacing(_ expect: (Bool, String) throws -> Void) throws {
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

    static func message(_ id: String, _ role: MessageRole, _ parts: [MessagePart]) -> ChatMessage {
        ChatMessage(
            id: id, role: role, agentType: .claudeCode, parts: parts, createdAt: Date(timeIntervalSince1970: 1))
    }

    static func settling(_ expect: (Bool, String) throws -> Void) throws {
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

    static func placement(_ expect: (Bool, String) throws -> Void) throws {
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

    static func strips(_ expect: (Bool, String) throws -> Void) throws {
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
}
