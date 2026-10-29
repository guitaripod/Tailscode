import AppKit
import TailscodeCore

extension WallInk {
    /// The colour as AppKit draws it, at `alpha`.
    func watchColor(alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

extension WallRect {
    /// The rectangle in the wall's own space: points, origin at the top leading corner.
    var watchFrame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The faces the wall sets its words in, sized from the layout's unit so a laptop and a monitor read
/// the same from where each is watched.
struct WatchType {
    let unit: Double

    func size(_ units: Double, floor: Double = 11) -> CGFloat {
        CGFloat(max(floor, units * unit))
    }

    func prose(_ units: Double, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size(units), weight: weight)
    }

    func mono(_ units: Double, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size(units), weight: weight)
    }
}

/// How tall words are before they are placed, so a frame is chosen from what the words need and
/// nothing is cut that was promised whole.
@MainActor
enum WatchText {
    private static let manager = NSLayoutManager()

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(manager.defaultLineHeight(for: font))
    }

    /// The lines `text` takes at `width` set in `font`; a single-line label is always one.
    static func lines(_ text: String, font: NSFont, width: CGFloat, wrap: WatchLabel.Wrap) -> Int {
        guard !text.isEmpty else { return 0 }
        guard wrap != .none, width > 1 else { return 1 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wrap == .words ? .byWordWrapping : .byCharWrapping
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style])
        return max(1, Int((box.height / lineHeight(font)).rounded(.up) - 0.001))
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// A label the wall places by frame: it takes no press, wears no focus ring and says nothing to a
/// screen reader of its own, since the view that holds it speaks the whole sentence once.
@MainActor
final class WatchLabel: NSTextField {
    enum Wrap: Equatable {
        case none
        case words
        case characters
    }

    private(set) var wrap: Wrap
    private(set) var lineLimit = 1

    init(wrap: Wrap = .none, lines: Int = 1) {
        self.wrap = wrap
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityElement(false)
        configure(wrap: wrap, lines: lines)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(wrap: Wrap, lines: Int) {
        self.wrap = wrap
        lineLimit = max(1, lines)
        maximumNumberOfLines = lineLimit
        cell?.truncatesLastVisibleLine = true
        switch wrap {
        case .none:
            lineBreakMode = .byTruncatingTail
            cell?.wraps = false
            cell?.usesSingleLineMode = true
        case .words:
            lineBreakMode = .byWordWrapping
            cell?.wraps = true
            cell?.usesSingleLineMode = false
        case .characters:
            lineBreakMode = .byCharWrapping
            cell?.wraps = true
            cell?.usesSingleLineMode = false
        }
    }

    func show(
        _ text: String, font: NSFont, ink: NSColor, align: NSTextAlignment = .natural
    ) {
        if stringValue != text { stringValue = text }
        if self.font != font { self.font = font }
        if textColor != ink { textColor = ink }
        if alignment != align { alignment = align }
    }

    func show(_ text: NSAttributedString) {
        if attributedStringValue != text { attributedStringValue = text }
    }

    var text: String { stringValue }

    /// How tall the words are at `width`, never more than the lines the label may take.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let font, !stringValue.isEmpty else { return 0 }
        let lines = min(lineLimit, WatchText.lines(stringValue, font: font, width: width - 4, wrap: wrap))
        return CGFloat(lines) * WatchText.lineHeight(font) + 2
    }

    /// How many lines the whole of the words would take at `width`, however many the label may show.
    func naturalLines(forWidth width: CGFloat) -> Int {
        guard let font else { return 0 }
        return WatchText.lines(stringValue, font: font, width: width - 4, wrap: wrap)
    }

    var naturalWidth: CGFloat {
        let plain = attributedStringValue.length > 0 ? attributedStringValue.size().width : 0
        return ceil(plain) + 4
    }
}

/// The view that holds a wall's words. It takes a press only where a word is a control, so a press
/// anywhere else falls through to the wall, which knows which tile it landed on.
@MainActor
class WatchPassView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A pill the wall draws its answers on: Deny, Approve (a press that must be held) and Open chat.
/// It reports the press and the release and decides nothing; what a hold means is the wall's.
@MainActor
final class WatchPressView: NSView {
    let label = WatchLabel()
    var onDown: ((NSEvent) -> Void)?
    var onUp: ((NSEvent, Bool) -> Void)?
    private(set) var isPressed = false
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.45
        }
    }
    private var fill = NSColor.white.withAlphaComponent(0.1)
    private var rim = NSColor.white.withAlphaComponent(0.25)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        addSubview(label)
        setAccessibilityRole(.button)
        refreshLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }

    func wear(fill: NSColor, rim: NSColor) {
        self.fill = fill
        self.rim = rim
        refreshLayer()
    }

    func set(title: String, font: NSFont, ink: NSColor) {
        label.show(title, font: font, ink: ink, align: .center)
        setAccessibilityLabel(title)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = min(newSize.height / 2, 18)
        centreLabel()
    }

    private func centreLabel() {
        guard let font = label.font else { return }
        let height = WatchText.lineHeight(font) + 2
        label.frame = CGRect(
            x: 6, y: max(0, (bounds.height - height) / 2), width: max(0, bounds.width - 12), height: height)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        refreshLayer()
        onDown?(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        refreshLayer()
        let point = convert(event.locationInWindow, from: nil)
        onUp?(event, bounds.contains(point))
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayer()
    }

    private func refreshLayer() {
        let base = isPressed ? fill.withAlphaComponent(min(1, fill.alphaComponent + 0.18)) : fill
        layer?.backgroundColor = base.cgColor
        layer?.borderColor = rim.cgColor
    }
}
