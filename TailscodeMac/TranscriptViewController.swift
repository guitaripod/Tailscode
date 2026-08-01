import AppKit
import CodingAgentKit
import TailscodeCore

/// The conversation, rendered the way a terminal agent renders it: the user's turn behind an
/// accent rule, the agent's answer as plain prose at full measure, and every tool call as one
/// dense line. No bubbles, no cards — the chrome around this view is where material lives.
@MainActor
final class TranscriptViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let statusLine = NSTextField(labelWithString: "")
    private let composer = ComposerView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var backend: (any CodingAgentBackend)?
    private var entry: SessionEntry?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = MacTheme.Color.canvas.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.m
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.xl,
            bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.xl)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        scrollView.contentView = clip
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = MacTheme.Font.mono(11)
        statusLine.textColor = MacTheme.Color.secondaryLabel
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.isHidden = true

        emptyLabel.stringValue = Localized.text("Pick a conversation")
        emptyLabel.font = MacTheme.Font.body()
        emptyLabel.textColor = MacTheme.Color.tertiaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.isHidden = true

        container.addSubview(scrollView)
        container.addSubview(statusLine)
        container.addSubview(composer)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -MacTheme.Spacing.s),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            statusLine.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: MacTheme.Spacing.xl),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -MacTheme.Spacing.s),

            composer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            composer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),
            composer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.l),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    func open(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        guard self.entry?.session.id != entry.session.id || self.entry?.profileID != entry.profileID
        else { return }
        streamTask?.cancel()
        self.entry = entry
        self.backend = backend
        emptyLabel.isHidden = true
        composer.isHidden = false
        render(ConversationState())

        let conversation = AgentConversation(
            backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
        self.conversation = conversation
        streamTask = Task { [weak self] in
            for await state in await conversation.states() {
                guard !Task.isCancelled else { return }
                self?.render(state)
            }
        }
    }

    /// Re-dials without disturbing the stream — the socket a sleeping Mac wakes up holding looks
    /// alive and delivers nothing.
    func reconnect() {
        guard let conversation else { return }
        Task { await conversation.reconnect() }
    }

    private func send(_ text: String) {
        guard let conversation else { return }
        Task {
            do {
                try await conversation.send(text)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func render(_ state: ConversationState) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for message in state.messages {
            for row in TranscriptRow.rows(for: message) {
                stack.addArrangedSubview(row.makeView(width: view.bounds.width))
            }
        }
        composer.setBusy(state.status == .running)
        statusLine.isHidden = state.status != .running
        statusLine.stringValue = Localized.text("Working…")
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let documentView = scrollView.documentView else { return }
        DispatchQueue.main.async {
            documentView.scroll(NSPoint(x: 0, y: max(0, documentView.bounds.height)))
        }
    }
}

/// A clip view whose origin is the top, so a transcript grows downwards like a terminal instead of
/// upwards like a default AppKit document.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
