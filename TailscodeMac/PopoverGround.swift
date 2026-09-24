import AppKit

/// What every popover's content stands on.
///
/// A popover is a pane of glass, and on macOS 26 a clear one: a transcript behind it reads through
/// the blur as a second layer of text, and a dimmed register — a caption, a key, an age — sinks into
/// it. Tinting the glass is not an answer, since the glass flips light and dark on its own and the
/// palette's ink would not follow it. So the content gets its own ground in the theme's canvas, the
/// surface every palette colour was proved legible against, and the glass keeps its rim and its
/// arrow.
final class GroundedPopoverContent: NSViewController {
    let content: NSViewController

    init(_ content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        addChild(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    override func loadView() {
        let ground = PopoverGround()
        let inner = content.view
        ground.translatesAutoresizingMaskIntoConstraints = inner.translatesAutoresizingMaskIntoConstraints
        ground.frame = NSRect(origin: .zero, size: inner.frame.size)
        inner.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            inner.topAnchor.constraint(equalTo: ground.topAnchor),
            inner.bottomAnchor.constraint(equalTo: ground.bottomAnchor),
        ])
        view = ground
        preferredContentSize = content.preferredContentSize
    }
}

private final class PopoverGround: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.canvas.withAlphaComponent(0.94).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension NSPopover {
    /// Sets the popover's content on a ground of the theme's canvas; see `GroundedPopoverContent`.
    func ground(_ content: NSViewController) {
        contentViewController = GroundedPopoverContent(content)
    }
}
