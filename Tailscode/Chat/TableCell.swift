import TailscodeCore
import UIKit

/// A pipe table as columns rather than punctuation. Column widths come from the shared arithmetic
/// (`TableLayout`): each column asks for its widest cell, and when the row is wider than the
/// transcript the wide columns give way together and wrap, so a table fits a phone by folding its
/// prose column and never by shrinking its numbers. What still cannot fit scrolls sideways under
/// the finger instead of clipping.
///
/// A table that is still being written grows a row at a time, and this cell grows with it: the
/// rows already on screen stay exactly where they are, the new one is added under them, and a
/// column may widen but never narrow. Rebuilding the grid on every arrival — which is what a
/// reconfigure asks for — reset the sideways scroll under the reader's thumb and moved every
/// column each time a cell arrived wider than the last.
final class TableCell: UICollectionViewCell {
    static let reuseID = "TableCell"

    private let scroll = UIScrollView()
    private let grid = UIStackView()
    private var gridTop: NSLayoutConstraint!
    private var table: MarkdownTable?
    private var builtWidth: CGFloat = 0
    private var widths: [CGFloat] = []
    /// One column's width constraint on every row drawn so far, so a column that widens under the
    /// writing widens in the rows already standing rather than only in the new one.
    private var columnConstraints: [[NSLayoutConstraint]] = []
    private var ruleWidth: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        grid.axis = .vertical
        grid.alignment = .leading
        grid.spacing = Theme.Spacing.xs
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroll)
        scroll.addSubview(grid)
        let content = scroll.contentLayoutGuide
        let frameGuide = scroll.frameLayoutGuide
        gridTop = scroll.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            gridTop,
            scroll.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            scroll.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            scroll.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            frameGuide.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualTo: frameGuide.widthAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Extra gap above the table when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { gridTop.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(_ table: MarkdownTable, width: CGFloat) {
        let available = max(120, width - Theme.Spacing.l * 2)
        guard table != self.table || abs(available - builtWidth) > 0.5 else { return }
        let sameWidth = abs(available - builtWidth) <= 0.5
        let grewFrom = sameWidth ? self.table.flatMap { table.extends($0) ? $0.rows.count : nil } : nil
        self.table = table
        builtWidth = available
        if let grewFrom {
            append(table, from: grewFrom)
            return
        }
        scroll.setContentOffset(.zero, animated: false)
        build(table, fitting: available)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        table = nil
        builtWidth = 0
        widths = []
        columnConstraints = []
        ruleWidth = nil
    }

    /// The same grid for a surface whose width nobody knows yet — a subagent report card — built
    /// at natural measure and left to that surface to place.
    static func tableView(_ table: MarkdownTable) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .leading
        grid.spacing = Theme.Spacing.xs
        var tracking = [[NSLayoutConstraint]](repeating: [], count: table.columnCount)
        let widths = naturalWidths(of: table)
        grid.addArrangedSubview(headerRow(table, widths: widths, tracking: &tracking))
        grid.addArrangedSubview(rule(widths: widths).view)
        fill(grid, table: table, widths: widths, from: 0, tracking: &tracking)
        return grid
    }

    private static let columnGap = CGFloat(TableLayout.gap)

    private func build(_ table: MarkdownTable, fitting: CGFloat) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        widths = Self.widths(for: table, fitting: fitting, since: [])
        columnConstraints = [[NSLayoutConstraint]](repeating: [], count: table.columnCount)
        grid.addArrangedSubview(
            Self.headerRow(table, widths: widths, tracking: &columnConstraints))
        let seat = Self.rule(widths: widths)
        ruleWidth = seat.width
        grid.addArrangedSubview(seat.view)
        Self.fill(grid, table: table, widths: widths, from: 0, tracking: &columnConstraints)
    }

    /// The rows that arrived since the last time, added under the ones already drawn.
    private func append(_ table: MarkdownTable, from first: Int) {
        let grown = Self.widths(for: table, fitting: builtWidth, since: widths)
        if grown != widths {
            widths = grown
            for (column, constraints) in columnConstraints.enumerated() where column < grown.count {
                for constraint in constraints { constraint.constant = grown[column] }
            }
            ruleWidth?.constant = CGFloat(TableLayout.width(of: grown.map(Double.init)))
        }
        Self.fill(grid, table: table, widths: widths, from: first, tracking: &columnConstraints)
    }

    private static func headerRow(
        _ table: MarkdownTable, widths: [CGFloat], tracking: inout [[NSLayoutConstraint]]
    ) -> UIView {
        let cells = table.header.indices.map { column in
            rendered(table.header[column], header: true, tabular: table.isNumeric(column: column))
        }
        return rowView(cells, widths: widths, table: table, tracking: &tracking)
    }

    private static func rule(widths: [CGFloat]) -> (view: UIView, width: NSLayoutConstraint) {
        let view = UIView()
        view.backgroundColor = Theme.Color.separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        let width = view.widthAnchor.constraint(
            equalToConstant: CGFloat(TableLayout.width(of: widths.map(Double.init))))
        width.isActive = true
        return (view, width)
    }

    private static func fill(
        _ grid: UIStackView, table: MarkdownTable, widths: [CGFloat], from first: Int,
        tracking: inout [[NSLayoutConstraint]]
    ) {
        for row in table.rows.indices where row >= first {
            let cells = table.cells(in: row).enumerated().map { column, text in
                rendered(text, header: false, tabular: table.isNumeric(column: column))
            }
            grid.addArrangedSubview(
                rowView(cells, widths: widths, table: table, tracking: &tracking))
        }
    }

    private static func rowView(
        _ cells: [NSAttributedString], widths: [CGFloat], table: MarkdownTable,
        tracking: inout [[NSLayoutConstraint]]
    ) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = columnGap
        for (column, text) in cells.enumerated() {
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = text
            switch table.alignment(of: column) {
            case .leading: label.textAlignment = .natural
            case .center: label.textAlignment = .center
            case .trailing: label.textAlignment = .right
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            if column < widths.count {
                let width = label.widthAnchor.constraint(equalToConstant: widths[column])
                width.isActive = true
                if column < tracking.count { tracking[column].append(width) }
            }
            row.addArrangedSubview(label)
        }
        return row
    }

    private static func rendered(_ text: String, header: Bool, tabular: Bool = false)
        -> NSAttributedString
    {
        let color = header ? Theme.Color.secondaryLabel : Theme.Color.label
        let base = TextBubbleCell.rendered(text, color: color)
        guard header || tabular else { return base }
        let styled = NSMutableAttributedString(attributedString: base)
        let whole = NSRange(location: 0, length: styled.length)
        if header {
            styled.addAttribute(.font, value: Theme.Ramp.font(.rowTitleStrong), range: whole)
        }
        if tabular { applyTabularFigures(to: styled) }
        return styled
    }

    /// One digit width across a column of figures, so the numbers line up down the page rather
    /// than drifting with whichever glyphs a row happens to use.
    private static func applyTabularFigures(to text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [
                        UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                        UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                    ]
                ]
            ])
            text.addAttribute(
                .font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
        }
    }

    private static func naturalWidths(of table: MarkdownTable) -> [CGFloat] {
        (0..<table.columnCount).map { column in
            let tabular = table.isNumeric(column: column)
            let measures = table.column(column).enumerated().map { index, text -> CGFloat in
                ceil(rendered(text, header: index == 0, tabular: tabular).size().width) + 1
            }
            return measures.max() ?? CGFloat(TableLayout.minimumColumn)
        }
    }

    /// Column widths from the shared arithmetic, measured in this cell's own font, and never
    /// narrower than they were a moment ago.
    private static func widths(
        for table: MarkdownTable, fitting: CGFloat, since previous: [CGFloat]
    ) -> [CGFloat] {
        let natural = naturalWidths(of: table).map(Double.init)
        let fresh = TableLayout.widths(natural: natural, fitting: Double(fitting))
        return TableLayout.settled(fresh, since: previous.map(Double.init)).map { CGFloat($0) }
    }
}
