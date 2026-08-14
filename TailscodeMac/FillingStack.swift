import AppKit

/// A container that says when the light changed.
///
/// A `CGColor` in a layer is the light it was resolved under rather than a colour that answers
/// again, and `NSViewController` has no appearance hook at all — so a pane that paints its own
/// ground needs the view to tell it, or a Mac that crossed into dark keeps a pale slab under a
/// dark transcript until the app is relaunched.
final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// A vertical stack whose arranged subviews are as wide as the stack itself.
///
/// AppKit coerces `NSStackView.alignment = .width` to `.notAnAttribute` — the setter accepts the
/// value and stores nothing — so a column that asked to stretch its rows never stretched one.
/// What a subview got instead was AppKit's own pair of `>=` edges and a 260-priority pin to the
/// *trailing* edge, which is why every card, code block and capsule in this client sat at its
/// intrinsic width and slid to the right of the pane it was supposed to fill. Filling is therefore
/// one constraint per subview, added as the subview is arranged and dropped when it leaves.
///
/// The insets are the stack's own `edgeInsets`, re-applied when they change, so a column reads the
/// same whether AppKit's gravity areas or these pins are what positioned a row.
final class FillingStack: NSStackView {
    private var fills: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        translatesAutoresizingMaskIntoConstraints = false
    }

    convenience init(views: [NSView]) {
        self.init(frame: .zero)
        for view in views { addArrangedSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        fill(view)
    }

    override func insertArrangedSubview(_ view: NSView, at index: Int) {
        super.insertArrangedSubview(view, at: index)
        fill(view)
    }

    override func removeArrangedSubview(_ view: NSView) {
        release(view)
        super.removeArrangedSubview(view)
    }

    override func setViews(_ views: [NSView], in gravity: NSStackView.Gravity) {
        for view in arrangedSubviews { release(view) }
        super.setViews(views, in: gravity)
        for view in views { fill(view) }
    }

    override var edgeInsets: NSEdgeInsets {
        didSet {
            let views = arrangedSubviews
            for view in views { release(view) }
            for view in views { fill(view) }
        }
    }

    private func fill(_ view: NSView) {
        release(view)
        let pins = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right),
        ]
        NSLayoutConstraint.activate(pins)
        fills[ObjectIdentifier(view)] = pins
    }

    private func release(_ view: NSView) {
        guard let pins = fills.removeValue(forKey: ObjectIdentifier(view)) else { return }
        NSLayoutConstraint.deactivate(pins)
    }
}
