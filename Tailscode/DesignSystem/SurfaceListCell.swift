import UIKit

/// A list row that sits on the theme's surface instead of the platform's.
///
/// The system draws a list cell in white or black whatever the screen behind it wears, so a themed
/// window shows a cream card layer as a stack of white strips. A row is content, which is the
/// palette's to colour, so this cell paints the raised canvas on a grouped list and nothing at all
/// on a plain one (`ground`), where the screen's own background is the surface. A finger on the row
/// washes it toward the accent rather than toward the system's grey. "System" is a choice too
/// and is the platform's own look, so under it a raised row keeps the colours Apple drew.
@MainActor
final class SurfaceListCell: UICollectionViewListCell {
    enum Surface {
        case raised
        case ground
    }

    var surface = Surface.raised {
        didSet {
            guard surface != oldValue else { return }
            setNeedsUpdateConfiguration()
        }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = defaultBackgroundConfiguration().updated(for: state)
        guard surface == .ground || traitCollection.palette != nil else {
            backgroundConfiguration = background
            return
        }
        let raised = surface == .raised
        let base: UIColor = raised ? Theme.Color.groupedSurface : .clear
        if state.isHighlighted || state.isSelected {
            background.backgroundColor = UIColor { traits in
                let wash = Theme.Color.accent.resolvedColor(with: traits)
                guard raised else { return wash.withAlphaComponent(0.14) }
                return base.resolvedColor(with: traits).mixed(with: wash, fraction: 0.14)
            }
        } else {
            background.backgroundColor = base
        }
        backgroundConfiguration = background
    }
}
