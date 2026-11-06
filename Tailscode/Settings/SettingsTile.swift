import CodingAgentKit
import UIKit

/// The rounded square a row on the first page of Settings wears, as every row on the first page of
/// the iPhone's own Settings does: the colour says which family a page belongs to and the glyph
/// which page it is. Under "System" the fills are Apple's own hues; under a theme they are the
/// theme's signal slots, and the glyph is the ink the theme sets on a filled surface, so a tile
/// reads on a cream canvas as well as on black.
struct SettingsTile: Hashable, Sendable {
    enum Hue: Hashable, Sendable {
        case blue, indigo, purple, pink, red, orange, green, cyan, gray
        case brand(AgentType)
    }

    let symbol: String
    let hue: Hue

    init(_ symbol: String, _ hue: Hue) {
        self.symbol = symbol
        self.hue = hue
    }

    @MainActor
    var fill: UIColor {
        switch hue {
        case .blue: return ThemePalette.color(\.accent, system: .systemBlue)
        case .indigo: return ThemePalette.color(\.info, system: .systemIndigo)
        case .purple: return ThemePalette.color(\.special, system: .systemPurple)
        case .pink: return ThemePalette.color(\.special, system: .systemPink)
        case .red: return ThemePalette.color(\.danger, system: .systemRed)
        case .orange: return ThemePalette.color(\.warn, system: .systemOrange)
        case .green: return ThemePalette.color(\.accent, system: .systemGreen)
        case .cyan: return ThemePalette.color(\.info, system: .systemCyan)
        case .gray: return ThemePalette.color(\.textDim, system: .systemGray)
        case .brand(let agent): return agent.brandColor
        }
    }

    /// The tile for these traits, carrying its light and dark faces in one asset so the image view
    /// that shows it changes face with the window and nothing has to configure the row again. A
    /// theme or a text size is a different tile, made once and kept.
    @MainActor
    func image(for traits: UITraitCollection) -> UIImage {
        let side = Self.side(for: traits)
        let scale = traits.displayScale > 0 ? traits.displayScale : 3
        let key = "\(symbol)|\(hue)|\(traits.themeID)|\(side)|\(scale)" as NSString
        if let made = Self.made.object(forKey: key) { return made.image(with: traits) }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let faced = traits.modifyingTraits {
                $0.userInterfaceStyle = style
                $0.displayScale = scale
            }
            let registered = UITraitCollection {
                $0.userInterfaceStyle = style
                $0.displayScale = scale
            }
            asset.register(render(side: side, traits: faced), with: registered)
        }
        Self.made.setObject(asset, forKey: key)
        return asset.image(with: traits.modifyingTraits { $0.displayScale = scale })
    }

    /// The tile's size in points, which a row hands its image view so the tile is drawn at the size
    /// it was made for.
    @MainActor
    static func size(for traits: UITraitCollection) -> CGSize {
        let side = side(for: traits)
        return CGSize(width: side, height: side)
    }

    @MainActor private static let made = NSCache<NSString, UIImageAsset>()

    /// Thirty points, the size the system's own rows use, growing with the accessibility text
    /// sizes so a tile never shrinks beside a title twice its height.
    private static func side(for traits: UITraitCollection) -> CGFloat {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 30, compatibleWith: traits)
        return min(max(30, scaled.rounded()), 44)
    }

    @MainActor
    private func render(side: CGFloat, traits: UITraitCollection) -> UIImage {
        let fillColor = fill.resolvedColor(with: traits)
        let ink = Theme.Color.onAccent.resolvedColor(with: traits)
        let glyph = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold))
        let format = UIGraphicsImageRendererFormat(for: traits)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            fillColor.setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.25).fill()
            guard let glyph = glyph?.withTintColor(ink, renderingMode: .alwaysOriginal) else { return }
            let box = side * 0.68
            let scale = min(box / glyph.size.width, box / glyph.size.height, 1)
            let size = CGSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            glyph.draw(
                in: CGRect(
                    x: (side - size.width) / 2, y: (side - size.height) / 2,
                    width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}
