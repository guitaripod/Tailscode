import AppKit
import TailscodeCore

/// The two sheet shapes every destructive or one-line decision in the app shares, so a rename
/// here and a remove there ask the same way: a confirm states what it destroys and waits for the
/// second click; a prompt takes one line of text and lets Enter stand for the default button.
@MainActor
enum MacDialogs {
    static func confirm(
        on window: NSWindow?, title: String, body: String, confirmLabel: String,
        destructive: Bool = true, onConfirm: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = body
        let confirm = alert.addButton(withTitle: confirmLabel)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: Localized.text("Cancel"))
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
        }
    }

    /// One line of text in, two buttons out. Serves rename, the compact preflight, and every
    /// prompt like them. The field is the first responder, so Enter confirms without a reach for
    /// the mouse.
    ///
    /// - Parameter draft: which prompt box this is, when what is typed here outlives the sheet.
    ///   Given one, the field opens on whatever was last typed into it, records every change, and
    ///   lets it go on confirm — cancelling keeps it, because cancelling is not deciding against
    ///   the words. Left out, the sheet forgets what was typed the moment it closes, which is what
    ///   a rename wants.
    static func prompt(
        on window: NSWindow?, title: String, body: String? = nil, placeholder: String,
        initial: String = "", confirmLabel: String, destructive: Bool = false,
        draft: DraftScope? = nil,
        onConfirm: @escaping @MainActor (String) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        if let body { alert.informativeText = body }
        let field: NSTextField
        if let draft {
            field = DraftingField(
                scope: draft, initial: initial.isEmpty ? DraftStore.text(for: draft) : initial)
        } else {
            field = NSTextField(string: initial)
        }
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let confirm = alert.addButton(withTitle: confirmLabel)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: Localized.text("Cancel"))
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if let draft { DraftStore.clear(draft) }
            onConfirm(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let window else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    /// A top-anchored column inside a scroll view — the shape the servers window and every
    /// list-like dialog wants, where AppKit's default document would grow from the bottom.
    static func scrollColumn(holding column: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        let clip = TopAnchoredClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        return scroll
    }

    static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = MacTheme.Color.secondaryLabel
        return label
    }

    static func detailLabel(_ text: String, wraps: Bool = false) -> NSTextField {
        let label =
            wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = MacTheme.Font.caption()
        label.textColor = MacTheme.Color.secondaryLabel
        if !wraps { label.lineBreakMode = .byTruncatingMiddle }
        return label
    }
}

private final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A one-line field whose text belongs to a box rather than to the sheet it is standing in: it
/// records what is typed as it is typed, so a `/compact` instruction or a goal condition survives
/// the sheet being dismissed, the window being closed, or the app being quit. The one who confirms
/// clears it — nothing else does, because a sheet closing is not an answer.
final class DraftingField: NSTextField, NSTextFieldDelegate {
    private let scope: DraftScope

    init(scope: DraftScope, initial: String) {
        self.scope = scope
        super.init(frame: .zero)
        stringValue = initial
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) {
        DraftStore.record(stringValue, for: scope)
    }
}
