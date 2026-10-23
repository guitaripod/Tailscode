import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
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

    static func railViews(_ expect: (Bool, String) throws -> Void) throws {
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

    static func fetches(_ expect: (Bool, String) throws -> Void) async throws {
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
