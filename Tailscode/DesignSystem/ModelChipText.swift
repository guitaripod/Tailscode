import TailscodeCore
import UIKit

/// The model wearing its family's hue and the effort wearing its heat, as the attributed runs a
/// row's detail line leads with — the same two facts the desktop chips carry, in UIKit's idiom.
/// Ultracode is not a heat, so its word is set letter by letter from the shared rainbow, each
/// held to the canvas's own contrast floor.
enum ModelChipText {
    /// - Parameter strength: how much of its own colour the chip keeps. A read row's chip steps
    ///   back with the row, so the hues are there to recognise and never the brightest thing on it.
    static func runs(for chip: ModelChip, size: CGFloat, strength: Double = 1) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        func inked(_ color: UIColor) -> UIColor {
            strength == 1 ? color : color.withAlphaComponent(strength)
        }
        let text = NSMutableAttributedString(
            string: chip.name,
            attributes: [.font: font, .foregroundColor: inked(Theme.Color.modelIdentity(chip))])
        guard let effort = chip.effort else { return text }
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        if chip.isUltracode {
            for (index, letter) in effort.enumerated() {
                text.append(
                    NSAttributedString(
                        string: String(letter),
                        attributes: [
                            .font: font,
                            .foregroundColor: inked(
                                Theme.Color.modelRainbowLetter(index, of: effort.count)),
                        ]))
            }
        } else {
            text.append(
                NSAttributedString(
                    string: effort,
                    attributes: [
                        .font: font,
                        .foregroundColor: inked(
                            Theme.Color.modelEffort(effort) ?? Theme.Color.secondaryLabel),
                    ]))
        }
        return text
    }

    /// The whole second line: the chip leading, then each remaining fact at its own weight —
    /// the same three-weight read the desktop rows give, with the separators kept at the
    /// quietest weight so they never outrank a fact. An empty piece vanishes rather than
    /// leaving a stranded dot; no chip is just the facts.
    ///
    /// - Parameter chipTrails: put the chip after the facts instead of before them. A chat row
    ///   leads with the project a person knows the chat by, and the model follows.
    static func line(
        chip: ModelChip?, pieces: [(text: String, color: UIColor)], size: CGFloat,
        chipTrails: Bool = false, strength: Double = 1
    ) -> NSAttributedString {
        let font = Theme.Ramp.font(.panelFootnote).withSize(size)
        let line = NSMutableAttributedString()
        if let chip, !chipTrails { line.append(runs(for: chip, size: size, strength: strength)) }
        defer {
            if let chip, chipTrails {
                if line.length > 0 {
                    line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
                }
                line.append(runs(for: chip, size: size, strength: strength))
            }
        }
        for piece in pieces where !piece.text.isEmpty {
            if line.length > 0 {
                line.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: Theme.Color.tertiaryLabel]))
            }
            line.append(
                NSAttributedString(
                    string: piece.text,
                    attributes: [.font: font, .foregroundColor: piece.color]))
        }
        return line
    }

    /// A working row says what it is working on in the accent and nothing else; an idle row
    /// leads with the project a step up from the origin, exactly as the desktop detail lines do.
    static func facetPieces(
        _ facets: SessionRowFacets, snippet: String?
    ) -> [(text: String, color: UIColor)] {
        if let snippet, !snippet.isEmpty { return [(snippet, Theme.Color.accent)] }
        var pieces: [(text: String, color: UIColor)] = []
        if let project = facets.project { pieces.append((project, Theme.Color.secondaryLabel)) }
        if let origin = facets.origin { pieces.append((origin, Theme.Color.tertiaryLabel)) }
        return pieces
    }
}
