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

    /// The decision screen `/compact` opens instead of firing bare — compaction is destructive to
    /// the agent's memory and takes minutes, so an NSAlert's one line is not enough. Every word
    /// comes from the shared ``CompactPreflight``; this sheet only lays them out: the argument,
    /// the instruction field, what the previous compaction traded, and the wait.
    static func compactPreflight(
        on window: NSWindow?, facts: CompactPreflight, initialInstruction: String = "",
        draft: DraftScope? = nil,
        onConfirm: @escaping @MainActor (String?) -> Void
    ) {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = Localized.text("Compact this conversation?")

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: facts.headline)
        headline.font = MacTheme.Ramp.font(.headline)
        column.addArrangedSubview(headline)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: headline)
        let subtitle = NSTextField(labelWithString: facts.subtitle)
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        subtitle.textColor = MacTheme.Color.secondaryLabel
        column.addArrangedSubview(subtitle)

        for paragraph in facts.paragraphs {
            let body = NSTextField(wrappingLabelWithString: paragraph)
            body.font = MacTheme.Ramp.font(.panelLabel)
            body.textColor = MacTheme.Color.secondaryLabel
            column.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        var field: NSTextField?
        if facts.showsInstruction {
            let caption = NSTextField(labelWithString: facts.fieldCaption.uppercased())
            caption.font = MacTheme.Ramp.font(.metricLabel)
            caption.textColor = MacTheme.Color.tertiaryLabel
            column.addArrangedSubview(caption)
            column.setCustomSpacing(MacTheme.Spacing.xs, after: caption)

            if let draft {
                field = DraftingField(
                    scope: draft,
                    initial: initialInstruction.isEmpty
                        ? DraftStore.text(for: draft) : initialInstruction)
            } else {
                field = NSTextField(string: initialInstruction)
            }
            field?.placeholderString = facts.fieldPlaceholder
            column.addArrangedSubview(field!)
            field!.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        for line in [facts.lastTime, facts.wait].compactMap({ $0 }) {
            let note = NSTextField(wrappingLabelWithString: line)
            note.font = MacTheme.Ramp.font(.panelFootnote)
            note.textColor = MacTheme.Color.tertiaryLabel
            column.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        let dismiss: @MainActor () -> Void = { [weak window, weak panel] in
            guard let panel else { return }
            if let window { window.endSheet(panel) } else { panel.orderOut(nil) }
        }
        let cancel = RowKit.ActionButton(title: Localized.text("Cancel")) {
            dismiss()
        }
        cancel.keyEquivalent = "\u{1b}"
        let confirm = RowKit.ActionButton(title: facts.confirmTitle) { [weak field] in
            let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let draft { DraftStore.clear(draft) }
            dismiss()
            onConfirm(text.isEmpty ? nil : text)
        }
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = "\r"

        let buttons = NSStackView(views: [RowKit.spacer(), cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
        guard let window else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        window.beginSheet(panel)
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
        label.font = MacTheme.Ramp.font(.sectionLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        return label
    }

    static func detailLabel(_ text: String, wraps: Bool = false) -> NSTextField {
        let label =
            wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.panelFootnote)
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
