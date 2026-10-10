import AppKit
import TailscodeCore

/// A pane that paints. It is not a second image surface: it is the Studio's Image lane at pane size —
/// the same stage, the same dock and a compact shelf strip, in the same workspace the panel uses — over
/// a studio of its own, so two panes and the panel never share a prompt and none can stop another's
/// render. The dividers resize it, zoom hides its siblings, and the layout snapshot restores that the
/// pane was a draw slot and which machine it painted on.
///
/// Closing the pane lets go of what it holds, including a render still out: a pane is a place to work
/// and there is nobody left to collect the picture.
@MainActor
final class DrawSlotView: NSView {
    private let studio: MacImageStudio
    private let lane: ImageLane
    private let workspace = StudioWorkspaceView(scoped: true)

    /// Told to the pane whenever the slot changes what it says about itself, so the identity strip and
    /// the persisted layout follow the machine rather than lag a state behind.
    var onChange: (() -> Void)?

    /// The strip of identity the pane floats over its top edge: the workspace leaves it clear.
    private static let identityClearance: CGFloat = 40

    init(endpoint: ImageGenEndpoint?) {
        studio = MacImageStudio(endpoint: endpoint)
        lane = ImageLane(studio: studio)
        super.init(frame: .zero)
        wantsLayer = true
        workspace.topPadding = Self.identityClearance
        workspace.translatesAutoresizingMaskIntoConstraints = false
        addSubview(workspace)
        NSLayoutConstraint.activate([
            workspace.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: trailingAnchor),
            workspace.topAnchor.constraint(equalTo: topAnchor),
            workspace.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        workspace.setLane(lane)
        workspace.onChange = { [weak self] change in
            guard change == .everything else { return }
            self?.onChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var endpoint: ImageGenEndpoint { studio.endpoint }

    /// What the identity strip says: the slot's own title — the words, or the engine while painting —
    /// and the machine that paints.
    var title: String { "\(studio.slot.title) · \(studio.endpoint.shortName)" }

    /// One line for the headless selftest: the phase and what the stage is holding.
    var summary: String {
        let phase: String
        switch studio.slot.phase {
        case .asking: phase = "asking"
        case .composing: phase = "composing"
        case .painting: phase = "painting"
        case .failed: phase = "failed"
        }
        return "draw \(phase) \(studio.endpoint.address) tiles=\(studio.slot.pictures.count)"
    }

    func point(at endpoint: ImageGenEndpoint) {
        studio.point(at: endpoint)
        onChange?()
    }

    func focusPrompt() {
        lane.dock.focusWords()
    }

    func shutdown() {
        studio.release()
    }
}
