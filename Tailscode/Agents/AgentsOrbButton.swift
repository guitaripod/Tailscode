import TailscodeCore
import UIKit

/// Home's one way to the agents: the presence orb worn as the bar's Agents button, always there and
/// always saying, in colour, motion and satellites, what every machine's agents are doing. A press
/// opens the wall full screen; a long press offers the board, and on an iPad that can hold several
/// windows the wall in a window of its own. Where Metal cannot draw the bead the button wears the
/// board's mark instead, so the way in never disappears.
@MainActor
final class AgentsOrbButton: UIButton {
    static let side: CGFloat = 36

    private let orb = PresenceOrbView()
    var onWall: (() -> Void)?
    var onBoard: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        if orb.isAvailable {
            orb.frame = bounds
            orb.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(orb)
        } else {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: AgentsPresenter.symbol)
            self.configuration = configuration
        }
        addAction(UIAction { [weak self] _ in self?.onWall?() }, for: .primaryActionTriggered)
        menu = UIMenu(children: menuActions())
        showsMenuAsPrimaryAction = false
        isPointerInteractionEnabled = true
        showsLargeContentViewer = true
        largeContentTitle = String(localized: "Agents")
        largeContentImage = UIImage(systemName: AgentsPresenter.symbol)
        addInteraction(UILargeContentViewerInteraction())
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Agents")
        accessibilityHint = String(localized: "Opens the agents wall")
        accessibilityValue = orb.signal.spoken
        accessibilityIdentifier = "home.agents"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Agents board")) { [weak self] _ in
                self?.onBoard?()
                return true
            }
        ]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let pressed = isHighlighted
            UIView.animate(
                withDuration: pressed ? 0.12 : 0.32, delay: 0, usingSpringWithDamping: 0.62,
                initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.orb.transform = pressed ? CGAffineTransform(scaleX: 0.84, y: 0.84) : .identity
            }
        }
    }

    func update(signal: PresenceSignal) {
        orb.update(signal: signal)
        accessibilityValue = signal.spoken
    }

    func setHeld(_ held: Bool) {
        orb.setHeld(held)
    }

    private func menuActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Agents board"), image: UIImage(systemName: AgentsPresenter.symbol)
            ) { [weak self] _ in self?.onBoard?() }
        ]
        if UIDevice.current.userInterfaceIdiom == .pad, UIApplication.shared.supportsMultipleScenes {
            actions.append(
                UIAction(
                    title: String(localized: "Open in New Window"),
                    image: UIImage(systemName: "macwindow.badge.plus")
                ) { _ in WatchScene.openWindow() })
        }
        return actions
    }
}
