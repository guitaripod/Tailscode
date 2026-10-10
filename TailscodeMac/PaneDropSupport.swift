import AppKit
import TailscodeCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Private type for a chat in flight — never plain text, so a drop on a prompt box cannot
    /// arrive as pasted words.
    static let tailscodeChat = NSPasteboard.PasteboardType(PaneDragPayload.identifier)
    /// Private type for a pane in flight, distinct from a chat's so a chat target never mistakes a
    /// pane for a chat and a prompt box never receives it as words.
    static let tailscodePane = privateType(PaneMovePayload.identifier)

    /// The pasteboard spelling of Core's private type. A MIME string is what the other desktop's
    /// toolkit takes; AppKit's pasteboard wants a type identifier and refuses to write anything
    /// else, so the MIME type is turned into the dynamic identifier the system derives for it —
    /// valid on every release, and the same string on both ends of an in-process drag.
    static func privateType(_ mime: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType(mimeType: mime)?.identifier ?? mime)
    }
}

/// A pane's identity strip, which is the handle a pane is picked up by: dragged past the usual
/// threshold it carries the pane under its own private type, and the strip itself is what the
/// pointer holds. A press that does not become a drag is left to whoever else wants it.
@MainActor
final class PaneStripView: NSStackView, NSDraggingSource {
    var payload: (() -> PaneMovePayload?)?
    private var pressed: NSEvent?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed, let payload = payload?() else { return }
        let travelled = hypot(
            event.locationInWindow.x - start.locationInWindow.x,
            event.locationInWindow.y - start.locationInWindow.y)
        guard travelled >= Self.dragThreshold else { return }
        pressed = nil
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: payload))
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
    }

    /// How far the pointer travels before a press becomes a drag.
    static let dragThreshold: CGFloat = 4

    static func pasteboardItem(for payload: PaneMovePayload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(payload.encoded, forType: .tailscodePane)
        return item
    }

    /// A pane is moved, never copied: the cursor says so, and a target that would copy refuses.
    nonisolated static let operation: NSDragOperation = .move

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operation
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The region a dragged chat would take, drawn over a pane while the pointer is over it.
@MainActor
final class PaneDropHighlightView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 8
        isHidden = true
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The wash, the rule and the caption's face are resolved at the moment of the drag rather than
    /// at construction: this view is built once, with the window, and a `CGColor` and a font taken
    /// then would still be the launch theme's accent at the launch type size long after the app had
    /// changed both.
    func show(frame: NSRect, caption: String) {
        self.frame = frame
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.7).cgColor
        label.font = MacTheme.Ramp.font(.cardTitle)
        label.textColor = MacTheme.Color.label
        label.stringValue = caption
        isHidden = false
    }

    func clear() {
        isHidden = true
    }
}
