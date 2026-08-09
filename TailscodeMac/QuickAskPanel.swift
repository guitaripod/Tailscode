import AppKit
import TailscodeCore

/// The quick-ask surface, drawn: one field, the aim it remembered, and nothing else. Enter is
/// the whole ceremony — the words go out as a new conversation with no project directory on the
/// server named in the popup, and the panel stays up only long enough for that server to answer,
/// so a failed mint keeps the question in hand rather than swallowing it. `QuickAskDefaults`
/// remembers where the last ask went.
@MainActor
final class QuickAskPanel: NSPanel {
    private(set) static weak var frontmost: QuickAskPanel?

    private let field = NSTextField()
    private let serverPopup = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let servers: [(profileID: String, name: String)]
    private var asking = false
    private let onAsk:
        (String, String, @escaping @MainActor (NewChatFailure?) -> Void) -> Void

    static func present(
        over window: NSWindow?, servers: [(profileID: String, name: String)],
        preferredServer: String?,
        onAsk: @escaping (String, String, @escaping @MainActor (NewChatFailure?) -> Void) -> Void
    ) {
        guard !servers.isEmpty else { return }
        frontmost?.close()
        let panel = QuickAskPanel(
            servers: servers, preferredServer: preferredServer, onAsk: onAsk)
        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
        frontmost = panel
    }

    private init(
        servers: [(profileID: String, name: String)], preferredServer: String?,
        onAsk: @escaping (String, String, @escaping @MainActor (NewChatFailure?) -> Void) -> Void
    ) {
        self.servers = servers
        self.onAsk = onAsk
        super.init(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = Localized.text("Quick ask")
        isFloatingPanel = true
        isReleasedWhenClosed = false

        field.placeholderString = Localized.text("Ask anything — no project, no setup")
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(submit)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

        let aimed = QuickAskDefaults.target(
            among: servers.map(\.profileID), fallback: preferredServer)
        for server in servers { serverPopup.addItem(withTitle: server.name) }
        if let index = servers.firstIndex(where: { $0.profileID == aimed }) {
            serverPopup.selectItem(at: index)
        }
        serverPopup.isHidden = servers.count < 2

        status.font = .systemFont(ofSize: 11)
        status.textColor = MacTheme.Color.secondaryLabel
        status.stringValue =
            servers.count < 2
            ? Localized.text("Asks %@ — enter sends, esc closes", servers[0].name)
            : Localized.text("Enter sends, esc closes")
        status.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [field, serverPopup, status])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        contentView = column
        setContentSize(column.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The panel outlives Enter the way the new-chat sheet outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words back.
    @objc private func submit() {
        guard !asking else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let index = max(0, serverPopup.indexOfSelectedItem)
        let server = servers[min(index, servers.count - 1)]
        asking = true
        field.isEnabled = false
        serverPopup.isEnabled = false
        status.stringValue = Localized.text("Asking %@…", server.name)
        onAsk(server.profileID, text) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                QuickAskDefaults.record(profileID: server.profileID)
                self.close()
                return
            }
            self.asking = false
            self.field.isEnabled = true
            self.serverPopup.isEnabled = true
            self.status.stringValue = "\(failure.title) — \(failure.detail)"
            self.makeFirstResponder(self.field)
        }
    }
}
