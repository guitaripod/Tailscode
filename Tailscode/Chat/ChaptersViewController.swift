import CodingAgentKit
import TailscodeCore
import UIKit

/// How a long chat got here: the header, the strip that draws the chapters to scale, and one row
/// per chapter — number, title, what it came to, the turns and times it spans and who named it
/// when it was not the model — the current one lit. A row takes the transcript to where its
/// chapter began; the sheet opens scrolled to the chapter it was asked for, or the current one,
/// and reads again when the chapters change while it is up.
final class ChaptersViewController: UITableViewController {
    private let read: () -> ChapterReading?
    private let reveal: (String) -> Void
    private var focus: String?
    private var reading: ChapterReading?
    private let header = UILabel()
    private let strip = ChapterStripView()
    private var fittedWidth: CGFloat = 0

    init(focus: String?, read: @escaping () -> ChapterReading?, reveal: @escaping (String) -> Void) {
        self.read = read
        self.reveal = reveal
        self.focus = focus
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Chapters")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        tableView.register(ChapterRowCell.self, forCellReuseIdentifier: ChapterRowCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        header.numberOfLines = 0
        header.adjustsFontForContentSizeCategory = true
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard abs(tableView.bounds.width - fittedWidth) > 0.5 else { return }
        fitHeader()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToFocus(animated: false)
    }

    func chaptersChanged() {
        guard isViewLoaded else { return }
        reload()
    }

    func focus(on anchor: String?) {
        focus = anchor
        scrollToFocus(animated: true)
    }

    private func reload() {
        reading = read()
        let column = UIStackView(arrangedSubviews: [header, strip])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        header.attributedText = NSAttributedString(
            string: reading?.header ?? "",
            attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.secondaryLabel))
        strip.pieces = reading?.strip ?? []
        strip.isHidden = reading?.strip == nil
        let holder = UIView()
        column.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: holder.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: holder.layoutMarginsGuide.trailingAnchor),
            column.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.s),
            column.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.s),
        ])
        tableView.tableHeaderView = holder
        fitHeader()
        tableView.reloadData()
    }

    /// Sizes the header to the table's width, which a rotation, a Duo fold or an iPad window change
    /// moves while the sheet is up.
    private func fitHeader() {
        guard let holder = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        fittedWidth = width
        let size = holder.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        holder.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        tableView.tableHeaderView = holder
    }

    private func scrollToFocus(animated: Bool) {
        guard let lines = reading?.lines, !lines.isEmpty else { return }
        let index = focus.flatMap { anchor in lines.firstIndex { $0.anchorID == anchor } }
            ?? lines.count - 1
        tableView.scrollToRow(
            at: IndexPath(row: index, section: 0), at: .middle, animated: animated)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        reading?.lines.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChapterRowCell.reuseID, for: indexPath) as! ChapterRowCell
        if let line = reading?.lines[indexPath.row] { cell.configure(line) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let anchor = reading?.lines[indexPath.row].anchorID else { return }
        Theme.Haptics.selection()
        reveal(anchor)
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        reading?.lines[indexPath.row].anchorID != nil
    }
}

/// One chapter in the sheet.
final class ChapterRowCell: UITableViewCell {
    static let reuseID = "ChapterRowCell"

    private let number = UILabel()
    private let badge = UIView()
    private let title = UILabel()
    private let current = UILabel()
    private let gist = UILabel()
    private let span = UILabel()
    private let note = UILabel()
    private var isCurrent = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChapterRowCell, _) in
            cell.paintBadge()
        }
        for label in [title, gist, span, note] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        number.textAlignment = .center
        number.adjustsFontForContentSizeCategory = true
        badge.layer.cornerRadius = 12
        badge.translatesAutoresizingMaskIntoConstraints = false
        number.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(number)
        current.adjustsFontForContentSizeCategory = true
        current.setContentHuggingPriority(.required, for: .horizontal)
        let head = UIStackView(arrangedSubviews: [title, current])
        head.spacing = Theme.Spacing.s
        head.alignment = .firstBaseline
        let column = UIStackView(arrangedSubviews: [head, gist, span, note])
        column.axis = .vertical
        column.spacing = 3
        let row = UIStackView(arrangedSubviews: [badge, column])
        row.spacing = Theme.Spacing.m
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            number.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ line: ChapterLine) {
        number.attributedText = NSAttributedString(
            string: "\(line.number)",
            attributes: Theme.Ramp.attributes(
                .rowMeta, color: line.isCurrent ? .white : Theme.Color.secondaryLabel))
        isCurrent = line.isCurrent
        paintBadge()
        title.attributedText = NSAttributedString(
            string: line.title, attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        current.attributedText = NSAttributedString(
            string: Localized.text("Current"),
            attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.accent))
        current.isHidden = !line.isCurrent
        gist.attributedText = line.gist.map {
            NSAttributedString(string: $0, attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.label))
        }
        gist.isHidden = line.gist == nil
        span.attributedText = NSAttributedString(
            string: line.span, attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.secondaryLabel))
        note.attributedText = line.note.map {
            NSAttributedString(
                string: $0,
                attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.secondaryLabel))
        }
        note.isHidden = line.note == nil
        backgroundColor = line.isCurrent
            ? Theme.Color.accent.withAlphaComponent(0.10) : .secondarySystemGroupedBackground
        accessibilityLabel = line.spoken
        accessibilityTraits = line.anchorID == nil ? .staticText : .button
    }

    /// The number's ring, resolved again when the appearance changes: a layer's colour is a
    /// snapshot of the dynamic one at the moment it was set.
    private func paintBadge() {
        badge.backgroundColor = isCurrent ? Theme.Color.accent : .clear
        badge.layer.borderWidth = isCurrent ? 0 : 1.25
        badge.layer.borderColor = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
    }
}

/// The chapters drawn to scale: one rounded piece per chapter by its share of the person's
/// messages, the current one in the accent. A picture only — the rows say the same to VoiceOver.
final class ChapterStripView: UIView {
    var pieces: [ChapterStripPiece] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let gap: CGFloat = 3
        let room = bounds.width - gap * CGFloat(max(0, pieces.count - 1))
        var x: CGFloat = 0
        for piece in pieces {
            let width = max(6, room * piece.share)
            let frame = CGRect(x: x, y: 0, width: min(width, bounds.width - x), height: bounds.height)
            (piece.isCurrent ? Theme.Color.accent : Theme.Color.label.withAlphaComponent(0.22)).setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 4).fill()
            x += width + gap
        }
    }
}
