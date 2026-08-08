import TailscodeCore
import UIKit

/// A pipe table as columns rather than punctuation. Column widths start at each column's natural
/// measure; when the sum outgrows the transcript, the widest column gives way first and its cells
/// wrap, so a table fits a phone by folding its prose column, never by shrinking its numbers.
/// What still cannot fit scrolls sideways under the finger instead of clipping.
final class TableCell: UICollectionViewCell {
    static let reuseID = "TableCell"

    private let scroll = UIScrollView()
    private let grid = UIStackView()
    private var gridTop: NSLayoutConstraint!
    private var table: MarkdownTable?
    private var builtWidth: CGFloat = 0

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
        self.table = table
        builtWidth = available
        scroll.setContentOffset(.zero, animated: false)
        Self.build(table, into: grid, fitting: available)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        table = nil
        builtWidth = 0
    }

    /// The same grid for a surface whose width nobody knows yet — a subagent report card — built
    /// at natural measure and left to that surface to place.
    static func tableView(_ table: MarkdownTable) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .leading
        grid.spacing = Theme.Spacing.xs
        build(table, into: grid, fitting: .greatestFiniteMagnitude)
        return grid
    }

    private static let columnGap = Theme.Spacing.m

    private static func build(_ table: MarkdownTable, into grid: UIStackView, fitting: CGFloat) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = table.header.map { rendered($0, header: true) }
        let body = table.rows.indices.map { row in
            table.cells(in: row).map { rendered($0, header: false) }
        }
        let widths = columnWidths(header: header, body: body, fitting: fitting)
        let tableWidth = widths.reduce(0, +) + columnGap * CGFloat(max(0, widths.count - 1))

        grid.addArrangedSubview(rowView(header, widths: widths, table: table))
        let rule = UIView()
        rule.backgroundColor = Theme.Color.separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        rule.widthAnchor.constraint(equalToConstant: tableWidth).isActive = true
        grid.addArrangedSubview(rule)
        for cells in body {
            grid.addArrangedSubview(rowView(cells, widths: widths, table: table))
        }
    }

    private static func rowView(
        _ cells: [NSAttributedString], widths: [CGFloat], table: MarkdownTable
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
                label.widthAnchor.constraint(equalToConstant: widths[column]).isActive = true
            }
            row.addArrangedSubview(label)
        }
        return row
    }

    private static func rendered(_ text: String, header: Bool) -> NSAttributedString {
        let color = header ? Theme.Color.secondaryLabel : Theme.Color.label
        let base = TextBubbleCell.rendered(text, color: color)
        guard header else { return base }
        let bold = NSMutableAttributedString(attributedString: base)
        bold.addAttribute(
            .font, value: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold),
            range: NSRange(location: 0, length: bold.length))
        return bold
    }

    /// Natural widths, then the widest column gives way until the table fits — never below the
    /// floor that keeps a word per line, so a hopeless fit scrolls instead of crushing.
    private static func columnWidths(
        header: [NSAttributedString], body: [[NSAttributedString]], fitting: CGFloat
    ) -> [CGFloat] {
        let floor: CGFloat = 56
        var widths = header.indices.map { column -> CGFloat in
            var cells = [header[column]]
            for row in body where column < row.count { cells.append(row[column]) }
            return cells.map { ceil($0.size().width) + 1 }.max() ?? floor
        }
        let gaps = columnGap * CGFloat(max(0, widths.count - 1))
        var total = widths.reduce(0, +) + gaps
        while total > fitting {
            guard let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
                widths[widest] > floor
            else { break }
            let runnerUp = widths.indices.filter { $0 != widest }.map { widths[$0] }.max() ?? 0
            let target = max(floor, max(runnerUp, widths[widest] - (total - fitting)))
            let cut = min(widths[widest] - target, total - fitting)
            guard cut > 0 else {
                widths[widest] = max(floor, widths[widest] - (total - fitting))
                break
            }
            widths[widest] -= cut
            total -= cut
        }
        return widths
    }
}
