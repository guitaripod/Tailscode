import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// `TailscodeMac --bench <transcript.json …>` — what a conversation costs to show, measured
/// headlessly off the same rows and the same column the transcript builds, from transcripts this
/// Mac has cached (`~/Library/Caches/Sessions/messages-*.json`).
///
/// Each pass is timed on the main thread in a window that is never ordered front: a view laid out
/// with no window builds a fresh constraint engine on every pass, which prices a layout ten to a
/// hundred times over. The column is also laid beside a plain stack of the same rows, because the
/// column exists to cost less and not to measure differently — a row whose height the two disagree
/// on is a row the column would have drawn wrong.
@MainActor
enum TranscriptBench {
    static var isRequested: Bool { CommandLine.arguments.contains("--bench") }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--bench") else { exit(2) }
        let paths = arguments[(flag + 1)...].prefix { !$0.hasPrefix("-") }
        guard !paths.isEmpty else {
            print("usage: TailscodeMac --bench <transcript.json …> | brain | tiles=N[:R:K:S] | tiles [<transcript.json …>]")
            exit(2)
        }
        if let spec = paths.first, spec.hasPrefix("brain-stream") {
            let pieces = spec.split(separator: "=").dropFirst().first.map { $0.split(separator: ":") } ?? []
            let sizes = pieces.first.map { $0.split(separator: ",").compactMap { Int($0) } }
                ?? [100, 600, 2400]
            let only = pieces.dropFirst().first.flatMap { BrainStreamBench.Mode(rawValue: String($0)) }
            let count = pieces.dropFirst(2).first.flatMap { Int($0) }
            BrainStreamBench.run(sizes: sizes, only: only, tokens: count ?? (only == nil ? nil : 600))
            exit(0)
        }
        if paths.first == "brain" {
            if MacBrain.isEnabled { BrainBench.run() }
            exit(0)
        }
        if let spec = paths.first, spec.hasPrefix("brain-open") {
            let rounds = spec.split(separator: "=").dropFirst().first.flatMap { Int($0) } ?? 200
            if MacBrain.isEnabled { BrainBench.runOpening(rounds: rounds) }
            exit(0)
        }
        if paths.first == "tiles" {
            TileCanvasBench.run()
        }
        if TileBench.isRequested(paths), let spec = paths.first {
            TileBench.run(spec)
        }
        var disagreed = false
        for path in paths {
            disagreed = !bench(path) || disagreed
        }
        if MacBrain.isEnabled { BrainBench.run() }
        exit(disagreed ? 1 : 0)
    }

    private static let width: CGFloat = 1200
    private static var windows: [NSWindow] = []

    private static func time(_ block: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        block()
        return (CACurrentMediaTime() - start) * 1000
    }

    private static func ms(_ value: Double) -> String { String(format: "%.1fms", value) }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// A window's worth of room with a column pinned across it the way the canvas pins the
    /// transcript's, inset by the canvas's own margins.
    private static func stage<Column: NSView>(_ column: Column) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        windows.append(window)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: MacTheme.Spacing.xl),
            column.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -MacTheme.Spacing.xl),
        ])
        return root
    }

    private static func disclosures(in view: NSView) -> [DisclosureRow] {
        if let row = view as? DisclosureRow { return [row] }
        return view.subviews.flatMap { disclosures(in: $0) }
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for child in view.subviews { found += labels(in: child) }
        return found
    }

    /// Returns whether the column and the stack agreed on every row.
    private static func bench(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("== \(name): unreadable")
            return true
        }
        var messages: [ChatMessage] = []
        let decode = time {
            messages = (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
        }
        var rows: [TranscriptRow] = []
        let fold = time { rows = TranscriptRowBuilder().rows(for: Array(messages.suffix(300))) }
        rows = Array(rows.suffix(400))
        let context = TranscriptContext()
        print("== \(name): \(messages.count) messages, \(rows.count) rows")
        print("   decode \(ms(decode))  fold \(ms(fold))")
        tokens(Array(messages.suffix(300)))

        let column = TranscriptColumn()
        column.spacing = MacTheme.Spacing.m
        column.metrics = ChatLayout.metrics
        let root = stage(column)
        var hops: [Double] = []
        var start = max(0, rows.count - rowChunk)
        hops.append(
            time {
                for row in rows[start...] {
                    column.addArrangedSubview(row.makeView(context: context), spacing: row.spacing)
                }
                root.layoutSubtreeIfNeeded()
            })
        while start > 0 {
            let from = max(0, start - rowChunk)
            let upper = start
            hops.append(
                time {
                    for (offset, row) in rows[from..<upper].enumerated() {
                        column.insertArrangedSubview(
                            row.makeView(context: context), at: offset, spacing: row.spacing)
                    }
                    root.layoutSubtreeIfNeeded()
                })
            start = from
        }
        print(
            "   open: tail \(ms(hops[0])) · whole \(ms(hops.reduce(0, +))) in \(hops.count) batches, "
                + "worst \(ms(hops.max() ?? 0))")

        var builds: [Double] = []
        var settles: [Double] = []
        for row in column.arrangedSubviews.reversed().flatMap({ disclosures(in: $0) }).prefix(12) {
            builds.append(time { _ = row.accessibilityPerformPress() })
            settles.append(time { root.layoutSubtreeIfNeeded() })
        }
        if !builds.isEmpty {
            let whole = zip(builds, settles).map { $0 + $1 }
            print(
                "   expand: \(ms(median(whole))) median, \(ms(whole.max() ?? 0)) worst "
                    + "(\(builds.count) rows)")
        }

        let arrival = time {
            column.addArrangedSubview(
                TranscriptRow(
                    key: "bench:arrival",
                    kind: .agentProse(
                        text: "A new answer arriving under everything else.",
                        rendered: MacMarkdown.render("A new answer arriving under everything else."))
                ).makeView(context: context), spacing: .row(.prose))
            root.layoutSubtreeIfNeeded()
        }
        var growth: [Double] = []
        if let label = column.arrangedSubviews.last.flatMap({ labels(in: $0).last }) {
            let grown = NSMutableAttributedString(attributedString: label.attributedStringValue)
            let attributes = grown.length > 0 ? grown.attributes(at: 0, effectiveRange: nil) : [:]
            for step in 0..<30 {
                grown.append(
                    NSAttributedString(
                        string: " word\(step) and a few more of them", attributes: attributes))
                let copy = NSAttributedString(attributedString: grown)
                growth.append(
                    time {
                        label.attributedStringValue = copy
                        root.layoutSubtreeIfNeeded()
                    })
            }
        }
        print("   a row arriving \(ms(arrival)) · words arriving \(ms(median(growth))) median")

        let narrower = time {
            root.window?.setContentSize(NSSize(width: width - 240, height: 1000))
            root.layoutSubtreeIfNeeded()
        }
        let wider = time {
            root.window?.setContentSize(NSSize(width: width, height: 1000))
            root.layoutSubtreeIfNeeded()
        }
        print("   resize \(ms(narrower)) narrower · \(ms(wider)) back")

        return agrees(rows, context: context)
    }

    /// What one streamed token costs the rebuild: the whole transcript folded again by a builder that
    /// already holds the conversation, which is what every state of a running turn does. Measured
    /// without the brain, with it (the turns read into heads, the rows they consume dropped and the
    /// head's own row put where it goes), and a pass of the row comparison the transcript makes
    /// before it decides a state changed only the last row.
    private static func tokens(_ window: [ChatMessage]) {
        guard let end = window.lastIndex(where: { $0.role == .assistant }),
            let part = window[end].parts.lastIndex(where: {
                if case .text = $0.kind { return true }
                return false
            })
        else { return }
        func run(_ builder: TranscriptRowBuilder) -> (rebuild: Double, compare: Double, rows: Int) {
            var grown = window
            var previous = builder.rows(for: grown, turnOpen: true)
            var rebuilds: [Double] = []
            var compares: [Double] = []
            for step in 0..<40 {
                var message = grown[end]
                if case .text(let words) = message.parts[part].kind {
                    message.parts[part].kind = .text(words + " word\(step) and a few more of them")
                }
                grown[end] = message
                var rows: [TranscriptRow] = []
                rebuilds.append(time { rows = builder.rows(for: grown, turnOpen: true) })
                let count = min(previous.count, rows.count)
                compares.append(
                    time {
                        _ = previous.prefix(max(0, count - 1)).elementsEqual(
                            rows.prefix(max(0, count - 1)))
                    })
                previous = rows
            }
            return (median(rebuilds), median(compares), previous.count)
        }
        let plain = run(TranscriptRowBuilder())
        let brained = TranscriptRowBuilder()
        let store = BrainStore()
        brained.brains = store
        let withBrain = run(brained)
        print(
            "   a streamed token: rebuild \(ms(plain.rebuild)) · row compare \(ms(plain.compare)) "
                + "(\(plain.rows) rows) · with the brain \(ms(withBrain.rebuild)) "
                + "(\(withBrain.rows) rows, \(store.order.count) heads)")
    }

    private static let rowChunk = 40

    /// The same rows in a plain stack and in the column, row by row.
    private static func agrees(_ rows: [TranscriptRow], context: TranscriptContext) -> Bool {
        let stack = FillingStack(topDown: true)
        stack.spacing = MacTheme.Spacing.m
        let stackRoot = stage(stack)
        let stacked = rows.map { row -> NSView? in
            if case .file = row.kind { return nil }
            return row.makeView(context: context)
        }
        for view in stacked.compactMap({ $0 }) { stack.addArrangedSubview(view) }
        stackRoot.layoutSubtreeIfNeeded()

        let column = TranscriptColumn()
        column.spacing = MacTheme.Spacing.m
        column.metrics = ChatLayout.metrics
        let columnRoot = stage(column)
        let placed = rows.map { $0.makeView(context: context) }
        for (index, view) in placed.enumerated() {
            column.addArrangedSubview(view, spacing: rows[index].spacing)
        }
        columnRoot.layoutSubtreeIfNeeded()

        var disagreements: [String] = []
        for (index, row) in rows.enumerated() {
            guard let expected = stacked[index]?.frame.height else { continue }
            let actual = placed[index].frame.height
            guard abs(expected - actual) > 1 else { continue }
            disagreements.append(
                "\(row.key) stack \(Int(expected))pt column \(Int(actual))pt")
        }
        let stackHeight = stack.fittingSize.height
        print(
            "   heights: column \(Int(column.intrinsicContentSize.height))pt "
                + "(the old one-gap stack, minus the pictures it cannot flow: \(Int(stackHeight))pt)"
                + (disagreements.isEmpty
                    ? " · every row agrees" : " · \(disagreements.count) rows disagree"))
        for line in disagreements.prefix(8) { print("     \(line)") }
        return disagreements.isEmpty
    }
}
