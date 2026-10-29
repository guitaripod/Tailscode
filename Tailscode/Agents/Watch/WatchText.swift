import TailscodeCore
import UIKit

extension WallInk {
    func color(_ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension WallRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

/// How type is sized on the wall: hundredths of the shorter side, scaled by the person's text size up
/// to a cap, and never below a floor in points, so a small screen shows less and never smaller.
struct WatchScale: Equatable {
    static let largest: CGFloat = 1.35
    static let smallest: CGFloat = 0.9

    let unit: CGFloat
    let factor: CGFloat

    init(unit: Double, traits: UITraitCollection) {
        self.unit = CGFloat(unit)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits)
        factor = min(Self.largest, max(Self.smallest, scaled))
    }

    func type(_ units: CGFloat, floor: CGFloat = 11) -> CGFloat {
        max(floor, units * unit * factor)
    }

    func space(_ units: CGFloat, floor: CGFloat = 0) -> CGFloat {
        max(floor, units * unit)
    }
}

/// A label on the wall: it never takes a touch and never speaks, because the tile that owns it is the
/// one accessibility element and says all of it as a sentence.
final class WatchLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        lineBreakMode = .byTruncatingTail
        adjustsFontForContentSizeCategory = false
        backgroundColor = .clear
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(
        _ words: String, font next: UIFont, ink: UIColor, lines: Int = 1,
        alignment: NSTextAlignment = .natural
    ) {
        if text != words { text = words }
        if font != next { font = next }
        if textColor != ink { textColor = ink }
        if numberOfLines != lines { numberOfLines = lines }
        if textAlignment != alignment { textAlignment = alignment }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard width > 1, let text, !text.isEmpty else { return 0 }
        return ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    var lineHeight: CGFloat { ceil(font.lineHeight) }

    func widthFor(_ words: String) -> CGFloat {
        ceil((words as NSString).size(withAttributes: [.font: font as Any]).width)
    }

    func widthForOneLine() -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font as Any]).width)
    }
}

enum WatchFont {
    static func text(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .light) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension CGRect {
    func rounded() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
