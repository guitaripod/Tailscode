import TailscodeCore
import UIKit

/// A pipe table as an object with edges: a bordered card, a header band that is visibly not the
/// body, and every other row washed. The design and every number in it are Core's
/// (`TableStyle`); what a column holds, where it sits and whether it may fold are
/// `MarkdownTable`'s; how wide each column is is `TableLayout`'s. This file paints them in UIKit.
///
/// The banding is the whole point. A table used to be a bold header over a hairline with the rows
/// loose underneath, which on anything wider than a phone is not a table but a field of words: a
/// reader tracking one row across eight sparse columns has only the gap between the lines to go on,
/// and a cell that folds puts half of itself on a line that belongs, as far as the eye can tell, to
/// the row below. A washed row holds its own fold.
///
/// A table that is still being written grows a row at a time, and this cell grows with it: the
/// rows already on screen stay exactly where they are, the new one is added under them, and a
/// column may widen but never narrow. Rebuilding the grid on every arrival — which is what a
/// reconfigure asks for — reset the sideways scroll under the reader's thumb and moved every
/// column each time a cell arrived wider than the last.
final class TableCell: UICollectionViewCell {
    static let reuseID = "TableCell"

    private let masker = UIView()
    private let scroll = UIScrollView()
    private let card = UIView()
    private let grid = UIStackView()
    private let fade = CAGradientLayer()
    private var gridTop: NSLayoutConstraint!
    private var table: MarkdownTable?
    private var builtWidth: CGFloat = 0
    private var widths: [CGFloat] = []
    /// One column's width constraint on every row drawn so far, so a column that widens under the
    /// writing widens in the rows already standing rather than only in the new one.
    private var columnConstraints: [[NSLayoutConstraint]] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        masker.translatesAutoresizingMaskIntoConstraints = false
        Self.dress(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        grid.axis = .vertical
        grid.alignment = .fill
        grid.spacing = 0
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(masker)
        masker.addSubview(scroll)
        scroll.addSubview(card)
        card.addSubview(grid)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        let content = scroll.contentLayoutGuide
        let frameGuide = scroll.frameLayoutGuide
        gridTop = masker.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            gridTop,
            masker.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            masker.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            masker.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            scroll.topAnchor.constraint(equalTo: masker.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: masker.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: masker.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: masker.trailingAnchor),
            frameGuide.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualTo: frameGuide.widthAnchor),
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            grid.topAnchor.constraint(equalTo: card.topAnchor),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor),
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.layer.borderColor = Self.borderInk.cgColor
        refreshFade()
    }

    /// The last inch of a table with more table off the side dissolves rather than being cut off:
    /// a column chopped at a border reads as a bug, the same column fading reads as an invitation
    /// to push it. The fade lives on the frame around the scroller rather than on the scroller,
    /// whose own layer moves with the content it would be masking.
    private func refreshFade() {
        let hidden = scroll.contentSize.width
            <= scroll.bounds.width + scroll.contentOffset.x + 1
        guard !hidden else {
            masker.layer.mask = nil
            return
        }
        let width = masker.bounds.width
        guard width > 0 else { return }
        let stop = max(0, (width - CGFloat(TableStyle.fade)) / width)
        fade.locations = [0, NSNumber(value: Double(stop)), 1]
        fade.frame = masker.bounds
        masker.layer.mask = fade
    }

    private static var borderInk: UIColor {
        Theme.Color.label.withAlphaComponent(CGFloat(TableStyle.border))
    }

    private static func dress(_ card: UIView) {
        card.clipsToBounds = true
        card.layer.cornerRadius = CGFloat(TableStyle.radius)
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = borderInk.cgColor
    }

    private func build(_ table: MarkdownTable, fitting: CGFloat) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        widths = Self.widths(for: table, fitting: fitting, since: [])
        columnConstraints = [[NSLayoutConstraint]](repeating: [], count: table.columnCount)
        Self.fill(grid, table: table, widths: widths, from: nil, tracking: &columnConstraints)
    }

    /// The rows that arrived since the last time, added under the ones already drawn.
    private func append(_ table: MarkdownTable, from first: Int) {
        let grown = Self.widths(for: table, fitting: builtWidth, since: widths)
        if grown != widths {
            widths = grown
            for (column, constraints) in columnConstraints.enumerated() where column < grown.count {
                for constraint in constraints { constraint.constant = grown[column] }
            }
        }
        Self.fill(grid, table: table, widths: widths, from: first, tracking: &columnConstraints)
    }

    /// The same card for a surface whose width nobody knows yet — a subagent report card — built
    /// at natural measure and left to that surface to place.
    static func tableView(_ table: MarkdownTable) -> UIView {
        let card = UIView()
        dress(card)
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .fill
        grid.spacing = 0
        grid.translatesAutoresizingMaskIntoConstraints = false
        var tracking = [[NSLayoutConstraint]](repeating: [], count: table.columnCount)
        let widths = naturalWidths(of: table)
        fill(grid, table: table, widths: widths, from: nil, tracking: &tracking)
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private static let columnGap = CGFloat(TableStyle.columnGap)

    /// - Parameter first: the body row to start at, or nil to draw the header and rule too.
    private static func fill(
        _ grid: UIStackView, table: MarkdownTable, widths: [CGFloat], from first: Int?,
        tracking: inout [[NSLayoutConstraint]]
    ) {
        let kinds = table.kinds
        let names = table.namesItsRows
        if first == nil {
            let header = rowView(
                table.header.indices.map { column in
                    rendered(
                        table.header[column], role: .tableHeader, kind: kinds[column],
                        alignment: table.effectiveAlignment(of: column))
                },
                widths: widths, table: table, header: true, tracking: &tracking)
            header.backgroundColor = Theme.Color.accent.withAlphaComponent(
                CGFloat(TableStyle.headerWash))
            grid.addArrangedSubview(header)
            let rule = UIView()
            rule.backgroundColor = Theme.Color.label.withAlphaComponent(
                CGFloat(TableStyle.headerRule))
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            grid.addArrangedSubview(rule)
        }
        for row in table.rows.indices where row >= (first ?? 0) {
            let cells = table.cells(in: row).enumerated().map { column, text in
                rendered(
                    text, role: TableStyle.role(header: false, key: names && column == 0),
                    kind: kinds[column], alignment: table.effectiveAlignment(of: column))
            }
            let line = rowView(
                cells, widths: widths, table: table, header: false, tracking: &tracking)
            if TableStyle.stripes(row: row) {
                line.backgroundColor = Theme.Color.label.withAlphaComponent(
                    CGFloat(TableStyle.stripe))
            }
            grid.addArrangedSubview(line)
        }
    }

    private static func rowView(
        _ cells: [NSAttributedString], widths: [CGFloat], table: MarkdownTable, header: Bool,
        tracking: inout [[NSLayoutConstraint]]
    ) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = columnGap
        row.isLayoutMarginsRelativeArrangement = true
        let air = CGFloat(header ? TableStyle.headerPadding : TableStyle.rowPadding)
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: air, leading: CGFloat(TableStyle.edge), bottom: air,
            trailing: CGFloat(TableStyle.edge))
        for (column, text) in cells.enumerated() {
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = text
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

    /// One cell, set in the voice its column asks for. The markdown is rendered first, then the
    /// role's own face is laid over every run the renderer left in the body face — never over a
    /// code span, which is already saying something by being one.
    private static func rendered(
        _ text: String, role: TypeRole, kind: MarkdownTable.Kind,
        alignment: MarkdownTable.Alignment
    ) -> NSAttributedString {
        let ink = role == .tableHeader ? Theme.Color.secondaryLabel : Theme.Color.label
        let base = TextBubbleCell.rendered(text, color: ink)
        let styled = NSMutableAttributedString(attributedString: base)
        let whole = NSRange(location: 0, length: styled.length)
        let body = Theme.Ramp.font(.answer)
        let face = Theme.Ramp.font(role)
        styled.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont, font == body else { return }
            styled.addAttribute(.font, value: face, range: range)
        }
        let spec = Typography.spec(role)
        if spec.tracking != 0 {
            styled.addAttribute(
                .tracking, value: spec.tracking(forSize: Double(face.pointSize)), range: whole)
        }
        if kind == .number { applyTabularFigures(to: styled) }
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .leading: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        styled.addAttribute(.paragraphStyle, value: paragraph, range: whole)
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
        let kinds = table.kinds
        let names = table.namesItsRows
        return (0..<table.columnCount).map { column in
            let measures = table.column(column).enumerated().map { index, text -> CGFloat in
                let role = TableStyle.role(header: index == 0, key: names && column == 0)
                return ceil(
                    rendered(
                        text, role: role, kind: kinds[column],
                        alignment: table.effectiveAlignment(of: column)
                    ).size().width) + 1
            }
            return measures.max() ?? CGFloat(TableLayout.minimumColumn)
        }
    }

    /// Column widths from the shared arithmetic, measured in this cell's own font, and never
    /// narrower than they were a moment ago. The room the columns share is the card's, so the
    /// edges the bands are inset by come off the top.
    private static func widths(
        for table: MarkdownTable, fitting: CGFloat, since previous: [CGFloat]
    ) -> [CGFloat] {
        let natural = naturalWidths(of: table).map(Double.init)
        let room = max(TableLayout.minimumColumn, Double(fitting) - TableStyle.edge * 2)
        let fresh = TableLayout.widths(
            natural: natural, fitting: room, rigid: table.rigidColumns,
            floors: floorWidths(of: table))
        return TableLayout.settled(fresh, since: previous.map(Double.init)).map { CGFloat($0) }
    }

    /// What each column's widest unbreakable run measures here, which is the width below which a
    /// cell stops folding and starts breaking a token in half. Both voices are asked, because a
    /// column's name and its readings are not set in the same face.
    private static func floorWidths(of table: MarkdownTable) -> [Double] {
        let kinds = table.kinds
        let names = table.namesItsRows
        return (0..<table.columnCount).map { column in
            let run = table.unbreakable(column: column)
            let widths = [TypeRole.tableHeader, TableStyle.role(header: false, key: names && column == 0)]
                .map { role in
                    Double(
                        ceil(
                            rendered(run, role: role, kind: kinds[column], alignment: .leading)
                                .size().width) + 1)
                }
            return widths.max() ?? 0
        }
    }
}

extension TableCell: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshFade()
    }
}
