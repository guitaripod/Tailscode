import TailscodeCore
import UIKit

/// The way into the video surface, wearing whether a render is out.
///
/// A clip is minutes of another machine's card and the phone is expected to be put away while it is
/// made, so the one place the app is always looking at — Home's own chrome — says that something is
/// being rendered elsewhere. The mark is the shared activity badge rather than a dot drawn here, so
/// it breathes on the same clock as every other live thing on screen and stops the moment the
/// render does, because nothing settled is allowed to move.
@MainActor
final class VideoMarkButton: UIButton {
    private let mark = ActivityBadgeView(pointSize: 7)

    private static let side: CGFloat = 34

    init() {
        super.init(frame: .zero)
        setImage(
            UIImage(
                systemName: "film",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        accessibilityLabel = ForgeRunner.shared.board.heading
        mark.isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    func apply(rendering: Bool, spoken: String?) {
        mark.activity = rendering ? .working : nil
        accessibilityValue = rendering ? spoken : nil
    }
}
