import AppKit
import TailscodeCore

/// A pipe table as an object with edges: a bordered card, a header band that is visibly not the
/// body, and every other row washed. The design and every number in it are Core's
/// (`TableStyle`); what a column holds, where it sits and whether it may fold are
/// `MarkdownTable`'s; how wide each column is is `TableLayout`'s. This file paints them in AppKit.
///
/// The banding is the whole point. A table used to be a bold header over a hairline with the rows
/// loose underneath, which in a window this wide is not a table but a field of words: a reader
/// tracking one row across eight sparse columns has only the gap between the lines to go on, and a
/// cell that folds puts half of itself on a line that belongs, as far as the eye can tell, to the
/// row below. A washed row holds its own fold.
///
/// It also uses the pane it is in. The measure used to be a flat six hundred and forty points
/// whatever the window was, so a table on a wide desk was squeezed into a third of it and folded
/// there. `layout()` is where a view is finally told how wide it is, so that is where the columns
/// are fitted — only the ones with something to fold pay for it, and what still will not fit
/// scrolls sideways with its last inch dissolving rather than cut off.
/// The card a table wears while it is being written: its own border, the open-work mark turning,
/// and the count of what has landed. `TableDraft` says why the rows are held — nothing here is
/// measured against anything, so an arrival costs two label sets and no layout at all.
@MainActor
final class MacTableDraftView: NSView {
    init(_ draft: TableDraft, key: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        MacTableView.Wash.note(draft: key)

        let mark = NSImageView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.image = NSImage(
            systemSymbolName: TableDraft.mark.symbol, accessibilityDescription: nil)
        mark.contentTintColor = MacTheme.Color.accent
        mark.imageScaling = .scaleProportionallyUpOrDown

        let title = RowKit.attributedLabel(
            MacMarkdown.tableCell(draft.title, role: .tableHeader, tabular: false))
        let row = NSStackView(views: [mark, title])
        if let detail = draft.detail {
            row.addView(
                RowKit.attributedLabel(MacMarkdown.tableCell(detail, role: .tableCell)),
                in: .leading)
        }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let air = CGFloat(TableStyle.rowPadding) + 2
        row.edgeInsets = NSEdgeInsets(
            top: air, left: CGFloat(TableStyle.edge), bottom: air, right: CGFloat(TableStyle.edge))
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        RowKit.ground(
            behind: card, fill: nil,
            stroke: MacTheme.Color.label.withAlphaComponent(CGFloat(TableStyle.border)),
            radius: CGFloat(TableStyle.radius))
        addSubview(card)

        setAccessibilityLabel(draft.reading)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 13),
            mark.heightAnchor.constraint(equalToConstant: 13),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        turn(mark)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func turn(_ mark: NSImageView) {
        guard TableDraft.motion.honoring(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ).isAnimated else { return }
        mark.wantsLayer = true
        mark.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
        sweep.fromValue = 0
        sweep.toValue = -2 * Double.pi
        sweep.duration = ActivityTuning.sweepPeriod
        sweep.repeatCount = .infinity
        mark.layer?.add(sweep, forKey: "sweep")
    }
}

final class MacTableView: NSView {
    private let table: MarkdownTable
    private let key: String
    private let scroll = NSScrollView()
    private let card = NSView()
    private let grid = NSStackView()
    private let fade = CAGradientLayer()
    private var cells: [[NSTextField]] = []
    private var pins: [[NSLayoutConstraint]] = []
    private var natural: [Double] = []
    private var floors: [Double] = []
    private var applied: [CGFloat] = []
    private var fitting: CGFloat = 0

    init(_ table: MarkdownTable, key: String) {
        self.table = table
        self.key = key
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        refit()
        refreshFade()
    }

    private func build() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = CGFloat(TableStyle.radius)
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        grid.orientation = .vertical
        // Every band is the width of the card, not of its own words: a row washed only as far as
        // its longest cell is a smear rather than a row, and the rule between the header and the
        // body has no width of its own at all.
        grid.alignment = .width
        grid.distribution = .fill
        grid.spacing = 0
        grid.translatesAutoresizingMaskIntoConstraints = false

        let kinds = table.kinds
        let names = table.namesItsRows
        cells = [[NSTextField]](repeating: [], count: max(1, table.columnCount))
        pins = [[NSLayoutConstraint]](repeating: [], count: max(1, table.columnCount))

        func cell(_ text: String, header: Bool, column: Int) -> NSTextField {
            let role = TableStyle.role(header: header, key: names && column == 0)
            let ink = MacMarkdown.tableCell(
                text, role: role, tabular: kinds[column] == .number)
            let label = RowKit.attributedLabel(aligned(ink, to: table.effectiveAlignment(of: column)))
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let pin = label.widthAnchor.constraint(equalToConstant: 1)
            pin.isActive = true
            cells[column].append(label)
            pins[column].append(pin)
            return label
        }

        func band(_ header: Bool) -> NSStackView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = CGFloat(TableStyle.columnGap)
            let air = CGFloat(header ? TableStyle.headerPadding : TableStyle.rowPadding)
            row.edgeInsets = NSEdgeInsets(
                top: air, left: CGFloat(TableStyle.edge), bottom: air,
                right: CGFloat(TableStyle.edge))
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        let head = band(true)
        for (column, title) in table.header.enumerated() {
            head.addView(cell(title, header: true, column: column), in: .leading)
        }
        RowKit.ground(
            behind: head,
            fill: MacTheme.Color.accent.withAlphaComponent(CGFloat(TableStyle.headerWash)))
        grid.addArrangedSubview(head)

        let rule = RowKit.Ground(frame: .zero)
        rule.fill = MacTheme.Color.label.withAlphaComponent(CGFloat(TableStyle.headerRule))
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        grid.addArrangedSubview(rule)

        for row in table.rows.indices {
            let line = band(false)
            for (column, text) in table.cells(in: row).enumerated() {
                line.addView(cell(text, header: false, column: column), in: .leading)
            }
            if TableStyle.stripes(row: row) {
                RowKit.ground(
                    behind: line,
                    fill: MacTheme.Color.label.withAlphaComponent(CGFloat(TableStyle.stripe)))
            }
            grid.addArrangedSubview(line)
        }

        card.addSubview(grid)
        RowKit.ground(
            behind: card, fill: nil,
            stroke: MacTheme.Color.label.withAlphaComponent(CGFloat(TableStyle.border)),
            radius: CGFloat(TableStyle.radius))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = card
        addSubview(scroll)

        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            grid.topAnchor.constraint(equalTo: card.topAnchor),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            card.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalTo: card.heightAnchor),
        ])

        if Wash.owed(key) { wash(bands: grid.arrangedSubviews) }

        natural = (0..<table.columnCount).map { column in
            Double(cells[column].map { ceil($0.attributedStringValue.size().width) + 1 }.max() ?? 1)
        }
        natural = TableLayout.settled(natural, since: Self.remembered[key] ?? [])
        Self.remember(natural, for: key)
        floors = (0..<table.columnCount).map { column in
            let run = table.unbreakable(column: column)
            let roles: [TypeRole] = [
                .tableHeader, TableStyle.role(header: false, key: names && column == 0),
            ]
            return roles.map { role in
                Double(
                    ceil(
                        MacMarkdown.tableCell(run, role: role, tabular: kinds[column] == .number)
                            .size().width) + 1)
            }.max() ?? 0
        }
        apply(fitting: Self.opening)
    }

    /// The measure the first pass is fitted to, before any window has said how wide it is. Wide
    /// enough that a table of prose is not folded twice over, narrow enough that the first frame
    /// in a narrow split is not visibly too wide.
    @MainActor private static var opening: CGFloat { 760 * MacTheme.UIScale.factor }

    private func refit() {
        guard bounds.width > 1, abs(bounds.width - fitting) > 0.5 else { return }
        apply(fitting: bounds.width)
    }

    private func apply(fitting available: CGFloat) {
        let room = max(CGFloat(TableLayout.minimumColumn), available - CGFloat(TableStyle.edge) * 2)
        let fresh = TableLayout.widths(
            natural: natural, fitting: Double(room), rigid: table.rigidColumns, floors: floors
        ).map { CGFloat($0) }
        fitting = available
        guard fresh != applied else { return }
        applied = fresh
        for (column, labels) in cells.enumerated() where column < fresh.count {
            for (index, label) in labels.enumerated() {
                pins[column][index].constant = fresh[column]
                label.preferredMaxLayoutWidth = fresh[column]
                label.invalidateIntrinsicContentSize()
            }
        }
    }

    /// The last inch of a table with more table off the side dissolves rather than being cut off.
    /// The mask lives on this view rather than on the scroller, whose own layer moves with the
    /// content it would be masking.
    private func refreshFade() {
        let content = card.frame.width
        let shown = scroll.contentView.bounds
        guard content > shown.width + shown.origin.x + 1, bounds.width > 0 else {
            layer?.mask = nil
            return
        }
        let stop = max(0, (bounds.width - CGFloat(TableStyle.fade)) / bounds.width)
        fade.locations = [0, NSNumber(value: Double(stop)), 1]
        fade.frame = bounds
        layer?.mask = fade
    }

    /// The author's own alignment, or a column of figures nobody placed sitting under its own last
    /// digit — laid over the paragraph style the markdown renderer already set, so the leading it
    /// asked for survives.
    private func aligned(_ text: NSAttributedString, to alignment: MarkdownTable.Alignment)
        -> NSAttributedString
    {
        let styled = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: styled.length)
        let existing = styled.length > 0
            ? styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil
        let paragraph =
            (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        switch alignment {
        case .leading: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        styled.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        return styled
    }

    /// The wash a finished table arrives on. The card is already standing — it was the draft — so
    /// the entrance has nothing to move: every band comes up on light alone, top-down, on the beat
    /// Core sets (`TableEntrance`). Only a table that was a draft a moment ago is washed in; one
    /// read out of history is a settled fact, and a settled fact does not animate.
    private func wash(bands: [NSView]) {
        guard !bands.isEmpty else { return }
        for band in bands {
            band.wantsLayer = true
            band.alphaValue = 0
        }
        for (index, band) in bands.enumerated() {
            let share = bands.count > 1 ? Double(index) / Double(bands.count - 1) : 0
            let rise = CABasicAnimation(keyPath: "opacity")
            rise.fromValue = 0
            rise.toValue = 1
            rise.duration = TableEntrance.duration
            rise.beginTime = CACurrentMediaTime() + TableEntrance.lead * share
            rise.fillMode = .backwards
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            band.alphaValue = 1
            band.layer?.add(rise, forKey: "wash")
        }
    }

    /// The ledger of which tables have earned a wash. Kept for the process rather than the view:
    /// a rebuilt row is not a new table, and a table reopened tomorrow is not one either.
    @MainActor
    enum Wash {
        private static var drafted: Set<String> = []

        static func note(draft key: String) {
            drafted.insert(key)
            if drafted.count > 400 { drafted = [key] }
        }

        static func owed(_ key: String) -> Bool {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                drafted.remove(key)
                return false
            }
            return drafted.remove(key) != nil
        }
    }

    /// What each table's columns measured last time it was built, so a table rebuilt on every
    /// arrival never narrows a column under the reader.
    @MainActor private static var remembered: [String: [Double]] = [:]

    @MainActor private static func remember(_ widths: [Double], for key: String) {
        remembered[key] = widths
        if remembered.count > 400 { remembered = [key: widths] }
    }
}
