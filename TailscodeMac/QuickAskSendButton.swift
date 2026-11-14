import AppKit
import TailscodeCore

/// The quick ask's send, as a disc the size of the microphone beside it: the accent with the arrow
/// in the ink that sits on it once there is something to send, and the chips' own opaque ground and
/// outline with a quiet arrow until then — opaque, so the glow a held dictation take casts on it is
/// not thinned by a see-through fill. AppKit's circular bezel draws a seventeen-point disc whatever
/// frame it is given, so beside a twenty-six-point microphone it read as a smaller, greyer thing
/// than the control it is.
@MainActor
final class QuickAskSendButton: NSButton {
    static let side: CGFloat = 26

    var isReady = false {
        didSet {
            guard isReady != oldValue else { return }
            repaint()
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: Localized.text("Send"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        setAccessibilityLabel(Localized.text("Send"))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        repaint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ChipGround.paint(layer, kind: .control, height: Self.side)
            guard isReady else { return }
            layer.backgroundColor = MacTheme.Color.accent.cgColor
            layer.borderWidth = 0
        }
    }

    @objc private func themeChanged() {
        repaint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    private func repaint() {
        contentTintColor = isReady ? MacTheme.Color.onAccent : MacTheme.Color.tertiaryLabel
        needsDisplay = true
    }

    /// A square button keeps a few points of bezel slack around its alignment rectangle even with
    /// no bezel drawn, which made the disc a point wider and five taller than the microphone.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }
}
