import TailscodeCore
import UIKit

/// The faces the open brain sets its lists in. Rows are a fixed height from Core (28, 32 for a
/// finger, 40 and 48 for a note), so their type follows Dynamic Type up to the size a row can
/// hold and stops there; everything that wraps (the account's prose, the cards) takes the ramp's
/// own faces and grows without a ceiling.
@MainActor
enum BrainFonts {
    private static func capped(_ role: TypeRole, maximum: CGFloat) -> UIFont {
        let font = Theme.Ramp.font(role)
        return font.pointSize > maximum ? font.withSize(maximum) : font
    }

    static var rowTitle: UIFont { capped(.rowTitleStrong, maximum: 15) }
    static var rowArgument: UIFont { capped(.rowDetail, maximum: 14) }
    static var rowNumber: UIFont { capped(.rowStamp, maximum: 13) }
    static var rowStatus: UIFont { capped(.rowMeta, maximum: 13) }
    static var rowNote: UIFont { capped(.thought, maximum: 15) }
    static var rowSaid: UIFont { capped(.panelDetail, maximum: 15) }

    /// The width of one character of the argument's face, for cutting a path to a width.
    static var argumentCharacterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: rowArgument]).width
    }
}

extension UIColor {
    /// This colour mixed toward `other` and resolved against `traits`, for ink that must be a
    /// real colour at draw time.
    func resolvedMix(_ other: UIColor, _ amount: CGFloat, traits: UITraitCollection) -> UIColor {
        resolvedColor(with: traits).mixed(with: other.resolvedColor(with: traits), amount)
    }
}

extension BrainCanvas {
    /// The hairline of the open brain: the canvas walked a third of the way to the dim ink, which
    /// is stronger than the theme's own rule and is what edges and frames are drawn in.
    static let rule: UIColor = UIColor { traits in
        Theme.Color.background.resolvedColor(with: traits).mixed(
            with: Theme.Color.secondaryLabel.resolvedColor(with: traits), 0.34)
    }

    /// The raised ground of a card or a work line.
    static let raised = Theme.Color.secondaryBackground
}
