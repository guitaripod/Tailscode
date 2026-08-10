import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The quick-ask surface, drawn: one field, the aim it remembered, and nothing else. Enter is
/// the whole ceremony — the words go out as a new conversation with no project directory on the
/// server named in the popup, and the panel stays up only long enough for that server to answer,
/// so a failed mint keeps the question in hand rather than swallowing it. The aim is both halves
/// and both are the quick ask's own: `QuickAskDefaults` remembers where the last ask went and
/// which model answered it, per server and beside the composer's memory rather than inside it.
@MainActor
final class QuickAskPanel: NSPanel {
    private(set) static weak var frontmost: QuickAskPanel?

    private let field = NSTextField()
    private let serverPopup = NSPopUpButton()
    private let modelButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let servers: [ConnectionProfile]
    private var asking = false
    private let onAsk:
        (String, String, @escaping @MainActor (NewChatFailure?) -> Void) -> Void

    static func present(
        over window: NSWindow?, servers: [ConnectionProfile], preferredServer: String?,
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
        servers: [ConnectionProfile], preferredServer: String?,
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
            among: servers.map(\.id), fallback: preferredServer)
        for server in servers { serverPopup.addItem(withTitle: server.name) }
        if let index = servers.firstIndex(where: { $0.id == aimed }) {
            serverPopup.selectItem(at: index)
        }
        serverPopup.isHidden = servers.count < 2
        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)

        modelButton.bezelStyle = .rounded
        modelButton.controlSize = .small
        modelButton.target = self
        modelButton.action = #selector(chooseModel)

        status.font = .systemFont(ofSize: 11)
        status.textColor = MacTheme.Color.secondaryLabel
        status.lineBreakMode = .byTruncatingTail

        let aim = NSStackView(views: [serverPopup, modelButton])
        aim.orientation = .horizontal
        aim.spacing = 8
        let column = NSStackView(views: [field, aim, status])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        contentView = column
        refreshAim()
        setContentSize(column.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private var targetServer: ConnectionProfile {
        servers[min(max(0, serverPopup.indexOfSelectedItem), servers.count - 1)]
    }

    @objc private func serverChanged() {
        refreshAim()
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat.
    @objc private func chooseModel() {
        let server = targetServer
        ModelChooserSheet.present(
            on: self, models: ModelCatalogStore.cached(server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id),
            allowsServerDefault: server.backend == .claudeCode
        ) { [weak self] selection in
            QuickAskDefaults.recordModel(selection, forProfileID: server.id)
            self?.refreshAim()
        }
    }

    /// The button names what the question will actually run on, and the line under it says how
    /// to send — with one server that line also names the machine, which the hidden popup no
    /// longer can.
    private func refreshAim() {
        let server = targetServer
        modelButton.title = ModelBadge.label(
            model: QuickAskDefaults.model(forProfileID: server.id),
            effort: QuickAskDefaults.effort(forProfileID: server.id))
        modelButton.isHidden = ModelCatalogStore.cached(server.id).isEmpty
        guard !asking else { return }
        status.stringValue =
            servers.count < 2
            ? Localized.text("Asks %@ — enter sends, esc closes", server.name)
            : Localized.text("Enter sends, esc closes")
    }

    /// The panel outlives Enter the way the new-chat sheet outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words back.
    @objc private func submit() {
        guard !asking else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let server = targetServer
        asking = true
        field.isEnabled = false
        serverPopup.isEnabled = false
        modelButton.isEnabled = false
        status.stringValue = Localized.text("Asking %@…", server.name)
        onAsk(server.id, text) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                QuickAskDefaults.record(profileID: server.id)
                self.close()
                return
            }
            self.asking = false
            self.field.isEnabled = true
            self.serverPopup.isEnabled = true
            self.modelButton.isEnabled = true
            self.status.stringValue = "\(failure.title) — \(failure.detail)"
            self.makeFirstResponder(self.field)
        }
    }
}
