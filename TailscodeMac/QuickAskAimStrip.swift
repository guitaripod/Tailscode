import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Every machine the question could go to, as one control: segments while the fleet fits in a
/// row, each named and wearing its agent's symbol with the agent's name a tooltip away, and one
/// popup past that — a list is a single click either way, never a chip that only shows its
/// border on hover. The strip states the aim; the panel decides it.
@MainActor
final class QuickAskAimStrip: NSView {
    var onPick: ((String) -> Void)?
    private let ids: [String]
    private let segments: NSSegmentedControl?
    private let popup: NSPopUpButton?

    private static let segmentCeiling = 5

    init(servers: [ConnectionProfile]) {
        ids = servers.map(\.id)
        if servers.count <= Self.segmentCeiling {
            let control = NSSegmentedControl(
                labels: servers.map(\.name), trackingMode: .selectOne, target: nil, action: nil)
            control.controlSize = .small
            control.segmentStyle = .rounded
            control.segmentDistribution = .fit
            for (index, server) in servers.enumerated() {
                control.setImage(Self.symbol(for: server.backend), forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
                control.setToolTip(
                    ServerLabel.agent(server.backend) + " · " + ServerLabel.address(server),
                    forSegment: index)
            }
            segments = control
            popup = nil
        } else {
            let control = NSPopUpButton()
            control.controlSize = .small
            for server in servers {
                control.addItem(withTitle: ServerLabel.display(name: server.name, backend: server.backend))
                control.lastItem?.image = Self.symbol(for: server.backend)
                control.lastItem?.toolTip = ServerLabel.address(server)
            }
            segments = nil
            popup = control
        }
        super.init(frame: .zero)
        let control: NSControl = segments ?? popup!
        control.target = self
        control.action = #selector(picked)
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isEnabled: Bool = true {
        didSet {
            segments?.isEnabled = isEnabled
            popup?.isEnabled = isEnabled
        }
    }

    func select(id: String) {
        guard let index = ids.firstIndex(of: id) else { return }
        segments?.selectedSegment = index
        popup?.selectItem(at: index)
    }

    @objc private func picked() {
        let index = segments?.selectedSegment ?? popup?.indexOfSelectedItem ?? -1
        guard ids.indices.contains(index) else { return }
        onPick?(ids[index])
    }

    private static func symbol(for agent: AgentType) -> NSImage? {
        NSImage(systemSymbolName: MacTheme.brandSymbol(agent), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    }
}
