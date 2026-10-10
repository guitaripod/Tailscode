import TailscodeCore
import UIKit

/// A line the server wrote for the reader rather than the model: the model or agent changing
/// hands, a turn picked back up after a restart, work the agent left running reporting back.
///
/// It stands between the turns it separates, never inside one, so it is the same seam line a
/// compaction is: a rule, the words beside their symbol and tinted by the tone Core read them
/// with. It holds perfectly still, because a note is a fact about what already happened rather
/// than something still moving.
final class TranscriptNoteCell: UICollectionViewCell {
    static let reuseID = "TranscriptNoteCell"

    private let seam = SeamLineView()
    private lazy var topConstraint = seam.topAnchor.constraint(equalTo: contentView.topAnchor)

    override init(frame: CGRect) {
        super.init(frame: frame)
        seam.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(seam)
        NSLayoutConstraint.activate([
            topConstraint,
            seam.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            seam.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            seam.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    func configure(_ line: TranscriptNoteLine) {
        seam.show(
            text: line.text, symbol: line.symbol, tint: Self.color(for: line.tone), tappable: false,
            spoken: line.spoken)
    }

    private static func color(for tone: ActivityTone) -> UIColor {
        switch tone {
        case .attention: return Theme.Color.warning
        case .live, .danger, .quiet: return Theme.Color.secondaryLabel
        }
    }
}
