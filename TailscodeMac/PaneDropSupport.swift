import AppKit
import TailscodeCore

extension NSPasteboard.PasteboardType {
    /// Private type for a chat in flight — never plain text, so a drop on a prompt box cannot
    /// arrive as pasted words.
    static let tailscodeChat = NSPasteboard.PasteboardType(PaneDragPayload.identifier)
}

/// The region a dragged chat would take, drawn over a pane while the pointer is over it.
@MainActor
final class PaneDropHighlightView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 8
        isHidden = true
        label.font = MacTheme.Font.emphasis()
        label.textColor = MacTheme.Color.label
        label.alignment = .center
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

    func show(frame: NSRect, caption: String) {
        self.frame = frame
        label.stringValue = caption
        isHidden = false
    }

    func clear() {
        isHidden = true
    }
}
