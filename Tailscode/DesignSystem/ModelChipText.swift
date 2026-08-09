import TailscodeCore
import UIKit

/// The model wearing its family's hue and the effort wearing its heat, as the attributed runs a
/// row's detail line leads with — the same two facts the desktop chips carry, in UIKit's idiom.
/// Ultracode is not a heat, so its word is set letter by letter from the shared rainbow, each
/// held to the canvas's own contrast floor.
enum ModelChipText {
    static func runs(for chip: ModelChip, size: CGFloat) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSMutableAttributedString(
            string: chip.name,
            attributes: [.font: font, .foregroundColor: Theme.Color.modelIdentity(chip)])
        guard let effort = chip.effort else { return text }
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        if chip.isUltracode {
            for (index, letter) in effort.enumerated() {
                text.append(
                    NSAttributedString(
                        string: String(letter),
                        attributes: [
                            .font: font,
                            .foregroundColor: Theme.Color.modelRainbowLetter(
                                index, of: effort.count),
                        ]))
            }
        } else {
            text.append(
                NSAttributedString(
                    string: effort,
                    attributes: [
                        .font: font,
                        .foregroundColor: Theme.Color.modelEffort(effort)
                            ?? Theme.Color.secondaryLabel,
                    ]))
        }
        return text
    }

    /// The whole second line: the chip leading, then the rest of the facts in the register the
    /// caller was already using. An empty remainder is just the chip; no chip is just the facts.
    static func detailLine(
        chip: ModelChip?, rest: String, size: CGFloat, restColor: UIColor
    ) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .caption2)
            .withSize(size)
        let line = NSMutableAttributedString()
        if let chip {
            line.append(runs(for: chip, size: size))
            if !rest.isEmpty {
                line.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: restColor]))
            }
        }
        if !rest.isEmpty {
            line.append(
                NSAttributedString(
                    string: rest,
                    attributes: [.font: font, .foregroundColor: restColor]))
        }
        return line
    }
}
