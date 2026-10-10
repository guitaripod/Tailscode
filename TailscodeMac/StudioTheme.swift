import AppKit
import TailscodeCore

/// A raised card that carries prose or a decision over picture content: an opaque canvas with the
/// raised surface laid over it, because the system's own raised fill is translucent and a card that
/// shows the picture through its words is a card nobody can read. Never glass — prose does not sit on
/// a material.
@MainActor
class StudioRaisedView: NSView {
    private let raised = CALayer()

    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        raised.cornerRadius = radius
        raised.cornerCurve = .continuous
        layer?.insertSublayer(raised, at: 0)
        paintGround()
        NotificationCenter.default.addObserver(
            self, selector: #selector(groundChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func groundChanged() { paintGround() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintGround()
    }

    private func paintGround() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.cgColor
            raised.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        raised.frame = bounds
        CATransaction.commit()
    }
}

/// The few numbers and derived colours the Studio adds to the Mac's tokens. Every colour here is a
/// token walked toward another or given an opacity — nothing is a hex — and every size is the one
/// the design names.
enum StudioTheme {
    static let stageRadius: CGFloat = 16
    static let pictureRadius: CGFloat = 10
    static let stageMargin: CGFloat = 24
    static let captionBand: CGFloat = 42
    static let shelfWidth: CGFloat = 112
    static let tile: CGFloat = 88
    static let gutter: CGFloat = 8
    static let stripHeight: CGFloat = 88
    static let dockInset: CGFloat = 16
    static let dockBase: CGFloat = 124
    static let capsuleHeight: CGFloat = 36
    static let capsuleLift: CGFloat = 12
    static let progressThickness: CGFloat = 2
    static let crossfade: TimeInterval = 0.24
    static let rewriteRise: TimeInterval = 0.16
    static let tileSlide: TimeInterval = 0.16

    /// What the verbs capsule is filled with on top of regular glass: the canvas, mostly opaque, so
    /// its ink clears contrast over a near-white picture as well as over a near-black one. The dock
    /// sits on canvas and needs none; this is the one piece that sits on picture content.
    static var scrim: NSColor { MacTheme.Color.canvas.withAlphaComponent(0.78) }

    /// What dims a held picture behind an invitation or a failure: the canvas at enough opacity that
    /// the picture is a memory of itself and the words in front of it read at full contrast.
    static let dimmed: Float = 0.28

    /// The stage's picture ground. A picture is content, so it sits on the opaque canvas the
    /// transcript sits on — never on a material.
    static var ground: NSColor { MacTheme.Color.canvas }

    static var motionAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func label(
        _ role: TypeRole, color: NSColor = MacTheme.Color.label, lines: Int = 1,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = MacTheme.Ramp.font(role)
        field.textColor = color
        field.alignment = alignment
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = true
        return field
    }

    /// A line of text measured in the label's own font, which is how frame-laid views size a label.
    static func width(of text: String, role: TypeRole) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: MacTheme.Ramp.font(role)]).width)
    }

    static func height(of role: TypeRole) -> CGFloat {
        let font = MacTheme.Ramp.font(role)
        return ceil(font.ascender - font.descender + font.leading)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}
