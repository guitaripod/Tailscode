import UIKit

/// The scroll view the hour sits in: the lanes take the height they need and the legend lands
/// beneath them, so a long list scrolls while a short one fills the pane.
@MainActor
final class AgentsHourPane: UIScrollView {
    let hourView = AgentHourView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
        addSubview(hourView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let side = AgentsLayout.side(for: width) - Theme.Spacing.l
        let hourWidth = width - 2 * side
        let height = max(
            hourView.requiredHeight(for: hourWidth),
            bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
        let frame = CGRect(x: side, y: 0, width: hourWidth, height: height)
        if hourView.frame != frame { hourView.frame = frame }
        let size = CGSize(width: width, height: height)
        if contentSize != size { contentSize = size }
    }

    func redraw() { hourView.redraw() }
}
