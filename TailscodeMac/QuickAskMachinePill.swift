import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Which machine the question goes to, as one pill under the question: the machine and the agent
/// that answers there, and a press for the list of the others. Tab still walks them without a
/// press; the pill only states the aim and offers the rest. It is the chat's own chip, so it has
/// the dial's height, capsule, type and baseline beside it rather than AppKit's push-button bezel.
@MainActor
final class QuickAskMachinePill: NSView {
    var onPick: ((String) -> Void)?
    private var servers: [ConnectionProfile]
    private let button = SymbolChip()
    private var selected: String?

    init(servers: [ConnectionProfile]) {
        self.servers = servers
        super.init(frame: .zero)
        button.symbol = "desktopcomputer"
        button.target = self
        button.action = #selector(showMachines)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshEnabled()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isEnabled: Bool = true {
        didSet { refreshEnabled() }
    }

    var title: String { button.text }

    /// The machines a summon offers, which can differ from the last summon's.
    func reload(servers: [ConnectionProfile]) {
        self.servers = servers
        refreshEnabled()
    }

    func select(id: String) {
        selected = id
        guard let server = servers.first(where: { $0.id == id }) else { return }
        button.text = ServerLabel.display(name: server.name, backend: server.backend)
        button.setAccessibilityLabel(button.text)
        button.toolTip = ServerLabel.address(server)
    }

    /// A pill held while a question is out offers nothing, and says so by fading, since a chip
    /// draws no disabled face of its own. With one machine behind it the press still answers,
    /// with that one machine ticked and its address beside it.
    private func refreshEnabled() {
        button.isEnabled = isEnabled
        button.alphaValue = isEnabled ? 1 : QuickAskPanel.heldAlpha
    }

    @objc private func showMachines() {
        let menu = NSMenu()
        for server in servers {
            let id = server.id
            let item = ClosureMenuItem(
                title: ServerLabel.display(name: server.name, backend: server.backend)
            ) { [weak self] in
                self?.onPick?(id)
            }
            item.image = NSImage(
                systemSymbolName: MacTheme.brandSymbol(server.backend), accessibilityDescription: nil)
            item.toolTip = ServerLabel.address(server)
            item.state = id == selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}
