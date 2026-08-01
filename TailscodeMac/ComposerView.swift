import AppKit
import TailscodeCore

/// Type, ⌘↩ to send. Return makes a newline, because a desktop prompt is written rather than
/// dashed off, and a turn already running takes the next message as a queued follow-up rather
/// than refusing it.
@MainActor
final class ComposerView: NSView {
    var onSend: ((String) -> Void)?

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let sendButton = NSButton()
    private var busy = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.borderWidth = 1
        layer?.borderColor = MacTheme.Color.separator.cgColor

        textView.isRichText = false
        textView.font = MacTheme.Font.body()
        textView.textContainerInset = NSSize(width: MacTheme.Spacing.s, height: MacTheme.Spacing.s)
        textView.drawsBackground = false
        textView.delegate = self
        textView.isAutomaticQuoteSubstitutionEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        sendButton.title = Localized.text("Send")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(sendButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(
                equalTo: sendButton.leadingAnchor, constant: -MacTheme.Spacing.s),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setBusy(_ value: Bool) {
        busy = value
        sendButton.title = value ? Localized.text("Queue") : Localized.text("Send")
    }

    @objc private func sendTapped() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        onSend?(text)
    }
}

extension ComposerView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        false
    }
}
